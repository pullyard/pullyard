import XCTest
@testable import PullYard

final class DiffIntralineTests: XCTestCase {
    func testChangedRangeFindsMiddle() {
        let range = DiffIntraline.changedRange("let timeout = 30", "let timeout = 45")
        XCTAssertEqual(range, NSRange(location: 14, length: 2))
    }

    func testChangedRangeSkipsUnrelatedLines() {
        XCTAssertNil(DiffIntraline.changedRange("return value", "import Foundation"))
    }

    func testChangedRangeSkipsIdenticalLines() {
        XCTAssertNil(DiffIntraline.changedRange("same", "same"))
    }

    func testPartnersPairDeletionsWithAdditionsInOrder() {
        let rows: [DiffTableRow] = [
            .line(id: "d1", line: DiffLine(id: 1, kind: .del, text: "a = 1", oldLine: 1, newLine: nil), commentable: false),
            .line(id: "d2", line: DiffLine(id: 2, kind: .del, text: "b = 2", oldLine: 2, newLine: nil), commentable: false),
            .line(id: "a1", line: DiffLine(id: 3, kind: .add, text: "a = 3", oldLine: nil, newLine: 1), commentable: false),
            .line(id: "c1", line: DiffLine(id: 4, kind: .context, text: "c", oldLine: 3, newLine: 2), commentable: false),
            .line(id: "a2", line: DiffLine(id: 5, kind: .add, text: "d = 4", oldLine: nil, newLine: 3), commentable: false),
        ]
        let pairs = DiffIntraline.partners(rows)
        XCTAssertEqual(pairs["d1"], "a = 3")
        XCTAssertEqual(pairs["a1"], "a = 1")
        XCTAssertNil(pairs["d2"])
        XCTAssertNil(pairs["a2"])
    }
}

final class DiffExpandTests: XCTestCase {
    func testFullFileFillsGapsAroundHunk() {
        let patch = "@@ -3,2 +3,2 @@\n line3\n-old4\n+new4"
        let lines = DiffParser.parse(patch)
        let full = DiffExpand.fullFile(lines, newText: ["line1", "line2", "line3", "new4", "line5"])
        XCTAssertEqual(full.map(\.text), ["line1", "line2", "line3", "old4", "new4", "line5"])
        XCTAssertEqual(full.first?.oldLine, 1)
        XCTAssertEqual(full.first?.outsideHunk, true)
        XCTAssertEqual(full.last?.newLine, 5)
        XCTAssertEqual(full.last?.oldLine, 5)
        XCTAssertFalse(full.first?.commentable ?? true)
        XCTAssertTrue(full[2].commentable)
    }

    func testHeaderParsesCountsAndDefaults() {
        let h = DiffExpand.header("@@ -10 +12,3 @@ func")
        XCTAssertEqual(h?.oldStart, 10)
        XCTAssertEqual(h?.oldCount, 1)
        XCTAssertEqual(h?.newStart, 12)
        XCTAssertEqual(h?.newCount, 3)
    }
}
