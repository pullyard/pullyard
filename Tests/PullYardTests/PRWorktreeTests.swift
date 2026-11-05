import XCTest
@testable import PullYard

final class PRWorktreeTests: XCTestCase {
    private var root: URL!
    private var origin: String { root.appendingPathComponent("o/r").path }
    private var clone: String { root.appendingPathComponent("work/r").path }
    private let repo = RepoRef(owner: "o", name: "r")

    private func git(_ args: [String], in dir: String) throws -> String {
        try PRWorktrees.git(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root.appendingPathComponent("work").path, withIntermediateDirectories: true)
        try git(["init", "--quiet", "-b", "main"], in: origin)
        try "a".write(toFile: origin + "/a.txt", atomically: true, encoding: .utf8)
        try git(["add", "."], in: origin)
        try git(["commit", "--quiet", "-m", "base"], in: origin)
        try git(["checkout", "--quiet", "-b", "feature"], in: origin)
        try "b".write(toFile: origin + "/b.txt", atomically: true, encoding: .utf8)
        try git(["add", "."], in: origin)
        try git(["commit", "--quiet", "-m", "pr"], in: origin)
        try git(["update-ref", "refs/pull/7/head", "feature"], in: origin)
        try git(["checkout", "--quiet", "main"], in: origin)
        try git(["clone", "--quiet", origin, clone], in: root.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesWorktreeAtPRHeadWithoutTouchingClone() throws {
        let wt = try PRWorktrees.prepare(clone: clone, repo: repo, number: 7)
        XCTAssertEqual(wt.path, root.appendingPathComponent("work/r-worktrees/pr-7").standardizedFileURL.path)
        XCTAssertEqual(wt.remote, "origin")
        XCTAssertFalse(wt.reused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path + "/b.txt"))
        XCTAssertEqual(wt.headOid, try git(["rev-parse", "feature"], in: origin))
        XCTAssertEqual(try git(["branch", "--show-current"], in: wt.path), "pullyard/pr-7")
        XCTAssertEqual(try git(["branch", "--show-current"], in: clone), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone + "/b.txt"))
        XCTAssertEqual(PRWorktrees.existing(clone: clone, number: 7), wt.path)
    }

    func testReuseUpdatesCleanWorktreeAndKeepsDirtyOne() throws {
        _ = try PRWorktrees.prepare(clone: clone, repo: repo, number: 7)
        try git(["checkout", "--quiet", "feature"], in: origin)
        try "c".write(toFile: origin + "/c.txt", atomically: true, encoding: .utf8)
        try git(["add", "."], in: origin)
        try git(["commit", "--quiet", "-m", "more"], in: origin)
        try git(["update-ref", "refs/pull/7/head", "feature"], in: origin)
        let updated = try PRWorktrees.prepare(clone: clone, repo: repo, number: 7)
        XCTAssertTrue(updated.reused)
        XCTAssertFalse(updated.dirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.path + "/c.txt"))

        try "local".write(toFile: updated.path + "/b.txt", atomically: true, encoding: .utf8)
        let dirty = try PRWorktrees.prepare(clone: clone, repo: repo, number: 7)
        XCTAssertTrue(dirty.dirty)
        XCTAssertEqual(try String(contentsOfFile: dirty.path + "/b.txt", encoding: .utf8), "local")
        XCTAssertThrowsError(try PRWorktrees.remove(clone: clone, number: 7))

        try git(["checkout", "--quiet", "--", "b.txt"], in: dirty.path)
        try PRWorktrees.remove(clone: clone, number: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirty.path))
        XCTAssertNil(PRWorktrees.existing(clone: clone, number: 7))
        XCTAssertFalse(try git(["branch", "--list"], in: clone).contains("pullyard/pr-7"))
    }

    func testMissingPullRefFails() {
        XCTAssertThrowsError(try PRWorktrees.prepare(clone: clone, repo: repo, number: 99))
    }

    func testRemoteMatching() {
        let remotes = "fork\tgit@github.com:me/r.git (fetch)\nupstream\thttps://github.com/O/R.git (fetch)\n"
        XCTAssertEqual(PRWorktrees.remote(for: repo, remotes: remotes), "upstream")
        XCTAssertNil(PRWorktrees.remote(for: RepoRef(owner: "x", name: "y"), remotes: remotes))
    }

    func testPromptAdaptation() throws {
        let json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "feature", "baseRefName": "main", "headRefOid": "abc",
            "headRepository": ["nameWithOwner": "o/r"], "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []], "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": []], "allCommits": ["nodes": []], "timelineItems": ["nodes": []], "reviewThreads": ["nodes": []]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
        let wt = PRWorktree(path: "/tmp/r-worktrees/pr-7", branch: "pullyard/pr-7", remote: "upstream", headOid: "abcdef1234567890", reused: false, dirty: false)
        let prompt = FixPrompt.build(pr: pr, repo: repo, threads: [], general: [], options: FixOptions(commit: true, push: true, replyAndResolve: false))
        let adapted = PRWorktrees.adapt(prompt, worktree: wt, pr: pr, repo: repo)
        XCTAssertFalse(adapted.contains(FixPrompt.checkoutStep(7)))
        XCTAssertTrue(adapted.contains("isolated git worktree at /tmp/r-worktrees/pr-7"))
        XCTAssertTrue(adapted.contains("`git push upstream HEAD:feature`"))
        let other = PRWorktrees.adapt("Custom prompt", worktree: wt, pr: pr, repo: RepoRef(owner: "up", name: "r"))
        XCTAssertTrue(other.hasPrefix("You are working in an isolated git worktree"))
        let fork = PRWorktrees.adapt(prompt, worktree: wt, pr: pr, repo: RepoRef(owner: "up", name: "r"))
        XCTAssertTrue(fork.contains("ask me before pushing: this pull request's branch lives in the fork o/r"))
        let conflicts = PRWorktrees.adapt(ConflictPrompt.build(pr: pr, repo: repo, files: ["a"], push: true), worktree: wt, pr: pr, repo: repo)
        XCTAssertFalse(conflicts.contains(FixPrompt.checkoutStep(7)))
        XCTAssertTrue(conflicts.contains("isolated git worktree"))
    }
}
