import Foundation

enum GitHubError: LocalizedError, Equatable {
    case message(String)
    case unauthorized
    case rateLimited(Date?)
    case secondaryRateLimit(Date?)
    case missingScopes([String])
    case ssoRequired
    case forbidden(String)
    case notFound(String?)
    case validation(String)
    case offline
    case server(Int)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        case .unauthorized: "GitHub rejected this token. It may have expired or been revoked. Sign in again."
        case let .rateLimited(until): "GitHub rate limit reached. Try again \(until.map { "at \($0.formatted(date: .omitted, time: .shortened))" } ?? "later")."
        case let .secondaryRateLimit(until): "GitHub is temporarily limiting requests. Try again \(until.map { "at \($0.formatted(date: .omitted, time: .shortened))" } ?? "in a minute")."
        case let .missingScopes(scopes): "This token is missing the \(scopes.joined(separator: ", ")) scope. Create a token with it and sign in again."
        case .ssoRequired: "This organization requires SAML SSO. Authorize your token for the organization in GitHub settings, then try again."
        case let .forbidden(message): message
        case let .notFound(context): context ?? "Not found. The item may have been deleted, or this token can't access the repository."
        case let .validation(message): message
        case .offline: "You're offline. Showing the last saved data."
        case let .server(code): "GitHub is having trouble (\(code)). Try again in a moment."
        }
    }

    var isAuthFailure: Bool { self == .unauthorized }
    var isRateLimit: Bool {
        switch self { case .rateLimited, .secondaryRateLimit: true; default: false }
    }
    var retryDate: Date? {
        switch self { case let .rateLimited(date), let .secondaryRateLimit(date): date; default: nil }
    }

    static func map(response http: HTTPURLResponse, data: Data, grantedScopes: [String] = []) -> GitHubError {
        struct ErrorBody: Decodable {
            let message: String?
            let errors: [Detail]?
            struct Detail: Decodable { let message: String?; let code: String?; let field: String? }
        }
        let decoder = JSONDecoder()
        let body = try? decoder.decode(ErrorBody.self, from: data)
        let message = body?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        switch http.statusCode {
        case 401:
            return .unauthorized
        case 404:
            return .notFound(nil)
        case 422:
            let details = (body?.errors ?? []).compactMap { $0.message ?? $0.code.map { "\($0)" } }.filter { !$0.isEmpty }
            return .validation(details.isEmpty ? message : details.joined(separator: "\n"))
        case 403, 429:
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { return .rateLimited(reset) }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).map { Date(timeIntervalSinceNow: $0) }
            let lowercased = message.lowercased()
            if http.statusCode == 429 || retryAfter != nil || lowercased.contains("secondary rate limit") || lowercased.contains("abuse detection") {
                return .secondaryRateLimit(retryAfter ?? reset)
            }
            if http.value(forHTTPHeaderField: "X-GitHub-SSO")?.localizedCaseInsensitiveContains("required") == true { return .ssoRequired }
            if let accepted = http.value(forHTTPHeaderField: "X-Accepted-OAuth-Scopes") {
                let needed = accepted.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !needed.isEmpty, !needed.contains(where: grantedScopes.contains) { return .missingScopes(needed) }
            }
            return .forbidden(message)
        case 500...599:
            return .server(http.statusCode)
        default:
            return .message("GitHub (\(http.statusCode)): \(message)")
        }
    }

    static func map(urlError: URLError) -> Error {
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
            return GitHubError.offline
        default:
            return GitHubError.message(urlError.localizedDescription)
        }
    }
}

extension Error {
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        return false
    }
    var asGitHubError: GitHubError? { self as? GitHubError }
}

enum ReviewEvent: String, CaseIterable, Identifiable, Equatable, Codable {
    case approve = "APPROVE", requestChanges = "REQUEST_CHANGES", comment = "COMMENT"
    var id: String { rawValue }
    var title: String { switch self { case .approve: "Approve"; case .requestChanges: "Request changes"; case .comment: "Comment" } }
}

