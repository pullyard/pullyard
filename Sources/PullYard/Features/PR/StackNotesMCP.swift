import Foundation
import StackNotesKit

enum StackNotesMCP {
    static let flag = "--mcp-stack-notes"
    static let serverName = "pullyard"
    static let helperName = "pullyard-mcp"
    @MainActor static var target: () -> (account: String?, host: String)? = { nil }

    @MainActor static var args: [String] {
        guard let t = target(), let json = config(account: t.account, host: t.host) else { return [] }
        return ["--mcp-config", json]
    }

    static var helperPath: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + helperName).path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let sibling = dir.appendingPathComponent(helperName).path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    static func config(account: String?, host: String, command: String? = helperPath) -> String? {
        guard let exe = command else { return nil }
        var args = ["--host", host]
        if let account { args += ["--account", account] }
        let server: [String: Any] = ["type": "stdio", "command": exe, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: server]]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
