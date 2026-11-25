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
