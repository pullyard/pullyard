import XCTest
@testable import PullYardMobile

final class PullListMergerTests: XCTestCase {
    private func pull(_ id: Int, minutesAgo: Double, repo: String = "acme/app") -> PullRequest {
        let date = Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60)
        return PullRequest(id: id, number: id, title: "PR \(id)", body: nil, state: "open", draft: false, htmlUrl: URL(string: "https://github.com/\(repo)/pull/\(id)")!, createdAt: date, updatedAt: date, user: nil, head: .init(label: nil, ref: "", sha: ""), base: .init(label: nil, ref: "", sha: ""), additions: nil, deletions: nil, changedFiles: nil, comments: nil, reviewComments: nil, requestedReviewers: nil, merged: false, mergedAt: nil, mergeable: nil, repo: repo)
    }

    func testIncompleteFirstPageReplacesList() {
        let existing = [pull(1, minutesAgo: 1), pull(2, minutesAgo: 2), pull(3, minutesAgo: 300)]
        let fresh = [pull(1, minutesAgo: 1)]
        XCTAssertEqual(PullListMerger.mergeFirstPage(existing: existing, fresh: fresh, pageSize: 2).map(\.id), [1])
    }

    func testFullFirstPageKeepsOlderTail() {
        let existing = [pull(6, minutesAgo: 0.5), pull(1, minutesAgo: 1), pull(2, minutesAgo: 2), pull(3, minutesAgo: 300)]
        let fresh = [pull(5, minutesAgo: 0), pull(1, minutesAgo: 1)]
        let merged = PullListMerger.mergeFirstPage(existing: existing, fresh: fresh, pageSize: 2)
        XCTAssertEqual(merged.map(\.id), [5, 1, 2, 3])
    }

    func testAppendPageSkipsDuplicates() {
        let merged = PullListMerger.appendPage(existing: [pull(1, minutesAgo: 1)], page: [pull(1, minutesAgo: 1), pull(2, minutesAgo: 5)])
        XCTAssertEqual(merged.map(\.id), [1, 2])
    }

    func testLocallyReadNotificationsStayVisible() {
        let date = Date()
        let subject = GHNotification.Subject(title: "T", url: nil, type: "PullRequest")
        let repo = GHNotification.Repository(fullName: "acme/app", htmlUrl: nil)
        let read = GHNotification(id: "a", unread: true, reason: "mention", updatedAt: date, subject: subject, repository: repo)
        let other = GHNotification(id: "b", unread: true, reason: "mention", updatedAt: date.addingTimeInterval(-10), subject: subject, repository: repo)
        let merged = PullListMerger.mergeNotifications(existing: [read, other], fresh: [other], locallyRead: ["a"])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.first?.unread, false)
    }
}

final class GitHubErrorMappingTests: XCTestCase {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testUnauthorized() {
        XCTAssertEqual(GitHubError.map(response: response(401), data: Data()), .unauthorized)
    }