protocol GitHubAPI: AnyObject {
    func currentUser() async throws -> (user: GitHubUser, scopes: [String])
    func pullRequests(list: PRListKey, cursor: String?, perPage: Int) async throws -> PullRequestPage
    func searchPullRequests(_ query: String, cursor: String?) async throws -> PullRequestPage
    func pullRequest(_ key: PRKey) async throws -> PullRequest
    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun]
    func reviews(_ key: PRKey) async throws -> [PRReview]
    func comments(_ key: PRKey) async throws -> [PRComment]
    func reviewComments(_ key: PRKey) async throws -> [PRComment]
    func notifications() async throws -> [GHNotification]
    func addComment(_ key: PRKey, body: String) async throws
    func reply(_ key: PRKey, commentID: Int, body: String) async throws
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws
    func markRead(_ notificationID: String) async throws
    func markDone(_ notificationID: String) async throws
    func mute(_ notificationID: String) async throws
    func markAllRead() async throws
    func repositories() async throws -> [ProjectSummary]
    func insight(_ key: PRKey) async throws -> PRInsight
    func files(_ key: PRKey) async throws -> [PRFile]
    func merge(_ key: PRKey, method: MergeMethod, title: String?, message: String?, sha: String) async throws
    func deleteBranch(repo: String, branch: String) async throws
    func updateBranch(_ key: PRKey, expectedHeadSHA: String) async throws
    func setState(_ key: PRKey, open: Bool) async throws
    func requestReviewers(_ key: PRKey, logins: [String]) async throws
    func setThreadResolved(threadID: String, resolved: Bool) async throws
    func setDraft(pullID: String, draft: Bool) async throws
    func setAutoMerge(pullID: String, method: MergeMethod?) async throws
    func rerunFailedJobs(repo: String, runID: Int) async throws
    func rerequestCheckRun(repo: String, checkRunID: Int) async throws
    func timeline(_ key: PRKey) async throws -> [TimelineEvent]
    func addReaction(_ key: PRKey, commentID: Int, reviewComment: Bool, content: ReactionKind) async throws
    func issue(_ key: PRKey) async throws -> GHIssue
    func setIssueState(_ key: PRKey, open: Bool) async throws
    func addPendingLineComment(pullID: String, reviewNodeID: String?, path: String, line: Int, side: String, body: String) async throws
    func addSingleLineComment(_ key: PRKey, commitID: String, path: String, line: Int, side: String, body: String) async throws
    func viewedStates(_ key: PRKey) async throws -> [String: Bool]
    func setFileViewed(pullID: String, path: String, viewed: Bool) async throws
    func pendingCommentCount(_ key: PRKey, reviewID: Int) async throws -> Int
    func recentPushes(login: String) async throws -> [PushedBranch]
    func branches(repo: String) async throws -> [String]
    func defaultBranch(repo: String) async throws -> String
    func compare(repo: String, base: String, head: String) async throws -> BranchComparison
    func createPull(repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> PRKey
}

extension GitHubAPI {
    func insight(_ key: PRKey) async throws -> PRInsight { throw GitHubError.message("Not available.") }
    func files(_ key: PRKey) async throws -> [PRFile] { [] }
    func merge(_ key: PRKey, method: MergeMethod, title: String?, message: String?, sha: String) async throws {}
    func deleteBranch(repo: String, branch: String) async throws {}
    func updateBranch(_ key: PRKey, expectedHeadSHA: String) async throws {}
    func setState(_ key: PRKey, open: Bool) async throws {}
    func requestReviewers(_ key: PRKey, logins: [String]) async throws {}
    func setThreadResolved(threadID: String, resolved: Bool) async throws {}
    func setDraft(pullID: String, draft: Bool) async throws {}
    func setAutoMerge(pullID: String, method: MergeMethod?) async throws {}
    func rerunFailedJobs(repo: String, runID: Int) async throws {}
    func rerequestCheckRun(repo: String, checkRunID: Int) async throws {}
    func timeline(_ key: PRKey) async throws -> [TimelineEvent] { [] }
    func addReaction(_ key: PRKey, commentID: Int, reviewComment: Bool, content: ReactionKind) async throws {}
    func issue(_ key: PRKey) async throws -> GHIssue { throw GitHubError.message("Not available.") }
    func setIssueState(_ key: PRKey, open: Bool) async throws {}
    func addPendingLineComment(pullID: String, reviewNodeID: String?, path: String, line: Int, side: String, body: String) async throws {}
    func addSingleLineComment(_ key: PRKey, commitID: String, path: String, line: Int, side: String, body: String) async throws {}
    func viewedStates(_ key: PRKey) async throws -> [String: Bool] { [:] }
    func setFileViewed(pullID: String, path: String, viewed: Bool) async throws {}
    func pendingCommentCount(_ key: PRKey, reviewID: Int) async throws -> Int { 0 }
    func recentPushes(login: String) async throws -> [PushedBranch] { [] }
    func branches(repo: String) async throws -> [String] { [] }
    func defaultBranch(repo: String) async throws -> String { "main" }
    func compare(repo: String, base: String, head: String) async throws -> BranchComparison { BranchComparison(aheadBy: 0, behindBy: 0, messages: [], files: 0) }
    func createPull(repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> PRKey { throw GitHubError.message("Not available.") }
}

struct BranchComparison: Hashable {
    let aheadBy: Int
    let behindBy: Int
    let messages: [String]
    let files: Int
}

final class GitHubClient: GitHubAPI {
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let base = URL(string: "https://api.github.com")!
    private let conditional = ConditionalCache()
    private var grantedScopes: [String] = []

    init(token: String, session: URLSession? = nil) {
        self.token = token
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 25
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        decoder = GitHubClient.makeDecoder()
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601Parsing.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
        }
        return decoder
    }

