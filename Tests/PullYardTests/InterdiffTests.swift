import XCTest
@testable import PullYard

final class InterdiffTests: XCTestCase {
    private func pr(timeline: [[String: Any]] = [], latest: [[String: Any]] = [], commits: [String] = ["c1", "c2", "c3"], head: String = "c3") throws -> PullRequestDetail {
        let json: [String: Any] = [
            "id": "PR_1", "number": 1, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false,
            "mergeable": "MERGEABLE", "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "f", "baseRefName": "main", "headRefOid": head, "additions": 1, "deletions": 1, "changedFiles": 1,
            "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []], "reviewRequests": ["nodes": []],
            "latestOpinionatedReviews": ["nodes": latest], "lastCommit": ["nodes": []],
            "allCommits": ["nodes": commits.map { ["commit": ["oid": $0, "abbreviatedOid": $0, "messageHeadline": "m", "committedDate": "2026-01-01T00:00:00Z", "url": "u"]] }],
            "timelineItems": ["nodes": timeline], "reviewThreads": ["nodes": []]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func review(_ login: String, _ oid: String, _ date: String, state: String = "COMMENTED") -> [String: Any] {
        ["__typename": "PullRequestReview", "state": state, "createdAt": date, "author": ["login": login, "avatarUrl": ""], "commit": ["oid": oid]]
    }

    func testPicksViewersLatestReviewIncludingComments() throws {
        let p = try pr(timeline: [
            review("me", "c1", "2026-01-02T00:00:00Z", state: "APPROVED"),
            review("other", "c2", "2026-01-04T00:00:00Z"),
            review("Me", "c2", "2026-01-03T00:00:00Z")
        ])
        let r = try XCTUnwrap(Interdiff.lastReviewed(p, viewer: "me"))
        XCTAssertEqual(r.oid, "c2")
        XCTAssertEqual(r.commitsSince, 1)
        XCTAssertFalse(r.rewritten)
    }

    func testFallsBackToLatestOpinionatedReviews() throws {
        let latest: [[String: Any]] = [["state": "APPROVED", "submittedAt": "2026-01-02T00:00:00Z", "commit": ["oid": "c1"], "author": ["login": "me", "avatarUrl": ""]]]
        let r = try XCTUnwrap(Interdiff.lastReviewed(try pr(latest: latest), viewer: "me"))
        XCTAssertEqual(r.oid, "c1")
        XCTAssertEqual(r.commitsSince, 2)
    }

    func testNothingWhenReviewedHeadOrNeverReviewed() throws {
        XCTAssertNil(Interdiff.lastReviewed(try pr(timeline: [review("me", "c3", "2026-01-02T00:00:00Z")]), viewer: "me"))
        XCTAssertNil(Interdiff.lastReviewed(try pr(timeline: [review("other", "c1", "2026-01-02T00:00:00Z")]), viewer: "me"))
        XCTAssertNil(Interdiff.lastReviewed(try pr(timeline: [review("me", "c1", "2026-01-02T00:00:00Z")]), viewer: ""))
    }

    func testForcePushedCommitIsRewritten() throws {
        let r = try XCTUnwrap(Interdiff.lastReviewed(try pr(timeline: [review("me", "gone", "2026-01-02T00:00:00Z")]), viewer: "me"))
        XCTAssertTrue(r.rewritten)
        XCTAssertNil(r.commitsSince)
    }

    func testCompareResultDecodesSnakeCase() throws {
        let json = #"{"status":"diverged","ahead_by":2,"behind_by":3,"files":[{"filename":"a.swift","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1,2 @@\n a\n+b","previous_filename":null}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let r = try decoder.decode(CompareResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.behindBy, 3)
        XCTAssertEqual(r.files?.map(\.filename), ["a.swift"])
        XCTAssertEqual(DiffFile(r.files![0]).lines.filter { $0.kind == .add }.count, 1)
    }

    func testTimelineQueryCarriesReviewCommit() {
        XCTAssertTrue(Q.pullRequest.contains("... on PullRequestReview { id author { login avatarUrl } state body bodyHTML createdAt url commit { oid } }"))
    }
}
