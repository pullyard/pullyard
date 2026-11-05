import Foundation

public struct PRContextSnapshot: Codable, Equatable, Sendable {
    public struct Requirement: Codable, Equatable, Sendable {
        public let state: String
        public let title: String
        public let detail: String?

        public init(state: String, title: String, detail: String?) {
            self.state = state
            self.title = title
            self.detail = detail
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let outcome: String
        public let required: Bool?
        public let url: String?

        public init(name: String, outcome: String, required: Bool?, url: String?) {
            self.name = name
            self.outcome = outcome
            self.required = required
            self.url = url
        }
    }

    public struct Review: Codable, Equatable, Sendable {
        public let login: String
        public let state: String

        public init(login: String, state: String) {
            self.login = login
            self.state = state
        }
    }

    public struct Comment: Codable, Equatable, Sendable {
        public let author: String
        public let body: String

        public init(author: String, body: String) {
            self.author = author
            self.body = body
        }
    }

    public struct Thread: Codable, Equatable, Sendable {
        public let path: String
        public let line: Int?
        public let resolved: Bool
        public let outdated: Bool
        public let comments: [Comment]

        public init(path: String, line: Int?, resolved: Bool, outdated: Bool, comments: [Comment]) {
            self.path = path
            self.line = line
            self.resolved = resolved
            self.outdated = outdated
            self.comments = comments
        }
    }

    public struct OwnerGroup: Codable, Equatable, Sendable {
        public let owners: [String]
        public let files: [String]

        public init(owners: [String], files: [String]) {
            self.owners = owners
            self.files = files
        }
    }

    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let state: String
    public let isDraft: Bool
    public let author: String?
    public let baseRef: String
    public let headRef: String
    public let headOid: String
    public let body: String
    public let mergeStatus: String
    public let requirements: [Requirement]
    public let checks: [Check]
    public let reviews: [Review]
    public let threads: [Thread]
    public let files: [String]
    public let codeOwners: [OwnerGroup]?
    public let unownedFiles: [String]?
    public let reviewedOid: String?
    public let commitsSinceReview: Int?
    public let captured: Date

    public init(repo: String, number: Int, title: String, url: String, state: String, isDraft: Bool, author: String?, baseRef: String, headRef: String, headOid: String,
                body: String, mergeStatus: String, requirements: [Requirement], checks: [Check], reviews: [Review], threads: [Thread], files: [String],
                codeOwners: [OwnerGroup]?, unownedFiles: [String]?, reviewedOid: String?, commitsSinceReview: Int?, captured: Date = Date()) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.author = author
        self.baseRef = baseRef
        self.headRef = headRef
        self.headOid = headOid
        self.body = body
        self.mergeStatus = mergeStatus
        self.requirements = requirements
        self.checks = checks
        self.reviews = reviews
        self.threads = threads
        self.files = files
        self.codeOwners = codeOwners
        self.unownedFiles = unownedFiles
        self.reviewedOid = reviewedOid
        self.commitsSinceReview = commitsSinceReview
        self.captured = captured
    }
}

public enum PRContextStore {
    public static let maxFiles = 200
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    public static var defaultDirectory: URL {
        StackNotesFile.defaultFile.deletingLastPathComponent().appendingPathComponent("pr-context", isDirectory: true)
    }

    public static func fileName(key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }) + ".json"
    }

    public static func write(_ snapshot: PRContextSnapshot, key: String, directory: URL = defaultDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: directory.appendingPathComponent(fileName(key: key)), options: [.atomic])
        prune(directory: directory)
    }

    public static func read(key: String, directory: URL = defaultDirectory) -> PRContextSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName(key: key))) else { return nil }
        return try? decoder.decode(PRContextSnapshot.self, from: data)
    }

    public static func prune(directory: URL = defaultDirectory, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.filter { $0.pathExtension == "json" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in dated.enumerated() where index >= maxFiles || now.timeIntervalSince(entry.1) > maxAge {
            try? fm.removeItem(at: entry.0)
        }
    }
}

public enum PRContextFormatter {
    static let bodyLimit = 6000
    static let listLimit = 300

