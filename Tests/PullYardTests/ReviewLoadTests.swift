import XCTest
@testable import PullYard

final class ReviewLoadTests: XCTestCase {
    func testQueryUsesUserAndTeamQualifiers() {
        let (query, aliases) = ReviewLoad.query(["alice", "acme/core", "bad\"name", "bob"])
        XCTAssertEqual(aliases, ["r0": "alice", "r1": "acme/core", "r2": "bob"])
        XCTAssertTrue(query.contains(#"r0: search(query: "is:pr is:open archived:false review-requested:alice", type: ISSUE, first: 0) { issueCount }"#))
        XCTAssertTrue(query.contains("team-review-requested:acme/core"))
        XCTAssertFalse(query.contains("bad"))
        XCTAssertEqual(ReviewLoad.query((0..<30).map { "u\($0)" }).aliases.count, ReviewLoad.maxPerQuery)
    }

    func testParseAndLabels() throws {
        let data = try JSONDecoder().decode([String: ReviewLoad.Hit?].self, from: Data(#"{"r0":{"issueCount":3},"r1":{"issueCount":12},"r2":null}"#.utf8))
        XCTAssertEqual(ReviewLoad.parse(data, aliases: ["r0": "Alice", "r1": "acme/Core", "r2": "bob"]), ["alice": 3, "acme/core": 12])
        XCTAssertEqual(ReviewLoad.label(1), "1 open review")
        XCTAssertEqual(ReviewLoad.label(4), "4 open reviews")
        XCTAssertTrue(ReviewLoad.busy(10))
        XCTAssertFalse(ReviewLoad.busy(9))
    }
}
