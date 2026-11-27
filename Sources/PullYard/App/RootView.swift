import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var splashHold = true

    var body: some View {
        Group {
            if splashHold || app.phase == .checking {
                SplashView()
                    .transition(.opacity)
                    .onTapGesture { splashHold = false }
            } else if app.phase == .loggedOut {
                LoginView().transition(.rise)
            } else if app.phase == .locked, let account = app.lockedAccount {
                UnlockView(account: account) { app.unlocked(account) }.transition(.rise)
            } else {
                MainView().transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: app.phase)
        .sheet(item: Binding(get: { app.unlockRequest }, set: { app.unlockRequest = $0 })) { account in
            UnlockView(account: account, sheet: true) { app.unlocked(account) }
                .environment(app)
        }
        .animation(Motion.smooth, value: splashHold)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(SplashLogo.hold * 1_000_000_000))
            splashHold = false
        }
        .task { await Updater.shared.checkOnLaunch() }
        .onChange(of: Updater.shared.presentRequest) { openWindow(id: "update") }
        .environment(\.locale, .app)
    }
}

struct ThemedRoot<Content: View>: View {
    @AppStorage(Theme.styleKey) private var style = ThemeStyle.pullyard.rawValue
    @AppStorage(Theme.appearanceKey) private var appearance = AppearanceMode.auto.rawValue
    @ViewBuilder let content: Content

    var body: some View {
        let current = ThemeStyle(rawValue: style) ?? .pullyard
        let _ = Theme.style = current
        content
            .font(.syBody)
            .tint(Color.syAccent)
            .id(current)
            .onAppear {
                Theme.applyAppearance()
                TextZoom.shared.installEqualsShortcut()
            }
            .onChange(of: style) { Theme.applyAppearance() }
            .onChange(of: appearance) { Theme.applyAppearance() }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SplitAppShell.flagKey) private var nativeSplit = false

    var body: some View {
        @Bindable var app = app
        Group {
            if nativeSplit {
                SplitAppShell()
            } else {
                AppShell()
            }
        }
            .modifier(BrandToolbar())
            .overlay {
                if app.showOnboarding {
                    OnboardingView { app.finishOnboarding() }
                        .transition(.opacity)
                }
            }
            .toolbar(app.showOnboarding ? .hidden : .automatic, for: .windowToolbar)
            .task {
                guard !Demo.isOn, !UserDefaults.standard.bool(forKey: AppModel.onboardingKey) else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(Motion.smooth) { app.showOnboarding = true }
            }
            .sheet(isPresented: $app.showOpenLink) { OpenLinkSheet() }
            .sheet(isPresented: $app.showQuickOpen) { AgentQuickOpen().environment(app) }
            .confirmationDialog(
                "Close “\(app.claude.pendingClose?.title ?? "")”?",
                isPresented: Binding(get: { app.claude.pendingClose != nil }, set: { if !$0 { app.claude.pendingClose = nil } }),
                presenting: app.claude.pendingClose
            ) { tab in
                Button("Stop and close", role: .destructive) { app.claude.close(tab) }
                Button("Cancel", role: .cancel) {}
            } message: { tab in
                Text(tab.state == .waiting ? "The agent is waiting for your answer. Closing stops the session." : "The agent is still working. Closing stops it mid-task; you can resume the session later from history.")
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    ToastBanner()
                    RateLimitBanner()
                    SyncErrorBanner()
                    ClipboardBanner()
                }
                .animation(Motion.smooth, value: app.clipboardRoute)
                .animation(Motion.fade, value: app.rateLimitedUntil)
                .animation(Motion.fade, value: app.syncError)
            }
            .overlay(alignment: .bottomTrailing) { FixTourOverlay().animation(Motion.smooth, value: FixTour.shared.active) }
            .overlay { CommandPaletteOverlay() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                app.checkClipboard()
                app.didBecomeActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                app.windowVisibilityChanged()
            }
            .onAppear { app.checkClipboard() }
    }
}

