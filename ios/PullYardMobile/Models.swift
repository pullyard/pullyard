import Foundation

struct GitHubUser: Codable, Hashable {
    let login: String
    let name: String?
    let avatarUrl: URL?
    let htmlUrl: URL?

    init(login: String, name: String? = nil, avatarUrl: URL? = nil, htmlUrl: URL? = nil) {
        self.login = login; self.name = name; self.avatarUrl = avatarUrl; self.htmlUrl = htmlUrl
    }

    func isSameAccount(as other: GitHubUser?) -> Bool {
        guard let other else { return false }
        return login.caseInsensitiveCompare(other.login) == .orderedSame
    }
}

struct PRKey: Codable, Hashable, Identifiable {
    let repo: String
    let number: Int
    var id: String { "\(repo)#\(number)" }
}

struct PRLabel: Codable, Hashable {
    let name: String
    let color: String?
}

struct PullRequest: Codable, Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: String
    let draft: Bool?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let user: GitHubUser?
    let head: Branch
    let base: Branch
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let comments: Int?
    let reviewComments: Int?
    let requestedReviewers: [GitHubUser]?
    let merged: Bool?
    let mergedAt: Date?
    let mergeable: Bool?
    var labels: [PRLabel]? = nil
    var reviewDecision: String? = nil
    var checkState: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, draft, htmlUrl, createdAt, updatedAt, user, head, base
        case additions, deletions, changedFiles, comments, reviewComments, requestedReviewers, merged, mergedAt, mergeable, labels, reviewDecision, checkState, repo
    }

    struct Branch: Codable, Hashable {
        let label: String?
        let ref: String
        let sha: String
        var repo: BranchRepo? = nil
    }
    struct BranchRepo: Codable, Hashable { let fullName: String }

    var repo: String? = nil
    var repoName: String { repo ?? base.repo?.fullName ?? "Repository" }
    var key: PRKey? {
        guard let name = repo ?? base.repo?.fullName else { return nil }
        return PRKey(repo: name, number: number)
    }
    var shortId: String { "#\(number)" }
    var isDraft: Bool { draft ?? false }
    var isMerged: Bool { (merged ?? false) || mergedAt != nil }
    var isOpen: Bool { state.caseInsensitiveCompare("open") == .orderedSame }
    var ciState: CIState? { checkState.flatMap(CIState.init(rollup:)) }
    var reviewState: ReviewDecision? { reviewDecision.flatMap(ReviewDecision.init(rawValue:)) }
    var displayState: PRDisplayState {
        if isMerged { return .merged }
        if !isOpen { return .closed }
        return isDraft ? .draft : .open
    }
}

enum CIState: Equatable {
    case passing, failing, pending

    init?(rollup: String) {
        switch rollup.uppercased() {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }

    var title: String { switch self { case .passing: "Checks passing"; case .failing: "Checks failing"; case .pending: "Checks running" } }
    var symbol: String { switch self { case .passing: "checkmark.circle.fill"; case .failing: "xmark.circle.fill"; case .pending: "clock.fill" } }
}

enum ReviewDecision: String {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
    var title: String { switch self { case .approved: "Approved"; case .changesRequested: "Changes requested"; case .reviewRequired: "Review required" } }
    var symbol: String { switch self { case .approved: "checkmark.seal.fill"; case .changesRequested: "arrow.uturn.backward.circle.fill"; case .reviewRequired: "eye" } }
}

enum PRDisplayState: String, Codable, Hashable {
    case open, draft, merged, closed
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }
}