    func testPrimaryRateLimit() {
        let error = GitHubError.map(response: response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000000000"]), data: Data())
        XCTAssertEqual(error, .rateLimited(Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testSecondaryRateLimit() {
        let body = Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)
        guard case .secondaryRateLimit = GitHubError.map(response: response(403), data: body) else { return XCTFail() }
    }

    func testValidationUsesDetailMessages() {
        let body = Data(#"{"message":"Unprocessable Entity","errors":[{"message":"Can not approve your own pull request"}]}"#.utf8)
        XCTAssertEqual(GitHubError.map(response: response(422), data: body), .validation("Can not approve your own pull request"))
    }

    func testMissingScopes() {
        let error = GitHubError.map(response: response(403, ["X-Accepted-OAuth-Scopes": "notifications"]), data: Data(#"{"message":"Forbidden"}"#.utf8), grantedScopes: ["repo"])
        XCTAssertEqual(error, .missingScopes(["notifications"]))
    }

    func testOfflineMapping() {
        XCTAssertEqual(GitHubError.map(urlError: URLError(.notConnectedToInternet)) as? GitHubError, .offline)
        XCTAssertTrue(GitHubError.map(urlError: URLError(.cancelled)).isCancellation)
    }

    func testNextLinkParsing() {
        let link = #"<https://api.github.com/repos/a/b/issues/1/comments?page=2>; rel="next", <https://api.github.com/repos/a/b/issues/1/comments?page=5>; rel="last""#
        XCTAssertEqual(GitHubClient.nextLink(response(200, ["Link": link])), "https://api.github.com/repos/a/b/issues/1/comments?page=2")
        XCTAssertNil(GitHubClient.nextLink(response(200)))
    }
}

private final class MemoryVault: CredentialStore {
    var token: String?
    var locked = false
    init(token: String?) { self.token = token }
    func read() -> CredentialReadResult { locked ? .locked : token.map(CredentialReadResult.found) ?? .notFound }
    func write(_ token: String) throws { self.token = token }
    func clear() { token = nil }
}

private final class OfflineAPI: GitHubAPI {
    func currentUser() async throws -> (user: GitHubUser, scopes: [String]) { throw GitHubError.offline }
    func pullRequests(list: PRListKey, cursor: String?, perPage: Int) async throws -> PullRequestPage { throw GitHubError.offline }
    func searchPullRequests(_ query: String, cursor: String?) async throws -> PullRequestPage { throw GitHubError.offline }
    func pullRequest(_ key: PRKey) async throws -> PullRequest { throw GitHubError.offline }
    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun] { throw GitHubError.offline }
    func reviews(_ key: PRKey) async throws -> [PRReview] { throw GitHubError.offline }
    func comments(_ key: PRKey) async throws -> [PRComment] { throw GitHubError.offline }
    func reviewComments(_ key: PRKey) async throws -> [PRComment] { throw GitHubError.offline }
    func notifications() async throws -> [GHNotification] { throw GitHubError.offline }
    func addComment(_ key: PRKey, body: String) async throws { throw GitHubError.offline }
    func reply(_ key: PRKey, commentID: Int, body: String) async throws { throw GitHubError.offline }
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws { throw GitHubError.offline }
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws { throw GitHubError.offline }
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws { throw GitHubError.offline }
    func markRead(_ notificationID: String) async throws { throw GitHubError.offline }
    func markDone(_ notificationID: String) async throws { throw GitHubError.offline }
    func mute(_ notificationID: String) async throws { throw GitHubError.offline }
    func markAllRead() async throws { throw GitHubError.offline }
    func repositories() async throws -> [ProjectSummary] { throw GitHubError.offline }
}

private final class UnauthorizedAPI: GitHubAPI {
    func currentUser() async throws -> (user: GitHubUser, scopes: [String]) { throw GitHubError.unauthorized }
    func pullRequests(list: PRListKey, cursor: String?, perPage: Int) async throws -> PullRequestPage { throw GitHubError.unauthorized }
    func searchPullRequests(_ query: String, cursor: String?) async throws -> PullRequestPage { throw GitHubError.unauthorized }
    func pullRequest(_ key: PRKey) async throws -> PullRequest { throw GitHubError.unauthorized }
    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun] { [] }
    func reviews(_ key: PRKey) async throws -> [PRReview] { [] }
    func comments(_ key: PRKey) async throws -> [PRComment] { [] }
    func reviewComments(_ key: PRKey) async throws -> [PRComment] { [] }
    func notifications() async throws -> [GHNotification] { throw GitHubError.unauthorized }
    func addComment(_ key: PRKey, body: String) async throws {}
    func reply(_ key: PRKey, commentID: Int, body: String) async throws {}
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws {}
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws {}
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws {}
    func markRead(_ notificationID: String) async throws {}
    func markDone(_ notificationID: String) async throws {}
    func mute(_ notificationID: String) async throws {}
    func markAllRead() async throws {}
    func repositories() async throws -> [ProjectSummary] { throw GitHubError.unauthorized }
}

final class PRListKeyTests: XCTestCase {
    func testQueueQuery() {
        XCTAssertEqual(PRListKey(queue: .needsMyReview, status: .open).searchQuery, "is:pr archived:false review-requested:@me is:open")
    }

    func testProjectQueries() {
        XCTAssertEqual(PRListKey.project("acme/app", status: .open, audience: .everyone).searchQuery, "is:pr repo:acme/app is:open")
        XCTAssertEqual(PRListKey.project("acme/app", status: .merged, audience: .mine).searchQuery, "is:pr repo:acme/app author:@me is:merged")
        XCTAssertEqual(PRListKey.project("acme/app", status: .all, audience: .needsMyReview).searchQuery, "is:pr repo:acme/app review-requested:@me")
    }
}

final class DeepLinkTests: XCTestCase {
    func testGitHubLinks() {
        XCTAssertEqual(DeepLink.route(from: URL(string: "https://github.com/acme/app/pull/42")!), .pull(PRKey(repo: "acme/app", number: 42)))
        XCTAssertEqual(DeepLink.route(from: URL(string: "https://github.com/acme/app/pull/42/files")!), .files(PRKey(repo: "acme/app", number: 42)))
        XCTAssertEqual(DeepLink.route(from: URL(string: "https://github.com/acme/app")!), .project("acme/app"))
        XCTAssertEqual(DeepLink.route(from: URL(string: "https://github.com/acme/app/issues/3")!), .issue(PRKey(repo: "acme/app", number: 3)))
        XCTAssertNil(DeepLink.route(from: URL(string: "https://example.com/acme/app/pull/1")!))
    }

    func testSchemeAndShorthand() {
        XCTAssertEqual(DeepLink.route(from: URL(string: "pullyard://pull/acme/app/7")!), .pull(PRKey(repo: "acme/app", number: 7)))
        XCTAssertEqual(DeepLink.route(fromText: "acme/app#12"), .pull(PRKey(repo: "acme/app", number: 12)))
    }

    func testDiffParsing() {
        let lines = DiffLine.parse("@@ -10,2 +10,3 @@\n context\n-old\n+new\n+added")
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .delete, .add, .add])
        XCTAssertEqual(lines[1].newLine, 10)
        XCTAssertEqual(lines[3].newLine, 11)
        XCTAssertEqual(lines[2].oldLine, 11)
    }
}

final class BackgroundSyncTests: XCTestCase {
    private func pull(_ number: Int, repo: String = "acme/app", decision: String? = nil, ci: String? = nil) -> PullRequest {
        PullRequest(id: number, number: number, title: "PR \(number)", body: nil, state: "open", draft: false, htmlUrl: URL(string: "https://github.com/\(repo)/pull/\(number)")!, createdAt: .now, updatedAt: .now, user: GitHubUser(login: "dev"), head: .init(label: nil, ref: "", sha: ""), base: .init(label: nil, ref: "", sha: ""), additions: nil, deletions: nil, changedFiles: nil, comments: nil, reviewComments: nil, requestedReviewers: nil, merged: false, mergedAt: nil, mergeable: nil, reviewDecision: decision, checkState: ci, repo: repo)
    }

    func testFirstRunOnlyBuildsBaseline() {
        let (alerts, baseline) = BackgroundSync.diff(previous: nil, reviews: [pull(1)], mine: [pull(2)], notifications: [])
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(baseline.reviewKeys, ["acme/app#1"])
    }

    func testDetectsNewReviewApprovalAndFailure() {
        let (_, base) = BackgroundSync.diff(previous: nil, reviews: [pull(1)], mine: [pull(2, decision: "REVIEW_REQUIRED", ci: "PENDING")], notifications: [])
        let (alerts, _) = BackgroundSync.diff(previous: base, reviews: [pull(1), pull(3)], mine: [pull(2, decision: "APPROVED", ci: "FAILURE")], notifications: [])
        XCTAssertEqual(Set(alerts.map(\.id)), ["review-acme/app#3", "decision-acme/app#2-APPROVED", "ci-acme/app#2"])
    }
}

final class FeatureHelpersTests: XCTestCase {
    func testSnoozePresetsAreInTheFuture() {
        let now = Date()
        let presets = SnoozeStore.presets(now: now)
        XCTAssertEqual(presets.count, 4)
        XCTAssertTrue(presets.allSatisfy { $0.1 > now })
    }

    func testRepoFileDecodesBase64() {
        let file = RepoFile(name: "a.txt", path: "a.txt", size: 5, content: Data("hello".utf8).base64EncodedString() + "\n", encoding: "base64", htmlUrl: nil, downloadUrl: nil)
        XCTAssertEqual(file.text, "hello")
    }

    func testTemplatesHaveDefaults() {
        XCTAssertFalse(TemplateStore.defaults.isEmpty)
    }
}

final class MarkdownParserTests: XCTestCase {
    func testParsesBlocksAndStripsComments() {
        let source = "<!-- hidden -->\n## Summary\n- [x] done\n- [ ] todo\n\n```swift\nlet a = 1\n```\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownParser.blocks(source)
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "Summary"))
        XCTAssertEqual(blocks[1], .bullet(items: [.init(text: "done", task: true, depth: 0), .init(text: "todo", task: false, depth: 0)]))
        XCTAssertEqual(blocks[2], .code(language: "swift", text: "let a = 1"))
        XCTAssertEqual(blocks[3], .quote("quoted"))
        XCTAssertEqual(blocks[4], .table(rows: [["a", "b"], ["1", "2"]]))
    }

