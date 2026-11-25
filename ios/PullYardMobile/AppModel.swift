import Foundation
import Combine
import UIKit

enum PullListMerger {
    static func mergeFirstPage(existing: [PullRequest], fresh: [PullRequest], pageSize: Int) -> [PullRequest] {
        guard fresh.count >= pageSize, let cutoff = fresh.map(\.updatedAt).min() else { return fresh }
        let freshIDs = Set(fresh.map(\.id))
        let tail = existing.filter { !freshIDs.contains($0.id) && $0.updatedAt < cutoff }
        return (fresh + tail).sorted { $0.updatedAt > $1.updatedAt }
    }

    static func appendPage(existing: [PullRequest], page: [PullRequest]) -> [PullRequest] {
        let known = Set(existing.map(\.id))
        return existing + page.filter { !known.contains($0.id) }
    }

    static func mergeNotifications(existing: [GHNotification], fresh: [GHNotification], locallyRead: Set<String>) -> [GHNotification] {
        let freshIDs = Set(fresh.map(\.id))
        var result = fresh.map { item -> GHNotification in
            var copy = item
            if locallyRead.contains(item.id) { copy.unread = false }
            return copy
        }
        for item in existing where locallyRead.contains(item.id) && !freshIDs.contains(item.id) {
            var copy = item; copy.unread = false
            result.append(copy)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }
}

private struct CacheSnapshot: Codable {
    var user: GitHubUser?
    var lists: [PRListKey: [PullRequest]]
    var totals: [PRListKey: Int]
    var cursors: [PRListKey: String]
    var notifications: [GHNotification]
    var lastUpdated: Date?
    var projects: [ProjectSummary]? = nil
}

@MainActor
final class AppModel: ObservableObject {
    enum SessionState: Equatable { case signedOut, locked, signedIn }

    static let pageSize = 50

    @Published private(set) var session: SessionState = .signedOut
    @Published private(set) var user: GitHubUser?
    @Published private(set) var scopes: [String] = []
    @Published var selectedTab: AppTab { didSet { defaults.set(selectedTab.rawValue, forKey: "mobile.selectedTab") } }
    @Published var queue: PRQueue {
        didSet {
            defaults.set(queue.rawValue, forKey: "mobile.queue")
            if oldValue != queue { listDidChange() }
        }
    }
    @Published private var statusFilters: [PRQueue: PRStatusFilter] = [:]
    @Published var selectedProject = "" { didSet { preferences?.selectedProject = selectedProject } }
    @Published var projectOrder: [String] = [] { didSet { preferences?.projectOrder = projectOrder } }
    @Published private(set) var lists: [PRListKey: [PullRequest]] = [:]
    @Published private(set) var listTotals: [PRListKey: Int] = [:]
    @Published private(set) var listCursors: [PRListKey: String] = [:]
    @Published private(set) var listStates: [PRListKey: LoadState] = [:]
    @Published private(set) var discovering: Set<PRListKey> = []
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var projectsState: LoadState = .idle
    @Published var pinnedProjects: [String] = [] { didSet { preferences?.pinnedProjects = pinnedProjects } }
    @Published var savedSearches: [String] = [] { didSet { preferences?.savedSearches = savedSearches } }
    @Published var activeSavedSearch: String? { didSet { if oldValue != activeSavedSearch { listDidChange() } } }
    @Published private(set) var notifications: [GHNotification] = []
    @Published private(set) var inboxState: LoadState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningIn = false
    @Published var signInError: String?

    let feedback: FeedbackCenter
    let isDemo: Bool
    private let vault: CredentialStore
    private let cache: LocalStore
    private let defaults: UserDefaults
    private let makeClient: (String) -> GitHubAPI
    private var client: GitHubAPI?
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var loadingPages: Set<PRListKey> = []
    private var locallyRead: Set<String> = []
    private var rateLimitedUntil: Date?
    private var recentlyReviewed: [PRKey: Date] = [:]
    private var pendingDone: [String: Task<Void, Never>] = [:]
    private var preferences: AccountPreferences? { user.map { AccountPreferences(login: $0.login, defaults: defaults) } }

    init(vault: CredentialStore = CredentialVault(), cache: LocalStore = .cache, defaults: UserDefaults = .standard, feedback: FeedbackCenter? = nil, isDemo: Bool = false, makeClient: @escaping (String) -> GitHubAPI = { GitHubClient(token: $0) }) {
        self.vault = vault
        self.cache = cache
        self.defaults = defaults
        self.feedback = feedback ?? FeedbackCenter()
        self.isDemo = isDemo
        self.makeClient = makeClient
        selectedTab = defaults.string(forKey: "mobile.selectedTab").flatMap(AppTab.init(rawValue:)) ?? .pulls
        queue = defaults.string(forKey: "mobile.queue").flatMap(PRQueue.init(rawValue:)) ?? .needsMyReview
        restoreSession()
    }

