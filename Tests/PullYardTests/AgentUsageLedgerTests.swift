import XCTest
@testable import PullYard

@MainActor
final class AgentUsageLedgerTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testRecordsPerDayAndPersists() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = AgentUsageLedger(file: file)
        ledger.record(cost: 0.5, at: now, calendar: utc)
        ledger.record(cost: 0.25, at: now, calendar: utc)
        ledger.record(cost: 1, at: now.addingTimeInterval(-3 * 86_400), calendar: utc)
        ledger.record(cost: -4, at: now.addingTimeInterval(-40 * 86_400), calendar: utc)
        XCTAssertEqual(ledger.total(lastDays: 1, now: now, calendar: utc), .init(cost: 0.75, turns: 2))
        XCTAssertEqual(ledger.total(lastDays: 7, now: now, calendar: utc), .init(cost: 1.75, turns: 3))
        XCTAssertEqual(ledger.total(lastDays: 30, now: now, calendar: utc).turns, 3)
        let reloaded = AgentUsageLedger(file: file)
        XCTAssertEqual(reloaded.total(lastDays: 60, now: now, calendar: utc), .init(cost: 1.75, turns: 4))
        reloaded.clear()
        XCTAssertTrue(AgentUsageLedger(file: file).days.isEmpty)
    }

    func testChatRecordsCostDeltaPerTurn() {
        let ledger = AgentUsageLedger(file: nil)
        let chat = ChatSession(folder: "/tmp", configDir: nil)
        chat.ledger = ledger
        chat.handle(["type": "result", "total_cost_usd": 0.01])
        chat.handle(["type": "result", "total_cost_usd": 0.03])
        let today = ledger.total(lastDays: 1)
        XCTAssertEqual(today.turns, 2)
        XCTAssertEqual(today.cost, 0.03, accuracy: 0.0001)
    }

    func testTrimDropsOldestItems() {
        let chat = ChatSession(folder: "/tmp", configDir: nil)
        chat.items = (0..<50).map { ChatItem.notice(id: "i\($0)", text: "\($0)", isError: false) }
        chat.trimItems(limit: 40)
        XCTAssertEqual(chat.items.count, 33)
        XCTAssertEqual(chat.items.first?.id, "nolder")
        XCTAssertEqual(chat.items.last?.id, "ni49")
    }
}