    func currentUser() async throws -> (user: GitHubUser, scopes: [String]) {
        let (data, response) = try await raw("GET", "/user", conditional: false)
        let scopes = (response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        grantedScopes = scopes
        return (try decode(GitHubUser.self, data), scopes)
    }

    func pullRequests(list: PRListKey, cursor: String? = nil, perPage: Int = 50) async throws -> PullRequestPage {
        try await graphQLSearch("\(list.searchQuery) sort:updated-desc", cursor: cursor, first: perPage)
    }

    func searchPullRequests(_ query: String, cursor: String? = nil) async throws -> PullRequestPage {
        try await graphQLSearch("is:pr \(query)", cursor: cursor, first: 30)
    }

    func repositories() async throws -> [ProjectSummary] {
        var result: [ProjectSummary] = []
        var cursor: String?
        for _ in 0..<3 {
            var variables: [String: Any] = [:]
            if let cursor { variables["after"] = cursor }
            let data: GQLRepositoriesData = try await graphQL(GQLRepositoriesData.query, variables: variables)
            result += data.viewer.repositories.nodes.compactMap { $0?.summary }
            guard data.viewer.repositories.pageInfo.hasNextPage, let next = data.viewer.repositories.pageInfo.endCursor else { break }
            cursor = next
        }
        return result
    }

    private func graphQLSearch(_ query: String, cursor: String?, first: Int) async throws -> PullRequestPage {
        var variables: [String: Any] = ["q": query, "first": first]
        if let cursor { variables["after"] = cursor }
        let data: GQLSearchData = try await graphQL(GQLSearchData.query, variables: variables)
        let items = data.search.nodes.compactMap { $0?.pullRequest }
        return PullRequestPage(totalCount: min(data.search.issueCount, 1_000), items: items, nextCursor: data.search.pageInfo.hasNextPage ? data.search.pageInfo.endCursor : nil)
    }

    private func graphQL<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        let (data, _) = try await raw("POST", "/graphql", body: ["query": query, "variables": variables], conditional: false)
        let envelope = try decode(GQLEnvelope<T>.self, data)
        if let problems = envelope.errors, !problems.isEmpty {
            if problems.contains(where: { $0.type == "RATE_LIMITED" }) { throw GitHubError.secondaryRateLimit(nil) }
            if envelope.data == nil { throw GitHubError.message(problems.map(\.message).joined(separator: "\n")) }
        }
        guard let value = envelope.data else { throw GitHubError.message("GitHub returned an empty response.") }
        return value
    }

    func pullRequest(_ key: PRKey) async throws -> PullRequest {
        do {
            var value: PullRequest = try await get("/repos/\(path(key.repo))/pulls/\(key.number)")
            value.repo = key.repo
            return value
        } catch GitHubError.notFound {
            throw GitHubError.notFound("\(key.repo) #\(key.number) is unavailable. It may have been deleted, or this token can't access the repository.")
        }
    }

    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun] {
        var runs: [CheckRun] = []
        var next: String? = "/repos/\(path(key.repo))/commits/\(path(sha))/check-runs?per_page=100"
        var pages = 0
        while let current = next, pages < 3 {
            let (data, response) = try await raw("GET", current)
            runs += try decode(CheckRunPage.self, data).checkRuns
            next = Self.nextLink(response)
            pages += 1
        }
        let combined: CombinedStatus? = try? await get("/repos/\(path(key.repo))/commits/\(path(sha))/status?per_page=100")
        var latestByContext: [String: CommitStatus] = [:]
        for status in combined?.statuses ?? [] where latestByContext[status.context] == nil { latestByContext[status.context] = status }
        let statuses = latestByContext.values.sorted { $0.context < $1.context }.map(\.asCheckRun)
        var latestRuns: [String: CheckRun] = [:]
        for run in runs {
            if let existing = latestRuns[run.name], (existing.startedAt ?? .distantPast) >= (run.startedAt ?? .distantPast) { continue }
            latestRuns[run.name] = run
        }
        return (latestRuns.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) + statuses
    }

    func reviews(_ key: PRKey) async throws -> [PRReview] { try await paginated("/repos/\(path(key.repo))/pulls/\(key.number)/reviews?per_page=100") }
    func comments(_ key: PRKey) async throws -> [PRComment] { try await paginated("/repos/\(path(key.repo))/issues/\(key.number)/comments?per_page=100") }
    func reviewComments(_ key: PRKey) async throws -> [PRComment] { try await paginated("/repos/\(path(key.repo))/pulls/\(key.number)/comments?per_page=100") }
    func notifications() async throws -> [GHNotification] {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 86_400))
        return try await paginated("/notifications?all=true&since=\(encodeQuery(since))&per_page=50", maxPages: 4)
    }

    func addComment(_ key: PRKey, body: String) async throws {
        try await send("POST", "/repos/\(path(key.repo))/issues/\(key.number)/comments", body: ["body": body])
    }
    func reply(_ key: PRKey, commentID: Int, body: String) async throws {
        try await send("POST", "/repos/\(path(key.repo))/pulls/\(key.number)/comments/\(commentID)/replies", body: ["body": body])
    }
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws {
        var payload = ["event": event.rawValue]
        if !body.isEmpty { payload["body"] = body }
        try await send("POST", "/repos/\(path(key.repo))/pulls/\(key.number)/reviews", body: payload)
    }
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws {
        var payload = ["event": event.rawValue]
        if !body.isEmpty { payload["body"] = body }
        try await send("POST", "/repos/\(path(key.repo))/pulls/\(key.number)/reviews/\(reviewID)/events", body: payload)
    }
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws {
        try await send("DELETE", "/repos/\(path(key.repo))/pulls/\(key.number)/reviews/\(reviewID)")
    }
    func markRead(_ notificationID: String) async throws { try await send("PATCH", "/notifications/threads/\(path(notificationID))") }
    func markDone(_ notificationID: String) async throws { try await send("DELETE", "/notifications/threads/\(path(notificationID))") }
    func mute(_ notificationID: String) async throws {
        try await send("PUT", "/notifications/threads/\(path(notificationID))/subscription", body: ["ignored": true])
        try await markDone(notificationID)
    }
    func markAllRead() async throws {
        try await send("PUT", "/notifications", body: ["last_read_at": ISO8601DateFormatter().string(from: Date()), "read": true])
    }

    static func nextLink(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"next\"" }) else { continue }
            return pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        return nil
    }

    private func encodeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+#=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    private func path(_ value: String) -> String {
        value.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
    }
    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, url.host == base.host else { throw GitHubError.message("Invalid GitHub API path.") }
        return url
    }

    private func raw(_ method: String, _ path: String, body: [String: Any]? = nil, conditional useConditional: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let target = try url(path)
        var request = URLRequest(url: target); request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PullYard-iOS", forHTTPHeaderField: "User-Agent")
        let cacheable = method == "GET" && useConditional
        let cached = cacheable ? conditional.entry(for: target) : nil
        if let cached {
            if let etag = cached.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = cached.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError { throw GitHubError.map(urlError: error) }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.message("GitHub returned an invalid response.") }
        if http.statusCode == 304, let cached { return (cached.data, http) }
        if (200..<300).contains(http.statusCode) {
            if cacheable {
                let etag = http.value(forHTTPHeaderField: "ETag")
                let modified = http.value(forHTTPHeaderField: "Last-Modified")
                if etag != nil || modified != nil { conditional.store(.init(etag: etag, lastModified: modified, data: data), for: target) }
            }
            return (data, http)
        }
        throw GitHubError.map(response: http, data: data, grantedScopes: grantedScopes)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw GitHubError.message("Couldn't read GitHub's response. \(error.localizedDescription)") }
    }
    private func get<T: Decodable>(_ path: String) async throws -> T { let (data, _) = try await raw("GET", path); return try decode(T.self, data) }
    private func paginated<T: Decodable>(_ path: String, maxPages: Int = 10) async throws -> [T] {
        var items: [T] = []
        var next: String? = path
        var pages = 0
        while let current = next, pages < maxPages {
            try Task.checkCancellation()
            let (data, response) = try await raw("GET", current)
            items += try decode([T].self, data)
            next = Self.nextLink(response)
            pages += 1
        }
        return items
    }
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws { _ = try await raw(method, path, body: body, conditional: false) }
}