    func testDetailsAndSuggestion() {
        let blocks = MarkdownParser.blocks("<details><summary>Logs</summary>\n\nline\n</details>\n```suggestion\nfixed()\n```")
        XCTAssertEqual(blocks.first, .details(summary: "Logs", body: [.paragraph("line")]))
        XCTAssertEqual(blocks.last, .suggestion("fixed()"))
    }
}

@MainActor
final class AppModelSessionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTokenWithoutNetworkStaysSignedIn() async {
        let model = AppModel(vault: MemoryVault(token: "t"), cache: LocalStore(directory: directory), defaults: defaults, makeClient: { _ in OfflineAPI() })
        XCTAssertEqual(model.session, .signedIn)
        await model.refreshAll().value
        XCTAssertEqual(model.session, .signedIn)
        XCTAssertEqual(model.feedback.banner, .offline)
    }

    func testLockedKeychainShowsLockedState() {
        let vault = MemoryVault(token: "t"); vault.locked = true
        let model = AppModel(vault: vault, cache: LocalStore(directory: directory), defaults: defaults, makeClient: { _ in OfflineAPI() })
        XCTAssertEqual(model.session, .locked)
        vault.locked = false
        model.restoreSession()
        XCTAssertEqual(model.session, .signedIn)
    }

    func testRevokedTokenSignsOutAndClearsVault() async {
        let vault = MemoryVault(token: "t")
        let model = AppModel(vault: vault, cache: LocalStore(directory: directory), defaults: defaults, makeClient: { _ in UnauthorizedAPI() })
        await model.refreshAll().value
        XCTAssertEqual(model.session, .signedOut)
        XCTAssertNil(vault.token)
        XCTAssertNotNil(model.signInError)
    }

    func testNoTokenStartsSignedOut() {
        let model = AppModel(vault: MemoryVault(token: nil), cache: LocalStore(directory: directory), defaults: defaults, makeClient: { _ in OfflineAPI() })
        XCTAssertEqual(model.session, .signedOut)
    }
}