struct CheckRun: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let htmlUrl: URL?
    let startedAt: Date?
    let completedAt: Date?
    let output: Output?
    struct Output: Codable, Hashable { let title: String?; let summary: String? }
    var isPending: Bool { status != "completed" }
    var isSkipped: Bool { !isPending && (conclusion == "skipped" || conclusion == "neutral") }
    var isSuccess: Bool { !isPending && conclusion == "success" }
    var isFailure: Bool { !isPending && !isSuccess && !isSkipped }
    var statusTitle: String {
        if isPending { return status.replacingOccurrences(of: "_", with: " ").capitalized }
        return (conclusion ?? "completed").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CheckRunPage: Decodable { let totalCount: Int; let checkRuns: [CheckRun] }

struct CommitStatus: Decodable, Hashable {
    let id: Int
    let state: String
    let context: String
    let description: String?
    let targetUrl: URL?
    let createdAt: Date?
    let updatedAt: Date?

    var asCheckRun: CheckRun {
        let pending = state == "pending"
        let conclusion: String? = pending ? nil : (state == "success" ? "success" : "failure")
        return CheckRun(id: -id, name: context, status: pending ? "in_progress" : "completed", conclusion: conclusion, htmlUrl: targetUrl, startedAt: createdAt, completedAt: pending ? nil : updatedAt, output: description.map { .init(title: nil, summary: $0) })
    }
}

struct CombinedStatus: Decodable { let state: String; let statuses: [CommitStatus] }

enum ChecksSummary: Equatable {
    case notLoaded, none, failing(Int), running(Int), passed(Int, skipped: Int)

    init(_ checks: [CheckRun]?) {
        guard let checks else { self = .notLoaded; return }
        guard !checks.isEmpty else { self = .none; return }
        let failing = checks.filter(\.isFailure).count
        let pending = checks.filter(\.isPending).count
        if failing > 0 { self = .failing(failing) }
        else if pending > 0 { self = .running(pending) }
        else { self = .passed(checks.filter(\.isSuccess).count, skipped: checks.filter(\.isSkipped).count) }
    }

    var title: String {
        switch self {
        case .notLoaded: "Loading checks…"
        case .none: "No checks reported"
        case let .failing(count): "\(count) failing check\(count == 1 ? "" : "s")"
        case let .running(count): "\(count) check\(count == 1 ? "" : "s") running"
        case let .passed(count, skipped): skipped > 0 ? "\(count) passed · \(skipped) skipped" : "All checks passed"
        }
    }

    var symbol: String {
        switch self {
        case .notLoaded: "ellipsis.circle"
        case .none: "minus.circle"
        case .failing: "xmark.circle.fill"
        case .running: "clock.fill"
        case .passed: "checkmark.circle.fill"
        }
    }
}

struct PRReview: Codable, Identifiable, Hashable {
    let id: Int
    var nodeId: String? = nil
    let user: GitHubUser?
    let body: String?
    let state: String
    let submittedAt: Date?
    var isPending: Bool { state == "PENDING" }
}

struct PRComment: Codable, Identifiable, Hashable {
    let id: Int
    let user: GitHubUser?
    let body: String
    let createdAt: Date
    let htmlUrl: URL?
    let path: String?
    let line: Int?
    let inReplyToId: Int?
    var diffHunk: String? = nil
    var originalLine: Int? = nil
    var reactions: ReactionRollup? = nil
    var threadRootId: Int { inReplyToId ?? id }
}

struct GHNotification: Codable, Identifiable, Hashable {
    let id: String
    var unread: Bool
    let reason: String
    let updatedAt: Date
    let subject: Subject
    let repository: Repository
    struct Subject: Codable, Hashable { let title: String; let url: String?; let type: String? }
    struct Repository: Codable, Hashable { let fullName: String; let htmlUrl: URL? }

    var subjectNumber: Int? {
        guard let url = subject.url, let last = URL(string: url)?.lastPathComponent else { return nil }
        return Int(last)
    }
    var pullKey: PRKey? {
        guard subject.type == "PullRequest", let number = subjectNumber else { return nil }
        return PRKey(repo: repository.fullName, number: number)
    }
    var issueKey: PRKey? {
        guard subject.type == "Issue", let number = subjectNumber else { return nil }
        return PRKey(repo: repository.fullName, number: number)
    }
    var route: Route {
        if let pullKey { return .pull(pullKey) }
        if let issueKey { return .issue(issueKey) }
        return .notification(id)
    }
    var webURL: URL? {
        guard let raw = subject.url, let apiURL = URL(string: raw) else { return repository.htmlUrl }
        let parts = apiURL.path.split(separator: "/")
        guard parts.count >= 5 else { return repository.htmlUrl }
        let kind = parts[3] == "pulls" ? "pull" : parts[3]
        return URL(string: "https://github.com/\(repository.fullName)/\(kind)/\(parts[4])")
    }
}

struct PullRequestPage {
    let totalCount: Int
    let items: [PullRequest]
    var nextCursor: String? = nil
}

enum PRQueue: String, CaseIterable, Identifiable, Codable {
    case needsMyReview = "Needs review"
    case createdByMe = "My PRs"
    case assigned = "Assigned"
    case mentioned = "Mentioned"
    case reviewed = "Reviewed"
    var id: String { rawValue }
    var qualifier: String {
        switch self {
        case .needsMyReview: "review-requested:@me"
        case .createdByMe: "author:@me"
        case .assigned: "assignee:@me"
        case .mentioned: "mentions:@me"
        case .reviewed: "reviewed-by:@me -author:@me"
        }
    }
    var symbol: String {
        switch self {
        case .needsMyReview: "eye"
        case .createdByMe: "person"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .mentioned: "at"
        case .reviewed: "checkmark.bubble"
        }
    }
}

enum PRStatusFilter: String, CaseIterable, Identifiable, Codable {
    case open = "Open"
    case merged = "Merged"
    case closed = "Closed"
    case all = "All"
    var id: String { rawValue }
    var qualifier: String {
        switch self {
        case .open: "is:open"
        case .merged: "is:merged"
        case .closed: "is:closed is:unmerged"
        case .all: ""
        }
    }
}

struct PRListKey: Codable, Hashable {
    let queue: PRQueue
    let status: PRStatusFilter
    var project: String? = nil
    var includeQueue = true
    var custom: String? = nil

    static func saved(_ query: String, status: PRStatusFilter) -> PRListKey {
        let hasState = query.range(of: "is:(open|closed|merged)", options: .regularExpression) != nil
        return PRListKey(queue: .needsMyReview, status: hasState ? .all : status, includeQueue: false, custom: query)
    }

    static func project(_ repo: String, status: PRStatusFilter, audience: ProjectAudience) -> PRListKey {
        PRListKey(queue: audience.queue ?? .needsMyReview, status: status, project: repo, includeQueue: audience.queue != nil)
    }

    var searchQuery: String {
        if let custom { return (["is:pr", custom, status.qualifier]).filter { !$0.isEmpty }.joined(separator: " ") }
        var parts = ["is:pr"]
        if let project { parts.append("repo:\(project)") } else { parts.append("archived:false") }
        if project == nil || includeQueue { parts.append(queue.qualifier) }
        parts.append(status.qualifier)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var filtersReviewQueue: Bool { queue == .needsMyReview && includeQueue && status == .open }
}

enum ProjectAudience: String, CaseIterable, Identifiable {
    case everyone = "Everyone", needsMyReview = "Needs my review", mine = "Mine"
    var id: String { rawValue }
    var queue: PRQueue? {
        switch self { case .everyone: nil; case .needsMyReview: .needsMyReview; case .mine: .createdByMe }
    }
}

struct ProjectSummary: Codable, Hashable, Identifiable {
    let nameWithOwner: String
    var description: String? = nil
    var isPrivate = false
    var ownerAvatar: URL? = nil
    var openPullRequests: Int? = nil
    var pushedAt: Date? = nil
    var url: URL? = nil
    var id: String { nameWithOwner }
    var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    var name: String { String(nameWithOwner.split(separator: "/").last ?? Substring(nameWithOwner)) }
    var webURL: URL { url ?? URL(string: "https://github.com/\(nameWithOwner)")! }
}

enum LoadState: Equatable {
    case idle, loading, loaded(Date), failed(String)
    var isLoading: Bool { self == .loading }
    var failureMessage: String? { if case let .failed(message) = self { return message }; return nil }
}

enum AppTab: String, CaseIterable, Identifiable, Codable {
    case pulls = "Pull requests", projects = "Projects", inbox = "Inbox", search = "Search", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .inbox: "tray.full"; case .pulls: "arrow.triangle.pull"; case .projects: "folder"; case .search: "magnifyingglass"; case .settings: "gearshape" }
    }
}