enum ISO8601Parsing {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter
    }()
    private static let lock = NSLock()
    static func date(from value: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

private final class ConditionalCache {
    struct Entry { let etag: String?; let lastModified: String?; let data: Data }
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private let lock = NSLock()
    private let limit = 120

    func entry(for url: URL) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[url]
    }
    func store(_ entry: Entry, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        if entries[url] == nil { order.append(url) }
        entries[url] = entry
        if order.count > limit { entries[order.removeFirst()] = nil }
    }
}

private struct GQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [Problem]?
    struct Problem: Decodable { let message: String; let type: String? }
}

private struct GQLSearchData: Decodable {
    static let query = """
    query($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            databaseId number title url state isDraft merged mergedAt createdAt updatedAt
            additions deletions changedFiles reviewDecision
            author { login avatarUrl url }
            repository { nameWithOwner }
            comments { totalCount }
            labels(first: 3) { nodes { name color } }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    let search: Connection

    struct Connection: Decodable {
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [Node?]
    }
    struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    struct Node: Decodable {
        let databaseId: Int?
        let number: Int?
        let title: String?
        let url: URL?
        let state: String?
        let isDraft: Bool?
        let merged: Bool?
        let mergedAt: Date?
        let createdAt: Date?
        let updatedAt: Date?
        let additions: Int?
        let deletions: Int?
        let changedFiles: Int?
        let reviewDecision: String?
        let author: Author?
        let repository: Repository?
        let comments: Count?
        let labels: Labels?
        let commits: Commits?

        struct Author: Decodable { let login: String; let avatarUrl: URL?; let url: URL? }
        struct Repository: Decodable { let nameWithOwner: String }
        struct Count: Decodable { let totalCount: Int }
        struct Labels: Decodable { let nodes: [PRLabel?] }
        struct Commits: Decodable {
            let nodes: [CommitNode?]
            struct CommitNode: Decodable { let commit: Commit }
            struct Commit: Decodable { let statusCheckRollup: Rollup? }
            struct Rollup: Decodable { let state: String }
        }

        var pullRequest: PullRequest? {
            guard let databaseId, let number, let title, let url, let state, let repo = repository?.nameWithOwner, let updatedAt else { return nil }
            let merged = (merged ?? false) || state == "MERGED"
            return PullRequest(id: databaseId, number: number, title: title, body: nil, state: state == "OPEN" ? "open" : "closed", draft: isDraft, htmlUrl: url, createdAt: createdAt ?? updatedAt, updatedAt: updatedAt, user: author.map { GitHubUser(login: $0.login, avatarUrl: $0.avatarUrl, htmlUrl: $0.url) }, head: .init(label: nil, ref: "", sha: ""), base: .init(label: nil, ref: "", sha: ""), additions: additions, deletions: deletions, changedFiles: changedFiles, comments: comments?.totalCount, reviewComments: nil, requestedReviewers: nil, merged: merged, mergedAt: mergedAt, mergeable: nil, labels: labels?.nodes.compactMap { $0 }, reviewDecision: reviewDecision, checkState: commits?.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state, repo: repo)
        }
    }
}

private struct GQLRepositoriesData: Decodable {
    static let query = """
    query($after: String) {
      viewer {
        repositories(first: 100, after: $after, isArchived: false, affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER], ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER], orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            nameWithOwner description isPrivate pushedAt url
            owner { avatarUrl }
            pullRequests(states: OPEN) { totalCount }
          }
        }
      }
    }
    """

    let viewer: Viewer
    struct Viewer: Decodable { let repositories: Connection }
    struct Connection: Decodable { let pageInfo: GQLSearchData.PageInfo; let nodes: [Node?] }
    struct Node: Decodable {
        let nameWithOwner: String
        let description: String?
        let isPrivate: Bool?
        let pushedAt: Date?
        let url: URL?
        let owner: Owner?
        let pullRequests: Count?
        struct Owner: Decodable { let avatarUrl: URL? }
        struct Count: Decodable { let totalCount: Int }
        var summary: ProjectSummary {
            ProjectSummary(nameWithOwner: nameWithOwner, description: description, isPrivate: isPrivate ?? false, ownerAvatar: owner?.avatarUrl, openPullRequests: pullRequests?.totalCount, pushedAt: pushedAt, url: url)
        }
    }
}

extension GitHubClient {
    func insight(_ key: PRKey) async throws -> PRInsight {
        let parts = key.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubError.message("Invalid repository.") }
        let data: GQLInsightData = try await graphQL(GQLInsightData.query, variables: ["owner": parts[0], "name": parts[1], "number": key.number])
        guard let insight = data.insight else { throw GitHubError.notFound(nil) }
        return insight
    }

    func files(_ key: PRKey) async throws -> [PRFile] {
        try await paginated("/repos/\(path(key.repo))/pulls/\(key.number)/files?per_page=100", maxPages: 30)
    }

    func merge(_ key: PRKey, method: MergeMethod, title: String?, message: String?, sha: String) async throws {
        var body: [String: Any] = ["merge_method": method.rawValue.lowercased(), "sha": sha]
        if let title, !title.isEmpty { body["commit_title"] = title }
        if let message { body["commit_message"] = message }
        do {
            try await send("PUT", "/repos/\(path(key.repo))/pulls/\(key.number)/merge", body: body)
        } catch let error as GitHubError {
            if case let .message(text) = error, text.contains("(405)") { throw GitHubError.validation("GitHub can't merge this pull request yet. Check required reviews and checks.") }
            if case let .message(text) = error, text.contains("(409)") { throw GitHubError.validation("The branch changed while you were merging. Refresh and try again.") }
            throw error
        }
    }

    func deleteBranch(repo: String, branch: String) async throws {
        try await send("DELETE", "/repos/\(path(repo))/git/refs/heads/\(path(branch))")
    }

    func updateBranch(_ key: PRKey, expectedHeadSHA: String) async throws {
        try await send("PUT", "/repos/\(path(key.repo))/pulls/\(key.number)/update-branch", body: ["expected_head_sha": expectedHeadSHA])
    }

    func setState(_ key: PRKey, open: Bool) async throws {
        try await send("PATCH", "/repos/\(path(key.repo))/pulls/\(key.number)", body: ["state": open ? "open" : "closed"])
    }

    func requestReviewers(_ key: PRKey, logins: [String]) async throws {
        try await send("POST", "/repos/\(path(key.repo))/pulls/\(key.number)/requested_reviewers", body: ["reviewers": logins])
    }

    func setThreadResolved(threadID: String, resolved: Bool) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { id } } }"
        let _: GQLEmpty = try await graphQL(mutation, variables: ["id": threadID])
    }

    func setDraft(pullID: String, draft: Bool) async throws {
        let mutation = draft
            ? "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { id } } }"
            : "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { id } } }"
        let _: GQLEmpty = try await graphQL(mutation, variables: ["id": pullID])
    }

    func setAutoMerge(pullID: String, method: MergeMethod?) async throws {
        if let method {
            let _: GQLEmpty = try await graphQL("mutation($id: ID!, $method: PullRequestMergeMethod!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method}) { pullRequest { id } } }", variables: ["id": pullID, "method": method.rawValue])
        } else {
            let _: GQLEmpty = try await graphQL("mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } } }", variables: ["id": pullID])
        }
    }

    func rerunFailedJobs(repo: String, runID: Int) async throws {
        try await send("POST", "/repos/\(path(repo))/actions/runs/\(runID)/rerun-failed-jobs")
    }

    func rerequestCheckRun(repo: String, checkRunID: Int) async throws {
        try await send("POST", "/repos/\(path(repo))/check-runs/\(checkRunID)/rerequest")
    }
}

private struct GQLEmpty: Decodable {}

private struct GQLInsightData: Decodable {
    static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed deleteBranchOnMerge autoMergeAllowed
        pullRequest(number: $number) {
          id isDraft mergeStateStatus mergeable reviewDecision headRefName headRefOid isCrossRepository viewerCanUpdate
          autoMergeRequest { mergeMethod enabledBy { login } }
          labels(first: 20) { nodes { name color } }
          assignees(first: 10) { nodes { login avatarUrl } }
          milestone { title }
          closingIssuesReferences(first: 5) { nodes { number title url } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login avatarUrl } ... on Team { name } } } }
          latestOpinionatedReviews(first: 20) { nodes { author { login avatarUrl } state submittedAt } }
          reviewThreads(first: 100) { nodes { id isResolved isOutdated comments(first: 1) { nodes { databaseId } } } }
          commits { totalCount }
        }
      }
    }
    """

    let repository: Repository?

    struct Repository: Decodable {
        let viewerPermission: String?
        let mergeCommitAllowed: Bool?
        let squashMergeAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let deleteBranchOnMerge: Bool?
        let autoMergeAllowed: Bool?
        let pullRequest: Pull?
    }
    struct Pull: Decodable {
        let id: String
        let isDraft: Bool
        let mergeStateStatus: String?
        let mergeable: String?
        let reviewDecision: String?
        let headRefName: String
        let headRefOid: String
        let isCrossRepository: Bool
        let viewerCanUpdate: Bool?
        let autoMergeRequest: AutoMerge?
        let labels: Nodes<PRLabel>?
        let assignees: Nodes<Person>?
        let milestone: Milestone?
        let closingIssuesReferences: Nodes<Issue>?
        let reviewRequests: Nodes<Request>?
        let latestOpinionatedReviews: Nodes<Review>?
        let reviewThreads: Nodes<Thread>?
        let commits: Count?
    }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T?]? }
    struct Person: Decodable { let login: String; let avatarUrl: URL? }
    struct AutoMerge: Decodable { let mergeMethod: String?; let enabledBy: Person? }
    struct Milestone: Decodable { let title: String }
    struct Issue: Decodable { let number: Int; let title: String; let url: URL? }
    struct Request: Decodable { let requestedReviewer: Reviewer? }
    struct Reviewer: Decodable { let login: String?; let avatarUrl: URL?; let name: String? }
    struct Review: Decodable { let author: Person?; let state: String; let submittedAt: Date? }
    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let comments: Nodes<Comment>?
        struct Comment: Decodable { let databaseId: Int? }
    }
    struct Count: Decodable { let totalCount: Int }

    var insight: PRInsight? {
        guard let repository, let pr = repository.pullRequest else { return nil }
        var methods: [MergeMethod] = []
        if repository.squashMergeAllowed ?? true { methods.append(.squash) }
        if repository.mergeCommitAllowed ?? true { methods.append(.merge) }
        if repository.rebaseMergeAllowed ?? true { methods.append(.rebase) }
        let requested = (pr.reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer }.map { ReviewerStatus(login: $0.login ?? $0.name ?? "team", avatarUrl: $0.avatarUrl, state: .requested, isTeam: $0.login == nil) }
        let reviewed = (pr.latestOpinionatedReviews?.nodes ?? []).compactMap { $0 }.compactMap { review -> ReviewerStatus? in
            guard let author = review.author else { return nil }
            return ReviewerStatus(login: author.login, avatarUrl: author.avatarUrl, state: ReviewerStatus.State(rawValue: review.state) ?? .commented, isTeam: false)
        }
        let requestedLogins = Set(requested.map(\.login))
        return PRInsight(
            nodeID: pr.id,
            isDraft: pr.isDraft,
            mergeStateStatus: pr.mergeStateStatus ?? "UNKNOWN",
            mergeable: pr.mergeable ?? "UNKNOWN",
            reviewDecision: pr.reviewDecision,
            headRefName: pr.headRefName,
            headSHA: pr.headRefOid,
            isCrossRepository: pr.isCrossRepository,
            viewerPermission: repository.viewerPermission ?? "READ",
            viewerCanUpdate: pr.viewerCanUpdate ?? false,
            mergeMethods: methods,
            deleteBranchOnMerge: repository.deleteBranchOnMerge ?? false,
            autoMergeAllowed: repository.autoMergeAllowed ?? false,
            autoMergeMethod: pr.autoMergeRequest?.mergeMethod.flatMap(MergeMethod.init(rawValue:)),
            autoMergeEnabled: pr.autoMergeRequest != nil,
            labels: (pr.labels?.nodes ?? []).compactMap { $0 },
            assignees: (pr.assignees?.nodes ?? []).compactMap { $0 }.map { GitHubUser(login: $0.login, avatarUrl: $0.avatarUrl) },
            milestone: pr.milestone?.title,
            closingIssues: (pr.closingIssuesReferences?.nodes ?? []).compactMap { $0 }.map { LinkedIssue(number: $0.number, title: $0.title, url: $0.url) },
            reviewers: reviewed.filter { !requestedLogins.contains($0.login) } + requested,
            threads: (pr.reviewThreads?.nodes ?? []).compactMap { $0 }.map { ThreadState(id: $0.id, isResolved: $0.isResolved, isOutdated: $0.isOutdated, rootCommentID: $0.comments?.nodes?.compactMap { $0?.databaseId }.first) },
            commitCount: pr.commits?.totalCount ?? 0
        )
    }
}

