import XCTest
@testable import PullYard

final class SessionIndexTests: XCTestCase {
    func testIndexesPromptsAndRepliesButNotToolOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        let rows: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "Refactor the Payment gateway"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Moved retries into PaymentClient"]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "secret build output zebra"]]]],
        ]
        let text = rows.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let index = SessionIndex(directory: dir.appendingPathComponent("idx"))
        let hits = await index.search("payment GATEWAY", files: [file])
        XCTAssertNotNil(hits[file.path])
        let reply = await index.search("paymentclient", files: [file])
        XCTAssertNotNil(reply[file.path])
        let tool = await index.search("zebra", files: [file])
        XCTAssertNil(tool[file.path])
    }
}
