import Foundation

public struct StackNote: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case note, question, decision
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .note: return "Note"
            case .question: return "Question"
            case .decision: return "Decision"
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var updated: Date
    public var source: String?

    public init(id: UUID = UUID(), kind: Kind = .note, text: String = "", updated: Date = Date(), source: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.updated = updated
        self.source = source
    }
}

public enum StackNotesFile {
    public static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PullYard", isDirectory: true)
        .appendingPathComponent("stack-notes.json")

    public static func key(account: String?, host: String, repo: String, number: Int) -> String {
        "\(account?.lowercased() ?? "")|\(host)|\(repo.lowercased())#\(number)"
    }

    public static func read(key: String) -> [StackNote] {
        let saved = (try? Data(contentsOf: defaultFile)).flatMap { try? JSONDecoder().decode([String: [StackNote]].self, from: $0) }?[key] ?? []
        let pending = StackNotesInbox.peek().filter { $0.key == key }.map { StackNote(kind: $0.kind, text: $0.text, updated: $0.created, source: "Claude") }
        return saved + pending
    }
}

public enum StackNotesInbox {
    public struct Entry: Codable, Sendable {
        public let key: String
        public let kind: StackNote.Kind
        public let text: String
        public let created: Date

        public init(key: String, kind: StackNote.Kind, text: String, created: Date) {
            self.key = key
            self.kind = kind
            self.text = text
            self.created = created
        }
    }

    public static var directory: URL {
        StackNotesFile.defaultFile.deletingLastPathComponent().appendingPathComponent("stack-notes-inbox", isDirectory: true)
    }

    public static func drop(_ entry: Entry) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try encoder.encode(entry).write(to: tmp, options: .atomic)
        try fm.moveItem(at: tmp, to: directory.appendingPathComponent("\(UUID().uuidString).json"))
    }

    public static func peek() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Entry.self, from: $0) } }
            .sorted { $0.created < $1.created }
    }

    public static func drain() -> [Entry] {
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

public enum StackNotesMCPServer {
    public static func run(arguments: [String]) -> Never {
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let server = Server(account: value("--account"), host: value("--host") ?? "github.com")
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = server.handle(message), let out = try? JSONSerialization.data(withJSONObject: reply) {
                try? FileHandle.standardOutput.write(contentsOf: out + Data("\n".utf8))
            }
        }
        exit(0)
    }

    public struct Server {
        public static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
        public let account: String?
        public let host: String

        public init(account: String?, host: String) {
            self.account = account
            self.host = host
        }

        public func handle(_ message: [String: Any]) -> [String: Any]? {
            guard let id = message["id"] else { return nil }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                return result(id, [
                    "protocolVersion": Self.versions.contains(params["protocolVersion"] as? String ?? "") ? params["protocolVersion"] as! String : Self.versions[0],
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
            guard let repoName = args["repo"] as? String, repoName.split(separator: "/").count == 2, !repoName.hasPrefix("/"), !repoName.hasSuffix("/"),
                  let number = (args["pr"] as? Int) ?? (args["pr"] as? String).flatMap(Int.init), number > 0 else {
                return text(id, "Pass repo as \"owner/name\" and pr as the pull request number.", error: true)
            }
            let key = StackNotesFile.key(account: account, host: host, repo: repoName, number: number)
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
                let notes = StackNotesFile.read(key: key)
                guard !notes.isEmpty else { return text(id, "No notes on \(repoName)#\(number).") }
                let lines = notes.map { "- [\($0.kind.rawValue)] \($0.text)" }
                return text(id, lines.joined(separator: "\n"))
            default:
                return text(id, "Unknown tool", error: true)
            }
        }

        public static let tools: [[String: Any]] = {
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