extension GitHubClient {
    func timeline(_ key: PRKey) async throws -> [TimelineEvent] {
        let parts = key.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        let data: GQLTimelineData = try await graphQL(GQLTimelineData.query, variables: ["owner": parts[0], "name": parts[1], "number": key.number])
        return data.events
    }

    func addReaction(_ key: PRKey, commentID: Int, reviewComment: Bool, content: ReactionKind) async throws {
        let kind = reviewComment ? "pulls" : "issues"
        try await send("POST", "/repos/\(path(key.repo))/\(kind)/comments/\(commentID)/reactions", body: ["content": content.rawValue])
    }

    func issue(_ key: PRKey) async throws -> GHIssue {
        try await get("/repos/\(path(key.repo))/issues/\(key.number)")
    }

    func setIssueState(_ key: PRKey, open: Bool) async throws {
        try await send("PATCH", "/repos/\(path(key.repo))/issues/\(key.number)", body: ["state": open ? "open" : "closed"])
    }
}

private struct GQLTimelineData: Decodable {
    static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          timelineItems(last: 80, itemTypes: [PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_REQUESTED_EVENT, LABELED_EVENT, UNLABELED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT]) {
            nodes {
              __typename
              ... on PullRequestCommit { id commit { abbreviatedOid messageHeadline committedDate author { name user { login } } } }
              ... on HeadRefForcePushedEvent { id createdAt actor { login } }
              ... on ReviewRequestedEvent { id createdAt actor { login } requestedReviewer { ... on User { login } ... on Team { name } } }
              ... on LabeledEvent { id createdAt actor { login } label { name color } }
              ... on UnlabeledEvent { id createdAt actor { login } label { name color } }
              ... on ReadyForReviewEvent { id createdAt actor { login } }
              ... on ConvertToDraftEvent { id createdAt actor { login } }
              ... on MergedEvent { id createdAt actor { login } }
              ... on ClosedEvent { id createdAt actor { login } }
              ... on ReopenedEvent { id createdAt actor { login } }
              ... on AssignedEvent { id createdAt actor { login } assignee { ... on User { login } } }
              ... on RenamedTitleEvent { id createdAt actor { login } previousTitle currentTitle }
            }
          }
        }
      }
    }
    """

    let repository: Repository?
    struct Repository: Decodable { let pullRequest: Pull? }
    struct Pull: Decodable { let timelineItems: Items }
    struct Items: Decodable { let nodes: [Node?] }
    struct Actor: Decodable { let login: String? }
    struct Named: Decodable { let login: String?; let name: String? }
    struct Label: Decodable { let name: String; let color: String? }
    struct Commit: Decodable {
        let abbreviatedOid: String
        let messageHeadline: String
        let committedDate: Date?
        let author: Author?
        struct Author: Decodable { let name: String?; let user: Actor? }
    }
    struct Node: Decodable {
        let __typename: String
        let id: String?
        let createdAt: Date?
        let actor: Actor?
        let commit: Commit?
        let requestedReviewer: Named?
        let label: Label?
        let assignee: Named?
        let previousTitle: String?
        let currentTitle: String?
    }

    var events: [TimelineEvent] {
        (repository?.pullRequest?.timelineItems.nodes ?? []).compactMap { node -> TimelineEvent? in
            guard let node, let id = node.id else { return nil }
            let actor = node.actor?.login
            switch node.__typename {
            case "PullRequestCommit":
                guard let commit = node.commit else { return nil }
                return TimelineEvent(id: id, date: commit.committedDate ?? .distantPast, kind: .commit, actor: commit.author?.user?.login ?? commit.author?.name, text: commit.messageHeadline, detail: commit.abbreviatedOid)
            case "HeadRefForcePushedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .forcePush, actor: actor, text: "force-pushed the branch", detail: nil)
            case "ReviewRequestedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .reviewRequested, actor: actor, text: "requested review from \(node.requestedReviewer?.login ?? node.requestedReviewer?.name ?? "a team")", detail: nil)
            case "LabeledEvent", "UnlabeledEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .label, actor: actor, text: "\(node.__typename == "LabeledEvent" ? "added" : "removed") label \(node.label?.name ?? "")", detail: node.label?.color)
            case "ReadyForReviewEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .ready, actor: actor, text: "marked this ready for review", detail: nil)
            case "ConvertToDraftEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .draft, actor: actor, text: "converted this to a draft", detail: nil)
            case "MergedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .merged, actor: actor, text: "merged this pull request", detail: nil)
            case "ClosedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .closed, actor: actor, text: "closed this", detail: nil)
            case "ReopenedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .reopened, actor: actor, text: "reopened this", detail: nil)
            case "AssignedEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .assigned, actor: actor, text: "assigned \(node.assignee?.login ?? "someone")", detail: nil)
            case "RenamedTitleEvent":
                return TimelineEvent(id: id, date: node.createdAt ?? .distantPast, kind: .renamed, actor: actor, text: "changed the title to “\(node.currentTitle ?? "")”", detail: nil)
            default:
                return nil
            }
        }
    }
}

extension GitHubClient {
    func addPendingLineComment(pullID: String, reviewNodeID: String?, path: String, line: Int, side: String, body: String) async throws {
        var reviewID = reviewNodeID
        if reviewID == nil {
            let created: GQLCreatedReview = try await graphQL("mutation($id: ID!) { addPullRequestReview(input: {pullRequestId: $id}) { pullRequestReview { id } } }", variables: ["id": pullID])
            reviewID = created.addPullRequestReview?.pullRequestReview?.id
        }
        guard let reviewID else { throw GitHubError.message("Couldn't start a review.") }
        let _: GQLEmpty = try await graphQL("mutation($review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!) { addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: $side, body: $body}) { thread { id } } }", variables: ["review": reviewID, "path": path, "line": line, "side": side, "body": body])
    }

    func addSingleLineComment(_ key: PRKey, commitID: String, path: String, line: Int, side: String, body: String) async throws {
        try await send("POST", "/repos/\(self.path(key.repo))/pulls/\(key.number)/comments", body: ["body": body, "commit_id": commitID, "path": path, "line": line, "side": side])
    }

    func viewedStates(_ key: PRKey) async throws -> [String: Bool] {
        let parts = key.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [:] }
        var result: [String: Bool] = [:]
        var cursor: String?
        for _ in 0..<5 {
            var variables: [String: Any] = ["owner": parts[0], "name": parts[1], "number": key.number]
            if let cursor { variables["after"] = cursor }
            let data: GQLViewedData = try await graphQL("query($owner: String!, $name: String!, $number: Int!, $after: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { path viewerViewedState } } } } }", variables: variables)
            guard let files = data.repository?.pullRequest?.files else { break }
            for node in files.nodes.compactMap({ $0 }) { result[node.path] = node.viewerViewedState == "VIEWED" }
            guard files.pageInfo.hasNextPage, let next = files.pageInfo.endCursor else { break }
            cursor = next
        }
        return result
    }

    func setFileViewed(pullID: String, path: String, viewed: Bool) async throws {
        let mutation = viewed
            ? "mutation($id: ID!, $path: String!) { markFileAsViewed(input: {pullRequestId: $id, path: $path}) { pullRequest { id } } }"
            : "mutation($id: ID!, $path: String!) { unmarkFileAsViewed(input: {pullRequestId: $id, path: $path}) { pullRequest { id } } }"
        let _: GQLEmpty = try await graphQL(mutation, variables: ["id": pullID, "path": path])
    }

    func pendingCommentCount(_ key: PRKey, reviewID: Int) async throws -> Int {
        let items: [PRComment] = try await paginated("/repos/\(path(key.repo))/pulls/\(key.number)/reviews/\(reviewID)/comments?per_page=100", maxPages: 3)
        return items.count
    }
}

private struct GQLCreatedReview: Decodable {
    let addPullRequestReview: Payload?
    struct Payload: Decodable { let pullRequestReview: Review? }
    struct Review: Decodable { let id: String }
}

private struct GQLViewedData: Decodable {
    let repository: Repository?
    struct Repository: Decodable { let pullRequest: Pull? }
    struct Pull: Decodable { let files: Files? }
    struct Files: Decodable { let pageInfo: GQLSearchData.PageInfo; let nodes: [Node?] }
    struct Node: Decodable { let path: String; let viewerViewedState: String? }
}

extension GitHubClient {
    func recentPushes(login: String) async throws -> [PushedBranch] {
        struct Event: Decodable {
            let type: String
            let createdAt: Date
            let repo: Repo
            let payload: Payload
            struct Repo: Decodable { let name: String }
            struct Payload: Decodable {
                let ref: String?
                let size: Int?
                let commits: [Commit]?
                struct Commit: Decodable { let message: String }
            }
        }
        let events: [Event] = try await paginated("/users/\(path(login))/events?per_page=100", maxPages: 2)
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        var seen: [String: PushedBranch] = [:]
        for event in events where event.type == "PushEvent" && event.createdAt > cutoff {
            guard let ref = event.payload.ref, ref.hasPrefix("refs/heads/") else { continue }
            let branch = String(ref.dropFirst("refs/heads/".count))
            let id = "\(event.repo.name):\(branch)"
            if seen[id] != nil { continue }
            let headline = event.payload.commits?.last?.message.split(separator: "\n").first.map(String.init)
            seen[id] = PushedBranch(repo: event.repo.name, branch: branch, pushedAt: event.createdAt, headline: headline, commits: event.payload.size ?? event.payload.commits?.count ?? 0)
        }
        var result: [PushedBranch] = []
        var defaults: [String: String] = [:]
        for var item in seen.values.sorted(by: { $0.pushedAt > $1.pushedAt }).prefix(12) {
            if defaults[item.repo] == nil { defaults[item.repo] = try? await defaultBranch(repo: item.repo) }
            guard let base = defaults[item.repo], base != item.branch else { continue }
            item.defaultBranch = base
            let owner = item.repo.split(separator: "/").first.map(String.init) ?? ""
            struct Pull: Decodable { let number: Int }
            let open: [Pull] = (try? await get("/repos/\(path(item.repo))/pulls?state=all&head=\(encodeQuery("\(owner):\(item.branch)"))&per_page=1")) ?? []
            if open.isEmpty { result.append(item) }
            if result.count >= 5 { break }
        }
        return result
    }

    func branches(repo: String) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        let items: [Branch] = try await paginated("/repos/\(path(repo))/branches?per_page=100", maxPages: 5)
        return items.map(\.name)
    }

    func defaultBranch(repo: String) async throws -> String {
        struct Repo: Decodable { let defaultBranch: String }
        let value: Repo = try await get("/repos/\(path(repo))")
        return value.defaultBranch
    }

    func compare(repo: String, base: String, head: String) async throws -> BranchComparison {
        struct Result: Decodable {
            let aheadBy: Int
            let behindBy: Int
            let commits: [Commit]
            let files: [File]?
            struct Commit: Decodable { let commit: Inner; struct Inner: Decodable { let message: String } }
            struct File: Decodable { let filename: String }
        }
        let value: Result = try await get("/repos/\(path(repo))/compare/\(encodeQuery(base))...\(encodeQuery(head))?per_page=100")
        return BranchComparison(aheadBy: value.aheadBy, behindBy: value.behindBy, messages: value.commits.map { $0.commit.message }, files: value.files?.count ?? 0)
    }

    func createPull(repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> PRKey {
        struct Created: Decodable { let number: Int }
        let (data, _) = try await raw("POST", "/repos/\(path(repo))/pulls", body: ["title": title, "head": head, "base": base, "body": body, "draft": draft], conditional: false)
        let created = try decode(Created.self, data)
        return PRKey(repo: repo, number: created.number)
    }
}
