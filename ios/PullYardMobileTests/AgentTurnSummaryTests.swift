import XCTest
@testable import PullYardMobile

final class AgentTurnSummaryTests: XCTestCase {
    func testSummarizesTheLastTurn() {
        let items = [
            PYLinkItem(id: "u1", kind: "user", text: "old"),
            PYLinkItem(id: "c0", kind: "tool", text: "/repo/Old.swift", tool: "Edit", status: "done"),
            PYLinkItem(id: "u2", kind: "user", text: "fix it"),
            PYLinkItem(id: "c1", kind: "tool", text: "/repo/Sources/App.swift", tool: "Edit", status: "done"),
            PYLinkItem(id: "c2", kind: "tool", text: "/repo/Sources/App.swift", tool: "Write", status: "done"),
            PYLinkItem(id: "c3", kind: "tool", text: "git commit -m \"Fix\"", tool: "Bash", status: "done"),
            PYLinkItem(id: "c4", kind: "tool", text: "git push", tool: "Bash", status: "done"),
            PYLinkItem(id: "t1", kind: "text", text: "Done."),
        ]
        let summary = AgentTurnSummary(items: items)
        XCTAssertEqual(summary?.files, ["App.swift"])
        XCTAssertEqual(summary?.commits, 1)
        XCTAssertEqual(summary?.pushed, true)
        XCTAssertEqual(summary?.steps, 4)
    }

    func testNoSummaryWithoutToolsOrRightAfterAMessage() {
        XCTAssertNil(AgentTurnSummary(items: [PYLinkItem(id: "u1", kind: "user", text: "hi"), PYLinkItem(id: "t1", kind: "text", text: "hello")]))
        XCTAssertNil(AgentTurnSummary(items: [PYLinkItem(id: "c1", kind: "tool", text: "ls", tool: "Bash", status: "done"), PYLinkItem(id: "u1", kind: "user", text: "next")]))
    }
}
