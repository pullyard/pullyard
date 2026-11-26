import XCTest
@testable import PullYardMobile

final class AgentDiffBuilderTests: XCTestCase {
    func testLineDiffKeepsContextAndMarksChanges() {
        let result = AgentDiffBuilder.compare(["a", "b", "c"], ["a", "x", "c", "d"])
        XCTAssertEqual(result.map { "\($0.0)|\($0.1)" }, ["context|a", "delete|b", "add|x", "context|c", "add|d"])
    }

    func testWriteShowsEveryLineAsAdded() {
        let lines = AgentDiffBuilder.lines(for: PYLinkDiff(path: "/r/New.swift", tool: "Write", edits: [PYLinkEdit(old: "", new: "one\ntwo\n")]))
        XCTAssertEqual(lines.map(\.kind), [.add, .add])
        XCTAssertEqual(AgentDiffBuilder.counts(lines).added, 2)
    }

    func testMultiEditGetsAHeaderPerChange() {
        let diff = PYLinkDiff(path: "/r/A.swift", tool: "MultiEdit", edits: [PYLinkEdit(old: "a", new: "b"), PYLinkEdit(old: "c", new: "d")])
        XCTAssertEqual(AgentDiffBuilder.lines(for: diff).filter { $0.kind == .hunk }.count, 2)
    }
}
