import Foundation

enum ReviewLoad {
    static let ttl: TimeInterval = 600
    static let maxPerQuery = 20

    static func valid(_ handle: String) -> Bool {
        !handle.isEmpty && handle.count <= 100 && handle.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "." }
    }

    static func query(_ handles: [String]) -> (query: String, aliases: [String: String]) {
        var aliases: [String: String] = [:]
        var parts: [String] = []
        for (i, h) in handles.filter(valid).prefix(maxPerQuery).enumerated() {
            let alias = "r\(i)"
            aliases[alias] = h
            let qualifier = h.contains("/") ? "team-review-requested:\(h)" : "review-requested:\(h)"
            parts.append("\(alias): search(query: \"is:pr is:open archived:false \(qualifier)\", type: ISSUE, first: 0) { issueCount }")
        }
        return ("query { " + parts.joined(separator: " ") + " }", aliases)
    }

    struct Hit: Decodable { let issueCount: Int }

    static func parse(_ data: [String: Hit?], aliases: [String: String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (alias, handle) in aliases {
            if let hit = data[alias], let n = hit?.issueCount { out[handle.lowercased()] = n }
        }
        return out
    }

    static func label(_ count: Int) -> String {
        count == 1 ? "1 open review" : "\(count) open reviews"
    }

    static func busy(_ count: Int) -> Bool { count >= 10 }
}

@MainActor
final class ReviewLoadStore {
    static let shared = ReviewLoadStore()
    private var cache: [String: (count: Int, at: Date)] = [:]

    func cached(_ handle: String) -> Int? {
        guard let hit = cache[handle.lowercased()], Date().timeIntervalSince(hit.at) < ReviewLoad.ttl else { return nil }
        return hit.count
    }

    func load(_ handles: [String], api: GitHubAPI) async -> [String: Int] {
        var result: [String: Int] = [:]
        var missing: [String] = []
        for h in handles {
            if let n = cached(h) { result[h.lowercased()] = n } else if ReviewLoad.valid(h) { missing.append(h) }
        }
        var start = 0
        while start < missing.count {
            let chunk = Array(missing[start..<min(start + ReviewLoad.maxPerQuery, missing.count)])
            start += ReviewLoad.maxPerQuery
            let (query, aliases) = ReviewLoad.query(chunk)
            guard let data: [String: ReviewLoad.Hit?] = try? await api.graphQL(query) else { continue }
            for (handle, n) in ReviewLoad.parse(data, aliases: aliases) {
                cache[handle] = (n, Date())
                result[handle] = n
            }
        }
        return result
    }
}