enum Route: Codable, Hashable {
    case pull(PRKey)
    case notification(String)
    case project(String)
    case files(PRKey)
    case fileDiff(PRKey, String)
    case issue(PRKey)
    case list(OverviewFilter)
    case allPulls
    case newPull(repo: String, head: String?)
    case finishReview(PRKey)
    case newIssue(String)
    case browse(repo: String, ref: String?, path: String)
    case agent(String)
    case agents
}

struct PushedBranch: Codable, Hashable, Identifiable {
    let repo: String
    let branch: String
    let pushedAt: Date
    let headline: String?
    let commits: Int
    var defaultBranch: String?
    var id: String { "\(repo):\(branch)" }
}

enum OverviewFilter: Codable, Hashable {
    case queue(PRQueue)
    case readyToMerge
    case failingChecks
    case changesRequested
    case snoozed
    case saved(String)

    var title: String {
        switch self {
        case let .queue(queue): queue.rawValue
        case .readyToMerge: "Ready to merge"
        case .failingChecks: "Failing checks"
        case .changesRequested: "Changes requested"
        case .snoozed: "Snoozed"
        case let .saved(query): query
        }
    }

    var symbol: String {
        switch self {
        case let .queue(queue): queue.symbol
        case .readyToMerge: "arrow.triangle.merge"
        case .failingChecks: "xmark.octagon"
        case .changesRequested: "arrow.uturn.backward.circle"
        case .snoozed: "moon.zzz"
        case .saved: "bookmark"
        }
    }

    var listKey: PRListKey {
        switch self {
        case let .queue(queue): PRListKey(queue: queue, status: .open)
        case .readyToMerge, .failingChecks, .changesRequested, .snoozed: PRListKey(queue: .createdByMe, status: .open)
        case let .saved(query): .saved(query, status: .open)
        }
    }

    func includes(_ pull: PullRequest) -> Bool {
        switch self {
        case .queue, .saved, .snoozed: true
        case .readyToMerge: pull.reviewState == .approved && pull.ciState != .failing && !pull.isDraft
        case .failingChecks: pull.ciState == .failing
        case .changesRequested: pull.reviewState == .changesRequested
        }
    }
}
