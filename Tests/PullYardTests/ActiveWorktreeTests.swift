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
