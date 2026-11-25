import Foundation

enum MergeMethod: String, CaseIterable, Identifiable, Codable {
    case squash = "SQUASH", merge = "MERGE", rebase = "REBASE"
    var id: String { rawValue }
    var title: String {
        switch self { case .squash: "Squash and merge"; case .merge: "Create a merge commit"; case .rebase: "Rebase and merge" }
    }
    var short: String {
        switch self { case .squash: "Squash"; case .merge: "Merge commit"; case .rebase: "Rebase" }
    }
    var symbol: String {
        switch self { case .squash: "square.stack.3d.down.right"; case .merge: "arrow.triangle.merge"; case .rebase: "arrow.up.arrow.down" }
    }
}

struct ReviewerStatus: Codable, Hashable, Identifiable {
    enum State: String, Codable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", commented = "COMMENTED", dismissed = "DISMISSED", requested = "REQUESTED"
    }
    let login: String
    let avatarUrl: URL?
    let state: State
    let isTeam: Bool
    var id: String { login }
}

struct LinkedIssue: Codable, Hashable {
    let number: Int
    let title: String
    let url: URL?
}

struct ThreadState: Codable, Hashable {
    let id: String
    var isResolved: Bool
    let isOutdated: Bool
    let rootCommentID: Int?
}

struct PRInsight: Codable, Hashable {
    let nodeID: String
    var isDraft: Bool
    let mergeStateStatus: String
    let mergeable: String
    let reviewDecision: String?
    let headRefName: String
    let headSHA: String
    let isCrossRepository: Bool
    let viewerPermission: String
    let viewerCanUpdate: Bool
    let mergeMethods: [MergeMethod]
    let deleteBranchOnMerge: Bool
    let autoMergeAllowed: Bool
    var autoMergeMethod: MergeMethod?
    var autoMergeEnabled: Bool
    let labels: [PRLabel]
    let assignees: [GitHubUser]
    let milestone: String?
    let closingIssues: [LinkedIssue]
    let reviewers: [ReviewerStatus]
    var threads: [ThreadState]
    let commitCount: Int

    var canWrite: Bool { ["ADMIN", "MAINTAIN", "WRITE"].contains(viewerPermission) }
    var hasConflicts: Bool { mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" }
    var isBehind: Bool { mergeStateStatus == "BEHIND" }
    var isReadyToMerge: Bool { mergeStateStatus == "CLEAN" || mergeStateStatus == "HAS_HOOKS" || mergeStateStatus == "UNSTABLE" }
    var unresolvedCount: Int { threads.filter { !$0.isResolved }.count }
    func thread(forRoot commentID: Int) -> ThreadState? { threads.first { $0.rootCommentID == commentID } }
}

struct PRFile: Codable, Hashable, Identifiable {
    let sha: String?
    let filename: String
    let status: String
    let additions: Int
    let deletions: Int
    let changes: Int
    let patch: String?
    let previousFilename: String?
    let blobUrl: URL?
    var id: String { filename }

    var statusSymbol: String {
        switch status {
        case "added": "plus.square.fill"
        case "removed": "minus.square.fill"
        case "renamed": "arrow.right.square.fill"
        default: "pencil.line"
        }
    }
    var directory: String {
        let parts = filename.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }
    var name: String { String(filename.split(separator: "/").last ?? Substring(filename)) }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case hunk, add, delete, context }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?

    static func parse(_ patch: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        for (index, raw) in patch.components(separatedBy: "\n").enumerated() {
            if raw.hasPrefix("@@") {
                let numbers = raw.split(separator: " ").dropFirst().prefix(2)
                if let old = numbers.first, let new = numbers.dropFirst().first {
                    oldLine = Int(old.dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(new.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                result.append(DiffLine(id: index, kind: .hunk, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("+") {
                result.append(DiffLine(id: index, kind: .add, text: String(raw.dropFirst()), oldLine: nil, newLine: newLine))
                newLine += 1
            } else if raw.hasPrefix("-") {
                result.append(DiffLine(id: index, kind: .delete, text: String(raw.dropFirst()), oldLine: oldLine, newLine: nil))
                oldLine += 1
            } else if raw.hasPrefix("\\") {
                continue
            } else {
                result.append(DiffLine(id: index, kind: .context, text: String(raw.dropFirst(raw.isEmpty ? 0 : 1)), oldLine: oldLine, newLine: newLine))
                oldLine += 1; newLine += 1
            }
        }
        return result
    }
}

enum ActionsRun {
    static func runID(from url: URL?) -> Int? {
        guard let url else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "runs"), index + 1 < parts.count else { return nil }
        return Int(parts[index + 1])
    }
}

struct PRDetailSnapshot: Codable {
    let pull: PullRequest
    let reviews: [PRReview]
    let comments: [PRComment]
    let reviewComments: [PRComment]
    let checks: [CheckRun]?
    let insight: PRInsight?
    let savedAt: Date
}

enum DeepLink {
    static func route(from url: URL) -> Route? {
        if url.scheme == "pullyard" {
            let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
            if parts.first == "pull", parts.count >= 4, let number = Int(parts[3]) { return .pull(PRKey(repo: "\(parts[1])/\(parts[2])", number: number)) }
            if parts.first == "project", parts.count >= 3 { return .project("\(parts[1])/\(parts[2])") }
            return nil
        }
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let repo = "\(parts[0])/\(parts[1])"
        if parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) {
            let key = PRKey(repo: repo, number: number)
            return parts.count >= 5 && parts[4] == "files" ? .files(key) : .pull(key)
        }
        if parts.count >= 4, parts[2] == "issues", let number = Int(parts[3]) { return .issue(PRKey(repo: repo, number: number)) }
        if parts.count == 2 || (parts.count == 3 && parts[2] == "pulls") { return .project(repo) }
        return nil
    }

    static func route(fromText text: String) -> Route? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host != nil, let route = route(from: url) { return route }
        if let match = trimmed.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$", options: .regularExpression) {
            let value = String(trimmed[match])
            let pieces = value.split(separator: "#")
            if let number = Int(pieces[1]) { return .pull(PRKey(repo: String(pieces[0]), number: number)) }
        }
        return nil
    }
}

struct TimelineEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case commit, forcePush, reviewRequested, label, ready, draft, merged, closed, reopened, assigned, renamed }
    let id: String
    let date: Date
    let kind: Kind
    let actor: String?
    let text: String
    let detail: String?

