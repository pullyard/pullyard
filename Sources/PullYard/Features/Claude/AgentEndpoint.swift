import Foundation

struct AgentEndpoint: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case openRouter, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .custom: return "Custom endpoint"
            }
        }
    }

    static let openRouterURL = "https://openrouter.ai/api"
    static let managedKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL"]

    var kind: Kind
    var baseURL: String
    var model: String?

    var host: String { URL(string: baseURL)?.host ?? baseURL }

    func environment(token: String) -> [String: String] {
        var env = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": token,
            "ANTHROPIC_API_KEY": "",
        ]
        if let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { env["ANTHROPIC_MODEL"] = model }
        return env
    }

    static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func problem(baseURL raw: String) -> String? {
        let s = normalized(raw)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return "Enter the full address, e.g. https://openrouter.ai/api"
        }
        if scheme == "https" { return nil }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return nil }
        return "Use https. Plain http is allowed only for localhost."
    }

    static func keychainAccount(profileID: String) -> String { "agent-endpoint-\(profileID)" }
}

enum AgentEndpoints {
    private static let listKey = "claude.profiles"

    static func endpoint(configDir: String?, defaults: UserDefaults = .standard) -> (profileID: String, endpoint: AgentEndpoint)? {
        guard let configDir,
              let data = defaults.data(forKey: listKey),
              let profiles = try? JSONDecoder().decode([ClaudeProfile].self, from: data),
              let profile = profiles.first(where: { $0.configDir == configDir }),
              let endpoint = profile.endpoint else { return nil }
        return (profile.id, endpoint)
    }

    static func hasKey(profileID: String) -> Bool {
        !(Keychain.load(account: AgentEndpoint.keychainAccount(profileID: profileID)) ?? "").isEmpty
    }

    static func environment(configDir: String?) -> [String: String]? {
        guard let found = endpoint(configDir: configDir) else { return nil }
        let token = Keychain.load(account: AgentEndpoint.keychainAccount(profileID: found.profileID)) ?? ""
        return found.endpoint.environment(token: token)
    }

    static func shellPrelude(configDir: String?, directory: URL) throws -> String {
        try shellPrelude(env: environment(configDir: configDir), directory: directory)
    }

    static func shellPrelude(env: [String: String]?, directory: URL) throws -> String {
        guard let env else { return "" }
        sweep(directory)
        let file = directory.appendingPathComponent("env-\(UUID().uuidString.prefix(8))")
        let body = env.keys.sorted().map { "export \($0)=\(ClaudeLauncher.shellQuote(env[$0] ?? ""))" }.joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: file.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600])
        let quoted = ClaudeLauncher.shellQuote(file.path)
        return ". \(quoted); rm -f \(quoted)"
    }

    static func sweep(_ directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("env-") {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(date) > 600 { try? fm.removeItem(at: file) }
        }
    }
}