    var isSignedIn: Bool { session == .signedIn }
    var unreadCount: Int { notifications.filter(\.unread).count }
    var statusFilter: PRStatusFilter {
        get { statusFilters[queue] ?? .open }
        set {
            guard newValue != statusFilter else { return }
            statusFilters[queue] = newValue
            preferences?.setStatusFilter(newValue, for: queue)
            listDidChange()
        }
    }
    var currentListKey: PRListKey {
        if let activeSavedSearch { return .saved(activeSavedSearch, status: statusFilter) }
        return PRListKey(queue: queue, status: statusFilter)
    }

    func savedCount(_ query: String) -> Int? { listTotals[.saved(query, status: .open)] ?? listTotals[.saved(query, status: statusFilter)] }

    func toggleSaved(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = savedSearches.firstIndex(of: trimmed) {
            savedSearches.remove(at: index)
            if activeSavedSearch == trimmed { activeSavedSearch = nil }
        } else {
            savedSearches.append(trimmed)
        }
    }
    var currentPulls: [PullRequest] { visible(lists[currentListKey] ?? [], in: currentListKey) }
    var currentListState: LoadState { listStates[currentListKey] ?? .idle }
    var isDiscoveringCurrentList: Bool { discovering.contains(currentListKey) }
    func openCount(for queue: PRQueue) -> Int? {
        let key = PRListKey(queue: queue, status: .open)
        guard let total = listTotals[key] else { return nil }
        let loaded = lists[key] ?? []
        let hidden = loaded.count - visible(loaded, in: key).count
        return max(0, total - hidden)
    }
    func hasMore(_ key: PRListKey) -> Bool {
        let count = lists[key]?.count ?? 0
        return listCursors[key] != nil && count < (listTotals[key] ?? 0) && count < 1_000
    }
    func pulls(for key: PRListKey) -> [PullRequest] { visible(lists[key] ?? [], in: key) }

    func pulls(for filter: OverviewFilter) -> [PullRequest] {
        if filter == .snoozed { return snoozedPulls }
        return pulls(for: filter.listKey).filter(filter.includes).sorted { $0.updatedAt > $1.updatedAt }
    }

    func count(for filter: OverviewFilter) -> Int? {
        switch filter {
        case let .queue(queue): return openCount(for: queue)
        case .saved: return listTotals[filter.listKey]
        case .snoozed: return snoozedPulls.count
        default: return lists[filter.listKey] == nil ? nil : pulls(for: filter).count
        }
    }

    func refreshOverview() async {
        if let refreshTask { await refreshTask.value; return }
        let keys = PRQueue.allCases.map { PRListKey(queue: $0, status: .open) } + savedSearches.map { PRListKey.saved($0, status: .open) }
        await performRefresh(lists: keys, includeInbox: true, includeUser: true)
        await refreshPushedBranches()
    }

    @Published private(set) var pushedBranches: [PushedBranch] = []
    @Published var dismissedBranches: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mobile.dismissedBranches") ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedBranches), forKey: "mobile.dismissedBranches") }
    }

    var suggestedBranches: [PushedBranch] { pushedBranches.filter { !dismissedBranches.contains("\($0.id)@\($0.pushedAt.timeIntervalSince1970)") } }

    func dismissBranch(_ branch: PushedBranch) {
        dismissedBranches.insert("\(branch.id)@\(branch.pushedAt.timeIntervalSince1970)")
    }

    func refreshPushedBranches() async {
        guard let login = user?.login, let client else { return }
        if let value = try? await client.recentPushes(login: login) { pushedBranches = value }
    }

