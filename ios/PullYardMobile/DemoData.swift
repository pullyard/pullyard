#if DEBUG
import Foundation

final class DemoGitHubAPI: GitHubAPI {
    private let me = GitHubUser(login: "demo-reviewer", name: "Demo Reviewer")
    private let now = Date()
    private var notificationStore: [GHNotification]

    init() {
        notificationStore = []
        notificationStore = makeNotifications()
    }

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func pull(_ number: Int, _ repo: String, _ title: String, author: String, state: String = "open", draft: Bool = false, merged: Bool = false, updated: Double, comments: Int = 0) -> PullRequest {
        PullRequest(id: number * 31 + repo.count, number: number, title: title, body: "## Summary\nThis change **improves** the `\(repo)` flow.\n\n- Adds caching\n- Fixes a race on refresh\n<!-- template comment -->", state: state, draft: draft, htmlUrl: URL(string: "https://github.com/\(repo)/pull/\(number)")!, createdAt: ago(updated + 600), updatedAt: ago(updated), user: GitHubUser(login: author), head: .init(label: nil, ref: "feature/\(number)-update", sha: "abc\(number)"), base: .init(label: nil, ref: "main", sha: "def\(number)", repo: .init(fullName: repo)), additions: 120 + number, deletions: 14 + number % 7, changedFiles: 3 + number % 5, comments: comments, reviewComments: 2, requestedReviewers: [me], merged: merged, mergedAt: merged ? ago(updated) : nil, mergeable: number % 4 == 0 ? false : true, labels: number % 3 == 0 ? [PRLabel(name: "bug", color: "d73a4a"), PRLabel(name: "mobile", color: "0e8a16")] : [PRLabel(name: "enhancement", color: "a2eeef")], reviewDecision: number % 2 == 0 ? "CHANGES_REQUESTED" : (number % 5 == 0 ? "APPROVED" : "REVIEW_REQUIRED"), checkState: number % 2 == 0 ? "FAILURE" : (number % 3 == 0 ? "PENDING" : "SUCCESS"), repo: repo)
    }

    private var allPulls: [PullRequest] {
        [
            pull(482, "harbor/api", "Add ETag support to repository sync", author: "mira-dev", updated: 12, comments: 4),
            pull(1290, "harbor/mobile", "Fix cold start when offline", author: "alex-k", updated: 47, comments: 9),
            pull(77, "harbor/design", "New status colours for pull request states", author: "sam-ui", draft: true, updated: 180),
            pull(483, "harbor/api", "Paginate review comments", author: "mira-dev", updated: 320, comments: 1),
            pull(1288, "harbor/mobile", "Keep drafts when a reply fails", author: "demo-reviewer", updated: 25, comments: 3),
            pull(1279, "harbor/mobile", "Notification deep links", author: "demo-reviewer", state: "closed", merged: true, updated: 2_000),
            pull(470, "harbor/api", "Drop legacy webhook endpoint", author: "alex-k", state: "closed", updated: 4_000),
        ]
    }

    private func makeNotifications() -> [GHNotification] {
        [
            GHNotification(id: "1", unread: true, reason: "review_requested", updatedAt: ago(12), subject: .init(title: "Add ETag support to repository sync", url: "https://api.github.com/repos/harbor/api/pulls/482", type: "PullRequest"), repository: .init(fullName: "harbor/api", htmlUrl: nil)),
            GHNotification(id: "2", unread: true, reason: "mention", updatedAt: ago(47), subject: .init(title: "Fix cold start when offline", url: "https://api.github.com/repos/harbor/mobile/pulls/1290", type: "PullRequest"), repository: .init(fullName: "harbor/mobile", htmlUrl: nil)),
            GHNotification(id: "3", unread: false, reason: "ci_activity", updatedAt: ago(200), subject: .init(title: "CI failed on main", url: nil, type: "CheckSuite"), repository: .init(fullName: "harbor/api", htmlUrl: URL(string: "https://github.com/harbor/api"))),
        ]
    }

    func currentUser() async throws -> (user: GitHubUser, scopes: [String]) { (me, ["repo", "notifications"]) }

    func pullRequests(list: PRListKey, cursor: String?, perPage: Int) async throws -> PullRequestPage {
        try await Task.sleep(for: .milliseconds(350))
        let mine = list.queue == .createdByMe
        let items = allPulls.filter { pr in
            if let project = list.project, pr.repo != project { return false }
            let ownership: Bool
            switch list.includeQueue ? list.queue : nil {
            case nil: ownership = true
            case .createdByMe?: ownership = pr.user?.login == me.login
            case .needsMyReview?: ownership = pr.user?.login != me.login
            case .assigned?, .mentioned?: ownership = pr.number % 2 == 0 && pr.user?.login != me.login
            case .reviewed?: ownership = pr.number == 483
            }
            _ = mine
            switch list.status {
            case .open: return ownership && pr.isOpen
            case .merged: return ownership && pr.isMerged
            case .closed: return ownership && !pr.isOpen && !pr.isMerged
            case .all: return ownership
            }
        }
        return PullRequestPage(totalCount: items.count, items: cursor == nil ? items : [])
    }

