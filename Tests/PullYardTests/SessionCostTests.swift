import XCTest
@testable import PullYard

@MainActor
final class SessionCostTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SessionCost.budgetKey)
    }

    func testMath() {
        XCTAssertEqual(SessionCost.total(base: 0.5, reported: 0.25), 0.75)
        XCTAssertEqual(SessionCost.total(base: 0.5, reported: -1), 0.5)
        XCTAssertFalse(SessionCost.overBudget(cost: 10, budget: 0, allowance: 0))
        XCTAssertTrue(SessionCost.overBudget(cost: 2, budget: 2, allowance: 0))
        XCTAssertFalse(SessionCost.overBudget(cost: 3, budget: 2, allowance: 2))
        XCTAssertEqual(SessionCost.nextAllowance(cost: 2.5, budget: 2), 2.5)
        XCTAssertEqual(SessionCost.nextAllowance(cost: 1, budget: 0), 0)
        XCTAssertEqual(SessionCost.format(0.043), "$0.04")
        XCTAssertEqual(SessionCost.format(12.5), "$12.50")
        XCTAssertEqual(SessionCost.format(250), "$250")
    }

    func testReportedCostIsCumulativePerProcess() {
        let chat = ChatSession(folder: NSTemporaryDirectory(), configDir: nil)
        chat.handle(["type": "result", "total_cost_usd": 0.0302])
        chat.handle(["type": "result", "total_cost_usd": 0.0432])
        XCTAssertEqual(chat.totalCost, 0.0432, accuracy: 1e-9)
        XCTAssertFalse(chat.budgetPaused)
    }

    func testBudgetPausesAndContinues() {
        UserDefaults.standard.set(0.04, forKey: SessionCost.budgetKey)
        let chat = ChatSession(folder: NSTemporaryDirectory(), configDir: nil)
        chat.handle(["type": "result", "total_cost_usd": 0.03])
        XCTAssertFalse(chat.budgetPaused)
        chat.handle(["type": "result", "total_cost_usd": 0.045])
        XCTAssertTrue(chat.budgetPaused)
        let before = chat.items.count
        chat.send("next step")
        XCTAssertEqual(chat.items.count, before + 1)
        XCTAssertFalse(chat.busy)
        chat.continuePastBudget()
        XCTAssertFalse(chat.budgetPaused)
        chat.handle(["type": "result", "total_cost_usd": 0.07])
        XCTAssertFalse(chat.budgetPaused)
        chat.handle(["type": "result", "total_cost_usd": 0.09])
        XCTAssertTrue(chat.budgetPaused)
    }
}