    func branches(repo: String) async throws -> [String] { try await call { try await $0.branches(repo: repo) } }
    func pendingComments(_ key: PRKey, reviewID: Int) async throws -> [PRComment] { try await call { try await $0.pendingComments(key, reviewID: reviewID) } }
    func editReviewComment(repo: String, commentID: Int, body: String) async throws { try await call { try await $0.editReviewComment(repo: repo, commentID: commentID, body: body) } }
    func deleteReviewComment(repo: String, commentID: Int) async throws { try await call { try await $0.deleteReviewComment(repo: repo, commentID: commentID) } }
    func issues(repo: String, state: String, page: Int) async throws -> [GHIssue] { try await call { try await $0.issues(repo: repo, state: state, page: page) } }
    func createIssue(repo: String, title: String, body: String) async throws -> PRKey { try await call { try await $0.createIssue(repo: repo, title: title, body: body) } }
    func contents(repo: String, path: String, ref: String?) async throws -> RepoContent { try await call { try await $0.contents(repo: repo, path: path, ref: ref) } }
    func defaultBranch(repo: String) async throws -> String { try await call { try await $0.defaultBranch(repo: repo) } }
    func compare(repo: String, base: String, head: String) async throws -> BranchComparison { try await call { try await $0.compare(repo: repo, base: base, head: head) } }
    func createPull(repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> PRKey {
        let key = try await call { try await $0.createPull(repo: repo, title: title, head: head, base: base, body: body, draft: draft) }
        pushedBranches.removeAll { $0.repo == repo && $0.branch == head }
        refreshAll()
        return key
    }

    private func isRecentlyReviewed(_ key: PRKey) -> Bool {
        guard let date = recentlyReviewed[key] else { return false }
        return Date.now.timeIntervalSince(date) < 600
    }

    private func visible(_ pulls: [PullRequest], in key: PRListKey) -> [PullRequest] {
        var result = pulls
        if key.filtersReviewQueue, !recentlyReviewed.isEmpty {
            result = result.filter { pull in !(pull.key.map(isRecentlyReviewed) ?? false) }
        }
        if !snoozed.isEmpty {
            result = result.filter { pull in pull.key.map { snoozed[$0.id] == nil } ?? true }
        }
        if focusPinnedOnly, key.project == nil, !pinnedProjects.isEmpty {
            result = result.filter { pull in pull.repo.map(pinnedProjects.contains) ?? false }
        }
        return result
    }

    @Published private(set) var snoozed: [String: Date] = SnoozeStore.all()
    @Published private(set) var focusPinnedOnly = FocusSettings.pinnedOnly

    func reloadFocus() { focusPinnedOnly = FocusSettings.pinnedOnly }
    func isSnoozed(_ key: PRKey) -> Bool { snoozed[key.id].map { $0 > .now } ?? false }

    func snooze(_ key: PRKey, until date: Date) {
        snoozed[key.id] = date
        SnoozeStore.save(snoozed)
        feedback.info("Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))", key: "snooze-\(key.id)", actionTitle: L("Undo")) { [weak self] in self?.unsnooze(key) }
    }

    func unsnooze(_ key: PRKey) {
        snoozed[key.id] = nil
        SnoozeStore.save(snoozed)
    }

    var snoozedPulls: [PullRequest] {
        let all = lists.values.flatMap { $0 }
        var seen = Set<String>()
        return all.filter { pull in
            guard let key = pull.key, snoozed[key.id] != nil, !seen.contains(key.id) else { return false }
            seen.insert(key.id)
            return true
        }
        .sorted { (snoozed[$0.key?.id ?? ""] ?? .distantFuture) < (snoozed[$1.key?.id ?? ""] ?? .distantFuture) }
    }

    func noteReviewed(_ key: PRKey) {
        recentlyReviewed = recentlyReviewed.filter { Date.now.timeIntervalSince($0.value) < 600 }
        recentlyReviewed[key] = .now
        objectWillChange.send()
    }

    func nextInQueue(after key: PRKey) -> PRKey? {
        pulls(for: PRListKey(queue: .needsMyReview, status: .open)).compactMap(\.key).first { $0 != key }
    }
    func notification(id: String) -> GHNotification? { notifications.first { $0.id == id } }

    var allProjects: [ProjectSummary] {
        var known = Set(projects.map(\.nameWithOwner))
        var result = projects
        for key in [PRListKey(queue: .needsMyReview, status: .open), PRListKey(queue: .createdByMe, status: .open)] {
            for pull in lists[key] ?? [] {
                guard let repo = pull.repo, !known.contains(repo) else { continue }
                known.insert(repo)
                result.append(ProjectSummary(nameWithOwner: repo, pushedAt: pull.updatedAt))
            }
        }
        return result
    }

    func reviewRequests(in repo: String) -> Int {
        pulls(for: PRListKey(queue: .needsMyReview, status: .open)).filter { $0.repo == repo }.count
    }

    func myOpenPulls(in repo: String) -> Int {
        (lists[PRListKey(queue: .createdByMe, status: .open)] ?? []).filter { $0.repo == repo }.count
    }

    func isPinned(_ repo: String) -> Bool { pinnedProjects.contains(repo) }

    func togglePin(_ repo: String) {
        if let index = pinnedProjects.firstIndex(of: repo) { pinnedProjects.remove(at: index) } else { pinnedProjects.append(repo) }
    }

    func refreshProjects() async {
        guard let client, session == .signedIn else { return }
        let current = generation
        if projects.isEmpty { projectsState = .loading }
        do {
            let value = try await client.repositories()
            guard current == generation else { return }
            projects = value
            projectsState = .loaded(.now)
            saveCache()
        } catch {
            guard current == generation, !error.isCancellation else { return }
            projectsState = .failed(error.localizedDescription)
            if !handleErrors([error]), !projects.isEmpty { feedback.error(error, key: "projects") }
        }
    }

    func refreshList(_ key: PRListKey) async {
        await performRefresh(lists: [key], includeInbox: false, includeUser: false)
    }

    func listState(_ key: PRListKey) -> LoadState { listStates[key] ?? .idle }

    func restoreSession() {
        guard session != .signedIn else { return }
        if isDemo {
            activate(token: "demo")
            return
        }
        switch vault.read() {
        case let .found(token):
            activate(token: token)
        case .locked:
            session = .locked
        case .notFound, .failure:
            session = .signedOut
        }
    }

    private func activate(token: String) {
        client = makeClient(token)
        loadCache()
        session = .signedIn
        refreshAll()
    }

    func signIn(_ candidate: String) async {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { signInError = "Paste a GitHub token to continue."; return }
        generation += 1
        let current = generation
        isSigningIn = true; signInError = nil
        let nextClient = makeClient(clean)
        do {
            let identity = try await nextClient.currentUser()
            guard current == generation else { return }
            try vault.write(clean)
            prepareCache(for: identity.user.login)
            user = identity.user; scopes = identity.scopes; client = nextClient
            applyPreferences()
            isSigningIn = false
            session = .signedIn
            saveCache()
            refreshAll()
        } catch {
            guard current == generation else { return }
            isSigningIn = false
            signInError = error.localizedDescription
        }
    }

    func signOut(message: String? = nil) {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        vault.clear()
        cache.clear()
        DraftStore.shared.clearAll()
        AccountPreferences.clearAll(defaults: defaults)
        client = nil; user = nil; scopes = []
        lists = [:]; listTotals = [:]; listCursors = [:]; listStates = [:]; discovering = []; loadingPages = []; recentlyReviewed = [:]
        pendingDone.values.forEach { $0.cancel() }; pendingDone = [:]
        notifications = []; inboxState = .idle; locallyRead = []
        projects = []; projectsState = .idle; pinnedProjects = []; detailCache = nil; savedSearches = []; activeSavedSearch = nil; pushedBranches = []
        outbox = []; LocalStore.support.remove("outbox.json")
        snoozed = [:]; SnoozeStore.save([:]); SpotlightIndexer.clear()
        VisitStore.clear()
        if !isDemo { BackgroundSync.reset() }
        lastUpdated = nil; isRefreshing = false; rateLimitedUntil = nil
        selectedProject = ""; projectOrder = []; statusFilters = [:]
        feedback.clearAll()
        signInError = message
        session = .signedOut
    }

    @discardableResult
    func refreshAll() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(lists: self.listsToRefresh(), includeInbox: true, includeUser: true)
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    func refreshCurrentList() async {
        await refreshAll().value
    }

    func refreshInbox() async {
        if let refreshTask { await refreshTask.value; return }
        await performRefresh(lists: [], includeInbox: true, includeUser: false)
    }

    func refreshVisible() async {
        switch selectedTab {
        case .pulls: await refreshAll().value
        case .inbox: await refreshInbox()
        case .projects: await refreshProjects()
        case .agents: await LinkClient.shared.refreshSessions()
        case .search, .settings: break
        }
    }

    func handleForeground() {
        if session == .locked { restoreSession(); return }
        guard session == .signedIn else { return }
        Task { await flushOutbox() }
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 60 { return }
        refreshAll()
    }

    private func listsToRefresh() -> [PRListKey] {
        var keys = [currentListKey, PRListKey(queue: .needsMyReview, status: .open), PRListKey(queue: .createdByMe, status: .open)]
        keys = keys.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return keys
    }

    private func performRefresh(lists keys: [PRListKey], includeInbox: Bool, includeUser: Bool) async {
        guard let client, session == .signedIn else { return }
        if let until = rateLimitedUntil, until > .now {
            feedback.banner = .rateLimited(until)
            return
        }
        let current = generation
        isRefreshing = true
        for key in keys where self.lists[key] == nil { listStates[key] = .loading }
        if includeInbox && notifications.isEmpty {
            if case .loaded = inboxState {} else { inboxState = .loading }
        }
        defer { if current == generation { isRefreshing = false } }

        let identityTask: Task<Result<(user: GitHubUser, scopes: [String]), Error>, Never>? = includeUser ? Task { await Self.capture { try await client.currentUser() } } : nil
        let inboxTask: Task<Result<[GHNotification], Error>, Never>? = includeInbox ? Task { await Self.capture { try await client.notifications() } } : nil
        let pageResults = await withTaskGroup(of: (PRListKey, Result<PullRequestPage, Error>).self) { group in
            for key in keys {
                group.addTask { (key, await Self.capture { try await client.pullRequests(list: key, cursor: nil, perPage: Self.pageSize) }) }
            }
            var collected: [(PRListKey, Result<PullRequestPage, Error>)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        let identity = await identityTask?.value
        let inbox = await inboxTask?.value
        guard current == generation else { return }

        var errors: [Error] = []
        if let identity {
            switch identity {
            case let .success(value):
                prepareCache(for: value.user.login)
                let changedAccount = !value.user.isSameAccount(as: user)
                user = value.user; scopes = value.scopes
                if changedAccount { applyPreferences() }
            case let .failure(error): errors.append(error)
            }
        }
        for (key, result) in pageResults {
            switch result {
            case let .success(page):
                let existing = lists[key] ?? []
                let merged = PullListMerger.mergeFirstPage(existing: existing, fresh: page.items, pageSize: Self.pageSize)
                lists[key] = merged
                listTotals[key] = page.totalCount
                listCursors[key] = merged.count > page.items.count ? (listCursors[key] ?? page.nextCursor) : page.nextCursor
                listStates[key] = .loaded(.now)
            case let .failure(error):
                listStates[key] = .failed(error.localizedDescription)
                errors.append(error)
            }
        }
        if let inbox {
            switch inbox {
            case let .success(value):
                notifications = PullListMerger.mergeNotifications(existing: notifications, fresh: value, locallyRead: locallyRead)
                inboxState = .loaded(.now)
            case let .failure(error):
                inboxState = .failed(error.localizedDescription)
                errors.append(error)
            }
        }
        if handleErrors(errors) { return }
        let connectivityIssue = errors.contains { $0.asGitHubError == .offline || $0.asGitHubError?.isRateLimit == true }
        if !connectivityIssue {
            rateLimitedUntil = nil
            switch feedback.banner {
            case .offline, .rateLimited: feedback.banner = nil
            default: break
            }
        }
        let reviewKey = PRListKey(queue: .needsMyReview, status: .open)
        let mineKey = PRListKey(queue: .createdByMe, status: .open)
        if !isDemo, includeInbox, lists[reviewKey] != nil, lists[mineKey] != nil {
            BackgroundSync.updateBaseline(reviews: lists[reviewKey] ?? [], mine: lists[mineKey] ?? [], notifications: notifications)
        }
        if !connectivityIssue, !outbox.isEmpty { Task { await flushOutbox() } }
        snoozed = SnoozeStore.all()
        if !isDemo { SpotlightIndexer.index((lists[reviewKey] ?? []) + (lists[mineKey] ?? [])) }
        let requestCount = keys.count + (includeInbox ? 1 : 0) + (includeUser ? 1 : 0)
        if errors.count < requestCount { lastUpdated = .now }
        saveCache()
        startDiscovery(for: currentListKey)
    }

    private func handleErrors(_ errors: [Error]) -> Bool {
        let meaningful = errors.filter { !$0.isCancellation }
        if meaningful.contains(where: { $0.asGitHubError == .unauthorized }) {
            signOut(message: "Your GitHub token has expired or was revoked. Sign in again to continue.")
            return true
        }
        if let limited = meaningful.compactMap(\.asGitHubError).first(where: \.isRateLimit) {
            rateLimitedUntil = limited.retryDate ?? Date.now.addingTimeInterval(60)
            feedback.banner = .rateLimited(limited.retryDate)
            return false
        }
        if meaningful.contains(where: { $0.asGitHubError == .offline }) {
            feedback.banner = .offline
            return false
        }
        if let scopes = meaningful.compactMap(\.asGitHubError).first(where: { if case .missingScopes = $0 { return true }; return false }) {
            feedback.banner = .notice(scopes.localizedDescription)
            return false
        }
        if let first = meaningful.first, !currentPulls.isEmpty || !notifications.isEmpty {
            feedback.error(first, key: "refresh")
        }
        return false
    }

    private func listDidChange() {
        let key = currentListKey
        if lists[key] == nil {
            Task { await performRefresh(lists: [key], includeInbox: false, includeUser: false) }
        } else {
            startDiscovery(for: key)
        }
    }

    func startDiscovery(for key: PRListKey) {
        guard hasMore(key), !discovering.contains(key) else { return }
        discoveryTask?.cancel()
        discovering = [key]
        let current = generation
        discoveryTask = Task { [weak self] in
            while let self, !Task.isCancelled, current == self.generation, self.hasMore(key) {
                let before = self.lists[key]?.count ?? 0
                await self.loadNextPage(key)
                guard (self.lists[key]?.count ?? 0) > before else { break }
                try? await Task.sleep(for: .milliseconds(1_200))
            }
            guard let self, current == self.generation else { return }
            self.discovering.remove(key)
        }
    }

    func loadNextPage(_ key: PRListKey) async {
        guard let client, hasMore(key), !loadingPages.contains(key) else { return }
        let current = generation
        let cursor = listCursors[key]
        loadingPages.insert(key)
        defer { loadingPages.remove(key) }
        do {
            let page = try await client.pullRequests(list: key, cursor: cursor, perPage: Self.pageSize)
            guard current == generation else { return }
            lists[key] = PullListMerger.appendPage(existing: lists[key] ?? [], page: page.items)
            listTotals[key] = page.totalCount
            listCursors[key] = page.nextCursor
            saveCache()
        } catch {
            guard current == generation, !error.isCancellation else { return }
            _ = handleErrors([error])
            discovering.remove(key)
        }
    }

    func pullRequest(_ key: PRKey) async throws -> PullRequest { try await call { try await $0.pullRequest(key) } }
    func checks(_ key: PRKey, sha: String) async throws -> [CheckRun] { try await call { try await $0.checks(key, sha: sha) } }
    func reviews(_ key: PRKey) async throws -> [PRReview] { try await call { try await $0.reviews(key) } }
    func comments(_ key: PRKey) async throws -> [PRComment] { try await call { try await $0.comments(key) } }
    func reviewComments(_ key: PRKey) async throws -> [PRComment] { try await call { try await $0.reviewComments(key) } }
    func search(_ query: String, cursor: String? = nil) async throws -> PullRequestPage { try await call { try await $0.searchPullRequests(query, cursor: cursor) } }
    func addComment(_ key: PRKey, body: String) async throws { try await queueingOffline(OutboxItem(key: key, kind: .comment, body: body)) { try await $0.addComment(key, body: body) } }
    func reply(_ key: PRKey, commentID: Int, body: String) async throws { try await queueingOffline(OutboxItem(key: key, kind: .reply(commentID), body: body)) { try await $0.reply(key, commentID: commentID, body: body) } }
    func submitReview(_ key: PRKey, event: ReviewEvent, body: String) async throws { try await queueingOffline(OutboxItem(key: key, kind: .review(event), body: body)) { try await $0.submitReview(key, event: event, body: body) } }

    @Published private(set) var outbox: [OutboxItem] = LocalStore.support.readJSON([OutboxItem].self, "outbox.json") ?? []
    private var flushing = false

    private func queueingOffline(_ item: OutboxItem, _ operation: (GitHubAPI) async throws -> Void) async throws {
        do {
            try await call(operation)
        } catch GitHubError.offline {
            outbox.append(item)
            saveOutbox()
            feedback.info("You're offline. It will be sent when you're back online.", key: "outbox")
            throw OutboxQueued()
        }
    }

    func removeFromOutbox(_ item: OutboxItem) {
        outbox.removeAll { $0.id == item.id }
        saveOutbox()
    }

    func flushOutbox() async {
        guard !flushing, !outbox.isEmpty, client != nil else { return }
        flushing = true
        defer { flushing = false }
        var sent = 0
        for item in outbox {
            do {
                try await call { api in
                    switch item.kind {
                    case .comment: try await api.addComment(item.key, body: item.body)
                    case let .reply(id): try await api.reply(item.key, commentID: id, body: item.body)
                    case let .review(event): try await api.submitReview(item.key, event: event, body: item.body)
                    }
                }
                outbox.removeAll { $0.id == item.id }
                sent += 1
            } catch GitHubError.offline {
                break
            } catch {
                if let index = outbox.firstIndex(where: { $0.id == item.id }) { outbox[index].lastError = error.localizedDescription }
            }
        }
        saveOutbox()
        if sent > 0 { feedback.success("Sent \(sent) queued item\(sent == 1 ? "" : "s")", key: "outbox-sent") }
    }

    private func saveOutbox() { LocalStore.support.writeJSON(outbox, "outbox.json") }
    func submitPendingReview(_ key: PRKey, reviewID: Int, event: ReviewEvent, body: String) async throws { try await call { try await $0.submitPendingReview(key, reviewID: reviewID, event: event, body: body) } }
    func deletePendingReview(_ key: PRKey, reviewID: Int) async throws { try await call { try await $0.deletePendingReview(key, reviewID: reviewID) } }

    func insight(_ key: PRKey) async throws -> PRInsight { try await call { try await $0.insight(key) } }
    func files(_ key: PRKey) async throws -> [PRFile] { try await call { try await $0.files(key) } }
    func merge(_ key: PRKey, method: MergeMethod, title: String?, message: String?, sha: String) async throws { try await call { try await $0.merge(key, method: method, title: title, message: message, sha: sha) } }
    func deleteBranch(repo: String, branch: String) async throws { try await call { try await $0.deleteBranch(repo: repo, branch: branch) } }
    func updateBranch(_ key: PRKey, expectedHeadSHA: String) async throws { try await call { try await $0.updateBranch(key, expectedHeadSHA: expectedHeadSHA) } }
    func setState(_ key: PRKey, open: Bool) async throws { try await call { try await $0.setState(key, open: open) } }
    func requestReviewers(_ key: PRKey, logins: [String]) async throws { try await call { try await $0.requestReviewers(key, logins: logins) } }
    func setThreadResolved(threadID: String, resolved: Bool) async throws { try await call { try await $0.setThreadResolved(threadID: threadID, resolved: resolved) } }
    func setDraft(pullID: String, draft: Bool) async throws { try await call { try await $0.setDraft(pullID: pullID, draft: draft) } }
    func setAutoMerge(pullID: String, method: MergeMethod?) async throws { try await call { try await $0.setAutoMerge(pullID: pullID, method: method) } }
    func rerunFailedJobs(repo: String, runID: Int) async throws { try await call { try await $0.rerunFailedJobs(repo: repo, runID: runID) } }
    func rerequestCheckRun(repo: String, checkRunID: Int) async throws { try await call { try await $0.rerequestCheckRun(repo: repo, checkRunID: checkRunID) } }

    func timeline(_ key: PRKey) async throws -> [TimelineEvent] { try await call { try await $0.timeline(key) } }
    func addReaction(_ key: PRKey, commentID: Int, reviewComment: Bool, content: ReactionKind) async throws { try await call { try await $0.addReaction(key, commentID: commentID, reviewComment: reviewComment, content: content) } }
    func issue(_ key: PRKey) async throws -> GHIssue { try await call { try await $0.issue(key) } }
    func setIssueState(_ key: PRKey, open: Bool) async throws { try await call { try await $0.setIssueState(key, open: open) } }

    func addPendingLineComment(pullID: String, reviewNodeID: String?, path: String, line: Int, side: String, body: String) async throws { try await call { try await $0.addPendingLineComment(pullID: pullID, reviewNodeID: reviewNodeID, path: path, line: line, side: side, body: body) } }
    func addSingleLineComment(_ key: PRKey, commitID: String, path: String, line: Int, side: String, body: String) async throws { try await call { try await $0.addSingleLineComment(key, commitID: commitID, path: path, line: line, side: side, body: body) } }
    func viewedStates(_ key: PRKey) async throws -> [String: Bool] { try await call { try await $0.viewedStates(key) } }
    func pendingCommentCount(_ key: PRKey, reviewID: Int) async throws -> Int { try await call { try await $0.pendingCommentCount(key, reviewID: reviewID) } }

    func syncViewed(_ states: [String: Bool], files: [PRFile], for key: PRKey) {
        var set = viewedFiles(key)
        for file in files {
            let token = "\(file.filename)@\(file.sha ?? "")"
            if states[file.filename] == true { set.insert(token) }
        }
        defaults.set(Array(set), forKey: "mobile.viewed.\(key.id)")
        objectWillChange.send()
    }

    private var detailCache: [String: PRDetailSnapshot]?

    func cachedDetail(_ key: PRKey) -> PRDetailSnapshot? {
        if detailCache == nil { detailCache = isDemo ? [:] : cache.readJSON([String: PRDetailSnapshot].self, "pr-details.json") ?? [:] }
        return detailCache?[key.id]
    }

    func storeDetail(_ snapshot: PRDetailSnapshot, for key: PRKey) {
        guard !isDemo else { return }
        if detailCache == nil { detailCache = cache.readJSON([String: PRDetailSnapshot].self, "pr-details.json") ?? [:] }
        detailCache?[key.id] = snapshot
        if let all = detailCache, all.count > 30 {
            let keep = all.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(30)
            detailCache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let detailCache { cache.writeJSON(detailCache, "pr-details.json") }
    }

    func viewedFiles(_ key: PRKey) -> Set<String> {
        Set(defaults.stringArray(forKey: "mobile.viewed.\(key.id)") ?? [])
    }

    func setViewed(_ file: PRFile, viewed: Bool, for key: PRKey) {
        var set = viewedFiles(key)
        let token = "\(file.filename)@\(file.sha ?? "")"
        if viewed { set.insert(token) } else { set.remove(token) }
        defaults.set(Array(set), forKey: "mobile.viewed.\(key.id)")
        objectWillChange.send()
        if let pullID = cachedDetail(key)?.insight?.nodeID {
            Task { try? await call { try await $0.setFileViewed(pullID: pullID, path: file.filename, viewed: viewed) } }
        }
    }

    func isViewed(_ file: PRFile, for key: PRKey) -> Bool {
        viewedFiles(key).contains("\(file.filename)@\(file.sha ?? "")")
    }

    func isAuthor(of pull: PullRequest) -> Bool { pull.user?.isSameAccount(as: user) ?? false }

    func markRead(_ notification: GHNotification) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }), notifications[index].unread else { return }
        notifications[index].unread = false
        locallyRead.insert(notification.id)
        do {
            try await call { try await $0.markRead(notification.id) }
            saveCache()
        } catch {
            locallyRead.remove(notification.id)
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) { notifications[index].unread = true }
            feedback.error(error, key: "markRead")
        }
    }

