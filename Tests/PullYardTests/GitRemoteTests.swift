import XCTest
@testable import PullYard

final class GitRemoteTests: XCTestCase {
    func testParsesCommonURLForms() {
        XCTAssertEqual(GitRemote.parse("git@github.com:acme/app.git\n"), GitRemote(host: "github.com", path: "acme/app"))
        XCTAssertEqual(GitRemote.parse("https://github.com/acme/app"), GitRemote(host: "github.com", path: "acme/app"))
        XCTAssertEqual(GitRemote.parse("https://user@gitlab.example.com:8443/group/sub/app.git"), GitRemote(host: "gitlab.example.com", path: "group/sub/app"))
        XCTAssertEqual(GitRemote.parse("ssh://git@bitbucket.org/team/app.git"), GitRemote(host: "bitbucket.org", path: "team/app"))
        XCTAssertNil(GitRemote.parse(""))
        XCTAssertNil(GitRemote.parse("/local/path/repo.git"))
        XCTAssertNil(GitRemote.parse("https://github.com/only-owner"))
    }

    func testOnlyGitHubDotComYieldsRepoRef() {
        XCTAssertEqual(GitRemote.parse("git@github.com:acme/app.git")?.githubRepo?.full, "acme/app")
        XCTAssertNil(GitRemote.parse("git@gitlab.com:acme/app.git")?.githubRepo)
    }

    func testKindAndNewRequestURL() {
        let lab = GitRemote(host: "gitlab.com", path: "acme/app")
        XCTAssertEqual(lab.kind, .gitlab)
        XCTAssertEqual(lab.newRequestURL(branch: "feat/x", kind: lab.kind), "https://gitlab.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/x")
        let bb = GitRemote(host: "bitbucket.org", path: "team/app")
        XCTAssertEqual(bb.newRequestURL(branch: "a&b", kind: bb.kind), "https://bitbucket.org/team/app/pull-requests/new?source=a%26b")
        let own = GitRemote(host: "git.example.com", path: "acme/app")
        XCTAssertEqual(own.kind, .other)
        XCTAssertEqual(own.kind(for: .gitlab), .gitlab)
        XCTAssertEqual(own.newRequestURL(branch: "x", kind: .other), "https://git.example.com/acme/app/pulls")
    }

    func testOpenPromptMatchesHost() {
        XCTAssertTrue(AgentShip.openPRPrompt(branch: "feat/x", defaultBranch: "main", hasChanges: true, ahead: 0).contains("gh pr create"))
        let lab = AgentShip.openPRPrompt(branch: "feat/x", defaultBranch: "main", hasChanges: true, ahead: 0, remote: GitRemote(host: "gitlab.com", path: "acme/app"))
        XCTAssertTrue(lab.contains("glab mr create"))
        XCTAssertFalse(lab.contains("gh pr create"))
        XCTAssertEqual(AgentShip.pullRequestURL(in: "done: https://gitlab.com/group/sub/app/-/merge_requests/12 ok"), "https://gitlab.com/group/sub/app/-/merge_requests/12")
        XCTAssertEqual(AgentShip.pullRequestURL(in: "https://github.com/acme/app/pull/7"), "https://github.com/acme/app/pull/7")
    }
}
