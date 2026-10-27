import XCTest
@testable import PullYard

final class DiffLayoutTests: XCTestCase {
    private func lines(_ patch: String) -> [DiffLine] { DiffParser.parse(patch) }

    private func shape(_ rows: [SplitDiffRow]) -> [String] {
        rows.map { row in
            switch row {
            case .full(let l): return "full:\(l.id)"
            case .pair(let a, let b): return "\(a.map { "\($0.id)" } ?? "_")|\(b.map { "\($0.id)" } ?? "_")"
            }
        }
    }

    func testPairsRemovalsWithAdditionsInOrder() {
        let rows = DiffSplit.pair(lines("@@ -1,4 +1,3 @@\n a\n-b\n-c\n+B\n d"))
        XCTAssertEqual(shape(rows), ["full:0", "1|1", "2|4", "3|_", "5|5"])
    }

    func testExtraAdditionsGetFillerOnLeft() {
        let rows = DiffSplit.pair(lines("@@ -1,2 +1,4 @@\n-x\n+X\n+Y\n+Z\n k"))
        XCTAssertEqual(shape(rows), ["full:0", "1|2", "_|3", "_|4", "5|5"])
    }

    func testAdditionsBeforeRemovalsDoNotPairAcrossRuns() {
        let rows = DiffSplit.pair(lines("@@ -1,1 +1,1 @@\n+new\n-old"))
        XCTAssertEqual(shape(rows), ["full:0", "_|1", "2|_"])
    }

    func testHunksAndMetaStayFullWidth() {
        let rows = DiffSplit.pair(lines("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n@@ -9 +9 @@\n c"))
        XCTAssertEqual(shape(rows), ["full:0", "1|2", "full:3", "full:4", "5|5"])
    }

    func testRemovalRunsAcrossContextAreSeparate() {
        let rows = DiffSplit.pair(lines("@@ -1,3 +1,3 @@\n-a\n m\n+b"))
        XCTAssertEqual(shape(rows), ["full:0", "1|_", "2|2", "_|3"])
    }

    func testLeadingColumnsCountsSpacesAndTabStops() {
        XCTAssertEqual(DiffText.leadingColumns("return x"), 0)
        XCTAssertEqual(DiffText.leadingColumns("    return x"), 4)
        XCTAssertEqual(DiffText.leadingColumns("\t\treturn"), 8)
        XCTAssertEqual(DiffText.leadingColumns("  \treturn"), 4)
        XCTAssertEqual(DiffText.leadingColumns("   "), 3)
    }

    func testHangingColumnsIncludeSignAndContinuationIndent() {
        XCTAssertEqual(DiffText.hangingColumns("let a = 1", limit: 40), 3)
        XCTAssertEqual(DiffText.hangingColumns("        let a = 1", limit: 40), 11)
        XCTAssertEqual(DiffText.hangingColumns("\tlet a = 1", limit: 40), 7)
    }

    func testHangingColumnsAreCappedByLimit() {
        XCTAssertEqual(DiffText.hangingColumns(String(repeating: " ", count: 60) + "x", limit: 20), 20)
        XCTAssertEqual(DiffText.hangingColumns("    x", limit: 0), 0)
        XCTAssertEqual(DiffText.hangingColumns("    x", limit: -5), 0)
    }

    func testExpandTabsAlignsToTabStops() {
        XCTAssertEqual(DiffText.expandTabs("no tabs"), "no tabs")
        XCTAssertEqual(DiffText.expandTabs("\tx"), "    x")
        XCTAssertEqual(DiffText.expandTabs("ab\tc"), "ab  c")
        XCTAssertEqual(DiffText.expandTabs("a\t\tb", tabWidth: 2), "a   b")
    }
}
