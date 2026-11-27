import XCTest
@testable import PullYard

final class ActiveWorktreeTests: XCTestCase {
    func testDirectoryFromShellCommands() {
        XCTAssertEqual(ActiveWorktree.directory(in: "cd ../kr-mobile-app-KRIS-721 && git status"), "../kr-mobile-app-KRIS-721")
        XCTAssertEqual(ActiveWorktree.directory(in: "git -C ../kr-mobile-app-KRIS-721 diff"), "../kr-mobile-app-KRIS-721")
        XCTAssertEqual(ActiveWorktree.directory(in: "cd \"/Users/me/My Repo\" && ls"), "/Users/me/My Repo")
        XCTAssertEqual(ActiveWorktree.directory(in: "cd /a && git -C /b log"), "/b")
        XCTAssertNil(ActiveWorktree.directory(in: "flutter test"))
        XCTAssertNil(ActiveWorktree.directory(in: "cd -"))
    }

    func testLatestPathPrefersNewestCall() {
        let calls: [(name: String, input: [String: Any])] = [
            ("Edit", ["file_path": "/repo/lib/a.dart"]),
            ("Bash", ["command": "git -C ../repo-KRIS-721 status"]),
            ("Bash", ["command": "flutter analyze"]),
        ]
        XCTAssertEqual(ActiveWorktree.latestPath(in: calls, base: "/work/repo"), "/work/repo-KRIS-721")
        XCTAssertEqual(ActiveWorktree.latestPath(in: Array(calls.prefix(1)), base: "/work/repo"), "/repo/lib/a.dart")
        XCTAssertNil(ActiveWorktree.latestPath(in: [("Bash", ["command": "ls"])], base: "/work/repo"))
    }
}

final class GitWorktreeEntryTests: XCTestCase {
    func testParsePorcelain() {
        let out = """
        worktree /repo
        HEAD abc
        branch refs/heads/dev

        worktree /repo/.claude/worktrees/fix-1
        HEAD def
        branch refs/heads/claude/fix-1

        worktree /repo/.claude/worktrees/detached
        HEAD 123
        detached

        """
        let e = GitWorktreeEntry.parse(out)
        XCTAssertEqual(e.map(\.path), ["/repo", "/repo/.claude/worktrees/fix-1", "/repo/.claude/worktrees/detached"])
        XCTAssertEqual(e.map(\.branch), ["dev", "claude/fix-1", nil])
        XCTAssertEqual(e.map(\.isMain), [true, false, false])
        XCTAssertEqual(e[1].name, "fix-1")
    }

    func testInstructionNamesWorktree() {
        let w = GitWorktreeEntry(path: "/repo/wt", branch: "feat", isMain: false)
        let text = ActiveWorktree.instruction(for: w, sessionFolder: "/repo")
        XCTAssertTrue(text.contains("/repo/wt"))
        XCTAssertTrue(text.contains("feat"))
    }
}
