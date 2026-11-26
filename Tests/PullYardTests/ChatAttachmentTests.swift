import XCTest
@testable import PullYard

final class ChatAttachmentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String, age: TimeInterval = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url
    }

    func testDroppedFilesRoundTripThroughMentions() throws {
        let pdf = try touch("spec.pdf")
        let md = try touch("release notes.md")
        let message = ChatFileMention.compose("summarize these", files: [pdf, md], folder: dir.path)
        XCTAssertEqual(message, "summarize these\n\n@spec.pdf @\"release notes.md\"")
        let split = ChatFileMention.parse(message, folder: dir.path)
        XCTAssertEqual(split.text, "summarize these")
        XCTAssertEqual(split.files.map(\.lastPathComponent), ["spec.pdf", "release notes.md"])
    }

    func testInlineMentionsStayInText() throws {
        _ = try touch("spec.pdf")
        let text = "look at @spec.pdf and fix it"
        let split = ChatFileMention.parse(text, folder: dir.path)
        XCTAssertEqual(split.text, text)
        XCTAssertTrue(split.files.isEmpty)
    }

    func testMissingFilesStayAsText() {
        let text = "hi\n\n@gone.pdf"
        XCTAssertEqual(ChatFileMention.parse(text, folder: dir.path).text, text)
    }

    func testToolResultImagesAreDecoded() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "shot"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": Data([1, 2, 3]).base64EncodedString()]]
        ]
        let images = ChatSession.resultImages(content)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.mediaType, "image/jpeg")
        XCTAssertTrue(ChatSession.resultImages("plain").isEmpty)
    }

    func testBashScanKeepsOnlyFreshImages() throws {
        _ = try touch("old.png", age: 3600)
        let fresh = try touch("shot.png")
        let call = ChatToolCall(id: "b", name: "Bash")
        call.input = ["command": "screencapture shot.png && ls"]
        call.resultText = "old.png\nshot.png"
        call.startedAt = Date().addingTimeInterval(-1)
        let found = try XCTUnwrap(ToolImageScan(call, folder: dir.path)).run()
        XCTAssertEqual(found.compactMap(\.url?.lastPathComponent), [fresh.lastPathComponent])
    }

    func testReadOfImageFileIsFound() throws {
        let png = try touch("logo.png", age: 3600)
        let call = ChatToolCall(id: "r", name: "Read")
        call.input = ["file_path": png.path]
        let found = try XCTUnwrap(ToolImageScan(call, folder: dir.path)).run()
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(ToolImageScan(ChatToolCall(id: "g", name: "Grep"), folder: dir.path))
    }
}
