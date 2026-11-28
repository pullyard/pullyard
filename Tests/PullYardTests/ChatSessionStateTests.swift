import XCTest
@testable import PullYard

@MainActor
final class ChatSessionStateTests: XCTestCase {
    private func chat() -> ChatSession { ChatSession(folder: NSTemporaryDirectory(), configDir: nil) }

    private func call(_ name: String, status: ChatToolCall.Status, backgrounded: Bool = false, taskStatus: String? = nil) -> ChatToolCall {
        let c = ChatToolCall(id: UUID().uuidString, name: name)
        c.status = status
        c.backgrounded = backgrounded
        c.taskStatus = taskStatus
        return c
    }

    func testBackgroundCommandCountsAsRunningAfterTheTurn() {
        let s = chat()
        XCTAssertFalse(s.hasRunningTasks)
        s.items.append(.tool(call("Bash", status: .done, backgrounded: true)))
        XCTAssertTrue(s.hasRunningTasks, "a backgrounded build keeps the session working")
    }

    func testFinishedAndNonTaskToolsDoNotCount() {
        let s = chat()
        s.items.append(.tool(call("Bash", status: .done)))
        s.items.append(.tool(call("Bash", status: .done, backgrounded: true, taskStatus: "completed")))
        s.items.append(.tool(call("Read", status: .running)))
        XCTAssertFalse(s.hasRunningTasks)
    }

    func testFirstMessageGoesToWorktreeHookInsteadOfBeingSent() {
        let s = chat()
        s.worktreeAvailable = true
        s.useWorktree = true
        var moved: String?
        var titled: String?
        s.onWorktreeSend = { text, _ in moved = text }
        s.onFirstPrompt = { titled = $0 }
        s.send("  second test  ")
        XCTAssertEqual(moved, "second test")
        XCTAssertNil(titled)
        XCTAssertTrue(s.items.isEmpty, "the message is sent from the worktree session instead")
    }

    func testFirstMessageIsTitledOnceWithoutWorktree() {
        let s = chat()
        s.worktreeAvailable = true
        s.useWorktree = false
        var titles: [String] = []
        s.onWorktreeSend = { _, _ in XCTFail("worktree unticked") }
        s.onFirstPrompt = { titles.append($0) }
        s.send("first")
        s.send("second")
        XCTAssertEqual(titles, ["first"])
        XCTAssertEqual(s.items.count, 2)
    }
}
