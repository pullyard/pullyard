import Foundation

enum StackNotesInbox {
    struct Entry: Codable {
        let key: String
        let kind: StackNote.Kind
        let text: String
        let created: Date
    }

    static var directory: URL {
        StackNotes.defaultFile.deletingLastPathComponent().appendingPathComponent("stack-notes-inbox", isDirectory: true)
    }

    static func drop(_ entry: Entry) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try encoder.encode(entry).write(to: tmp, options: .atomic)
        try fm.moveItem(at: tmp, to: directory.appendingPathComponent("\(UUID().uuidString).json"))
    }

    static func drain() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Entry] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let entry = try? decoder.decode(Entry.self, from: data) { out.append(entry) }
            try? fm.removeItem(at: file)
        }
        return out.sorted { $0.created < $1.created }
    }
}

enum StackNotesMCP {
    static let flag = "--mcp-stack-notes"
    static let serverName = "pullyard"
    @MainActor static var target: (account: String?, host: String)?

    @MainActor static var args: [String] {
        guard let target, let json = config(account: target.account, host: target.host) else { return [] }
        return ["--mcp-config", json]
    }

    static func config(account: String?, host: String) -> String? {
        guard let exe = Bundle.main.executablePath else { return nil }
        var args = [flag, "--host", host]
        if let account { args += ["--account", account] }
        let server: [String: Any] = ["type": "stdio", "command": exe, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: server]]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func run(arguments: [String]) -> Never {
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let server = Server(account: value("--account"), host: value("--host") ?? GitProvider.github.defaultHost)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = server.handle(message), let out = try? JSONSerialization.data(withJSONObject: reply) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
        exit(0)
    }

    struct Server {
        let account: String?
        let host: String

        func handle(_ message: [String: Any]) -> [String: Any]? {
            guard let id = message["id"] else { return nil }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                return result(id, [
                    "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "pullyard", "version": "1.0"],
                    "instructions": "PullYard stack notes. Use add_stack_note when the user asks you to leave a note, question or decision on a pull request in their stack, or when you finish work on a stacked PR and something is worth remembering for the reviewer. Notes stay on the user's Mac and are never posted to GitHub.",
                ])
            case "ping":
                return result(id, [:])
            case "tools/list":
                return result(id, ["tools": Self.tools])
            case "tools/call":
                return call(id, name: params["name"] as? String, args: params["arguments"] as? [String: Any] ?? [:])
            default:
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
            }
        }

        private func result(_ id: Any, _ value: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": value]
        }

        private func text(_ id: Any, _ s: String, error: Bool = false) -> [String: Any] {
            result(id, ["content": [["type": "text", "text": s]], "isError": error])
        }

        private func call(_ id: Any, name: String?, args: [String: Any]) -> [String: Any] {
            guard let repoName = args["repo"] as? String, repoName.split(separator: "/").count == 2, let repo = RepoRef(full: repoName),
                  let number = (args["pr"] as? Int) ?? (args["pr"] as? String).flatMap(Int.init), number > 0 else {
                return text(id, "Pass repo as \"owner/name\" and pr as the pull request number.", error: true)
            }
            let key = StackNotes.key(account: account, host: host, repo: repo, number: number)
            switch name {
            case "add_stack_note":
                let body = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return text(id, "text is empty", error: true) }
                guard body.count <= 4000 else { return text(id, "Keep notes under 4000 characters.", error: true) }
                let kind = (args["kind"] as? String).flatMap(StackNote.Kind.init(rawValue:)) ?? .note
                do {
                    try StackNotesInbox.drop(.init(key: key, kind: kind, text: body, created: Date()))
                    return text(id, "Added a \(kind.rawValue) to \(repoName)#\(number). It shows on the PR's card in PullYard's Stack tab.")
                } catch {
                    return text(id, "Couldn't save the note: \(error.localizedDescription)", error: true)
                }
            case "list_stack_notes":
                let notes = StackNotes.read(key: key)
                guard !notes.isEmpty else { return text(id, "No notes on \(repoName)#\(number).") }
                let lines = notes.map { "- [\($0.kind.rawValue)] \($0.text)" }
                return text(id, lines.joined(separator: "\n"))
            default:
                return text(id, "Unknown tool", error: true)
            }
        }

        static let tools: [[String: Any]] = {
            let target: [String: Any] = [
                "repo": ["type": "string", "description": "Repository as owner/name, e.g. pullyard/pullyard"],
                "pr": ["type": "integer", "description": "Pull request number"],
            ]
            var addProps = target
            addProps["kind"] = ["type": "string", "enum": ["note", "question", "decision"], "description": "note (default), question or decision"]
            addProps["text"] = ["type": "string", "description": "The note text, plain text or short Markdown"]
            return [
                [
                    "name": "add_stack_note",
                    "description": "Add a note, question or decision to a pull request card in the user's PullYard Stack view. Local to the user's Mac, never posted to GitHub.",
                    "inputSchema": ["type": "object", "properties": addProps, "required": ["repo", "pr", "text"]],
                ],
                [
                    "name": "list_stack_notes",
                    "description": "List the PullYard stack notes on a pull request.",
                    "inputSchema": ["type": "object", "properties": target, "required": ["repo", "pr"]],
                    "annotations": ["readOnlyHint": true],
                ],
            ]
        }()
    }
}
