import XCTest
@testable import PullYard

final class StackTreeTests: XCTestCase {
    private let repo = "acme/app"

    private func pr(_ number: Int, head: String, base: String, state: String = "OPEN", draft: Bool = false,
                    headRepo: String? = "acme/app", ci: String? = nil, review: String? = nil, updated: TimeInterval = 0) -> StackNode {
        StackNode(number: number, title: "PR \(number)", state: state, isDraft: draft, headRefName: head, baseRefName: base,
                  headRepo: headRepo, author: "dev", updatedAt: Date(timeIntervalSince1970: updated), reviewDecision: review,
                  ci: ci, commitOid: nil, commitHeadline: nil)
    }

    func testLinearStack() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1")
        let tree = try XCTUnwrap(StackTree.build(current: p1, open: [p1, p2], repo: repo))
        XCTAssertEqual(tree.base, "dev")
        XCTAssertEqual(tree.root, 1)
        XCTAssertEqual(tree.children[1], [2])
        XCTAssertEqual(tree.parent[2], 1)
        XCTAssertEqual(tree.line.map(\.number), [1, 2])
    }

    func testBranchingStackKeepsSiblings() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1"), p3 = pr(3, head: "p3", base: "p1")
        let tree = try XCTUnwrap(StackTree.build(current: p2, open: [p3, p1, p2], repo: repo))
        XCTAssertEqual(tree.count, 3)
        XCTAssertEqual(tree.children[1], [2, 3])
        XCTAssertTrue(tree.onPath(1))
        XCTAssertTrue(tree.onPath(2))
        XCTAssertFalse(tree.onPath(3))
        XCTAssertEqual(tree.line.map(\.number), [1, 2])
    }

    func testUnrelatedPullRequestsOnBaseAreLeftOut() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1"), other = pr(9, head: "other", base: "dev")
        let tree = try XCTUnwrap(StackTree.build(current: p2, open: [p1, p2, other], repo: repo))
        XCTAssertEqual(Set(tree.nodes.keys), [1, 2])
    }

    func testSinglePullRequestIsNotAStack() {
        let p1 = pr(1, head: "p1", base: "dev"), other = pr(9, head: "other", base: "dev")
        XCTAssertNil(StackTree.build(current: p1, open: [p1, other], repo: repo))
    }

    func testForkBranchWithSameNameIsNotAParent() {
        let fork = pr(5, head: "dev", base: "main", headRepo: "someone/app")
        let p1 = pr(1, head: "p1", base: "dev")
        XCTAssertNil(StackTree.build(current: p1, open: [fork, p1], repo: repo))
    }

    func testCurrentPullRequestMissingFromOpenListIsAdded() throws {
        let merged = pr(1, head: "p1", base: "dev", state: "MERGED"), p2 = pr(2, head: "p2", base: "p1")
        let tree = try XCTUnwrap(StackTree.build(current: merged, open: [p2], repo: repo))
        XCTAssertEqual(tree.root, 1)
        XCTAssertEqual(tree.children[1], [2])
    }

    func testCycleDoesNotHang() throws {
        let a = pr(1, head: "a", base: "b"), b = pr(2, head: "b", base: "a")
        let tree = try XCTUnwrap(StackTree.build(current: a, open: [a, b], repo: repo))
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(StackLayout(tree).slots.count, 2)
    }

    func testDuplicateHeadPrefersMostRecent() throws {
        let old = pr(1, head: "p1", base: "dev", updated: 10), fresh = pr(4, head: "p1", base: "dev", updated: 20)
        let child = pr(2, head: "p2", base: "p1")
        let tree = try XCTUnwrap(StackTree.build(current: child, open: [old, fresh, child], repo: repo))
        XCTAssertEqual(tree.parent[2], 4)
    }

    func testLimitAlwaysKeepsCurrentPath() throws {
        var open = [pr(1, head: "root", base: "dev")]
        for n in 2...40 { open.append(pr(n, head: "leaf\(n)", base: "root")) }
        let deep = pr(100, head: "deep", base: "leaf40")
        open.append(deep)
        let tree = try XCTUnwrap(StackTree.build(current: deep, open: open, repo: repo, limit: 5))
        XCTAssertTrue(tree.nodes.keys.contains(100))
        XCTAssertTrue(tree.nodes.keys.contains(40))
        XCTAssertLessThanOrEqual(tree.count, 5)
    }

    func testLayoutCentersParentOverChildren() throws {
        let p1 = pr(1, head: "p1", base: "dev"), p2 = pr(2, head: "p2", base: "p1"), p3 = pr(3, head: "p3", base: "p1")
        let layout = StackLayout(try XCTUnwrap(StackTree.build(current: p1, open: [p1, p2, p3], repo: repo)))
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.levels, 2)
        XCTAssertEqual(layout.slots[1], .init(column: 0.5, level: 1))
        XCTAssertEqual(layout.slots[2], .init(column: 0, level: 2))
        XCTAssertEqual(layout.slots[3], .init(column: 1, level: 2))
    }

    func testStatus() {
        XCTAssertEqual(pr(1, head: "a", base: "b", draft: true).status, .draft)
        XCTAssertEqual(pr(1, head: "a", base: "b", ci: "FAILURE", review: "APPROVED").status, .ciFailed)
        XCTAssertEqual(pr(1, head: "a", base: "b", review: "CHANGES_REQUESTED").status, .changesRequested)
        XCTAssertEqual(pr(1, head: "a", base: "b", ci: "PENDING", review: "APPROVED").status, .checking)
        XCTAssertEqual(pr(1, head: "a", base: "b", ci: "SUCCESS", review: "APPROVED").status, .ready)
        XCTAssertEqual(pr(1, head: "a", base: "b", ci: "SUCCESS").status, .review)
        XCTAssertEqual(pr(1, head: "a", base: "b", state: "MERGED").status, .merged)
    }

    func testJiraKey() {
        XCTAssertEqual(StackNode.jiraKey(in: "COM-1640-fe-implement-onboarding"), "COM-1640")
        XCTAssertEqual(StackNode.jiraKey(in: "feature/ABC2-12_fix"), "ABC2-12")
        XCTAssertNil(StackNode.jiraKey(in: "fix-123-login"))
        XCTAssertNil(StackNode.jiraKey(in: "release/v2-1"))
    }
}
