import XCTest
@testable import PullYard

@MainActor
final class MergeQueueActionTests: XCTestCase {
    override func setUp() {
        StubProtocol.routes = [:]
        StubProtocol.queryRoutes = []
        StubProtocol.requests = []
        ForgeHTTP.protocolClasses = [StubProtocol.self]
    }

    override func tearDown() {
        ForgeHTTP.protocolClasses = []
    }

    func testMutationsAndFeatures() {
        XCTAssertTrue(Q.enqueue.contains("enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $oid})"))
        XCTAssertTrue(Q.dequeue.contains("dequeuePullRequest(input: {id: $id})"))
        XCTAssertTrue(PRFeatures.github.mergeQueue)
        XCTAssertTrue(PRFeatures.gitlab.mergeQueue)
        XCTAssertFalse(PRFeatures.bitbucket.mergeQueue)
        XCTAssertEqual(PRFeatures.github.queueTitle, "merge queue")
        XCTAssertEqual(PRFeatures.gitlab.queueTitle, "merge train")
    }

    private func pr(head: String) throws -> PullRequestDetail {
        let json: [String: Any] = [
            "id": "gitlab-mr-1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main", "headRefOid": head,
            "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []], "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": []], "allCommits": ["nodes": []], "timelineItems": ["nodes": []], "reviewThreads": ["nodes": []]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testGitLabTrainActions() async throws {
        StubProtocol.routes = [
            "/merge_trains/merge_requests/7": (201, "{}"),
            "/merge_requests/7/cancel_merge_when_pipeline_succeeds": (201, "{}")
        ]
        let account = GitAccount(id: "t", provider: .gitlab, host: "gitlab.example.com", login: "s", email: nil, userID: nil, keychainKey: "t")
        let backend = GitLabPRBackend(client: GitLabClient(account: account, credential: GitCredential(token: "x")))
        let ref = ItemRef(repo: RepoRef(owner: "group", name: "app"), number: 7)
        try await backend.perform(.enqueue, ref: ref, pr: try pr(head: "abc123"))
        let add = try XCTUnwrap(StubProtocol.requests.first { ($0.url?.path ?? "").hasSuffix("/merge_trains/merge_requests/7") })
        XCTAssertEqual(add.httpMethod, "POST")
        let body = try XCTUnwrap(add.httpBodyStream.map { s -> Data in
            s.open(); defer { s.close() }
            var d = Data(); var b = [UInt8](repeating: 0, count: 1024)
            while s.hasBytesAvailable { let n = s.read(&b, maxLength: b.count); if n <= 0 { break }; d.append(b, count: n) }
            return d
        })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["sha"] as? String, "abc123")
        XCTAssertEqual(json["when_pipeline_succeeds"] as? Bool, true)
        try await backend.perform(.dequeue, ref: ref, pr: try pr(head: "abc123"))
        XCTAssertTrue(StubProtocol.requests.contains { ($0.url?.path ?? "").hasSuffix("/cancel_merge_when_pipeline_succeeds") })
    }

    func testBitbucketRejectsQueueActions() async throws {
        let account = GitAccount(id: "t", provider: .bitbucket, host: "bitbucket.org", login: "s", email: "s@x", userID: "{u}", keychainKey: "t")
        let backend = BitbucketPRBackend(client: BitbucketClient(account: account, credential: GitCredential(token: "t")))
        do {
            try await backend.perform(.enqueue, ref: ItemRef(repo: RepoRef(owner: "a", name: "b"), number: 1), pr: try pr(head: "h"))
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not available for Bitbucket yet")
        }
    }
}
