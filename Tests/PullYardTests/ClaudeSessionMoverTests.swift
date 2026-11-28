import XCTest
@testable import PullYard

final class ClaudeSessionMoverTests: XCTestCase {
    private var root: URL!
    private var main: URL { root.appendingPathComponent("main") }
    private var personal: URL { root.appendingPathComponent("personal") }
    private let projectDir = "-Users-me-krisp-gate"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func session(_ id: String, in config: URL, sidecar: Bool = false, history: Bool = false, text: String = "{}") throws -> URL {
        let dir = config.appendingPathComponent("projects/\(projectDir)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try text.write(to: file, atomically: true, encoding: .utf8)
        if sidecar {
            let side = dir.appendingPathComponent("\(id)/subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
            try "s".write(to: side.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
        }
        if history {
            let h = config.appendingPathComponent("file-history/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
            try "v1".write(to: h.appendingPathComponent("a@v1"), atomically: true, encoding: .utf8)
        }
        return file
    }

    private func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func testFindsConfigFolderOfSessionFile() throws {
        let file = try session("a", in: main)
        XCTAssertEqual(ClaudeSessionMover.configDir(of: file).standardizedFileURL.path, main.standardizedFileURL.path)
    }

    func testMovesTranscriptSidecarAndHistory() throws {
        let file = try session("a", in: main, sidecar: true, history: true, text: "transcript")
        let result = try ClaudeSessionMover.move(sessionFiles: [file], to: personal)
        XCTAssertEqual(result, .init(moved: 1, skipped: 0))
        XCTAssertTrue(exists(personal, "projects/\(projectDir)/a.jsonl"))
        XCTAssertEqual(try String(contentsOf: personal.appendingPathComponent("projects/\(projectDir)/a.jsonl"), encoding: .utf8), "transcript")
        XCTAssertTrue(exists(personal, "projects/\(projectDir)/a/subagents/agent.jsonl"))
        XCTAssertTrue(exists(personal, "file-history/a/a@v1"))
        XCTAssertFalse(exists(main, "projects/\(projectDir)/a.jsonl"))
        XCTAssertFalse(exists(main, "file-history/a"))
        XCTAssertFalse(exists(main, "projects/\(projectDir)"), "empty project folder is cleaned up")
    }

    func testLeavesOtherSessionsOfTheFolderAlone() throws {
        let a = try session("a", in: main)
        try session("b", in: main)
        _ = try ClaudeSessionMover.move(sessionFiles: [a], to: personal)
        XCTAssertTrue(exists(main, "projects/\(projectDir)/b.jsonl"))
        XCTAssertTrue(exists(personal, "projects/\(projectDir)/a.jsonl"))
    }

    func testNeverOverwritesAnExistingSession() throws {
        let file = try session("a", in: main, text: "old")
        try session("a", in: personal, text: "kept")
        let result = try ClaudeSessionMover.move(sessionFiles: [file], to: personal)
        XCTAssertEqual(result, .init(moved: 0, skipped: 1))
        XCTAssertEqual(try String(contentsOf: personal.appendingPathComponent("projects/\(projectDir)/a.jsonl"), encoding: .utf8), "kept")
        XCTAssertTrue(exists(main, "projects/\(projectDir)/a.jsonl"))
    }

    func testSkipsSessionsAlreadyInTarget() throws {
        let file = try session("a", in: personal)
        let result = try ClaudeSessionMover.move(sessionFiles: [file], to: personal)
        XCTAssertEqual(result, .init(moved: 0, skipped: 1))
        XCTAssertTrue(exists(personal, "projects/\(projectDir)/a.jsonl"))
    }

    func testMovedSessionIsListedUnderTargetAccount() throws {
        let line = #"{"type":"user","sessionId":"a","cwd":"/Users/me/krisp_gate","message":{"role":"user","content":"hello"},"timestamp":"2026-11-26T10:00:00Z"}"#
        let file = try session("a", in: main, text: line + "\n")
        _ = try ClaudeSessionMover.move(sessionFiles: [file], to: personal)
        XCTAssertTrue(ClaudeSessionParser.loadAll(root: main.appendingPathComponent("projects")).flatMap(\.sessions).isEmpty)
        let moved = ClaudeSessionParser.loadAll(root: personal.appendingPathComponent("projects")).flatMap(\.sessions)
        XCTAssertEqual(moved.map(\.id), ["a"])
    }
}
