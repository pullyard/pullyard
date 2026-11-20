import XCTest
@testable import PullYard

@MainActor
private final class RecordingBackend: PRBackend {
    let features = PRFeatures.gitlab
    var calls: [String] = []
    var failReply: Set<String> = []

    func load(_ ref: ItemRef) async throws -> PRLoad { throw APIError(message: "offline") }
    func pulse(_ ref: ItemRef) async throws -> PRPulseToken? { nil }
    func files(_ ref: ItemRef, pr: PullRequestDetail) async throws -> [PRFile] { [] }
    func comment(_ ref: ItemRef, pr: PullRequestDetail, body: String) async throws {}
    func submitReview(_ ref: ItemRef, pr: PullRequestDetail, event: String, body: String, comments: [PendingComment], files: [DiffFile]) async throws {}
    func reply(_ ref: ItemRef, thread: String, body: String) async throws {
        if failReply.contains(thread) { throw APIError(message: "Thread is locked") }
        calls.append("reply \(thread): \(body)")
    }
    func setResolved(_ ref: ItemRef, thread: String, resolved: Bool) async throws { calls.append("resolve \(thread) \(resolved)") }
    func merge(_ ref: ItemRef, pr: PullRequestDetail, method: String, title: String?, body: String?, deleteBranch: Bool) async throws -> String? { nil }
    func enableAutoMerge(_ ref: ItemRef, pr: PullRequestDetail, method: String) async throws {}
    func perform(_ action: PRAction, ref: ItemRef, pr: PullRequestDetail) async throws {}
    func edit(_ ref: ItemRef, pr: PullRequestDetail, title: String, body: String) async throws {}
}

@MainActor
final class CloseLoopTests: XCTestCase {
    private func thread(_ id: String, resolved: Bool = false, canResolve: Bool = true) -> [String: Any] {
        ["id": id, "isResolved": resolved, "isOutdated": false, "path": "a.swift", "line": 3, "diffSide": "RIGHT",
         "viewerCanResolve": canResolve, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": ["nodes": []]]
    }

    private func pr(head: String, commits: [String], threads: [[String: Any]], state: String = "OPEN") throws -> PullRequestDetail {
        let json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": state, "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main", "headRefOid": head,
            "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []], "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": []],
            "allCommits": ["totalCount": commits.count, "nodes": commits.map { ["commit": ["oid": $0, "abbreviatedOid": String($0.prefix(7)), "messageHeadline": "m", "committedDate": "2026-01-01T00:00:00Z", "url": "u"]] }],
            "timelineItems": ["nodes": []], "reviewThreads": ["nodes": threads]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPendingNeedsNewCommitsAndOpenThreads() throws {
        let launch = ReviewFixLaunch(threadIDs: ["t1", "t2", "t3"], headOid: "c1", at: Date())
        let same = try pr(head: "c1", commits: ["c0", "c1"], threads: [thread("t1")])
        XCTAssertNil(CloseLoop.pending(launch, pr: same))
        let pushed = try pr(head: "c3", commits: ["c0", "c1", "c2", "c3"], threads: [thread("t1"), thread("t2", resolved: true), thread("t9")])
        XCTAssertEqual(CloseLoop.pending(launch, pr: pushed), CloseLoop.Pending(threads: ["t1"], newCommits: 2))
        let rewritten = try pr(head: "x9", commits: ["x8", "x9"], threads: [thread("t3")])
        XCTAssertEqual(CloseLoop.pending(launch, pr: rewritten)?.newCommits, 1)
        let done = try pr(head: "c3", commits: ["c1", "c3"], threads: [thread("t1", resolved: true)])
        XCTAssertNil(CloseLoop.pending(launch, pr: done))
        let merged = try pr(head: "c3", commits: ["c1", "c3"], threads: [thread("t1")], state: "MERGED")
        XCTAssertNil(CloseLoop.pending(launch, pr: merged))
        XCTAssertNil(CloseLoop.pending(nil, pr: pushed))
    }

    func testDefaultReply() {
        XCTAssertEqual(CloseLoop.defaultReply(head: "abcdef123456"), "Fixed in abcdef1.")
        XCTAssertEqual(CloseLoop.defaultReply(head: ""), "Fixed.")
    }

    func testCloseLoopRepliesResolvesAndReportsFailures() async throws {
        let backend = RecordingBackend()
        backend.failReply = ["t2"]
        let model = PRDetailModel(ref: ItemRef(repo: RepoRef(owner: "o", name: "r"), number: 7), backend: backend)
        let p = try pr(head: "c3", commits: ["c3"], threads: [thread("t1"), thread("t2"), thread("t3", canResolve: false)])
        let failures = await model.closeLoop(p.reviewThreads.nodes, body: "Fixed in c3.", resolve: true)
        XCTAssertEqual(failures, ["t2": "Thread is locked"])
        XCTAssertEqual(backend.calls, ["reply t1: Fixed in c3.", "resolve t1 true", "reply t3: Fixed in c3."])
        XCTAssertFalse(model.busy)

        backend.calls = []
        _ = await model.closeLoop([p.reviewThreads.nodes[0]], body: "Thanks", resolve: false)
        XCTAssertEqual(backend.calls, ["reply t1: Thanks"])
    }
}
