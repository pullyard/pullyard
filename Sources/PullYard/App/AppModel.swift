import AppKit
import SwiftUI

enum PRFilter: String, CaseIterable, Identifiable {
    case reviewRequested, mine, assigned, mentioned, reviewed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviewRequested: return "Review requests"
        case .mine: return "Created by me"
        case .assigned: return "Assigned to me"
        case .mentioned: return "Mentioned"
        case .reviewed: return "Reviewed by me"
        }
    }

    var icon: String {
        switch self {
        case .reviewRequested: return "eye"
        case .mine: return "person"
        case .assigned: return "person.crop.circle.badge.checkmark"
        case .mentioned: return "at"
        case .reviewed: return "checkmark.bubble"
        }
    }

    var query: String {
        switch self {
        case .reviewRequested: return Demo.query("review-requested:@me")
        case .mine: return Demo.query("author:@me")
        case .assigned: return Demo.query("assignee:@me")
        case .mentioned: return Demo.query("mentions:@me")
        case .reviewed: return Demo.query("reviewed-by:@me -author:@me")
        }
    }
}

enum IssueFilter: String, CaseIterable, Identifiable {
    case assigned, mine, mentioned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assigned: return "Assigned to me"
        case .mine: return "Created by me"
        case .mentioned: return "Mentioned"
        }
    }

    var icon: String {
        switch self {
        case .assigned: return "person.crop.circle.badge.checkmark"
        case .mine: return "person"
        case .mentioned: return "at"
        }
    }

    var query: String {
        switch self {
        case .assigned: return Demo.query("assignee:@me")
        case .mine: return Demo.query("author:@me")
        case .mentioned: return Demo.query("mentions:@me")
        }
    }
}

struct CodeOpenRequest {
    let repo: RepoRef
    let ref: String
    let path: String
    let blame: Bool
}

enum SidebarSection: Hashable {
    case overview
    case notifications
    case prs(PRFilter)
    case myPRsByRepo
    case allPRs
    case stacks
    case issues(IssueFilter)
    case repos
    case projects
    case claude
    case jira

    var isFullWidth: Bool { self == .claude || self == .overview || self == .jira }

    var storageKey: String {
        switch self {
        case .overview: return "overview"
        case .notifications: return "notifications"
        case .prs(let f): return "prs/\(f.rawValue)"
        case .myPRsByRepo: return "prs/byProject"
        case .allPRs: return "prs/all"
        case .stacks: return "stacks"
        case .issues(let f): return "issues/\(f.rawValue)"
        case .repos: return "repos"
        case .projects: return "projects"
        case .claude: return "claude"
        case .jira: return "jira"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: "/").map(String.init)
        switch (parts.first, parts.dropFirst().first) {
        case ("overview", _): self = .overview
        case ("notifications", _): self = .notifications
        case ("prs", "byProject"): self = .myPRsByRepo
        case ("prs", "all"): self = .allPRs
        case ("prs", let f?): self = .prs(PRFilter(rawValue: f) ?? .reviewRequested)
        case ("stacks", _): self = .stacks
        case ("issues", let f?): self = .issues(IssueFilter(rawValue: f) ?? .assigned)
        case ("repos", _): self = .repos
        case ("projects", _): self = .projects
        case ("claude", _): self = .claude
        case ("jira", _): self = .jira
        default: return nil
        }
    }
}

enum ToastKind: Equatable {
    case info, error, merged, approved
}

struct ToastAction {
    let title: String
    let run: @MainActor () -> Void
}

enum NavigationMemory {
    static let sectionKey = "nav.section"
    static let routeKey = "nav.route"

    static func encode(_ route: Route, account: String?) -> String? {
        let owner = account ?? ""
        switch route {
        case .pr(let ref): return "\(owner)|pr|\(ref.repo.full)|\(ref.number)"
        case .issue(let ref): return "\(owner)|issue|\(ref.repo.full)|\(ref.number)"
        case .repo(let repo): return "\(owner)|repo|\(repo.full)|0"
        default: return nil
        }
    }

    static func decode(_ stored: String, account: String?) -> Route? {
        let parts = stored.components(separatedBy: "|")
        guard parts.count == 4, parts[0] == (account ?? ""), let repo = RepoRef(full: parts[2]) else { return nil }
        switch parts[1] {
        case "pr": return Int(parts[3]).map { .pr(ItemRef(repo: repo, number: $0)) }
        case "issue": return Int(parts[3]).map { .issue(ItemRef(repo: repo, number: $0)) }
        case "repo": return .repo(repo)
        default: return nil
        }
    }
}

@Observable
@MainActor
final class AppModel {
    enum Phase { case checking, loggedOut, locked, loggedIn }

