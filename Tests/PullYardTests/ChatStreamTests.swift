import XCTest
@testable import PullYard

final class ChatStreamTests: XCTestCase {
    func testDecoderJoinsSplitLines() {
        let decoder = StreamLineDecoder()
        XCTAssertTrue(decoder.decode(Data(#"{"type":"a"}"#.utf8)).isEmpty)
        let objects = decoder.decode(Data("\n{\"type\":\"b\"}\n{\"ty".utf8))
        XCTAssertEqual(objects.compactMap { $0["type"] as? String }, ["a", "b"])
        XCTAssertEqual(decoder.decode(Data("pe\":\"c\"}\n".utf8)).compactMap { $0["type"] as? String }, ["c"])
    }

    func testDecoderSkipsGarbage() {
        let decoder = StreamLineDecoder()
        XCTAssertEqual(decoder.decode(Data("not json\n\n{\"type\":\"ok\"}\n".utf8)).count, 1)
    }

    func testStreamingParseMatchesFullParse() {
        let text = "# Title\n\nFirst paragraph.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n- one\n- two\n\nTail"
        XCTAssertEqual(MarkdownParser.parse(text, streaming: true), MarkdownParser.parse(text))
    }

    func testStableSplitIgnoresBlankLinesInsideFence() {
        let text = "Intro\n\n```\ncode\n\nmore"
        let split = MarkdownParser.stableSplit(text)
        XCTAssertEqual(split.map { String(text[$0...]) }, "```\ncode\n\nmore")
    }

    @MainActor
    func testLongToolOutputIsTruncated() {
        let long = String(repeating: "x", count: ChatSession.maxResultLength + 10)
        let out = ChatSession.resultText(long) ?? ""
        XCTAssertTrue(out.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertTrue(out.contains("output truncated"))
        XCTAssertEqual(ChatSession.resultText("short"), "short")
    }
}
