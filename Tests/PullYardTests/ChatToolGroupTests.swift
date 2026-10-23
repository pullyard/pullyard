import XCTest
@testable import PullYard

final class ChatToolGroupTests: XCTestCase {
    private func call(_ id: String, _ name: String) -> ChatToolCall {
        ChatToolCall(id: id, name: name)
    }

    func testConsecutiveToolsGroupTogether() {
        let items: [ChatItem] = [
            .user(id: "1", text: "go", images: []),
            .tool(call("a", "Bash")),
            .thinking(ChatText(id: "k", text: "hmm")),
            .tool(call("b", "Read")),
            .text(ChatText(id: "t", text: "done")),
            .tool(call("c", "Bash")),
        ]
        let built = ChatDisplayItem.build(items)
        XCTAssertEqual(built.map(\.id), ["u1", "ga", "tt", "gc"])
        if case .tools(_, let steps) = built[1] { XCTAssertEqual(steps.map(\.id), ["a", "kk", "b"]) } else { XCTFail() }
    }

    func testTodoAndPendingPermissionStayStandalone() {
        let pending = call("p", "Bash")
        pending.permission = PermissionRequest(id: "r", toolName: "Bash", input: [:], description: nil, blockedPath: nil, suggestions: [], toolUseId: "p")
        let built = ChatDisplayItem.build([.tool(call("a", "Bash")), .tool(call("todo", "TodoWrite")), .tool(pending)])
        XCTAssertEqual(built.map(\.id), ["ga", "ctodo", "cp"])
    }

    func testLabelCountsKinds() {
        let calls = [call("1", "Bash"), call("2", "Bash"), call("3", "Read"), call("4", "Edit")]
        XCTAssertEqual(ToolGrouping.label(calls), "Ran 2 commands, read 1 file, edited 1 file")
        XCTAssertEqual(ToolGrouping.label([call("1", "Bash")]), "Ran 1 command")
    }

    func testBashTitleUsesDescription() {
        let c = call("1", "Bash")
        c.input = ["command": "sed -n 1,2p a.swift", "description": "Read form state"]
        XCTAssertEqual(ToolGrouping.title(c, folder: "/x"), "Read form state")
        c.input = ["command": "ls\npwd"]
        XCTAssertEqual(ToolGrouping.title(c, folder: "/x"), "ls")
    }
}

extension ChatToolGroupTests {
    func testThinkingBeforeAnyToolStaysStandalone() {
        let built = ChatDisplayItem.build([.thinking(ChatText(id: "k", text: "plan")), .text(ChatText(id: "t", text: "hi"))])
        XCTAssertEqual(built.map(\.id), ["kk", "tt"])
    }
}
