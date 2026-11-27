import XCTest
@testable import PullYard

@MainActor
final class ConversationOrderTests: XCTestCase {
    private func pr() throws -> PullRequestDetail {
        let comment: (String, String) -> [String: Any] = { body, date in
            ["__typename": "IssueComment", "id": body, "author": ["login": "bot", "avatarUrl": ""], "body": body, "bodyHTML": "<p>\(body)</p>", "createdAt": date, "url": "https://github.com/o/r/pull/7#\(body)"]
        }
        let json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/o/r/pull/7", "state": "OPEN",
            "isDraft": false, "merged": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
            "body": "", "bodyHTML": "<p>DESC</p>", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "baseRefName": "main", "headRefOid": "head",
            "additions": 1, "deletions": 1, "changedFiles": 1,
            "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []],
            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": []], "allCommits": ["nodes": []],
            "timelineItems": ["nodes": [comment("FIRST", "2026-01-02T00:00:00Z"), comment("SECOND", "2026-01-03T00:00:00Z")]],
            "reviewThreads": ["nodes": []]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func positions(_ html: String, _ marks: [String]) -> [Int] {
        marks.map { html.range(of: $0).map { html.distance(from: html.startIndex, to: $0.lowerBound) } ?? -1 }
    }

    func testNewestFirstKeepsDescriptionOnTopAndReversesActivity() throws {
        let html = ConversationHTML.render(pr: try pr(), newestFirst: true)
        let p = positions(html, ["DESC", "py-latest", "SECOND", "FIRST"])
        XCTAssertFalse(p.contains(-1))
        XCTAssertEqual(p, p.sorted())
    }

    func testOldestFirstIsChronologicalWithoutAnchor() throws {
        let html = ConversationHTML.render(pr: try pr(), newestFirst: false)
        let p = positions(html, ["DESC", "FIRST", "SECOND"])
        XCTAssertFalse(p.contains(-1))
        XCTAssertEqual(p, p.sorted())
        XCTAssertNil(html.range(of: "py-latest"))
    }

    func testDefaultsToNewestFirstAndPersistsChoice() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ConversationOrder.key)
        defer { defaults.set(saved, forKey: ConversationOrder.key) }
        defaults.removeObject(forKey: ConversationOrder.key)
        XCTAssertTrue(ConversationOrder.newestFirst)
        defaults.set(false, forKey: ConversationOrder.key)
        XCTAssertFalse(ConversationOrder.newestFirst)
    }
}
