import UserNotifications
import XCTest
@testable import PullYardMobile

@MainActor
final class AgentNotifierTests: XCTestCase {
    private func session(_ id: String, request: String?) -> PYLinkSession {
        var session = PYLinkSession(id: id, title: "Fix", folder: "/r", state: request == nil ? "working" : "waiting")
        session.pending = request.map { PYLinkPermission(id: $0, tool: "Bash", summary: "Run tests") }
        return session
    }

    func testOnlyNewPermissionsNotify() {
        let sessions = [session("a", request: "r1"), session("b", request: nil), session("c", request: "r2")]
        let fresh = AgentNotifier.fresh(sessions, notified: [AgentNotifier.identifier(session: "a", request: "r1")], viewing: nil, appActive: false)
        XCTAssertEqual(fresh, [AgentNotifier.identifier(session: "c", request: "r2")])
    }

    func testOpenChatIsSkippedOnlyWhileTheAppIsActive() {
        let sessions = [session("a", request: "r1")]
        XCTAssertTrue(AgentNotifier.fresh(sessions, notified: [], viewing: "a", appActive: true).isEmpty)
        XCTAssertEqual(AgentNotifier.fresh(sessions, notified: [], viewing: "a", appActive: false).count, 1)
    }

    func testReplyCategoryHasTextInput() {
        let category = AgentNotifier.notificationCategory
        XCTAssertEqual(category.actions.map(\.identifier), [AgentNotifier.allowAction, AgentNotifier.denyAction, AgentNotifier.replyAction])
        XCTAssertTrue(category.actions.last is UNTextInputNotificationAction)
    }
}
