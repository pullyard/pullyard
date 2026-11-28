import SwiftUI
import CoreSpotlight
import Combine

@main
struct PullYardMobileApp: App {
    @StateObject private var model: AppModel
    @StateObject private var router = AppRouter()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 120 * 1024 * 1024)
        UIRefreshControl.appearance().tintColor = .clear
        ThemeStore.update(ThemeStore.style)
        BackgroundSync.register()
        AgentActivities.dismissFinished()
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            AgentActivities.endAllBeforeExit()
        }
        AgentIntentBridge.respond = { session, request, allow in
            try await LinkClient.shared.respondRemote(session: session, requestID: request, allow: allow)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PYDemo") {
            _model = StateObject(wrappedValue: AppModel(cache: LocalStore(directory: nil), defaults: UserDefaults(suiteName: "PullYardDemo") ?? .standard, isDemo: true, makeClient: { _ in DemoGitHubAPI() }))
            return
        }
        #endif
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.feedback)
                .environmentObject(router)
                .tint(MobileTheme.accent)
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var pullsPath: [Route] = []
    @Published var projectsPath: [Route] = []
    @Published var inboxPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var settingsPath: [Route] = []
    @Published var agentsPath: [Route] = []
    @Published var showSettings = false
    @Published var pendingPairing: PYLinkPairing?
    @Published var showScanner = false

    private struct Snapshot: Codable { var pulls: [Route]; var projects: [Route]?; var inbox: [Route]; var search: [Route] }

    var encoded: Data? { try? JSONEncoder().encode(Snapshot(pulls: pullsPath, projects: projectsPath, inbox: inboxPath, search: searchPath)) }

    func restore(_ data: Data?) {
        guard let data, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pullsPath = snapshot.pulls; projectsPath = snapshot.projects ?? []; inboxPath = snapshot.inbox; searchPath = snapshot.search
    }

    func reset() { pullsPath = []; projectsPath = []; inboxPath = []; searchPath = []; settingsPath = []; agentsPath = [] }

    func replaceTop(with route: Route, in tab: AppTab) {
        switch tab {
        case .pulls: if pullsPath.isEmpty { pullsPath = [route] } else { pullsPath[pullsPath.count - 1] = route }
        case .projects: if projectsPath.isEmpty { projectsPath = [route] } else { projectsPath[projectsPath.count - 1] = route }
        case .inbox: if inboxPath.isEmpty { inboxPath = [route] } else { inboxPath[inboxPath.count - 1] = route }
        case .search: if searchPath.isEmpty { searchPath = [route] } else { searchPath[searchPath.count - 1] = route }
        case .settings: if settingsPath.isEmpty { settingsPath = [route] } else { settingsPath[settingsPath.count - 1] = route }
        case .agents: if agentsPath.isEmpty { agentsPath = [route] } else { agentsPath[agentsPath.count - 1] = route }
        }
    }

    func top(in tab: AppTab) -> Route? {
        switch tab {
        case .pulls: pullsPath.last
        case .projects: projectsPath.last
        case .inbox: inboxPath.last
        case .search: searchPath.last
        case .settings: settingsPath.last
        case .agents: agentsPath.last
        }
    }

    func open(_ route: Route, in tab: AppTab) {
        switch tab {
        case .pulls: pullsPath.append(route)
        case .settings: settingsPath.append(route)
        case .agents: agentsPath.append(route)
        case .projects: projectsPath.append(route)
        case .inbox: inboxPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    func popTo(_ route: Route, in tab: AppTab) {
        func trim(_ path: inout [Route]) {
            if let index = path.lastIndex(of: route) { path = Array(path.prefix(through: index)) }
        }
        switch tab {
        case .pulls: trim(&pullsPath)
        case .settings: trim(&settingsPath)
        case .agents: trim(&agentsPath)
        case .projects: trim(&projectsPath)
        case .inbox: trim(&inboxPath)
        case .search: trim(&searchPath)
        }
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .pulls: pullsPath = []
        case .projects: projectsPath = []
        case .inbox: inboxPath = []
        case .search: searchPath = []
        case .settings: settingsPath = []
        case .agents: agentsPath = []
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ThemeStore.styleKey) private var styleRaw = ThemeStyle.pullyard.rawValue
    @AppStorage(ThemeStore.appearanceKey) private var appearanceRaw = AppearanceMode.automatic.rawValue

    private var style: ThemeStyle { ThemeStyle(rawValue: styleRaw) ?? .pullyard }
    @State private var showSplash = true

    var body: some View {
        let _ = ThemeStore.update(style)
        Group {
            switch model.session {
            case .signedIn: MainTabsView()
            case .locked: LockedView()
            case .signedOut: SignInView()
            }
        }
        .id(style)
        .overlay {
            if showSplash {
                SplashView { withAnimation(.easeOut(duration: 0.2)) { showSplash = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard model.isSignedIn, let route = DeepLink.route(from: url) else { return .systemAction }
            router.open(route, in: model.selectedTab)
            return .handled
        })
        .onReceive(NotificationCenter.default.publisher(for: .pullyardPendingLink)) { _ in consumePendingLink() }
        .onReceive(NotificationCenter.default.publisher(for: .pullyardFocusChanged)) { _ in model.reloadFocus() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard model.isSignedIn, let route = SpotlightIndexer.route(from: activity) else { return }
            router.open(route, in: model.selectedTab)
        }
        .onOpenURL { url in handleURL(url) }
        .onAppear {
            DispatchQueue.main.async {
                KeyboardDismisser.install()
                IslandPresenter.shared.install(feedback: model.feedback)
            }
            let arguments = ProcessInfo.processInfo.arguments
            if model.isDemo, arguments.contains("-PYPin") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.pinnedProjects = ["harbor/mobile", "harbor/api"] }
            }
            if model.isDemo, let index = arguments.firstIndex(of: "-PYOpen"), arguments.indices.contains(index + 1), let url = URL(string: arguments[index + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { handleURL(url) }
            }
        }
        .tint(MobileTheme.accent)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AgentActivities.dismissFinished()
                LinkClient.shared.enterForeground()
                KeyboardDismisser.install()
                model.reloadFocus()
                model.handleForeground()
                consumePendingLink()
            }
            if phase == .background {
                BackgroundSync.schedule()
                LinkClient.shared.enterBackground()
            }
            if phase == .active, model.isSignedIn { LinkClient.shared.connectIfNeeded() }
        }
        .onChange(of: model.session) { _, session in
            if session == .signedOut { router.reset() }
            if session == .signedIn { consumePendingLink() }
        }
    }

    private func consumePendingLink() {
        guard model.isSignedIn, let url = PendingLink.take() else { return }
        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        guard model.isSignedIn else {
            PendingLink.set(url)
            return
        }
        if url.scheme == "pullyard", url.host == "pair", let pairing = PYLinkPairing.parse(url.absoluteString) {
            router.pendingPairing = pairing
            return
        }
        if url.scheme == "pullyard", url.host == "pending" {
            if let pending = PendingLink.take() { handleURL(pending) }
            return
        }
        if url.scheme == "pullyard", url.host == "agent", let id = url.pathComponents.dropFirst().first {
            model.selectedTab = .agents
            if router.top(in: .agents) != .agent(id) { router.open(.agent(id), in: .agents) }
            return
        }
        if url.scheme == "pullyard", url.host == "jira" {
            UserDefaults.standard.set(ProjectsMode.jira.rawValue, forKey: ProjectsMode.key)
            router.popToRoot(.projects)
            model.selectedTab = .projects
            return
        }
        if url.scheme == "pullyard", url.host == "tab", let name = url.pathComponents.dropFirst().first, let tab = AppTab(rawValue: name) {
            router.popToRoot(tab)
            model.selectedTab = tab
            return
        }
        if url.scheme == "pullyard", url.host == "queue" {
            router.popToRoot(.pulls)
            model.activeSavedSearch = nil
            model.queue = .needsMyReview
            model.selectedTab = .pulls
            return
        }
        guard let route = DeepLink.route(from: url) else { return }
        if model.selectedTab == .settings || router.showSettings {
            router.showSettings = false
            if model.selectedTab == .settings { model.selectedTab = .pulls }
        }
        router.open(route, in: model.selectedTab)
    }
}

