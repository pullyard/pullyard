import XCTest
@testable import PullYard

final class ActivityNotifierTests: XCTestCase {
    private func item(_ n: Int, ci: String? = nil, decision: String? = nil, updated: TimeInterval = 1000) -> ActivityItem {
        ActivityItem(id: "https://github.com/o/r/pull/\(n)", ref: ItemRef(repo: RepoRef(owner: "o", name: "r"), number: n), title: "PR \(n)", updatedAt: Date(timeIntervalSince1970: updated), ciState: ci, reviewDecision: decision)
    }

    func testFirstLoadIsSilent() {
        var t = ActivityTracker()
        XCTAssertEqual(t.update(reviews: [item(1), item(2)], reviewTotal: 2, mine: [item(3, ci: "FAILURE", decision: "APPROVED")]), [])
    }

    func testNewReviewRequest() {
        var t = ActivityTracker()
        _ = t.update(reviews: [item(1)], reviewTotal: 1, mine: nil)
        XCTAssertEqual(t.update(reviews: [item(2), item(1)], reviewTotal: 2, mine: nil), [.reviewRequested(item(2))])
        XCTAssertEqual(t.update(reviews: [item(2), item(1)], reviewTotal: 2, mine: nil), [])
    }

    func testFailedFetchDoesNotPrime() {
        var t = ActivityTracker()
        _ = t.update(reviews: nil, reviewTotal: 0, mine: nil)
        XCTAssertEqual(t.update(reviews: [item(1)], reviewTotal: 1, mine: nil), [])
        _ = t.update(reviews: nil, reviewTotal: 0, mine: nil)
        XCTAssertEqual(t.update(reviews: [item(1), item(2)], reviewTotal: 2, mine: nil), [.reviewRequested(item(2))])
    }

    func testTruncatedListOnlyCountsGrowth() {
        var t = ActivityTracker()
        _ = t.update(reviews: [item(1), item(2)], reviewTotal: 15, mine: nil)
        XCTAssertEqual(t.update(reviews: [item(3), item(1)], reviewTotal: 15, mine: nil), [])
        XCTAssertEqual(t.update(reviews: [item(4), item(5), item(3)], reviewTotal: 16, mine: nil), [.reviewRequested(item(4))])
    }

    func testCIFailureTransition() {
        var t = ActivityTracker()
        _ = t.update(reviews: nil, reviewTotal: 0, mine: [item(1, ci: "PENDING"), item(2, ci: "FAILURE")])
        let events = t.update(reviews: nil, reviewTotal: 0, mine: [item(1, ci: "FAILURE"), item(2, ci: "ERROR")])
        XCTAssertEqual(events, [.ciFailed(item(1, ci: "FAILURE"))])
        XCTAssertEqual(t.update(reviews: nil, reviewTotal: 0, mine: [item(1, ci: "FAILURE")]), [])
    }

    func testCIFailureIgnoresNewlySeenPR() {
        var t = ActivityTracker()
        _ = t.update(reviews: nil, reviewTotal: 0, mine: [])
        XCTAssertEqual(t.update(reviews: nil, reviewTotal: 0, mine: [item(1, ci: "FAILURE")]), [])
    }

    func testReviewDecisionTransitions() {
        var t = ActivityTracker()
        _ = t.update(reviews: nil, reviewTotal: 0, mine: [item(1, decision: "REVIEW_REQUIRED"), item(2)])
        let events = t.update(reviews: nil, reviewTotal: 0, mine: [item(1, decision: "APPROVED"), item(2, decision: "CHANGES_REQUESTED")])
        XCTAssertEqual(events, [.approved(item(1, decision: "APPROVED")), .changesRequested(item(2, decision: "CHANGES_REQUESTED"))])
        XCTAssertEqual(t.update(reviews: nil, reviewTotal: 0, mine: [item(1, decision: "APPROVED")]), [])
    }

    func testEventKeysAndKinds() {
        let a = ActivityEvent.ciFailed(item(1, updated: 10))
        XCTAssertEqual(a.kind, .ciFailed)
        XCTAssertNotEqual(a.key, ActivityEvent.ciFailed(item(1, updated: 20)).key)
        XCTAssertNotEqual(a.key, ActivityEvent.reviewRequested(item(1, updated: 10)).key)
        XCTAssertEqual(ActivityEvent.approved(item(1)).kind, .reviewDecision)
    }

    func testRecentEventsDedupesAndCaps() {
        var r = RecentEvents(limit: 2)
        XCTAssertTrue(r.insert("a"))
        XCTAssertFalse(r.insert("a"))
        XCTAssertTrue(r.insert("b"))
        XCTAssertTrue(r.insert("c"))
        XCTAssertEqual(r.keys, ["b", "c"])
        XCTAssertTrue(r.insert("a"))
    }

    func testTargetRoundTrip() {
        let t = ActivityTarget(url: "https://github.com/o/r/pull/1", repo: "o/r", number: 1, account: "acct")
        let back = ActivityTarget(userInfo: t.userInfo)
        XCTAssertEqual(back?.repo, "o/r")
        XCTAssertEqual(back?.number, 1)
        XCTAssertEqual(back?.account, "acct")
        XCTAssertNil(ActivityTarget(userInfo: ["x": 1]))
    }

    func testDockBadgeCount() {
        XCTAssertEqual(DockBadge.count(reviews: 3, agents: 2, enabled: true, includesAgents: true), 5)
        XCTAssertEqual(DockBadge.count(reviews: 3, agents: 2, enabled: true, includesAgents: false), 3)
        XCTAssertEqual(DockBadge.count(reviews: 3, agents: 2, enabled: false, includesAgents: true), 0)
    }
}
