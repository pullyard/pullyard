import XCTest
@testable import PullYard

@MainActor
final class ChatProtocolTests: XCTestCase {
    private var sent: [[String: Any]] = []

    private func makeSession(delivers: Bool = true) -> ChatSession {
        let chat = ChatSession(folder: "/tmp", configDir: nil)
        chat.running = true
        chat.transport = { [unowned self] obj in
            sent.append(obj)
            return delivers
        }
        return chat
    }

    private func lastRequestID() -> String {
        sent.last?["request_id"] as? String ?? ""
    }

    func testInitSetsSessionModelAndMode() {
        let chat = makeSession()
        var reported: String?
        chat.onSessionId = { reported = $0 }
        chat.handle(["type": "system", "subtype": "init", "session_id": "s1", "model": "claude-opus", "permissionMode": "plan"])
        XCTAssertEqual(chat.sessionId, "s1")
        XCTAssertEqual(reported, "s1")
        XCTAssertEqual(chat.model, "claude-opus")
        XCTAssertEqual(chat.permissionMode, "plan")
    }

    func testCostIsCumulativePerProcess() {
        let chat = makeSession()
        chat.handle(["type": "result", "total_cost_usd": 0.10])
        chat.handle(["type": "result", "total_cost_usd": 0.25])
        XCTAssertEqual(chat.totalCost, 0.25, accuracy: 0.0001)
    }

    func testResultEndsTurnAndNotifies() {
        let chat = makeSession()
        var finished = 0
        chat.onTurnFinished = { finished += 1 }
        chat.send("hello")
        XCTAssertTrue(chat.busy)
        chat.handle(["type": "result", "total_cost_usd": 0.01])
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(finished, 1)
    }

    func testRejectedModelChangeRollsBack() {
        let chat = makeSession()
        chat.modelValue = "sonnet"
        chat.setModel("nope")
        XCTAssertEqual(chat.modelValue, "nope")
        chat.handle(["type": "control_response", "response": ["subtype": "error", "request_id": lastRequestID(), "error": "Unknown model"]])
        XCTAssertEqual(chat.modelValue, "sonnet")
        guard case .notice(_, let text, let isError)? = chat.items.last else { return XCTFail("expected a notice") }
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Unknown model"))
    }

    func testAcceptedModeChangeSticks() {
        let chat = makeSession()
        chat.setPermissionMode("auto")
        chat.handle(["type": "control_response", "response": ["subtype": "success", "request_id": lastRequestID(), "response": [:] as [String: Any]]])
        XCTAssertEqual(chat.permissionMode, "auto")
        XCTAssertTrue(chat.items.isEmpty)
    }

    func testUndeliveredMessageIsReported() {
        let chat = makeSession(delivers: false)
        chat.send("hello")
        XCTAssertFalse(chat.busy)
        guard case .notice(_, _, let isError)? = chat.items.last else { return XCTFail("expected a notice") }
        XCTAssertTrue(isError)
    }

    func testPermissionRequestIsQueuedAndAnswered() {
        let chat = makeSession()
        var asked: PermissionRequest?
        chat.onNeedsInput = { asked = $0 }
        chat.handle(["type": "control_request", "request_id": "r1", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"]]])
        XCTAssertEqual(chat.pendingCount, 1)
        XCTAssertEqual(asked?.toolName, "Bash")
        guard let request = chat.pendingPermissions.first else { return XCTFail("no request") }
        chat.respond(request, allow: true)
        XCTAssertEqual(chat.pendingCount, 0)
        let response = (sent.last?["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(response?["behavior"] as? String, "allow")
    }

    func testUnsupportedControlRequestIsRefused() {
        let chat = makeSession()
        chat.handle(["type": "control_request", "request_id": "r2", "request": ["subtype": "something_else"]])
        let response = sent.last?["response"] as? [String: Any]
        XCTAssertEqual(response?["subtype"] as? String, "error")
    }

    func testAuthErrorHeuristic() {
        XCTAssertTrue(ChatSession.isAuthError("Invalid API key · Please run /login"))
        XCTAssertTrue(ChatSession.isAuthError("API Error: 401 authentication_error"))
        XCTAssertTrue(ChatSession.isAuthError("OAuth token has expired"))
        XCTAssertFalse(ChatSession.isAuthError("MCP server returned 401 for tool fetch"))
        XCTAssertFalse(ChatSession.isAuthError("Set your api key in the tool config"))
        XCTAssertFalse(ChatSession.isAuthError("Wrote credential helper to disk"))
    }
}

@MainActor
final class ChatQueueTests: XCTestCase {
    private var delivered: [String] = []

    private func makeSession() -> ChatSession {
        let chat = ChatSession(folder: "/tmp", configDir: nil)
        chat.running = true
        chat.transport = { [unowned self] obj in
            if obj["type"] as? String == "user",
               let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
               let text = content.last?["text"] as? String { delivered.append(text) }
            return true
        }
        return chat
    }

    func testMessagesSentWhileBusyWaitForTheTurnToEnd() {
        let chat = makeSession()
        chat.send("first")
        chat.send("second")
        chat.send("third")
        XCTAssertEqual(delivered, ["first"])
        XCTAssertEqual(chat.queuedIDs.count, 2)
        chat.handle(["type": "result", "total_cost_usd": 0.01])
        XCTAssertEqual(delivered, ["first", "second"])
        XCTAssertTrue(chat.busy)
        chat.handle(["type": "result", "total_cost_usd": 0.02])
        XCTAssertEqual(delivered, ["first", "second", "third"])
        XCTAssertTrue(chat.queuedIDs.isEmpty)
    }

    func testCancellingAQueuedMessageRemovesItAndReturnsItsText() {
        let chat = makeSession()
        chat.send("first")
        chat.send("second")
        let id = chat.queuedIDs[0]
        XCTAssertEqual(chat.cancelQueued(id), "second")
        XCTAssertTrue(chat.queuedIDs.isEmpty)
        XCTAssertEqual(chat.items.count, 1)
        var finished = 0
        chat.onTurnFinished = { finished += 1 }
        chat.handle(["type": "result", "total_cost_usd": 0.01])
        XCTAssertEqual(delivered, ["first"])
        XCTAssertEqual(finished, 1)
    }

    func testPromptHistoryAndTranscript() {
        let chat = makeSession()
        chat.send("alpha")
        chat.handle(["type": "result", "total_cost_usd": 0.01])
        chat.send("beta")
        XCTAssertEqual(chat.sentPrompts, ["alpha", "beta"])
        let markdown = chat.markdownTranscript(title: "Demo")
        XCTAssertTrue(markdown.hasPrefix("# Demo"))
        XCTAssertTrue(markdown.contains("alpha"))
    }

    func testMultiSelectAnswers() {
        let labels = ["Red", "Green", "Blue"]
        var answer = QuestionAnswer.toggled(nil, label: "Blue", multi: true, labels: labels)
        answer = QuestionAnswer.toggled(answer, label: "Red", multi: true, labels: labels)
        XCTAssertEqual(answer, "Red, Blue")
        answer = QuestionAnswer.settingOther(answer, other: "Teal", labels: labels, multi: true)
        XCTAssertEqual(answer, "Red, Blue, Teal")
        XCTAssertEqual(QuestionAnswer.other(answer, labels: labels, multi: true), "Teal")
        answer = QuestionAnswer.toggled(answer, label: "Red", multi: true, labels: labels)
        XCTAssertEqual(answer, "Blue, Teal")
        XCTAssertEqual(QuestionAnswer.toggled("Red", label: "Green", multi: false, labels: labels), "Green")
    }
}
