import Foundation

struct CodeOwnersRule {
    let pattern: String
    let owners: [String]
    let line: Int
    let regex: NSRegularExpression
    var section = 0
}

struct CodeOwners {
    enum Flavor { case github, gitlab }

    static let paths = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]
    static let gitlabPaths = ["CODEOWNERS", "docs/CODEOWNERS", ".gitlab/CODEOWNERS"]
    static let bitbucketPaths = [".bitbucket/CODEOWNERS", "CODEOWNERS"]

    let path: String
    let rules: [CodeOwnersRule]
    let invalidLines: [Int]
    let flavor: Flavor

    init(text: String, path: String = ".github/CODEOWNERS", flavor: Flavor = .github) {
        self.path = path
        self.flavor = flavor
        var rules: [CodeOwnersRule] = []
        var invalid: [Int] = []
        var section = 0
        var defaults: [String] = []
        for (index, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated() {
            if flavor == .gitlab, let header = Self.sectionHeader(raw) {
                section += 1
                defaults = header
                continue
            }
            let tokens = Self.tokens(raw)
            guard let pattern = tokens.first else { continue }
            var owners = Array(tokens.dropFirst())
            guard owners.allSatisfy(Self.isOwner), let regex = Self.regex(for: pattern) else {
                invalid.append(index + 1)
                continue
            }
            if owners.isEmpty, flavor == .gitlab { owners = defaults }
            rules.append(CodeOwnersRule(pattern: pattern, owners: owners, line: index + 1, regex: regex, section: section))
        }
        self.rules = rules
        invalidLines = invalid
    }

    static func sectionHeader(_ line: String) -> [String]? {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("^") { s = s.dropFirst() }
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]"), s.index(after: s.startIndex) < close else { return nil }
        var rest = s[s.index(after: close)...]
        if rest.hasPrefix("["), let count = rest.firstIndex(of: "]") { rest = rest[rest.index(after: count)...] }
        let owners = tokens(String(rest))
        return owners.allSatisfy(isOwner) ? owners : nil
    }

    func rule(for file: String) -> CodeOwnersRule? {
        let range = NSRange(file.startIndex..., in: file)
        return rules.last { $0.regex.firstMatch(in: file, range: range) != nil }
    }

    func owners(for file: String) -> [String] {
        guard flavor == .gitlab else { return rule(for: file)?.owners ?? [] }
        let range = NSRange(file.startIndex..., in: file)
        var lastBySection: [Int: CodeOwnersRule] = [:]
        for r in rules where r.regex.firstMatch(in: file, range: range) != nil { lastBySection[r.section] = r }
        var seen = Set<String>()
        return lastBySection.keys.sorted().flatMap { lastBySection[$0]?.owners ?? [] }.filter { seen.insert($0.lowercased()).inserted }
    }

    static func isOwner(_ token: String) -> Bool {
        token.hasPrefix("@") ? token.count > 1 : token.contains("@") && !token.hasPrefix("@")
    }

    private static func tokens(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "#" {
                break
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func regex(for pattern: String) -> NSRegularExpression? {
        var p = pattern
        guard !p.hasPrefix("!"), !p.contains("["), !p.contains("]") else { return nil }
        let dirOnly = p.hasSuffix("/")
        if dirOnly { p.removeLast() }
        let anchored = p.hasPrefix("/") || p.contains("/")
        if p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { return nil }
        let last = p.split(separator: "/").last.map(String.init) ?? p
        let wildcardTail = last.contains("*") || last.contains("?")
        var body = ""
        let chars = Array(p)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    let slashAfter = i + 2 < chars.count && chars[i + 2] == "/"
                    if slashAfter {
                        body += "(?:.*/)?"
                        i += 3
                    } else {
                        body += ".*"
                        i += 2
                    }
                    continue
                }
                body += "[^/]*"
            } else if c == "?" {
                body += "[^/]"
            } else {
                body += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        let prefix = anchored ? "^" : "^(?:.*/)?"
        let suffix = dirOnly ? "/.*$" : wildcardTail ? "$" : "(?:/.*)?$"
        return try? NSRegularExpression(pattern: prefix + body + suffix)
    }
}

enum CodeOwnersStatus {
    case loading, missing, failed
    case loaded(CodeOwners)
}

enum OwnerStatus: Int, Comparable {
    case changesRequested, notRequested, requested, approved

    static func < (a: OwnerStatus, b: OwnerStatus) -> Bool { a.rawValue < b.rawValue }
}

struct OwnerEntry: Hashable {
    let handle: String
    let isTeam: Bool
    let status: OwnerStatus
}

struct OwnerGroup: Identifiable {
    let owners: [OwnerEntry]
    let files: [String]

    var id: String { owners.map(\.handle).joined(separator: ",") }
    var satisfied: Bool { owners.contains { $0.status == .approved } }
}

struct OwnershipSummary {
    let groups: [OwnerGroup]
    let unowned: [String]
    let sourcePath: String

    static func build(owners: CodeOwners, files: [String], pr: PullRequestDetail) -> OwnershipSummary {
        let approved = Set(pr.latestOpinionatedReviews.nodes.filter { $0.state == "APPROVED" }.compactMap { $0.author?.login.lowercased() })
        let blocked = Set(pr.latestOpinionatedReviews.nodes.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login.lowercased() })
        let requested = Set(pr.reviewRequests.nodes.compactMap { $0.requestedReviewer?.display.lowercased() })
        var byOwners: [[String]: [String]] = [:]
        var order: [[String]] = []
        var unowned: [String] = []
        for file in files {
            let list = owners.owners(for: file)
            if list.isEmpty {
                unowned.append(file)
                continue
            }
            if byOwners[list] == nil { order.append(list) }
            byOwners[list, default: []].append(file)
        }
        let groups = order.map { list -> OwnerGroup in
            let entries = list.map { raw -> OwnerEntry in
                let handle = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
                let key = handle.lowercased()
                let isTeam = handle.contains("/")
                let status: OwnerStatus
                if blocked.contains(key) {
                    status = .changesRequested
                } else if approved.contains(key) {
                    status = .approved
                } else if requested.contains(key) {
                    status = .requested
                } else {
                    status = .notRequested
                }
                return OwnerEntry(handle: handle, isTeam: isTeam, status: status)
            }
            return OwnerGroup(owners: entries, files: byOwners[list] ?? [])
        }
        return OwnershipSummary(groups: groups, unowned: unowned, sourcePath: owners.path)
    }

    func owners(of file: String) -> [OwnerEntry]? {
        groups.first { $0.files.contains(file) }?.owners
    }

    func suggestions(excluding: Set<String>) -> [OwnerEntry] {
        var seen = Set<String>()
        return groups.filter { !$0.satisfied }.flatMap(\.owners).filter {
            $0.status == .notRequested && !$0.handle.contains("@") && !excluding.contains($0.handle.lowercased()) && seen.insert($0.handle.lowercased()).inserted
        }
    }
}