struct AppShell: View {
    @Environment(AppModel.self) private var app
    @AppStorage("agents.sidebarHidden") private var hidden = false
    @AppStorage("shell.listWidth") private var listWidth: Double = 360
    @AppStorage("shell.sidebarWidth") private var sidebarStored: Double = 220
    @State private var windowWidth: CGFloat = 0

    static let compactBelow: CGFloat = 1180
    static let sidebarWidth: CGFloat = 220
    static let railWidth: CGFloat = 60

    private var compact: Bool { windowWidth > 0 && windowWidth < Self.compactBelow }
    private var showsList: Bool { !(app.section == .overview && app.forge == nil) && app.section != .jira }
    private var sidebarWidth: CGFloat { compact ? Self.railWidth : CGFloat(sidebarStored) }
    private var effectiveListWidth: CGFloat { compact ? min(CGFloat(listWidth), 320) : CGFloat(listWidth) }

    var body: some View {
        HStack(spacing: 0) {
            if !hidden {
                HStack(spacing: 0) {
                    SidebarView(compact: compact)
                        .frame(width: sidebarWidth)
                        .surface(.sidebar)
                    if compact {
                        Rectangle().fill(Color.syLine).frame(width: 1)
                    } else {
                        ColumnResizeHandle(width: $sidebarStored, range: 180...320, edge: .leading, reset: Double(Self.sidebarWidth))
                    }
                    if showsList {
                        ContentColumn()
                            .frame(width: effectiveListWidth)
                            .frame(maxHeight: .infinity)
                            .surface(.list)
                        ColumnResizeHandle(width: $listWidth, range: 280...(compact ? 320 : 560), edge: .leading, reset: compact ? 320 : 360)
                    }
                }
                .frame(width: sidebarWidth + 1 + (showsList ? 1 + effectiveListWidth : 0))
            }
            DetailColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in windowWidth = w }
            }
        }
        .animation(Motion.smooth, value: compact)
        .edgeReveal(.leading, enabled: hidden, width: showsList ? Self.sidebarWidth + 1 + CGFloat(listWidth) : Self.sidebarWidth) {
            EdgePanelContent(sidebarWidth: Self.sidebarWidth)
            .environment(app)
            .font(.syBody)
            .tint(Color.syAccent)
            .environment(\.locale, .app)
        }
        .toolbar(id: "main") {
            ToolbarItem(id: "sidebar", placement: .navigation) {
                SidebarToggleButton(hidden: $hidden)
            }
        }
    }
}

struct SplitAppShell: View {
    static let flagKey = "shell.nativeSplitView"
    @Environment(AppModel.self) private var app
    @AppStorage("agents.sidebarHidden") private var hidden = false
    @State private var visibility: NavigationSplitViewVisibility = .all

    private var showsList: Bool { !(app.section == .overview && app.forge == nil) && app.section != .jira }

    var body: some View {
        Group {
            if showsList {
                NavigationSplitView(columnVisibility: $visibility) {
                    sidebar
                } content: {
                    ContentColumn()
                        .surface(.list)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 560)
                } detail: {
                    DetailColumn()
                }
            } else {
                NavigationSplitView(columnVisibility: $visibility) {
                    sidebar
                } detail: {
                    DetailColumn()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { visibility = hidden ? .detailOnly : .all }
        .onChange(of: visibility) { _, v in hidden = v == .detailOnly }
        .onChange(of: hidden) { _, h in
            let next: NavigationSplitViewVisibility = h ? .detailOnly : .all
            if visibility != next { withAnimation(Motion.smooth) { visibility = next } }
        }
        .edgeReveal(.leading, enabled: hidden, width: showsList ? AppShell.sidebarWidth + 1 + 360 : AppShell.sidebarWidth) {
            EdgePanelContent(sidebarWidth: AppShell.sidebarWidth)
                .environment(app)
                .font(.syBody)
                .tint(Color.syAccent)
                .environment(\.locale, .app)
        }
    }

    private var sidebar: some View {
        SidebarView(compact: false)
            .modifier(SplitSidebarSurface())
            .navigationSplitViewColumnWidth(min: 180, ideal: AppShell.sidebarWidth, max: 320)
    }
}

private struct SplitSidebarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if GlassSupport.isAvailable, !reduceTransparency, Theme.isBrand {
            content.scrollContentBackground(.hidden).background(Color.sySidebar.opacity(0.35))
        } else {
            content.surface(.sidebar)
        }
    }
}