    func searchPullRequests(_ query: String, cursor: String?) async throws -> PullRequestPage {
        try await Task.sleep(for: .milliseconds(300))
        let items = allPulls.filter { $0.title.localizedCaseInsensitiveContains(query) || query.contains(":") }
        return PullRequestPage(totalCount: items.count, items: items)
    }

    func pullRequest(_ key: PRKey) async throws -> PullRequest {
        try await Task.sleep(for: .milliseconds(250))
        guard let value = allPulls.first(where: { $0.key == key }) else { throw GitHubError.notFound(nil) }
        return value
    }

    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun] {
        [
            CheckRun(id: 1, name: "build", status: "completed", conclusion: "success", htmlUrl: nil, startedAt: ago(20), completedAt: ago(15), output: nil),
            CheckRun(id: 2, name: "unit-tests", status: "completed", conclusion: key.number % 2 == 0 ? "failure" : "success", htmlUrl: nil, startedAt: ago(20), completedAt: ago(14), output: .init(title: nil, summary: "2 tests failed in SyncTests")),
            CheckRun(id: 3, name: "lint", status: "in_progress", conclusion: nil, htmlUrl: nil, startedAt: ago(3), completedAt: nil, output: nil),
            CheckRun(id: 4, name: "deploy-preview", status: "completed", conclusion: "skipped", htmlUrl: nil, startedAt: nil, completedAt: nil, output: nil),
        ]
    }

    func reviews(_ key: PRKey) async throws -> [PRReview] {
        [PRReview(id: 10, user: GitHubUser(login: "alex-k"), body: "Looks good overall, one question inline.", state: "COMMENTED", submittedAt: ago(40))]
    }

    func comments(_ key: PRKey) async throws -> [PRComment] {
        [PRComment(id: 20, user: GitHubUser(login: "mira-dev"), body: "Rebased on main, ready for another look.", createdAt: ago(30), htmlUrl: nil, path: nil, line: nil, inReplyToId: nil)]
    }

    func reviewComments(_ key: PRKey) async throws -> [PRComment] {
        [PRComment(id: 30, user: GitHubUser(login: "alex-k"), body: "Should this use `If-None-Match` too?", createdAt: ago(41), htmlUrl: nil, path: "Sources/Sync/Client.swift", line: 88, inReplyToId: nil, diffHunk: "@@ -80,6 +80,9 @@\n     let request = makeRequest(path)\n-    request.cachePolicy = .reload\n+    if let etag = cache.etag(for: path) {\n+        request.setValue(etag, forHTTPHeaderField: \"If-None-Match\")\n+    }"),
         PRComment(id: 31, user: GitHubUser(login: "demo-reviewer"), body: "Yes, added in the next commit.", createdAt: ago(35), htmlUrl: nil, path: "Sources/Sync/Client.swift", line: 88, inReplyToId: 30)]
    }

    func notifications() async throws -> [GHNotification] {
        try await Task.sleep(for: .milliseconds(300))
        return notificationStore
    }

    func addComment(_ key: PRKey, body: String) async throws { try await Task.sleep(for: .milliseconds(400)) }
    func reply(_ key: PRKey, commentID: Int, body: String) async throws { try await Task.sleep(for: .milliseconds(400)) }
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws { try await Task.sleep(for: .milliseconds(400)) }
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws {}
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws {}
    func markRead(_ notificationID: String) async throws {
        if let index = notificationStore.firstIndex(where: { $0.id == notificationID }) { notificationStore[index].unread = false }
    }
    func markDone(_ notificationID: String) async throws { notificationStore.removeAll { $0.id == notificationID } }
    func mute(_ notificationID: String) async throws { notificationStore.removeAll { $0.id == notificationID } }
    func repositories() async throws -> [ProjectSummary] {
        try await Task.sleep(for: .milliseconds(300))
        return [
            ProjectSummary(nameWithOwner: "harbor/mobile", description: "PullYard for iPhone", isPrivate: false, openPullRequests: 2, pushedAt: ago(20)),
            ProjectSummary(nameWithOwner: "harbor/api", description: "Sync and webhooks service", isPrivate: true, openPullRequests: 2, pushedAt: ago(60)),
            ProjectSummary(nameWithOwner: "harbor/design", description: "Design tokens and icons", openPullRequests: 1, pushedAt: ago(400)),
            ProjectSummary(nameWithOwner: "harbor/docs", description: "Public documentation", openPullRequests: 0, pushedAt: ago(9_000)),
        ]
    }
    func markAllRead() async throws { for index in notificationStore.indices { notificationStore[index].unread = false } }
}
#endif
