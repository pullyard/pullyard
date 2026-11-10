import XCTest
@testable import PullYard

final class AgentEndpointTests: XCTestCase {
    func testEnvironmentForOpenRouter() {
        let ep = AgentEndpoint(kind: .openRouter, baseURL: AgentEndpoint.openRouterURL, model: " anthropic/claude-sonnet-4.5 ")
        XCTAssertEqual(ep.environment(token: "sk-or-1"), [
            "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
            "ANTHROPIC_AUTH_TOKEN": "sk-or-1",
            "ANTHROPIC_API_KEY": "",
            "ANTHROPIC_MODEL": "anthropic/claude-sonnet-4.5",
        ])
        let noModel = AgentEndpoint(kind: .custom, baseURL: "https://gw.example.com", model: "  ")
        XCTAssertNil(noModel.environment(token: "k")["ANTHROPIC_MODEL"])
        XCTAssertEqual(noModel.host, "gw.example.com")
    }

    func testBaseURLValidation() {
        XCTAssertNil(AgentEndpoint.problem(baseURL: "https://openrouter.ai/api/"))
        XCTAssertNil(AgentEndpoint.problem(baseURL: "http://localhost:4000"))
        XCTAssertNil(AgentEndpoint.problem(baseURL: "http://127.0.0.1:8080"))
        XCTAssertNotNil(AgentEndpoint.problem(baseURL: "http://gw.example.com"))
        XCTAssertNotNil(AgentEndpoint.problem(baseURL: "openrouter.ai/api"))
        XCTAssertNotNil(AgentEndpoint.problem(baseURL: ""))
        XCTAssertEqual(AgentEndpoint.normalized(" https://openrouter.ai/api// "), "https://openrouter.ai/api")
    }

    func testProfileDecodingKeepsOldDataAndFindsEndpoint() throws {
        let suite = "agent-endpoint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"[{"id":"default","label":"Main"},{"id":"a","label":"Work","configDir":"/x/a"}]"#
        defaults.set(Data(old.utf8), forKey: "claude.profiles")
        XCTAssertNil(AgentEndpoints.endpoint(configDir: "/x/a", defaults: defaults))
        XCTAssertNil(AgentEndpoints.endpoint(configDir: nil, defaults: defaults))

        let ep = AgentEndpoint(kind: .openRouter, baseURL: AgentEndpoint.openRouterURL, model: nil)
        let profiles = [ClaudeProfile(id: "default", label: "Main"), ClaudeProfile(id: "b", label: "OR", configDir: "/x/b", endpoint: ep)]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "claude.profiles")
        let found = try XCTUnwrap(AgentEndpoints.endpoint(configDir: "/x/b", defaults: defaults))
        XCTAssertEqual(found.profileID, "b")
        XCTAssertEqual(found.endpoint, ep)
        XCTAssertEqual(AgentEndpoint.keychainAccount(profileID: "b"), "agent-endpoint-b")
    }

    func testShellPreludeWritesPrivateFileAndSourcesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try AgentEndpoints.shellPrelude(env: nil, directory: dir), "")
        let line = try AgentEndpoints.shellPrelude(env: ["ANTHROPIC_AUTH_TOKEN": "it's secret", "ANTHROPIC_API_KEY": ""], directory: dir)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("env-") })
        let path = dir.appendingPathComponent(file).path
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(line.contains("secret"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", line + "; printf '%s|%s' \"$ANTHROPIC_AUTH_TOKEN\" \"${ANTHROPIC_API_KEY-unset}\""]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "it's secret|")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSweepRemovesStaleEnvFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("env-old"), fresh = dir.appendingPathComponent("env-new"), other = dir.appendingPathComponent("prompt-1.md")
        for f in [stale, fresh, other] { FileManager.default.createFile(atPath: f.path, contents: Data()) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: other.path)
        AgentEndpoints.sweep(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