struct DetailColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.section == .claude {
                ClaudeWorkspaceView()
                    .surface(.panel)
            } else if app.section == .jira {
                JiraBoardView()
                    .surface(.panel)
            } else if app.section == .overview, app.forge == nil {
                OverviewView()
            } else if app.forge != nil {
                ForgeDetailColumn()
                    .surface(.panel)
            } else {
                NavigationStack(path: $app.detailPath) {
                    Group {
                        if let root = app.detailRoot {
                            RouteView(route: root).id(root).transition(.routeSwap)
                        } else {
                            PYEmptyState(
                                title: "Nothing open yet",
                                message: "Select a pull request, issue or project from the list.",
                                shortcuts: [("⌘L", "Open by link"), ("⌘K", "Command palette"), ("⌘/", "Shortcuts")],
                                nextUp: true
                            )
                            .transition(.opacity)
                        }
                    }
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
                .surface(.panel)
            }
        }
    }
}

struct DetachedRouteWindow: View {
    let route: Route
    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []

    var body: some View {
        Group {
            if app.phase == .loggedIn {
                NavigationStack(path: $path) {
                    RouteView(route: route, detached: true)
                        .navigationDestination(for: Route.self) { RouteView(route: $0, detached: true) }
                }
            } else {
                PYEmptyState(title: "PullYard is locked", message: "Open the main window to sign in or unlock.")
            }
        }
        .surface(.panel)
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct OpenInNewWindowCommand: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window") { if let route = app.frontRoute { openWindow(value: route) } }
            .keyboardShortcut(AppCommand.newWindow)
            .disabled(app.frontRoute == nil || app.section == .claude || app.phase != .loggedIn)
    }
}

struct SidebarToggleButton: View {
    @Binding var hidden: Bool

    var body: some View {
        Button { withAnimation(Motion.smooth) { hidden.toggle() } } label: {
            Label(hidden ? "Show sidebar" : "Hide sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut(AppCommand.toggleSidebar)
        .help(hidden ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
    }
}

struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let edge: HorizontalEdge
    var reset: Double?
    @State private var start: Double?
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.syLine)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside, !cursorPushed {
                            NSCursor.resizeLeftRight.push()
                            cursorPushed = true
                        } else if !inside, cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    .onDisappear {
                        if cursorPushed { NSCursor.pop() }
                        cursorPushed = false
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let base = start ?? width
                                start = base
                                width = min(range.upperBound, max(range.lowerBound, base + (edge == .leading ? g.translation.width : -g.translation.width)))
                            }
                            .onEnded { _ in start = nil }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            guard let reset else { return }
                            withAnimation(Motion.smooth) { width = min(range.upperBound, max(range.lowerBound, reset)) }
                        }
                    )
            }
    }
}

