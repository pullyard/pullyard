import XCTest
@testable import PullYard

final class SessionRewindTests: XCTestCase {
    private func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    func testForkCutsBeforeChosenPromptAndRenamesSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("old.jsonl")
        let rows = [
            line(["type": "user", "sessionId": "old", "uuid": "1", "message": ["role": "user", "content": "fix it"]]),
            line(["type": "assistant", "sessionId": "old", "uuid": "2", "message": ["role": "assistant", "content": [["type": "text", "text": "done"]]]]),
            line(["type": "user", "sessionId": "old", "uuid": "3", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]]),
            line(["type": "user", "sessionId": "old", "uuid": "4", "message": ["role": "user", "content": "fix it"]]),
            line(["type": "assistant", "sessionId": "old", "uuid": "5", "message": ["role": "assistant", "content": [["type": "text", "text": "again"]]]]),
        ]
        try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let last = try SessionRewind.fork(file: file, text: "fix it", occurrenceFromEnd: 0)
        let kept = try String(contentsOf: last.file).split(separator: "\n")
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept.allSatisfy { $0.contains(last.id) && !$0.contains("\"old\"") })

        let first = try SessionRewind.fork(file: file, text: "fix it", occurrenceFromEnd: 1)
        XCTAssertEqual(try String(contentsOf: first.file).split(separator: "\n").count, 0)

        XCTAssertThrowsError(try SessionRewind.fork(file: file, text: "missing", occurrenceFromEnd: 0))
    }
}

final class HistoryTailTests: XCTestCase {
    func testTailStartsAtLineBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let lines = (0..<200).map { "{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: 40))\"}" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let whole = try XCTUnwrap(ChatSession.readTail(file, maxBytes: 1 << 20))
        XCTAssertFalse(whole.truncated)
        let tail = try XCTUnwrap(ChatSession.readTail(file, maxBytes: 600))
        XCTAssertTrue(tail.truncated)
        let first = String(decoding: tail.data.split(separator: 0x0A).first!, as: UTF8.self)
        XCTAssertTrue(first.hasPrefix("{\"n\":"))
        XCTAssertTrue(String(decoding: tail.data, as: UTF8.self).contains("\"n\":199"))
    }
}