    var phase: Phase = .checking {
        didSet {
            guard phase == .loggedIn, oldValue != .loggedIn else { return }
            restoreRoute()
            replayPending()
        }
    }
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingTarget: ActivityTarget?
    var api: GitHubAPI?
    var forge: ForgeClient?
    var account: GitAccount?
    var forgeSelection: SearchItem? {
        didSet { if oldValue?.id != forgeSelection?.id { detailPath = [] } }
    }
    private var forgeReview: PRBackend?
    var forgeCaps = ForgeCapabilities(pullFilters: [.reviewRequested, .mine])
    var showAddAccount = false
    var lockedAccount: GitAccount?
    var unlockRequest: GitAccount?
    var user: RESTUser?
    var scopes: [String] = []
    var section: SidebarSection? = AppModel.storedSection {
        didSet {
            guard section != oldValue, let section else { return }
            if let oldValue, !oldValue.isFullWidth { lastListSection = oldValue }
            if !Demo.isOn { UserDefaults.standard.set(section.storageKey, forKey: NavigationMemory.sectionKey) }
        }
    }
    @ObservationIgnored private var lastListSection: SidebarSection?
    var detailRoot: Route? {
        didSet {
            guard detailRoot != oldValue, phase == .loggedIn, !Demo.isOn else { return }
            let stored = detailRoot.flatMap { NavigationMemory.encode($0, account: cacheAccount) }
            UserDefaults.standard.set(stored, forKey: NavigationMemory.routeKey)
        }
    }
    var detailPath: [Route] = [] {
        didSet {
            guard detailPath != oldValue else { return }
            if detailPath.count < oldValue.count, Array(oldValue.prefix(detailPath.count)) == detailPath {
                forwardRoutes += oldValue.suffix(oldValue.count - detailPath.count).reversed()
            } else if detailPath.count == oldValue.count + 1, Array(detailPath.dropLast()) == oldValue, detailPath.last == forwardRoutes.last {
                forwardRoutes.removeLast()
            } else {
                forwardRoutes = []
            }
        }
    }
    private(set) var forwardRoutes: [Route] = []
    var showMenuBar = UserDefaults.standard.object(forKey: "menuBar.show") as? Bool ?? true {
        didSet { if showMenuBar != oldValue { UserDefaults.standard.set(showMenuBar, forKey: "menuBar.show") } }
    }

    private static var storedSection: SidebarSection {
        guard !Demo.isOn else { return .prs(.reviewRequested) }
        guard let key = UserDefaults.standard.string(forKey: NavigationMemory.sectionKey) else { return .overview }
        return SidebarSection(storageKey: key) ?? .prs(.reviewRequested)
    }

    func goBack() {
        if !detailPath.isEmpty { detailPath.removeLast() }
    }

    func goForward() {
        if let next = forwardRoutes.last { detailPath.append(next) }
    }

    private func restoreRoute() {
        guard !Demo.isOn, api != nil, detailRoot == nil, section?.isFullWidth != true,
              let stored = UserDefaults.standard.string(forKey: NavigationMemory.routeKey),
              let route = NavigationMemory.decode(stored, account: cacheAccount) else { return }
        detailRoot = route
        remember(route)
    }

    func lockNow() {
        guard phase == .loggedIn, let account, AccountLock.shared.isProtected(account.id) else { return }
        flushDrafts()
        pollTask?.cancel()
        lockedAccount = account
        ClaudeProfiles.shared.scope = ""
        phase = .locked
    }