private struct LockedView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PYEmptyState(title: "Unlock your iPhone", message: "PullYard keeps your GitHub token in the Keychain. It becomes available after you unlock this iPhone.") {
            Button("Try again") { model.restoreSession() }.buttonStyle(.borderedProminent).tint(MobileTheme.accentFill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackdrop())
    }
}

struct MainTabsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var agentBadge = AgentBadge.shared
    @AppStorage("mobile.refresh.minutes") private var refreshMinutes = 5
    @SceneStorage("mobile.router") private var routerData: Data?
    @State private var restored = false

    var body: some View {
        tabs
        .sheet(isPresented: $router.showSettings) {
            settingsStack.pySheetStyle()
        }
        .fullScreenCover(isPresented: scannerBinding(inSettings: false)) { scanner }
        .alert(String(format: L("Pair with %@?"), router.pendingPairing?.name ?? "Mac"), isPresented: Binding(get: { router.pendingPairing != nil }, set: { if !$0 { router.pendingPairing = nil } }), presenting: router.pendingPairing) { pairing in
            Button("Pair") { confirmPairing(pairing) }
            Button("Cancel", role: .cancel) { router.pendingPairing = nil }
        } message: { pairing in
            Text(pairingWarning(pairing))
        }
        .onAppear {
            guard !restored else { return }
            restored = true
            router.restore(routerData)
        }
        .onReceive(router.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            routerData = router.encoded
        }
        .task(id: refreshMinutes) {
            guard refreshMinutes > 0 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(refreshMinutes * 60)) } catch { return }
                guard !Task.isCancelled else { return }
                await model.refreshVisible()
            }
        }
    }

    private func pairingWarning(_ pairing: PYLinkPairing) -> String {
        var text = String(format: L("Pair only if this link came from PullYard on your own Mac. The fingerprint must match the one on the Mac: %@"), PYLinkCrypto.fingerprint(pairing.key))
        if let current = LinkClient.shared.mac, current.id != pairing.id {
            text += "\n\n" + String(format: L("This replaces %@."), current.name)
        }
        return text
    }

    private func confirmPairing(_ pairing: PYLinkPairing) {
        router.pendingPairing = nil
        Task {
            do {
                try await LinkClient.shared.pair(pairing)
                model.feedback.success(String(format: L("Paired with %@"), pairing.name))
            } catch {
                model.feedback.error(error, key: "pair")
            }
        }
    }

    @ViewBuilder private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: tabSelection) {
                Tab("Overview", systemImage: "square.grid.2x2", value: AppTab.pulls) { pullsStack }
                    .badge(model.openCount(for: .needsMyReview) ?? 0)
                Tab("Projects", systemImage: "folder", value: AppTab.projects) { projectsStack }
                Tab("Inbox", systemImage: "tray.full", value: AppTab.inbox) { inboxStack }
                    .badge(model.unreadCount)
                Tab("Agents", systemImage: "wand.and.stars", value: AppTab.agents) { agentsStack }
                    .badge(agentBadge.count)
                Tab(value: AppTab.search, role: .search) { searchStack }
            }
            .pyTabBarMinimizeOnScroll()
        } else {
            TabView(selection: tabSelection) {
                pullsStack
                    .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                    .tag(AppTab.pulls)
                    .badge(model.openCount(for: .needsMyReview) ?? 0)
                projectsStack
                    .tabItem { Label("Projects", systemImage: "folder") }
                    .tag(AppTab.projects)
                inboxStack
                    .tabItem { Label("Inbox", systemImage: "tray.full") }
                    .tag(AppTab.inbox)
                    .badge(model.unreadCount)
                searchStack
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
                agentsStack
                    .tabItem { Label("Agents", systemImage: "wand.and.stars") }
                    .tag(AppTab.agents)
                    .badge(agentBadge.count)
            }
        }
    }

    private var pullsStack: some View { NavigationStack(path: $router.pullsPath) { OverviewView().routeDestinations() } }
    private var projectsStack: some View { NavigationStack(path: $router.projectsPath) { ProjectsHome().routeDestinations() } }
    private var inboxStack: some View { NavigationStack(path: $router.inboxPath) { InboxView().routeDestinations() } }
    private var searchStack: some View { NavigationStack(path: $router.searchPath) { SearchView().routeDestinations() } }
    private var agentsStack: some View { NavigationStack(path: $router.agentsPath) { AgentsHome().routeDestinations() } }
    private var settingsStack: some View {
        NavigationStack(path: $router.settingsPath) {
            SettingsView()
                .routeDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { router.showSettings = false }.fontWeight(.semibold)
                    }
                }
        }
        .fullScreenCover(isPresented: scannerBinding(inSettings: true)) { scanner }
    }

    private var scanner: some View {
        PairingScanner { pairing in try await LinkClient.shared.pair(pairing) }
    }

    private func scannerBinding(inSettings: Bool) -> Binding<Bool> {
        Binding {
            router.showScanner && router.showSettings == inSettings
        } set: { shown in
            if !shown { router.showScanner = false }
        }
    }

    private var tabSelection: Binding<AppTab> {
        Binding {
            model.selectedTab
        } set: { tab in
            if tab == model.selectedTab { router.popToRoot(tab) }
            model.selectedTab = tab
        }
    }
}