    var symbol: String {
        switch kind {
        case .commit: "smallcircle.filled.circle"
        case .forcePush: "arrow.up.forward.circle"
        case .reviewRequested: "eye"
        case .label: "tag"
        case .ready: "eye.circle"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .reopened: "arrow.uturn.left.circle"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .renamed: "pencil"
        }
    }
}

enum ReactionKind: String, CaseIterable, Codable, Identifiable {
    case plusOne = "+1", minusOne = "-1", laugh, hooray, confused, heart, rocket, eyes
    var id: String { rawValue }
    var emoji: String {
        switch self { case .plusOne: "👍"; case .minusOne: "👎"; case .laugh: "😄"; case .hooray: "🎉"; case .confused: "😕"; case .heart: "❤️"; case .rocket: "🚀"; case .eyes: "👀" }
    }
}

struct ReactionRollup: Codable, Hashable {
    var plusOne = 0, minusOne = 0, laugh = 0, hooray = 0, confused = 0, heart = 0, rocket = 0, eyes = 0

    enum CodingKeys: String, CodingKey {
        case plusOne = "+1", minusOne = "-1", laugh, hooray, confused, heart, rocket, eyes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plusOne = try container.decodeIfPresent(Int.self, forKey: .plusOne) ?? 0
        minusOne = try container.decodeIfPresent(Int.self, forKey: .minusOne) ?? 0
        laugh = try container.decodeIfPresent(Int.self, forKey: .laugh) ?? 0
        hooray = try container.decodeIfPresent(Int.self, forKey: .hooray) ?? 0
        confused = try container.decodeIfPresent(Int.self, forKey: .confused) ?? 0
        heart = try container.decodeIfPresent(Int.self, forKey: .heart) ?? 0
        rocket = try container.decodeIfPresent(Int.self, forKey: .rocket) ?? 0
        eyes = try container.decodeIfPresent(Int.self, forKey: .eyes) ?? 0
    }

    func count(_ kind: ReactionKind) -> Int {
        switch kind { case .plusOne: plusOne; case .minusOne: minusOne; case .laugh: laugh; case .hooray: hooray; case .confused: confused; case .heart: heart; case .rocket: rocket; case .eyes: eyes }
    }

    mutating func increment(_ kind: ReactionKind) {
        switch kind {
        case .plusOne: plusOne += 1
        case .minusOne: minusOne += 1
        case .laugh: laugh += 1
        case .hooray: hooray += 1
        case .confused: confused += 1
        case .heart: heart += 1
        case .rocket: rocket += 1
        case .eyes: eyes += 1
        }
    }

    var nonEmpty: [(ReactionKind, Int)] { ReactionKind.allCases.map { ($0, count($0)) }.filter { $0.1 > 0 } }
}

struct GHIssue: Codable, Hashable {
    let number: Int
    let title: String
    let body: String?
    let state: String
    let stateReason: String?
    let user: GitHubUser?
    let labels: [PRLabel]?
    let assignees: [GitHubUser]?
    let comments: Int?
    let createdAt: Date
    let updatedAt: Date
    let htmlUrl: URL
    var isOpen: Bool { state == "open" }
}

enum VisitStore {
    private static let key = "mobile.visits"

    static func lastVisit(_ pull: PRKey) -> Date? {
        (UserDefaults.standard.dictionary(forKey: key)?[pull.id] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func markVisited(_ pull: PRKey) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[pull.id] = Date().timeIntervalSince1970
        if all.count > 400 {
            all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func hasUnseenActivity(_ pull: PullRequest) -> Bool {
        guard let key = pull.key, let visit = lastVisit(key) else { return false }
        return pull.updatedAt.timeIntervalSince(visit) > 5
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
