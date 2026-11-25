import XCTest
@testable import PullYard

@MainActor
final class StackPlanTests: XCTestCase {
    private func pr(_ number: Int, head: String, base: String, draft: Bool = false) -> StackNode {
        StackNode(number: number, title: "PR \(number)", state: "OPEN", isDraft: draft, headRefName: head, baseRefName: base,
                  headRepo: "acme/app", author: "dev", updatedAt: nil, reviewDecision: nil, ci: nil, commitOid: nil, commitHeadline: nil)
    }

    func testUpdateOrderGoesFromBottomUp() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1"), p3 = pr(3, head: "p3", base: "p1"), p4 = pr(4, head: "p4", base: "p2")
        let tree = try XCTUnwrap(StackTree.build(current: p4, open: [p1, p2, p3, p4], repo: "acme/app"))
        XCTAssertEqual(StackPlan.updateOrder(tree), [1, 2, 3, 4])
    }

    func testMergeBottomRetargetsItsChildren() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1"), p3 = pr(3, head: "p3", base: "p1"), p4 = pr(4, head: "p4", base: "p2")
        let tree = try XCTUnwrap(StackTree.build(current: p2, open: [p1, p2, p3, p4], repo: "acme/app"))
        XCTAssertEqual(StackPlan.mergeable(tree)?.number, 1)
        XCTAssertEqual(StackPlan.retargets(afterMerging: tree), [2, 3])
        let run = StackActionRun(operation: .mergeBottom(method: "SQUASH"), tree: tree)
        XCTAssertEqual(run.steps.map(\.id), ["merge-1", "retarget-2", "retarget-3", "update-2", "update-3"])
    }

    func testDraftBottomIsNotMergeable() throws {
        let p1 = pr(1, head: "p1", base: "dev", draft: true), p2 = pr(2, head: "p2", base: "p1")
        let tree = try XCTUnwrap(StackTree.build(current: p2, open: [p1, p2], repo: "acme/app"))
        XCTAssertNil(StackPlan.mergeable(tree))
        XCTAssertTrue(StackActionRun(operation: .mergeBottom(method: "MERGE"), tree: tree).steps.isEmpty)
    }
}