    var canLock: Bool {
        phase == .loggedIn && account.map { AccountLock.shared.isProtected($0.id) } == true
    }
    var refreshTick = 0
    var liveTick = 0
    var showOpenLink = false
    var showQuickOpen = false
    var showCommandPalette = false
    var showOnboarding = false
    static let onboardingKey = "onboarding.seen.v1"

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        withAnimation(Motion.smooth) { showOnboarding = false }
        if forge == nil { section = .overview }
    }
    var recentRoutes: [Route] = []
    var clipboardRoute: Route?
    var toast: String?
    var loginNotice: String?
    var toastIsError = false
    var toastKind: ToastKind = .info
    var toastAction: ToastAction?
    var toastSerial = 0
    var pendingCode: CodeOpenRequest?
    var reviewRequests: [SearchItem] = []
    var myPRs: [SearchItem] = []
    var reviewRequestCount = 0 { didSet { DockBadge.set(reviews: reviewRequestCount) } }
    var myPRCount = 0
    var focusCounts: (scope: String, reviews: Int, mine: Int)?

    var sidebarReviewCount: Int {
        guard let focused = currentFocusCounts else { return reviewRequestCount }
        return focused.reviews
    }

    var sidebarMineCount: Int {
        guard let focused = currentFocusCounts else { return myPRCount }
        return focused.mine
    }

    private var currentFocusCounts: (scope: String, reviews: Int, mine: Int)? {
        let account = cacheAccount
        guard RepoFocus.shared.isActive(account) else { return nil }
        if forge != nil {
            let focus = RepoFocus.shared
            return ("", reviewRequests.filter { focus.includes($0.repository.nameWithOwner, account: account) }.count, myPRs.filter { focus.includes($0.repository.nameWithOwner, account: account) }.count)
        }
        guard let counts = focusCounts, counts.scope == "\(account ?? "")|\(RepoFocus.shared.query(account))" else { return nil }
        return counts
    }

    func refreshFocusCounts() async {
        let account = cacheAccount
        let query = RepoFocus.shared.query(account)
        guard forge == nil, !query.isEmpty, let api, !Demo.isOn else { return }
        let scope = "\(account ?? "")|\(query)"
        guard let counts = try? await api.focusCounts(query), self.api === api, cacheAccount == account else { return }
        focusCounts = (scope, counts.reviews, counts.mine)
    }
    var unreadCount = 0
    var lastBadgeRefresh: Date?
    var syncError: String?
    private var syncFailures = 0
    var rateLimitedUntil: Date?
    private var lastLiveRefresh = Date()
    private var liveStale = false
    private var resumeTask: Task<Void, Never>?
    let claude = ClaudeWorkspace()

    private var lastClipboard: String?
    private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var canonicalItems: [ItemRef: ItemRef] = [:]
    private var pollTask: Task<Void, Never>?
    private var prModels: [ItemRef: PRDetailModel] = [:]
    private var prOrder: [ItemRef] = []

    var hasProjectScope: Bool {
        scopes.isEmpty || scopes.contains("read:project") || scopes.contains("project")
    }

    init() {
        DiffPrefs.settleWrapDefault()
        URLCache.shared = URLCache(memoryCapacity: 40 << 20, diskCapacity: 200 << 20)
        Diagnostics.shared.start()
        DispatchQueue.main.async { [weak self] in
            if let self { PYLinkServer.shared.attach(self) }
            self?.claude.observeBadge()
            AppDelegate.workspace = self?.claude
            AppDelegate.flushDrafts = { [weak self] in self?.flushDrafts() }
            ForegroundActivity.start()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.section == .claude, let tab = self.claude.selectedTab else { return }
                tab.unread = false
                SessionSeen.shared.mark(tab.sessionId)
            }
        }
        NotificationCenter.default.addObserver(forName: .didCopyToPasteboard, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .loggedIn else { return }
                self.showToast("Copied")
            }
        }
        NotificationCenter.default.addObserver(forName: .openActivity, object: nil, queue: .main) { [weak self] note in
            guard let target = note.object as? ActivityTarget else { return }
            MainActor.assumeIsolated { self?.open(target) }
        }
        NotificationCenter.default.addObserver(forName: .openAgentTab, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            MainActor.assumeIsolated {
                guard let self, self.claude.tabs.contains(where: { $0.id == id }) else { return }
                self.section = .claude
                self.claude.selectedTabID = id
            }
        }
                StackNotesMCP.target = { [weak self] in
            guard let self, let api = self.api else { return nil }
            return (self.cacheAccount, api.host)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _ = StackNotes.shared }
        Task { await restore() }
    }

    private func restore() async {
        if let token = ProcessInfo.processInfo.environment["PULLYARD_TOKEN"] {
            await resumeGitHub(token: token, account: nil)
            return
        }
        let accounts = GitAccounts.shared
        guard let account = accounts.active, let credential = accounts.credential(for: account) else {
            phase = .loggedOut
            return
        }
        if AccountLock.shared.isProtected(account.id) {
            lockedAccount = account
            ClaudeProfiles.shared.scope = ""
            phase = .locked
            return
        }
        await resume(account, credential: credential)
    }

    func unlocked(_ account: GitAccount) {
        if lockedAccount?.id == account.id {
            lockedAccount = nil
            phase = .checking
            Task {
                if let credential = GitAccounts.shared.credential(for: account) {
                    await resume(account, credential: credential)
                } else {
                    phase = .loggedOut
                }
            }
        } else {
            unlockRequest = nil
            switchAccountReportingErrors(to: account.id)
        }
    }

    func requestSwitch(to id: String) {
        guard let target = GitAccounts.shared.accounts.first(where: { $0.id == id }) else { return }
        if target.id != account?.id, AccountLock.shared.isProtected(target.id) {
            unlockRequest = target
        } else {
            switchAccountReportingErrors(to: id)
        }
    }

    func resetLock(_ account: GitAccount) async -> Bool {
        guard await SystemAuth.deviceOwner("reset the PIN for \(account.subtitle)") else { return false }
        AccountLock.shared.removeLock(account.id)
        if ClaudeProfiles.shared.scope == account.id { claude.closeAllForProfileSwitch() }
        await ClaudeAccountStore.shared.logout(profiles: ClaudeProfiles.shared.owned(by: account.id))
        return true
    }

    private func resume(_ account: GitAccount, credential: GitCredential) async {
        if account.provider.isGitHub {
            await resumeGitHub(token: credential.token, account: account)
        } else if let client = makeForgeClient(account, credential: credential) {
            enterForge(account, client: client)
            await verifyForge(client)
        }
    }

    private func resumeGitHub(token: String, account: GitAccount?) async {
        let host = account?.host ?? GitProvider.github.defaultHost
        let cached = account.flatMap { $0.login.isEmpty ? nil : $0.user } ?? ListCache.account(for: token)
        if !Demo.isOn, let cached {
            let api = makeAPI(token, host: host)
            if self.account?.id != account?.id || self.user?.login != cached.login {
                SearchListModel.resetCache()
                resetStacks()
            }
            self.account = account
            self.forge = nil
            self.api = api
            user = cached
            ListCache.activate(account?.cacheKey ?? cached.login)
            if let account { bindClaude(to: account) }
            loginNotice = nil
            phase = .loggedIn
            startPolling()
            await verify(api, token: token)
            return
        }
        let api = makeAPI(token, host: host)
        do {
            let (user, scopes) = try await api.currentUser()
            enterGitHub(account.map { refreshed($0, user) }, api: api, user: user, scopes: scopes, token: token)
        } catch let e as APIError where e.status == 401 {
            revoked()
        } catch {
            self.account = account
            self.api = api
            if let account { bindClaude(to: account) }
            loginNotice = nil
            phase = .loggedIn
            startPolling()
        }
    }

    func refreshTokenFromGH() async -> String? {
        let provider = account?.provider ?? .github
        guard provider.isGitHub else { return nil }
        let host = account?.host ?? GitProvider.github.defaultHost
        do {
            let t = try await GHCLI.token(host: host)
            try await addAccount(provider, host: host, credential: GitCredential(token: t))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func addAccount(_ provider: GitProvider, host rawHost: String, credential: GitCredential, email: String? = nil) async throws {
        let host = provider.hostEditable ? GitProvider.normalizeHost(rawHost) : provider.defaultHost
        guard !host.isEmpty else { throw APIError(message: "Enter the server address") }
        let key = "account-\(UUID().uuidString.lowercased())"
        var draft = GitAccount(id: UUID().uuidString.lowercased(), provider: provider, host: host, login: "", email: email?.trimmingCharacters(in: .whitespacesAndNewlines), keychainKey: key)
        if provider.isGitHub {
            let api = makeAPI(credential.token, host: host)
            let (user, scopes) = try await api.currentUser()
            draft = refreshed(draft, user)
            let saved = try GitAccounts.shared.upsert(draft, credential: credential)
            await leaveCurrent(for: saved)
            enterGitHub(saved, api: api, user: user, scopes: scopes, token: credential.token)
        } else {
            guard let probe = makeForgeClient(draft, credential: credential) else { return }
            let user = try await probe.currentUser()
            draft.login = user.login
            draft.name = user.name
            draft.avatarUrl = user.avatarUrl
            draft.userID = user.id
            let saved = try GitAccounts.shared.upsert(draft, credential: credential)
            await leaveCurrent(for: saved)
            if let client = makeForgeClient(saved, credential: credential) { enterForge(saved, client: client) }
        }
    }

    func switchAccount(to id: String) async throws {
        let accounts = GitAccounts.shared
        guard id != account?.id || phase != .loggedIn, let target = accounts.accounts.first(where: { $0.id == id }) else { return }
        guard let credential = accounts.credential(for: target) else {
            throw APIError(message: "Sign-in for \(target.subtitle) has expired. Sign in again to use this account.")
        }
        await leaveCurrent(for: target)
        await resume(target, credential: credential)
    }

    func switchAccountReportingErrors(to id: String) {
        Task {
            do { try await switchAccount(to: id) } catch { showToast(error.localizedDescription, isError: true) }
        }
    }

    private func leaveCurrent(for next: GitAccount) async {
        if phase == .loggedIn, account?.id != next.id { resetSession(forgetCache: false) }
        GitAccounts.shared.setActive(next.id)
    }

    private func bindClaude(to account: GitAccount) {
        let profiles = ClaudeProfiles.shared
        if profiles.owned(by: account.id).isEmpty, !profiles.claimUnowned(for: account.id) {
            _ = try? profiles.add(label: "\(account.provider.shortTitle) @\(account.login)", shareSettings: false, owner: account.id)
        }
        profiles.scope = account.id
        guard let target = profiles.preferred(for: account.id), target.id != profiles.activeID else { return }
        switchClaudeProfile(to: target.id)
    }

    private func unbindClaude(from account: GitAccount) async {
        let profiles = ClaudeProfiles.shared
        let owned = profiles.owned(by: account.id)
        claude.closeAllForProfileSwitch()
        await ClaudeAccountStore.shared.logout(profiles: owned)
        for p in owned {
            if p.isDefault { profiles.release(p.id) } else { profiles.remove(p.id) }
        }
        profiles.scope = nil
    }

    private func refreshed(_ account: GitAccount, _ user: RESTUser) -> GitAccount {
        var a = account
        a.login = user.login
        a.name = user.name
        a.avatarUrl = user.avatarUrl
        return a
    }

    private func enterGitHub(_ account: GitAccount?, api: GitHubAPI, user: RESTUser, scopes: [String], token: String) {
        if self.account?.id != account?.id || self.user?.login != user.login { SearchListModel.resetCache() }
        resetStacks()
        if let account {
            GitAccounts.shared.update(account)
            bindClaude(to: account)
        }
        self.account = account
        self.forge = nil
        forgeReview = nil
        self.api = api
        self.user = Demo.isOn ? Demo.user : user
        self.scopes = scopes
        if !Demo.isOn {
            if account?.provider ?? .github == .github {
                ListCache.remember(user, token: token)
            } else if let account {
                ListCache.activate(account.cacheKey)
            }
        }
        loginNotice = nil
        phase = .loggedIn
        startPolling()
    }

    private func resetStacks() {
        flushDrafts()
        prModels = [:]
        prOrder = []
        StackStore.reset()
        StacksModel.reset()
    }

    private func enterForge(_ account: GitAccount, client: ForgeClient) {
        if self.account?.id != account.id { ForgeListModel.resetCache() }
        resetStacks()
        bindClaude(to: account)
        self.account = account
        forge = client
        forgeReview = client.reviewBackend()
        api = nil
        prModels = [:]
        prOrder = []
        user = account.user
        scopes = []
        ListCache.activate(account.cacheKey)
        forgeCaps = ForgeCapabilities(pullFilters: [.reviewRequested, .mine])
        if !forgeSupports(section) { section = .prs(.reviewRequested) }
        Task {
            let caps = await client.capabilities()
            guard forge === client else { return }
            forgeCaps = caps
            if !forgeSupports(section) { section = .prs(caps.pullFilters.first ?? .mine) }
            await refreshBadges()
        }
        detailRoot = nil
        detailPath = []
        forgeSelection = nil
        loginNotice = nil
        phase = .loggedIn
        startPolling()
    }

    private func verify(_ api: GitHubAPI, token: String) async {
        do {
            let (user, scopes) = try await api.currentUser()
            guard self.api === api else { return }
            self.user = user
            self.scopes = scopes
            if let account {
                let updated = refreshed(account, user)
                self.account = updated
                GitAccounts.shared.update(updated)
                if updated.provider == .github { ListCache.remember(user, token: token) }
            } else {
                ListCache.remember(user, token: token)
            }
        } catch let e as APIError where e.status == 401 {
            guard self.api === api else { return }
            revoked()
        } catch {}
    }

    private func verifyForge(_ client: ForgeClient) async {
        do {
            let u = try await client.currentUser()
            guard forge === client, var account else { return }
            account.login = u.login
            account.name = u.name
            account.avatarUrl = u.avatarUrl
            account.userID = u.id ?? account.userID
            self.account = account
            user = account.user
            GitAccounts.shared.update(account)
        } catch let e as APIError where e.status == 401 {
            guard forge === client else { return }
            revoked()
        } catch {}
    }

    var provider: GitProvider { account?.provider ?? .github }

    var accountSubtitle: String? {
        if Demo.isOn { return user.map { "@\($0.login)" } }
        return account?.subtitle ?? user.map { "@\($0.login)" }
    }

    var cacheAccount: String? {
        Demo.isOn ? nil : (account?.cacheKey ?? user?.login)
    }

    private func makeAPI(_ token: String, host: String = GitProvider.github.defaultHost) -> GitHubAPI {
        let api = GitHubAPI(token: token, host: host)
        api.onRateLimit = { [weak self] until in
            Task { @MainActor in self?.pauseLive(until: until) }
        }
        return api
    }

    var liveRefreshPaused: Bool {
        rateLimitedUntil.map { $0 > Date() } ?? false
    }

    func pauseLive(until: Date) {
        guard until > Date(), until > (rateLimitedUntil ?? .distantPast) else { return }
        rateLimitedUntil = until
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(until.timeIntervalSinceNow, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rateLimitedUntil = nil
        }
    }

    var frontRoute: Route? {
        section?.isFullWidth == true ? nil : (detailPath.last ?? detailRoot)
    }

    var detailTitle: DetailTitle?

    var frontHasRefreshPill: Bool {
        guard forge == nil else { return false }
        switch frontRoute {
        case .pr?, .issue?: return true
        default: return false
        }
    }

    var frontDetailKey: String? {
        if section?.isFullWidth == true { return nil }
        if forge != nil { return forgeSelection.map { "forge:\($0.id)" } }
        return frontRoute.map { "\($0)" }
    }

    var frontTitle: DetailTitle? {
        guard let t = detailTitle, let key = frontDetailKey, t.key == key else { return nil }
        return t
    }

    private var mainWindowVisible: Bool {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        guard !windows.isEmpty else { return true }
        return windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    func windowVisibilityChanged() {
        guard phase == .loggedIn, liveStale, !liveRefreshPaused, mainWindowVisible else { return }
        liveStale = false
        lastLiveRefresh = Date()
        Diagnostics.shared.beginTick()
        liveTick += 1
    }

    func signOut() async {
        let current = account
        if let current { await unbindClaude(from: current) }
        resetSession(forgetCache: true)
        if let current {
            AccountLock.shared.removeLock(current.id)
            GitAccounts.shared.remove(current.id)
        } else {
            Keychain.delete()
        }
        if let next = GitAccounts.shared.accounts.first { requestSwitch(to: next.id) }
    }

    private func revoked() {
        if let account {
            loginNotice = "The sign-in for \(account.subtitle) expired or was revoked. Sign in again to continue."
        } else {
            loginNotice = "Your sign-in expired or was revoked. Sign in again to continue."
        }
        if let account { GitAccounts.shared.forgetCredential(account.id) } else { Keychain.delete() }
        ClaudeProfiles.shared.scope = nil
        resetSession(forgetCache: false)
    }

    private func resetSession(forgetCache: Bool) {
        pollTask?.cancel()
        resumeTask?.cancel()
        rateLimitedUntil = nil
        if forgetCache { ListCache.forget(account?.cacheKey ?? user?.login ?? ListCache.rememberedLogin) }
        SearchListModel.resetCache()
        ForgeListModel.resetCache()
        api = nil
        forge = nil
        forgeReview = nil
        account = nil
        user = nil
        scopes = []
        detailRoot = nil
        detailPath = []
        forgeSelection = nil
        recentRoutes = []
        resetStacks()
        reviewRequests = []
        myPRs = []
        ActivityNotifier.shared.reset()
        reviewRequestCount = 0
        myPRCount = 0
        unreadCount = 0
        RowAppearTracker.resetAll()
        phase = .loggedOut
    }

    func newAgentSession() {
        guard phase == .loggedIn else { return }
        section = .claude
        if let folder = claude.selectedTab?.folder ?? claude.projects.first(where: \.exists)?.path {
            claude.newSession(folder: folder)
        } else {
            showQuickOpen = true
        }
    }

    func refresh() {
        lastLiveRefresh = Date()
        refreshTick += 1
        Task { await refreshBadges() }
    }

    func select(_ route: Route?) {
        detailRoot = route
        detailPath = []
        if let route { remember(route) }
    }

    private func remember(_ route: Route) {
        recentRoutes.removeAll { $0 == route }
        recentRoutes.insert(route, at: 0)
        if recentRoutes.count > 20 { recentRoutes.removeLast(recentRoutes.count - 20) }
    }

    func open(_ route: Route, push: Bool = false) {
        if section?.isFullWidth != false {
            section = lastListSection ?? .prs(.mine)
            detailPath = []
            detailRoot = route
            remember(route)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if push, detailRoot != nil {
            detailPath.append(route)
            remember(route)
        } else {
            select(route)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func replayPending() {
        let url = pendingURL
        let target = pendingTarget
        pendingURL = nil
        pendingTarget = nil
        guard url != nil || target != nil else { return }
        Task { @MainActor [weak self] in
            if let url { self?.handle(url: url) }
            if let target { self?.open(target) }
        }
    }

    func open(_ target: ActivityTarget) {
        guard phase == .loggedIn else {
            pendingTarget = target
            return
        }
        guard target.account == nil || target.account == cacheAccount else { return openInBrowser(target.url) }
        if forge != nil {
            guard let item = (reviewRequests + myPRs).first(where: { $0.url == target.url }) else { return openInBrowser(target.url) }
            if section?.isFullWidth != false { section = .prs(forgeCaps.pullFilters.first ?? .mine) }
            forgeSelection = item
            NSApp.activate(ignoringOtherApps: true)
        } else if let repo = RepoRef(full: target.repo) {
            open(.pr(ItemRef(repo: repo, number: target.number)))
        } else {
            openInBrowser(target.url)
        }
    }

    static let maxLinkPromptLength = 8000

    private static func promptPreview(_ prompt: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = prompt
        }
        return scroll
    }

    func handle(url: URL) {
        guard let scheme = url.scheme, scheme.hasPrefix("pullyard") || scheme.hasPrefix("shipyard") || scheme.hasPrefix("ghlite") else { return }
        guard phase == .loggedIn else {
            pendingURL = url
            return
        }
        if url.host == "section" {
            let parts = url.pathComponents.filter { $0 != "/" }
            switch (parts.first, parts.dropFirst().first) {
            case ("notifications", _): section = .notifications
            case ("repos", _): section = .repos
            case ("projects", _): section = .projects
            case ("claude", _): section = .claude
            case ("prs", "byProject"): section = .myPRsByRepo
            case ("prs", "all"): section = .allPRs
            case ("stacks", _): section = .stacks
            case ("prs", let f): section = .prs(f.flatMap(PRFilter.init(rawValue:)) ?? .reviewRequested)
            case ("issues", let f): section = .issues(f.flatMap(IssueFilter.init(rawValue:)) ?? .assigned)
            default: break
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if url.host == "claude" {
            section = .claude
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if url.path == "/new", let folder = value("folder"), FileManager.default.fileExists(atPath: folder) {
                let prompt = value("prompt")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Start a Claude session from a link?"
                if let prompt, prompt.count > Self.maxLinkPromptLength {
                    alert.alertStyle = .warning
                    alert.informativeText = "The link's prompt is \(prompt.count) characters long, which is more than PullYard accepts from a link (\(Self.maxLinkPromptLength))."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                alert.informativeText = "Folder: \(folder)\n\nThe session starts in Plan mode: Claude can read files but asks before it edits anything or runs commands. Read the whole prompt before you start it."
                if let prompt, !prompt.isEmpty { alert.accessoryView = Self.promptPreview(prompt) }
                alert.addButton(withTitle: "Start in Plan Mode")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    claude.newSession(folder: folder, prompt: prompt, name: value("name"), mode: .plan)
                }
            }
            if url.path == "/resume", let id = value("id") {
                let kind = value("kind").flatMap(ClaudeTabKind.init(rawValue:))
                Task {
                    if claude.sessionsByID[id] == nil { await claude.reloadProjects() }
                    if let s = claude.sessionsByID[id] { claude.resume(s, kind: kind) }
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let target: String
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
            target = q
        } else {
            target = "https://" + url.absoluteString.components(separatedBy: "://").dropFirst().joined(separator: "://")
        }
        if api != nil, let route = GitHubURL.parse(target) {
            open(route)
            if case .pr(let ref) = route, URL(string: target)?.lastPathComponent == "files" { prModel(ref)?.tab = .files }
        } else if api == nil, GitHubURL.parse(target) != nil {
            showToast("This link opens a GitHub item. Switch to a GitHub account to view it.", isError: true)
        }
    }

    func flushDrafts() {
        for model in prModels.values { model.saveDraftsNow() }
    }

    var forgeReviews: Bool { api == nil && forgeReview != nil }

    func prModel(_ ref: ItemRef) -> PRDetailModel? {
        let backend: PRBackend
        if let api {
            backend = GitHubPRBackend(api: api, provider: account?.provider ?? .github)
        } else if let forgeReview {
            backend = forgeReview
        } else {
            return nil
        }
        if let m = prModels[ref] {
            prOrder.removeAll { $0 == ref }
            prOrder.append(ref)
            return m
        }
        let m = PRDetailModel(ref: ref, backend: backend)
        m.cacheAccount = cacheAccount
        m.restoreDrafts()
        prModels[ref] = m
        prOrder.append(ref)
        if prOrder.count > 15 {
            let old = prOrder.removeFirst()
            prModels[old]?.saveDraftsNow()
            prModels[old] = nil
        }
        return m
    }

    func commitDetail(_ repo: RepoRef, sha: String) async throws -> CommitDetailREST? {
        if let api { return try await api.commit(repo, sha: sha) }
        if let lab = forge as? GitLabClient { return try await lab.commit(repo.full, sha: sha) }
        if let bucket = forge as? BitbucketClient { return try await bucket.commit(repo.full, sha: sha) }
        return nil
    }

    var frontItem: ItemRef? {
        guard let ref = ShortLink.ref(route: frontRoute) else { return nil }
        return canonicalItems[ref] ?? ref
    }

    func noteCanonical(_ ref: ItemRef, url: String) {
        guard let canonical = ShortLink.ref(url: url), canonical.number == ref.number else { return }
        canonicalItems[ref] = canonical
    }

    func copyShortLink(_ ref: ItemRef) {
        let link = ShortLink.make(ref)
        copyToPasteboard(link, announce: false)
        showToast("Copied \(link)")
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(Motion.fade) {
            toast = nil
            toastAction = nil
        }
    }

    func showToast(_ text: String, isError: Bool = false, kind: ToastKind? = nil, action: ToastAction? = nil) {
        toastTask?.cancel()
        withAnimation(Motion.quick) {
            toast = text
            toastIsError = isError
            toastKind = kind ?? (isError ? .error : .info)
            toastAction = action
            toastSerial += 1
        }
        AccessibilityNotification.Announcement(action.map { "\(text). \($0.title) available" } ?? text).post()
        let seconds: Double = isError ? 8 : (action != nil ? 5 : (kind == nil || kind == .info ? 1.8 : 3))
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) {
                self?.toast = nil
                self?.toastAction = nil
            }
        }
    }

    func runToastAction() {
        guard let action = toastAction else { return }
        dismissToast()
        action.run()
    }

    func nextReviewRequest(after ref: ItemRef?) -> SearchItem? {
        reviewRequests.first { $0.ref != ref }
    }

    func openQueue(step: Int) {
        let queue = reviewRequests
        guard !queue.isEmpty else { return }
        let current = ShortLink.ref(route: frontRoute)
        let index = queue.firstIndex { $0.ref == current }
        let target: Int
        if let index {
            target = (index + step + queue.count) % queue.count
        } else {
            target = step > 0 ? 0 : queue.count - 1
        }
        guard queue[target].ref != current else { return }
        if section?.isFullWidth == true { section = .prs(.reviewRequested) }
        open(queue[target].route)
    }

    func openNextReviewRequest(after ref: ItemRef?) {
        guard let next = nextReviewRequest(after: ref) else { return }
        open(next.route)
    }

    func nextReviewAction(after ref: ItemRef?) -> ToastAction? {
        guard nextReviewRequest(after: ref) != nil else { return nil }
        return ToastAction(title: "Next review →") { [weak self] in self?.openNextReviewRequest(after: ref) }
    }

    func openCode(_ repo: RepoRef, ref: String, path: String, blame: Bool) {
        pendingCode = CodeOpenRequest(repo: repo, ref: ref, path: path, blame: blame)
        open(.repo(repo), push: true)
    }

    func checkClipboard() {
        guard UserDefaults.standard.object(forKey: "clipboard.watch") as? Bool ?? true else {
            clipboardRoute = nil
            return
        }
        guard let s = NSPasteboard.general.string(forType: .string), s != lastClipboard else { return }
        lastClipboard = s
        guard api != nil, account?.provider ?? .github == .github, s.count < 300, s.contains("github.com"), let route = GitHubURL.parse(s, allowShort: false) else { return }
        switch route {
        case .pr, .issue:
            if route != detailRoot { clipboardRoute = route }
        default:
            break
        }
    }

    static var refreshInterval: TimeInterval {
        max(UserDefaults.standard.double(forKey: "pollInterval"), 15)
    }

    func startPolling() {
        pollTask?.cancel()
        lastLiveRefresh = Date()
        Task { await refreshBadges() }
        pollTask = Task { [weak self] in
            var cycle = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                cycle += 1
                let due = Date().timeIntervalSince(self.lastLiveRefresh) >= Self.refreshInterval * 0.8
                if due, !self.liveRefreshPaused, NSApp.isActive || cycle % 4 == 0 { self.tickLive() }
            }
        }
    }

    func didBecomeActive() {
        guard phase == .loggedIn, !liveRefreshPaused, Date().timeIntervalSince(lastLiveRefresh) > 10 else { return }
        tickLive()
    }

    private func tickLive() {
        Diagnostics.shared.beginTick()
        lastLiveRefresh = Date()
        if mainWindowVisible {
            liveStale = false
            liveTick += 1
        } else {
            liveStale = true
        }
        Diagnostics.liveTask { await self.refreshBadges(live: true) }
    }

    func refreshBadges(live: Bool = false) async {
        if let forge {
            await refreshForgeBadges(forge)
            return
        }
        guard let api else { return }
        if Demo.isOn {
            reviewRequestCount = 3
            myPRCount = 7
            unreadCount = 12
            return
        }
        var failure: Error?
        var b: BadgeResponse?
        do { b = try await api.badges() } catch { failure = error }
        guard self.api === api else { return }
        if let b {
            reviewRequests = b.rr.nodes
            reviewRequestCount = b.rr.issueCount
            myPRs = b.mine.nodes
            myPRCount = b.mine.issueCount
        }
        ActivityNotifier.shared.observe(account: cacheAccount, reviews: b?.rr.nodes, reviewTotal: b?.rr.issueCount ?? 0, mine: b?.mine.nodes)
        do { unreadCount = try await api.unreadNotificationCount(live: live) } catch { failure = failure ?? error }
        await refreshFocusCounts()
        recordSync(failure)
    }

    private func recordSync(_ failure: Error?) {
        guard let failure else {
            syncFailures = 0
            syncError = nil
            lastBadgeRefresh = Date()
            return
        }
        if failure is CancellationError || liveRefreshPaused { return }
        syncFailures += 1
        if syncFailures >= 2 { syncError = failure.localizedDescription }
    }

    func forgeSupports(_ section: SidebarSection?) -> Bool {
        switch section {
        case .prs(let f)?: return forgeCaps.pullFilters.contains(f)
        case .myPRsByRepo?: return forgeCaps.pullFilters.contains(.mine)
        case .issues(let f)?: return forgeCaps.issueFilters.contains(f)
        case .notifications?: return forgeCaps.hasInbox
        case .repos?: return forgeCaps.repositories
        case .claude?, .jira?: return true
        default: return false
        }
    }

    private func refreshForgeBadges(_ forge: ForgeClient) async {
        let supported = forgeCaps.pullFilters
        var seenReviews: [SearchItem]?
        var seenMine: [SearchItem]?
        var failure: Error?
        if supported.contains(.reviewRequested) {
            do {
                let rr = try await forge.pullRequests(.reviewRequested, state: .open)
                guard self.forge === forge else { return }
                reviewRequests = Array(rr.prefix(10))
                reviewRequestCount = rr.count
                seenReviews = rr
            } catch { failure = error }
        }
        if supported.contains(.mine) {
            do {
                let mine = try await forge.pullRequests(.mine, state: .open)
                guard self.forge === forge else { return }
                myPRs = Array(mine.prefix(10))
                myPRCount = mine.count
                seenMine = mine
            } catch { failure = failure ?? error }
        }
        guard self.forge === forge else { return }
        ActivityNotifier.shared.observe(account: cacheAccount, reviews: seenReviews, reviewTotal: seenReviews?.count ?? 0, mine: seenMine)
        if forgeCaps.hasInbox {
            do {
                let inbox = try await forge.notifications()
                guard self.forge === forge else { return }
                unreadCount = inbox.filter(\.unread).count
            } catch { failure = failure ?? error }
        } else {
            unreadCount = 0
        }
        recordSync(failure)
    }
}