    public static func overview(_ s: PRContextSnapshot) -> String {
        var out: [String] = []
        out.append("\(s.repo)#\(s.number): \(s.title)")
        out.append("State: \(s.isDraft ? "draft, " : "")\(s.state.lowercased()) · \(s.headRef) → \(s.baseRef) · head \(s.headOid.prefix(7))\(s.author.map { " · by @\($0)" } ?? "")")
        out.append("URL: \(s.url)")
        out.append("Loaded by PullYard: \(ISO8601DateFormatter().string(from: s.captured))")
        out.append("")
        out.append("Merge status: \(s.mergeStatus)")
        for r in s.requirements {
            out.append("- [\(r.state)] \(r.title)\(r.detail.map { " — \($0)" } ?? "")")
        }
        if !s.reviews.isEmpty {
            out.append("")
            out.append("Reviewers: " + s.reviews.map { "@\($0.login) (\($0.state.lowercased().replacingOccurrences(of: "_", with: " ")))" }.joined(separator: ", "))
        }
        if let groups = s.codeOwners {
            out.append("")
            out.append("Code owners: " + (groups.isEmpty ? "none of the changed files have owners" : groups.map { "\($0.owners.joined(separator: " ")) (\($0.files.count) files)" }.joined(separator: "; ")))
            if let unowned = s.unownedFiles, !unowned.isEmpty { out.append("Files without a code owner: \(unowned.count)") }
        }
        if let oid = s.reviewedOid {
            out.append("")
            out.append("The user last reviewed commit \(oid.prefix(7))" + (s.commitsSinceReview.map { ", \($0) commit(s) ago." } ?? "; the branch history was rewritten since."))
        }
        let open = s.threads.filter { !$0.resolved }.count
        let failing = s.checks.filter { $0.outcome == "failure" }.count
        out.append("")
        out.append("\(open) unresolved review thread(s), \(failing) failing check(s), \(s.files.count) changed file(s).")
        let body = s.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            out.append("")
            out.append("Description:")
            out.append(body.count > bodyLimit ? String(body.prefix(bodyLimit)) + "\n…(truncated)" : body)
        }
        return out.joined(separator: "\n")
    }

    public static func threads(_ s: PRContextSnapshot, includeResolved: Bool) -> String {
        let list = s.threads.filter { includeResolved || !$0.resolved }
        guard !list.isEmpty else { return includeResolved ? "No review threads on \(s.repo)#\(s.number)." : "No unresolved review threads on \(s.repo)#\(s.number)." }
        return list.enumerated().map { index, t in
            var head = "\(index + 1). \(t.path)\(t.line.map { ":\($0)" } ?? "")"
            var flags: [String] = []
            if t.resolved { flags.append("resolved") }
            if t.outdated { flags.append("outdated") }
            if !flags.isEmpty { head += " (\(flags.joined(separator: ", ")))" }
            let comments = t.comments.map { "   @\($0.author): \($0.body.replacingOccurrences(of: "\n", with: "\n   "))" }
            return ([head] + comments).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    public static func checks(_ s: PRContextSnapshot) -> String {
        guard !s.checks.isEmpty else { return "No checks reported for the head commit of \(s.repo)#\(s.number)." }
        let rank = ["failure": 0, "pending": 1, "neutral": 2, "skipped": 3, "success": 4]
        let sorted = s.checks.enumerated().sorted { (rank[$0.element.outcome] ?? 5, $0.offset) < (rank[$1.element.outcome] ?? 5, $1.offset) }.map(\.element)
        return sorted.map { c in
            let req = c.required.map { $0 ? " · required" : " · optional" } ?? ""
            return "- [\(c.outcome)] \(c.name)\(req)\(c.url.map { " · \($0)" } ?? "")"
        }.joined(separator: "\n")
    }

    public static func files(_ s: PRContextSnapshot) -> String {
        guard !s.files.isEmpty else { return "No changed files recorded for \(s.repo)#\(s.number)." }
        var owner: [String: String] = [:]
        for g in s.codeOwners ?? [] { for f in g.files { owner[f] = g.owners.joined(separator: " ") } }
        var lines = s.files.prefix(listLimit).map { f in owner[f].map { "\(f) — \($0)" } ?? f }
        if s.files.count > listLimit { lines.append("…and \(s.files.count - listLimit) more") }
        return lines.joined(separator: "\n")
    }
}