struct RouteView: View {
    let route: Route
    var detached = false
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch route {
            case .pr(let ref): PRDetailView(ref: ref)
            case .issue(let ref): IssueDetailView(ref: ref)
            case .repo(let repo): RepoDetailView(repo: repo)
            case .project(let p): ProjectBoardView(project: p)
            case .commit(let repo, let sha): CommitDetailView(repo: repo, sha: sha)
            }
        }
        .environment(\.liveFront, detached || app.frontRoute == route)
        .environment(\.detailKey, "\(route)")
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var layout = SidebarLayout.shared
    @State private var renameText = ""
    var compact = false

    var body: some View {
        List {
            SidebarGroup("") {
                SidebarItemList(group: "top", items: topItems)
            }
            SidebarGroup("") {
                FocusSidebarRow()
            }
            let keys = layout.arrangedGroups(groupKeys)
            ForEach(keys, id: \.self) { key in
                group(key)
            }
            .environment(\.sidebarGroupKeys, keys)
        }
        .listStyle(.sidebar)
        .environment(\.sidebarCompact, compact)
        .task(id: "\(RepoFocus.shared.query(app.cacheAccount))|\(app.cacheAccount ?? "")") { await app.refreshFocusCounts() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !compact, app.forge == nil {
                    SidebarPulseCard()
                }
                if let version = Updater.shared.availableVersion {
                    UpdateAvailableRow(version: version, compact: compact)
                }
                userFooter
            }
        }
        .alert("Rename \u{201C}\(layout.renaming?.title ?? "")\u{201D}", isPresented: Binding(
            get: { layout.renaming != nil },
            set: { if !$0 { layout.renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let item = layout.renaming {
                    layout.rename(item.section, to: renameText, default: item.title)
                }
                layout.renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { layout.renaming = nil }
        } message: {
            Text("Leave empty to use the original name.")
        }
        .onChange(of: layout.renaming?.id) { _, _ in
            if let item = layout.renaming {
                renameText = layout.title(for: item.section, default: item.title)
            }
        }
    }

    private var topItems: [SidebarItem] {
        var out: [SidebarItem] = []
        if app.forge == nil {
            out.append(SidebarItem(section: .overview, title: "Overview", icon: "square.grid.2x2.fill", color: .syAccent))
            out.append(SidebarItem(section: .notifications, title: "Notifications", icon: "bell.fill", color: .syAmber, count: app.unreadCount))
        } else if let inbox = app.forgeCaps.inboxTitle {
            out.append(SidebarItem(section: .notifications, title: inbox, icon: "bell.fill", color: .syAmber, count: app.unreadCount))
        }
        out.append(SidebarItem(section: .claude, title: "Agents", icon: "terminal.fill", color: .syCoral, count: app.claude.attentionCount > 0 ? app.claude.attentionCount : app.claude.tabs.filter(\.running).count))
        return out
    }

    private func prCount(_ f: PRFilter) -> Int {
        f == .reviewRequested ? app.sidebarReviewCount : (f == .mine ? app.sidebarMineCount : 0)
    }

    private var groupKeys: [String] {
        guard app.forge != nil else { return ["prs", "issues", "code", "jira"] }
        var keys = ["prs"]
        if !app.forgeCaps.issueFilters.isEmpty { keys.append("issues") }
        if app.forgeCaps.repositories { keys.append("code") }
        keys.append("jira")
        return keys
    }

    @ViewBuilder
    private func group(_ key: String) -> some View {
        switch key {
        case "prs":
            let title = app.forge != nil ? app.provider.requestsTitle : "Pull requests"
            SidebarGroup(title, key: key) {
                SidebarItemList(group: key, items: prItems(title))
            }
        case "issues":
            SidebarGroup("Issues", key: key, collapsible: true) {
                SidebarItemList(group: key, items: (app.forge != nil ? app.forgeCaps.issueFilters : IssueFilter.allCases).map {
                    SidebarItem(section: .issues($0), title: $0.title, icon: $0.tileIcon, color: $0.tint, group: "Issues")
                })
            }
        case "code":
            SidebarGroup("Code", key: key) {
                SidebarItemList(group: key, items: codeItems)
            }
        case "jira":
            SidebarGroup("Jira", key: key) {
                SidebarItemList(group: key, items: [
                    SidebarItem(section: .jira, title: "Board", icon: "rectangle.split.3x1.fill", color: .sySky, group: "Jira"),
                ])
            }
        default:
            EmptyView()
        }
    }

    private func prItems(_ title: String) -> [SidebarItem] {
        if app.forge != nil {
            let caps = app.forgeCaps
            var out = caps.pullFilters.map {
                SidebarItem(section: .prs($0), title: $0.title, icon: $0.tileIcon, color: $0.tint, count: prCount($0), group: title)
            }
            if caps.pullFilters.contains(.mine) {
                out.append(SidebarItem(section: .myPRsByRepo, title: "My \(app.provider.requestShort)s by project", icon: "folder.fill", color: .syCoral, group: title))
            }
            return out
        }
        return PRFilter.allCases.map {
            SidebarItem(section: .prs($0), title: $0.title, icon: $0.tileIcon, color: $0.tint, count: prCount($0), group: title)
        } + [
            SidebarItem(section: .myPRsByRepo, title: "My PRs by project", icon: "folder.fill", color: .syCoral, group: title),
            SidebarItem(section: .stacks, title: "Stacks", icon: "square.stack.3d.up.fill", color: .syIndigo, group: title),
        ]
    }

    private var codeItems: [SidebarItem] {
        if app.forge != nil {
            return [SidebarItem(section: .repos, title: app.provider.repositoriesTitle, icon: "book.closed.fill", color: .syTeal, group: "Code")]
        }
        return [
            SidebarItem(section: .repos, title: "Repositories", icon: "book.closed.fill", color: .syTeal, group: "Code"),
            SidebarItem(section: .projects, title: "Projects", icon: "rectangle.split.3x1.fill", color: .syIndigo, group: "Code"),
        ]
    }

    @ViewBuilder
    private var userFooter: some View {
        if app.user != nil || app.account != nil {
            AccountSwitcherFooter(compact: compact)
                .padding(compact ? Space.m : 10)
                .background(Theme.isBrand ? AnyShapeStyle(Color.sySidebar) : AnyShapeStyle(.clear))
                .overlay(alignment: .top) { if Theme.isBrand { Rectangle().fill(Color.syLine).frame(height: 1) } }
        }
    }
}

struct UpdateAvailableRow: View {
    let version: String
    var compact = false

    var body: some View {
        Button { Updater.shared.present() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.sySky)
                if !compact {
                    Text("Update to \(version)").foregroundStyle(Color.syText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.syCaption2.weight(.semibold)).foregroundStyle(Color.syDim)
                }
            }
            .font(.syCallout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.sySky.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .help("Update to PullYard \(version)")
        .accessibilityLabel("Update to PullYard \(version)")
    }
}

struct SidebarGroup<Content: View>: View {
    let title: Text
    let rawTitle: String
    let collapsible: Bool
    let key: String?
    @ViewBuilder let content: Content
    @AppStorage private var expanded: Bool
    @Environment(\.sidebarGroupKeys) private var groupKeys

    init(_ title: String, key: String? = nil, collapsible: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.rawTitle = title
        self.key = key
        self.collapsible = collapsible
        self.content = content()
        _expanded = AppStorage(wrappedValue: true, "sidebar.expanded.\(title)")
    }

    @Environment(\.sidebarCompact) private var compact

    private var railLabel: String {
        let raw = rawTitle.lowercased()
        if raw.contains("pull") || raw.contains("merge") { return "PR" }
        if raw.contains("issue") { return "ISS" }
        if raw.contains("inbox") { return "INBOX" }
        if raw.contains("code") { return "CODE" }
        return String(rawTitle.uppercased().prefix(4))
    }

    var body: some View {
        if collapsible, !compact {
            Section(isExpanded: $expanded) {
                content
            } header: {
                header
            }
        } else {
            Section {
                content
            } header: {
                header
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if rawTitle.isEmpty {
            EmptyView()
        } else if compact {
            Text(railLabel)
                .font(.sy(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Color.syMuted)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        } else {
            let label = title.font(.sySubheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            if let key {
                label
                    .draggable(SidebarDrag.section(key).payload) {
                        title.font(.sySubheadline.weight(.semibold)).padding(6)
                    }
                    .sidebarDropTarget(group: key, keys: groupKeys, row: nil)
                    .help("Drag to reorder sections")
            } else {
                label
            }
        }
    }
}

extension View {
    /// Accepts sidebar drags: a row from the same group lands at `row`, a section lands where `group` is.
    func sidebarDropTarget(group: String, keys: [String], row: (id: String, visible: [SidebarItem])?) -> some View {
        modifier(SidebarDropTarget(group: group, keys: keys, row: row))
    }
}

private struct SidebarDropTarget: ViewModifier {
    let group: String
    let keys: [String]
    let row: (id: String, visible: [SidebarItem])?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted {
                    Capsule().fill(Color.syAccent).frame(height: 2).offset(y: -2).allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                guard let drag = payloads.first.flatMap(SidebarDrag.init(payload:)) else { return false }
                let layout = SidebarLayout.shared
                var done = false
                withAnimation(Motion.smooth) {
                    switch drag {
                    case .row(let from, let id):
                        if from == group, let row { done = layout.drop(item: id, onto: row.id, group: group, visible: row.visible) }
                    case .section(let key):
                        done = layout.drop(group: key, onto: group, visible: keys)
                    }
                }
                return done
            } isTargeted: { targeted = $0 }
    }
}

private struct SidebarCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SidebarGroupKeysKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var sidebarCompact: Bool {
        get { self[SidebarCompactKey.self] }
        set { self[SidebarCompactKey.self] = newValue }
    }

    var sidebarGroupKeys: [String] {
        get { self[SidebarGroupKeysKey.self] }
        set { self[SidebarGroupKeysKey.self] = newValue }
    }
}

/// The rows of one sidebar group, in the user's order, with drag-to-reorder and a rename menu.
struct SidebarItemList: View {
    let group: String
    let items: [SidebarItem]
    @State private var layout = SidebarLayout.shared
    @Environment(\.sidebarGroupKeys) private var groupKeys

    var body: some View {
        let visible = layout.arranged(items, group: group)
        ForEach(visible) { item in
            SidebarRow(section: item.section, title: layout.title(for: item.section, default: item.title), icon: item.icon, color: item.color, count: item.count, group: item.group)
                .draggable(SidebarDrag.row(group: group, id: item.id).payload) {
                    Label(layout.title(for: item.section, default: item.title), systemImage: item.icon)
                        .padding(6)
                }
                .sidebarDropTarget(group: group, keys: groupKeys, row: (item.id, visible))
                .contextMenu {
                    Button("Rename\u{2026}") { layout.renaming = item }
                    if layout.hasCustomName(item.section) {
                        Button("Restore \u{201C}\(item.title)\u{201D}") { layout.resetName(item.section) }
                    }
                    if layout.isCustomised {
                        Divider()
                        Button("Reset Sidebar Order and Names") { withAnimation(Motion.fade) { layout.resetAll() } }
                    }
                }
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.sidebarCompact) private var compact
    let section: SidebarSection
    let title: String
    let icon: String
    let color: Color
    var count = 0
    var group: String?
    @State private var hovering = false

    private var spoken: String { group.map { "\($0): \(title)" } ?? title }

    var body: some View {
        let selected = app.section == section
        Group {
                if compact {
                    SidebarIcon(systemImage: icon, color: color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xs)
                        .overlay(alignment: .topTrailing) {
                            if count > 0 {
                                Text(count > 99 ? "99+" : "\(count)")
                                    .font(.syCaption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.syOnAccent)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(Color.syAccentFill))
                                    .offset(x: 2, y: -3)
                            }
                        }
                } else {
                    HStack(spacing: 8) {
                        SidebarIcon(systemImage: icon, color: color)
                        Text(title)
                            .font(.syBody)
                            .foregroundStyle(Color.syText)
                            .fontWeight(selected ? .medium : .regular)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if count > 0 {
                            Text(section == .notifications && count >= GitHubAPI.notificationPageSize ? "\(GitHubAPI.notificationPageSize)+" : "\(count)").font(.syCallout.monospacedDigit()).foregroundStyle(Color.syMuted)
                        }
                    }
                    .padding(.leading, Space.m)
                    .padding(.trailing, Space.m)
                    .padding(.vertical, 5)
                }
            }
            .background {
                ZStack(alignment: .leading) {
                    selected ? Color.sySelected : hovering ? Color.syHover : Color.clear
                    if selected { color.frame(width: 3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.m - 1))
            }
            .contentShape(Rectangle())
        // A tap gesture, not a Button: a Button swallows the mouse-down and the row could not be dragged to reorder.
        .onTapGesture { app.section = section }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.section = section }
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: selected)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .help(count > 0 ? "\(spoken) (\(count))" : spoken)
        .accessibilityLabel(spoken)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SidebarIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        let side = TextZoom.shared.size(21)
        Image(systemName: systemImage.hasSuffix(".fill") ? String(systemImage.dropLast(5)) : systemImage)
            .font(.syIcon(10.5))
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.syText.opacity(0.05)))
            .overlay {
                if !GlassSupport.isAvailable {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)), lineWidth: 1)
                }
            }
    }
}

