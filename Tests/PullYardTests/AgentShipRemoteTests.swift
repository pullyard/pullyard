import XCTest
@testable import PullYard

final class AgentShipRemoteTests: XCTestCase {
    func testParsesRemotes() {
        let gh = GitRemote.parse("git@github.com:pullyard/pullyard.git\n")
        XCTAssertEqual(gh, GitRemote(host: "github.com", path: "pullyard/pullyard", kind: .github))
        XCTAssertEqual(gh?.githubRepo?.full, "pullyard/pullyard")
        XCTAssertEqual(GitRemote.parse("https://github.com/o/r")?.kind, .github)
        XCTAssertEqual(GitRemote.parse("ssh://git@ssh.github.com:443/o/r.git")?.host, "github.com")

        let lab = GitRemote.parse("git@gitlab.example.com:group/sub/app.git")
        XCTAssertEqual(lab, GitRemote(host: "gitlab.example.com", path: "group/sub/app", kind: .gitlab))
        XCTAssertNil(lab?.githubRepo)
        XCTAssertEqual(GitRemote.parse("https://gitlab.com/group/app.git/")?.path, "group/app")

        XCTAssertEqual(GitRemote.parse("https://sofia@bitbucket.org/acme/api.git"), GitRemote(host: "bitbucket.org", path: "acme/api", kind: .bitbucket))
        XCTAssertEqual(GitRemote.parse("git@bitbucket.org:acme/api.git")?.kind, .bitbucket)
        XCTAssertEqual(GitRemote.parse("https://git.example.com/team/app.git")?.kind, .other)
        XCTAssertNil(GitRemote.parse(""))
        XCTAssertNil(GitRemote.parse("/Users/me/repo"))
    }

    func testNewRequestLinks() {
        XCTAssertEqual(GitRemote(host: "github.com", path: "o/r", kind: .github).newRequestURL(branch: "feat/x"), "https://github.com/o/r/pull/new/feat/x")
        XCTAssertEqual(GitRemote(host: "gitlab.com", path: "g/a", kind: .gitlab).newRequestURL(branch: "fix"), "https://gitlab.com/g/a/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix")
        XCTAssertEqual(GitRemote(host: "bitbucket.org", path: "acme/api", kind: .bitbucket).newRequestURL(branch: "fix"), "https://bitbucket.org/acme/api/pull-requests/new?source=fix")
    }

    func testPromptsFollowTheHost() {
        let github = AgentShip.openPRPrompt(branch: "feat", defaultBranch: "main", hasChanges: true, ahead: 0)
        XCTAssertTrue(github.contains("gh pr create"))
        XCTAssertTrue(github.hasPrefix("Open a pull request"))

        let gitlab = AgentShip.openPRPrompt(branch: "feat", defaultBranch: "main", hasChanges: false, ahead: 2, remote: GitRemote(host: "gitlab.com", path: "g/a", kind: .gitlab))
        XCTAssertTrue(gitlab.hasPrefix("Open a merge request"))
        XCTAssertTrue(gitlab.contains("glab mr create"))
        XCTAssertTrue(gitlab.contains("merge_request.create"))
        XCTAssertTrue(gitlab.contains("into main"))
        XCTAssertFalse(gitlab.contains("gh pr create"))

        let bitbucket = AgentShip.openPRPrompt(branch: "feat", defaultBranch: nil, hasChanges: false, ahead: 1, remote: GitRemote(host: "bitbucket.org", path: "acme/api", kind: .bitbucket))
        XCTAssertTrue(bitbucket.contains("https://bitbucket.org/acme/api/pull-requests/new?source=feat"))
        XCTAssertFalse(bitbucket.contains("gh pr create"))

        let onDefault = AgentShip.openPRPrompt(branch: "main", defaultBranch: "main", hasChanges: true, ahead: 0, remote: GitRemote(host: "git.example.com", path: "t/a", kind: .other))
        XCTAssertTrue(onDefault.contains("Create a new branch"))
        XCTAssertTrue(onDefault.contains("link to create a pull request"))
    }

    func testDetectsCreatedRequests() {
        XCTAssertEqual(AgentShip.pullRequestURL(in: "Done:\nhttps://github.com/o/r/pull/12\n"), "https://github.com/o/r/pull/12")
        XCTAssertEqual(AgentShip.pullRequestURL(in: "remote: View merge request:\nremote:   https://gitlab.com/group/sub/app/-/merge_requests/7 \n"), "https://gitlab.com/group/sub/app/-/merge_requests/7")
        XCTAssertEqual(AgentShip.pullRequestURL(in: "https://bitbucket.org/acme/api/pull-requests/5"), "https://bitbucket.org/acme/api/pull-requests/5")
        XCTAssertNil(AgentShip.pullRequestURL(in: "https://bitbucket.org/acme/api/pull-requests/new?source=feat"))
        XCTAssertEqual(AgentShip.describe("https://gitlab.com/group/sub/app/-/merge_requests/7"), AgentShip.CreatedRequest(repo: "group/sub/app", number: "7", mergeRequest: true))
        XCTAssertEqual(AgentShip.describe("https://github.com/o/r/pull/12").title, "Pull request #12 is open")
        XCTAssertEqual(AgentShip.describe("https://gitlab.com/g/a/-/merge_requests/3").title, "Merge request !3 is open")
        XCTAssertTrue(AgentShip.createCommands.contains { "git push -u origin HEAD -o merge_request.create".contains($0) })
    }
}