struct RouteDestination: View {
    let route: Route
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch route {
        case let .pull(key):
            PRDetailView(key: key, initial: model.lists.values.lazy.flatMap { $0 }.first { $0.key == key })
        case let .project(repo):
            ProjectDetailView(repo: repo)
        case let .files(key):
            FilesView(key: key)
        case let .issue(key):
            IssueDetailView(key: key)
        case let .list(filter):
            FilteredPullsView(filter: filter)
        case .allPulls:
            PullRequestsView()
        case let .newPull(repo, head):
            CreatePullView(repo: repo, initialHead: head)
        case let .finishReview(key):
            FinishReviewView(key: key)
        case let .newIssue(repo):
            CreateIssueView(repo: repo)
        case let .browse(repo, ref, path):
            RepoBrowserView(repo: repo, ref: ref, path: path)
        case let .agent(session):
            AgentChatView(session: session)
        case .agents:
            AgentSessionsView()
        case .jiraBoard:
            JiraBoardView()
        case let .fileDiff(key, path):
            FileDiffView(key: key, path: path)
        case let .notification(id):
            if let item = model.notification(id: id) {
                if let key = item.pullKey {
                    PRDetailView(key: key)
                } else {
                    NotificationFallbackView(item: item)
                }
            } else {
                ContentUnavailableView("Notification unavailable", systemImage: "bell.slash", description: Text("It may have been marked as done on another device."))
            }
        }
    }
}

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}