struct BrandToolbar: ViewModifier {
    static let glassKey = "ui.glassToolbar"
    @AppStorage(BrandToolbar.glassKey) private var glass = false

    func body(content: Content) -> some View {
        if Theme.isBrand, !(glass && GlassSupport.isAvailable) {
            content.toolbarBackground(Color.syBar, for: .windowToolbar)
        } else {
            content
        }
    }
}

extension PRFilter {
    var tint: Color {
        switch self {
        case .reviewRequested: return .sySky
        case .mine: return .syViolet
        case .assigned: return .syTeal
        case .mentioned: return .syIndigo
        case .reviewed: return .syGreen
        }
    }

    var tileIcon: String {
        switch self {
        case .reviewRequested: return "eye.fill"
        case .mine: return "person.fill"
        case .assigned: return "person.badge.clock.fill"
        case .mentioned: return "at"
        case .reviewed: return "checkmark.bubble.fill"
        }
    }
}

extension IssueFilter {
    var tint: Color {
        switch self {
        case .assigned: return .syTeal
        case .mine: return .syGreen
        case .mentioned: return .syIndigo
        }
    }

    var tileIcon: String {
        switch self {
        case .assigned: return "person.badge.clock.fill"
        case .mine: return "smallcircle.filled.circle"
        case .mentioned: return "at"
        }
    }
}

