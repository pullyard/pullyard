import XCTest
@testable import PullYard

final class SessionTreeTests: XCTestCase {
    private func s(_ id: String, parent: String? = nil, ago: Double) -> ClaudeSessionInfo {
        var info = ClaudeSessionInfo(id: id, file: URL(fileURLWithPath: "/tmp/\(id).jsonl"), cwd: "/repo", title: id, branch: nil, modified: Date(timeIntervalSince1970: 1_000_000 - ago), prURL: nil, prNumber: nil, model: nil, linesAdded: nil, linesRemoved: nil)
        info.parentId = parent
        return info
    }

    func testChildrenNestUnderParentAndBumpIt() {
        let nodes = SessionTree.build([s("a", ago: 10), s("b", ago: 50), s("c", parent: "b", ago: 1), s("d", parent: "missing", ago: 5)])
        XCTAssertEqual(nodes.map(\.id), ["b", "d", "a"])
        XCTAssertEqual(nodes.first?.children.map(\.id), ["c"])
    }

    func testDesktopIndexMapsLocalParentsToCliIds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parent: [String: Any] = ["sessionId": "local_p", "cliSessionId": "cli-p", "title": "Parent"]
        let child: [String: Any] = ["sessionId": "local_c", "cliSessionId": "cli-c", "title": "Child", "isArchived": true, "spawnedFrom": ["sessionId": "local_p"]]
        try JSONSerialization.data(withJSONObject: parent).write(to: dir.appendingPathComponent("local_p.json"))
        try JSONSerialization.data(withJSONObject: child).write(to: dir.appendingPathComponent("local_c.json"))
        let index = DesktopSessionIndex.load(directory: root)
        XCTAssertEqual(index["cli-c"]?.parent, "cli-p")
        XCTAssertEqual(index["cli-c"]?.archived, true)
        XCTAssertNil(index["cli-p"]?.parent)
        XCTAssertEqual(index["cli-p"]?.title, "Parent")
    }

    @MainActor
    func testInterruptedBecomesNotice() {
        if case .notice(_, let text, _)? = ChatSession.historyUserItem(id: "1", text: "[Request interrupted by user for tool use]") {
            XCTAssertEqual(text, "Interrupted")
        } else {
            XCTFail()
        }
        XCTAssertNil(ChatSession.historyUserItem(id: "2", text: "<system-reminder>x</system-reminder>"))
        if case .user(_, let text, _)? = ChatSession.historyUserItem(id: "3", text: "hi <system-reminder>secret</system-reminder>") {
            XCTAssertEqual(text, "hi")
        } else {
            XCTFail()
        }
    }
}