    func markDone(_ notification: GHNotification) {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        let removed = notifications.remove(at: index)
        let id = notification.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        pendingDone[id]?.cancel()
        pendingDone[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.pendingDone[id] = nil
            do {
                try await self.call { try await $0.markDone(id) }
                self.saveCache()
            } catch {
                if !self.notifications.contains(where: { $0.id == id }) {
                    self.notifications.insert(removed, at: min(index, self.notifications.count))
                }
                self.feedback.error(error, key: "markDone")
            }
        }
        feedback.info("Marked as done", key: "done-\(id)", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            self.pendingDone[id]?.cancel()
            self.pendingDone[id] = nil
            if !self.notifications.contains(where: { $0.id == id }) {
                self.notifications.insert(removed, at: min(index, self.notifications.count))
            }
        }
    }

    func mute(_ notification: GHNotification) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        let removed = notifications.remove(at: index)
        do {
            try await call { try await $0.mute(notification.id) }
            saveCache()
            feedback.success("Muted · you won't get updates for this thread", key: "mute")
        } catch {
            notifications.insert(removed, at: min(index, notifications.count))
            feedback.error(error, key: "mute")
        }
    }

    func markAllRead() async {
        let previous = notifications
        let unreadIDs = notifications.filter(\.unread).map(\.id)
        guard !unreadIDs.isEmpty else { return }
        for index in notifications.indices { notifications[index].unread = false }
        locallyRead.formUnion(unreadIDs)
        do {
            try await call { try await $0.markAllRead() }
            saveCache()
            feedback.success("All notifications marked as read", key: "allRead")
        } catch {
            notifications = previous
            locallyRead.subtract(unreadIDs)
            feedback.error(error, key: "allRead")
        }
    }

    func markNotificationsRead(for key: PRKey) async {
        guard defaults.object(forKey: "mobile.inbox.markReadOnOpen") as? Bool ?? true else { return }
        for item in notifications where item.unread && item.pullKey == key {
            await markRead(item)
        }
    }

    func markNotificationsRead(forIssue key: PRKey) async {
        guard defaults.object(forKey: "mobile.inbox.markReadOnOpen") as? Bool ?? true else { return }
        for item in notifications where item.unread && item.issueKey == key {
            await markRead(item)
        }
    }

    private func call<T>(_ operation: (GitHubAPI) async throws -> T) async throws -> T {
        guard let client else { throw GitHubError.unauthorized }
        let current = generation
        do {
            return try await operation(client)
        } catch {
            if current == generation, error.asGitHubError == .unauthorized {
                signOut(message: "Your GitHub token has expired or was revoked. Sign in again to continue.")
            }
            throw error
        }
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private func applyPreferences() {
        guard let preferences else { return }
        selectedProject = preferences.selectedProject
        projectOrder = preferences.projectOrder
        pinnedProjects = preferences.pinnedProjects
        savedSearches = preferences.savedSearches
        statusFilters = Dictionary(uniqueKeysWithValues: PRQueue.allCases.map { ($0, preferences.statusFilter(for: $0)) })
    }

    private func prepareCache(for login: String) {
        if let data = cache.read("account.txt"),
           let previousLogin = String(data: data, encoding: .utf8),
           previousLogin.caseInsensitiveCompare(login) != .orderedSame {
            lists = [:]; listTotals = [:]; listCursors = [:]; notifications = []; lastUpdated = nil; locallyRead = []
            cache.clear()
            DraftStore.shared.clearAll()
        }
        cache.write(Data(login.utf8), as: "account.txt")
    }

    private func saveCache() {
        guard !isDemo else { return }
        cache.writeJSON(CacheSnapshot(user: user, lists: lists, totals: listTotals, cursors: listCursors, notifications: notifications, lastUpdated: lastUpdated, projects: projects), "snapshot.v3.json")
    }

    private func loadCache() {
        guard !isDemo, let snapshot = cache.readJSON(CacheSnapshot.self, "snapshot.v3.json") else { return }
        user = snapshot.user
        lists = snapshot.lists
        listTotals = snapshot.totals
        listCursors = snapshot.cursors
        notifications = snapshot.notifications
        projects = snapshot.projects ?? []
        if !projects.isEmpty, let date = snapshot.lastUpdated { projectsState = .loaded(date) }
        lastUpdated = snapshot.lastUpdated
        for key in snapshot.lists.keys { listStates[key] = snapshot.lastUpdated.map(LoadState.loaded) ?? .idle }
        if let date = snapshot.lastUpdated { inboxState = .loaded(date) }
        applyPreferences()
    }
}