struct ContentColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.forge != nil {
            forgeContent
        } else {
            gitHubContent
        }
    }

    @ViewBuilder
    private var forgeContent: some View {
        let account = app.account?.id ?? ""
        switch app.section {
        case .prs(let f) where app.forgeSupports(app.section):
            ForgeListView(kind: .pulls(f)).id("forge-pr-\(f.rawValue)-\(account)")
        case .myPRsByRepo where app.forgeSupports(app.section):
            ForgeListView(kind: .pullsByProject).id("forge-pr-grouped-\(account)")
        case .issues(let f) where app.forgeSupports(app.section):
            ForgeListView(kind: .issues(f)).id("forge-issue-\(f.rawValue)-\(account)")
        case .notifications where app.forgeSupports(app.section):
            ForgeInboxView().id("forge-inbox-\(account)")
        case .repos where app.forgeSupports(app.section):
            ForgeReposView().id("forge-repos-\(account)")
        case .claude:
            ClaudeProjectsColumn()
        default:
            ForgeUnavailableView()
        }
    }

    @ViewBuilder
    private var gitHubContent: some View {
        switch app.section {
        case .notifications:
            NotificationsView()
        case .prs(let f):
            SearchListView(title: f.title, kind: "pr", baseQuery: f.query).id("pr-\(f.rawValue)")
        case .myPRsByRepo:
            SearchListView(title: "My PRs by project", kind: "pr", baseQuery: PRFilter.mine.query, grouped: true).id("pr-mine-by-repo")
        case .stacks:
            StacksListView()
        case .issues(let f):
            SearchListView(title: "Issues: \(f.title)", kind: "issue", baseQuery: f.query).id("issue-\(f.rawValue)")
        case .repos:
            ReposView()
        case .projects:
            ProjectsListView()
        case .claude:
            ClaudeProjectsColumn()
        case .overview, .jira:
            Color.clear
        case nil:
            Text("Select a section").foregroundStyle(Color.syMuted)
        }
    }
}

struct OpenLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        SheetFrame(title: "Open by link") {
            if app.forge != nil {
                Label("Opening links works with GitHub accounts. \(app.provider.title) \(app.provider.requestTitle)s open from the lists in the sidebar.", systemImage: "info.circle")
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://github.com/org/repo/pull/123 or org/repo#123", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
                .disabled(app.forge != nil)
                .accessibilityLabel("Link")
            if invalid {
                Label("Couldn’t recognize the link. Paste a GitHub pull request, issue, commit or repository URL.", systemImage: "exclamationmark.triangle.fill")
                    .font(.syCaption)
                    .foregroundStyle(Color.syRed)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(app.forge != nil)
            }
        }
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), GitHubURL.parse(s) != nil { text = s }
        }
    }

    private func open() {
        guard app.forge == nil else { return }
        guard let r = GitHubURL.parse(text) else {
            invalid = true
            return
        }
        app.open(r)
        dismiss()
    }
}

struct RateLimitBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let until = app.rateLimitedUntil {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(Color.syAmber)
                Text("\(app.provider.title) rate limit — live updates paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
            }
            .font(.syCaption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .pyGlassCapsule(outline: false)
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
            .padding(.bottom, app.clipboardRoute == nil ? 16 : 0)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

struct SyncErrorBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.syncError, app.rateLimitedUntil == nil {
            HStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.syAmber)
                Text("Can't refresh — showing the last known data").foregroundStyle(Color.syMuted).lineLimit(1)
                Button("Retry") { Task { await app.refreshBadges() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.sySky)
            }
            .font(.syCaption)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .pyGlassCapsule(outline: false)
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
            .padding(.bottom, app.clipboardRoute == nil ? 16 : 0)
            .help(error)
            .transition(.opacity)
        }
    }
}

struct ClipboardBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let route = app.clipboardRoute {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                Text("In clipboard: \(title(route))").lineLimit(1)
                Button("Open") {
                    app.open(route)
                    app.clipboardRoute = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    app.clipboardRoute = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .pyGlassCapsule(outline: false)
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func title(_ r: Route) -> String {
        switch r {
        case .pr(let ref): return "PR \(ref.title)"
        case .issue(let ref): return "Issue \(ref.title)"
        default: return ""
        }
    }
}

struct SidebarPulseCard: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let waiting = app.reviewRequestCount
        let running = app.claude.tabs.filter(\.running).count
        let attention = app.claude.attentionCount
        Button { app.section = .overview } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PullYardLogoMark(progress: 1, size: 26)
                    Text("Today")
                        .font(.system(size: TextZoom.shared.size(14), weight: .semibold, design: .serif))
                        .foregroundStyle(Color.syText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.syIcon(9))
                        .foregroundStyle(Color.syDim)
                        .opacity(hovering ? 1 : 0)
                }
                pulseLine(icon: "eye.fill", tint: waiting > 0 ? .syCoral : .syGreen, text: waiting == 0 ? "No reviews waiting" : plural(waiting, "review waiting", "reviews waiting"))
                if attention > 0 {
                    pulseLine(icon: "hand.raised.fill", tint: .syCoralInk, text: plural(attention, "agent needs you", "agents need you"))
                } else if running > 0 {
                    HStack(spacing: 6) {
                        PYLoader(size: 11, label: "Agents working")
                            .frame(width: 14)
                        Text(plural(running, "agent working", "agents working"))
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                    }
                }
                if app.unreadCount > 0 {
                    pulseLine(icon: "bell.fill", tint: .syAmber, text: plural(app.unreadCount, "unread notification", "unread notifications"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.syRaised.opacity(hovering ? 1 : 0.75))
                    .overlay(alignment: .bottom) {
                        HarborWaves()
                            .frame(height: 12)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                            .opacity(0.6)
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.syLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.fast)) { hovering = h } }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .help("Open Overview (⌥⌘0)")
        .accessibilityLabel("Today: open Overview")
    }

    private func pulseLine(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.syIcon(10))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .lineLimit(1)
        }
    }
}

private struct EdgePanelContent: View {
    let sidebarWidth: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarWidth)
                .surface(.sidebar)
            if !(app.section == .overview && app.forge == nil) {
                Rectangle().fill(Color.syLine).frame(width: 1)
                ContentColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .surface(.list)
            }
        }
    }
}
