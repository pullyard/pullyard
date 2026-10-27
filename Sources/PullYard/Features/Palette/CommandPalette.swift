import SwiftUI

enum PaletteSection: Int, CaseIterable {
    case link, goTo, items, repos, actions

    var title: String {
        switch self {
        case .link: return "Open link"
        case .goTo: return "Go to"
        case .items: return "Pull requests & issues"
        case .repos: return "Repositories"
        case .actions: return "Actions"
        }
    }
}

struct PaletteCommand: Identifiable {
    let id: String
    let section: PaletteSection
    let icon: String
    let tint: Color
    let title: String
    var detail = ""
    var shortcut: String?
    var keywords = ""
    let run: () -> Void
}

enum PaletteMatch {
    static func score(_ command: PaletteCommand, tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return 0 }
        let title = command.title.lowercased()
        let extra = (command.detail + " " + command.keywords).lowercased()
        var total = 0
        for token in tokens {
            if let s = score(title, token) {
                total += s
            } else if let s = score(extra, token) {
                total += s / 2
            } else {
                return nil
            }
        }
        return total
    }

    static func score(_ text: String, _ token: String) -> Int? {
        if text.hasPrefix(token) { return 1000 }
        if let r = text.range(of: token) {
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let boundary = text[text.index(before: r.lowerBound)].isLetter == false
            return (boundary ? 800 : 600) - min(start, 100)
        }
        var gaps = 0
        var index = text.startIndex
        for ch in token {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            gaps += text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return max(1, 300 - gaps * 4)
    }
}

struct CommandPaletteOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack(alignment: .top) {
            if app.showCommandPalette {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.showCommandPalette = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                CommandPalette()
                    .padding(.top, 72)
                    .transition(.pop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.quick, value: app.showCommandPalette)
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("agents.sidebarHidden") private var sidebarHidden = false
    @AppStorage(Theme.appearanceKey) private var appearance = AppearanceMode.auto.rawValue
    @State private var query = ""
    @State private var selection = 0
    @State private var repos: [RepoSummary] = []
    @State private var found: [SearchItem] = []
    @State private var searching = false
    @State private var hoverPoint: CGPoint?
    @FocusState private var focused: Bool

    private var rowHeight: CGFloat { TextZoom.shared.size(34) }
    private var headerHeight: CGFloat { TextZoom.shared.size(26) }

    private var tokens: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var results: [PaletteCommand] {
        let tokens = tokens
        let searching = !tokens.isEmpty
        var out: [PaletteCommand] = []
        for section in PaletteSection.allCases {
            let all = commands(section)
            let ranked: [PaletteCommand]
            if searching {
                ranked = all.enumerated()
                    .compactMap { i, c in PaletteMatch.score(c, tokens: tokens).map { (c, $0, i) } }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                    .map(\.0)
            } else {
                ranked = all
            }
            out += ranked.prefix(limit(section, searching: searching))
        }
        return out
    }

    private func limit(_ section: PaletteSection, searching: Bool) -> Int {
        switch section {
        case .link: return 1
        case .goTo: return searching ? 6 : 20
        case .items: return searching ? 20 : 6
        case .repos: return searching ? 12 : 3
        case .actions: return searching ? 10 : 40
        }
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if searching {
                    WakeLoader()
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.syMuted).accessibilityHidden(true)
                }
                TextField("Search commands, pull requests, repositories, or paste a link…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.sy(size: 16))
                    .focused($focused)
                    .accessibilityLabel("Command palette")
                    .accessibilityHint("Type to filter. Use the up and down arrow keys to choose, Return to run, Escape to close.")
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { move(1, list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, list); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Rectangle().fill(Color.syLine).frame(height: 1)
            resultsList(list)
            Rectangle().fill(Color.syLine).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", "select")
                hint("↩", "run")
                hint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
        }
        .frame(width: 560)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                if Theme.isBrand { RoundedRectangle(cornerRadius: 14).fill(Color.syPanel.opacity(0.72)) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.syLineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = true }
        .onExitCommand { close() }
        .onChange(of: query) { selection = 0 }
        .onChange(of: selection) { _, i in announce(i, list) }
        .task { await loadRepos() }
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private func resultsList(_ list: [PaletteCommand]) -> some View {
        let sections = Set(list.map(\.section)).count
        let content = CGFloat(list.count) * rowHeight + CGFloat(sections) * headerHeight + 12
        let cap = 8 * rowHeight + 2 * headerHeight + 12
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, command in
                        if index == 0 || list[index - 1].section != command.section {
                            Text(command.section.title)
                                .font(.syCaption.weight(.semibold))
                                .foregroundStyle(Color.syDim)
                                .padding(.horizontal, 10)
                                .frame(height: headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(command, selected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                run(list)
                            }
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                guard case .active(let point) = phase, point != hoverPoint else { return }
                                hoverPoint = point
                                if selection != index { selection = index }
                            }
                            .accessibilityAction { selection = index; run(list) }
                    }
                    if list.isEmpty {
                        Text("No results")
                            .foregroundStyle(Color.syMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: list.isEmpty ? 64 : min(content, cap))
            .onChange(of: selection) { _, i in
                withAnimation(Motion.quick) { proxy.scrollTo(i) }
            }
        }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.syCallout.weight(.semibold))
                .foregroundStyle(command.tint)
                .frame(width: 18)
            Text(command.title).foregroundStyle(Color.syText).lineLimit(1)
            if !command.detail.isEmpty {
                Text(command.detail).font(.syCaption).foregroundStyle(Color.syDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.syCaption.monospaced())
                    .foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.syText.opacity(0.08)))
            }
        }
        .font(.syBody)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.syAccent.opacity(0.16) : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(command))
        .accessibilityHint(command.shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.syCaption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.syText.opacity(0.08)))
            Text(text).font(.syCaption)
        }
        .foregroundStyle(Color.syMuted)
    }

    private func label(_ command: PaletteCommand) -> String {
        [command.title, command.detail, command.section.title].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func announce(_ index: Int, _ list: [PaletteCommand]) {
        guard list.indices.contains(index) else { return }
        AccessibilityNotification.Announcement(label(list[index])).post()
    }

    private func move(_ delta: Int, _ list: [PaletteCommand]) {
        guard !list.isEmpty else { return }
        selection = (selection + delta + list.count) % list.count
    }

    private func run(_ list: [PaletteCommand]) {
        guard list.indices.contains(selection) else { return }
        let command = list[selection]
        close()
        command.run()
    }

    private func close() {
        app.showCommandPalette = false
    }

    private func commands(_ section: PaletteSection) -> [PaletteCommand] {
        switch section {
        case .link: return linkCommands
        case .goTo: return goToCommands
        case .items: return itemCommands
        case .repos: return repoCommands
        case .actions: return actionCommands
        }
    }

    private var linkCommands: [PaletteCommand] {
        guard let route = GitHubURL.parse(query) else { return [] }
        let open = { app.open(route) }
        switch route {
        case .pr(let ref):
            return [PaletteCommand(id: "link", section: .link, icon: "arrow.triangle.pull", tint: .syGreen, title: "Open \(ref.title)", detail: "Pull request", keywords: query, run: open)]
        case .issue(let ref):
            return [PaletteCommand(id: "link", section: .link, icon: "smallcircle.filled.circle", tint: .syGreen, title: "Open \(ref.title)", detail: "Issue", keywords: query, run: open)]
        case .repo(let repo):
            return [PaletteCommand(id: "link", section: .link, icon: "book.closed", tint: .syTeal, title: "Open \(repo.full)", detail: "Repository", keywords: query, run: open)]
        case .commit(let repo, let sha):
            return [PaletteCommand(id: "link", section: .link, icon: "smallcircle.filled.circle", tint: .syMuted, title: "Open \(repo.full)@\(sha.prefix(7))", detail: "Commit", keywords: query, run: open)]
        case .project(let p):
            return [PaletteCommand(id: "link", section: .link, icon: "rectangle.split.3x1", tint: .syIndigo, title: "Open \(p.title)", detail: "Project", keywords: query, run: open)]
        }
    }

    private func destination(_ section: SidebarSection, _ title: String, _ icon: String, _ color: Color, group: String, shortcut: String? = nil) -> PaletteCommand {
        PaletteCommand(id: "go-\(title)-\(group)", section: .goTo, icon: icon, tint: color, title: title, detail: group, shortcut: shortcut, keywords: "go open show") {
            app.section = section
        }
    }

    private func shortcut(_ section: SidebarSection) -> String? {
        switch section {
        case .prs(.reviewRequested): return "⌘1"
        case .prs(.mine): return "⌘2"
        case .notifications: return "⌘3"
        case .repos: return "⌘4"
        case .projects: return "⌘5"
        case .claude: return "⌘6"
        default: return nil
        }
    }

    private var goToCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        if app.forge != nil {
            let caps = app.forgeCaps
            if let inbox = caps.inboxTitle {
                out.append(destination(.notifications, inbox, "bell.fill", .syAmber, group: "Inbox", shortcut: shortcut(.notifications)))
            }
            for f in caps.pullFilters {
                out.append(destination(.prs(f), f.title, f.tileIcon, f.tint, group: app.provider.requestsTitle, shortcut: shortcut(.prs(f))))
            }
            if caps.pullFilters.contains(.mine) {
                out.append(destination(.myPRsByRepo, "My \(app.provider.requestShort)s by project", "folder.fill", .syCoral, group: app.provider.requestsTitle))
            }
            for f in caps.issueFilters {
                out.append(destination(.issues(f), f.title, f.tileIcon, f.tint, group: "Issues"))
            }
            if caps.repositories {
                out.append(destination(.repos, app.provider.repositoriesTitle, "book.closed.fill", .syTeal, group: "Code", shortcut: shortcut(.repos)))
            }
        } else {
            out.append(destination(.notifications, "Notifications", "bell.fill", .syAmber, group: "Inbox", shortcut: shortcut(.notifications)))
            for f in PRFilter.allCases {
                out.append(destination(.prs(f), f.title, f.tileIcon, f.tint, group: "Pull requests", shortcut: shortcut(.prs(f))))
            }
            out.append(destination(.myPRsByRepo, "My PRs by project", "folder.fill", .syCoral, group: "Pull requests"))
            out.append(destination(.stacks, "Stacks", "square.stack.3d.up.fill", .syIndigo, group: "Pull requests"))
            for f in IssueFilter.allCases {
                out.append(destination(.issues(f), f.title, f.tileIcon, f.tint, group: "Issues"))
            }
            out.append(destination(.repos, "Repositories", "book.closed.fill", .syTeal, group: "Code", shortcut: shortcut(.repos)))
            out.append(destination(.projects, "Projects", "rectangle.split.3x1.fill", .syIndigo, group: "Code", shortcut: shortcut(.projects)))
        }
        out.append(destination(.claude, "Agents", "terminal.fill", .syCoral, group: "AI", shortcut: shortcut(.claude)))
        out.append(PaletteCommand(id: "go-settings", section: .goTo, icon: "gearshape.fill", tint: .sySlate, title: "Settings", detail: "PullYard", shortcut: "⌘,", keywords: "preferences") {
            openSettings()
        })
        return out
    }

    private var knownItems: [SearchItem] {
        let pinned = found + app.reviewRequests + app.myPRs
        let cached = (SearchListModel.cachedItems + ForgeListModel.cachedItems).sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        return (pinned + cached).filter { seen.insert($0.id).inserted }
    }

    private var itemCommands: [PaletteCommand] {
        let items = knownItems
        let byRoute = Dictionary(items.map { ($0.route, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [PaletteCommand] = []
        for route in app.recentRoutes {
            switch route {
            case .pr(let ref), .issue(let ref):
                if let item = byRoute[route] {
                    seen.insert(item.id)
                    out.append(itemCommand(item, recent: true))
                } else {
                    let isPR: Bool
                    if case .pr = route { isPR = true } else { isPR = false }
                    out.append(PaletteCommand(id: "recent-\(ref.title)", section: .items, icon: isPR ? "arrow.triangle.pull" : "smallcircle.filled.circle", tint: .syMuted, title: ref.title, detail: "Recently viewed", keywords: "\(ref.number) \(isPR ? "pr pull request" : "issue")") {
                        app.open(route)
                    })
                }
            default:
                break
            }
        }
        for item in items where !seen.contains(item.id) {
            out.append(itemCommand(item, recent: false))
        }
        return out
    }

    private func itemCommand(_ item: SearchItem, recent: Bool) -> PaletteCommand {
        let state = item.visualState
        let detail = "\(item.repo.full)#\(item.number)" + (recent ? " · Recently viewed" : "")
        let keywords = "\(item.number) \(item.author?.login ?? "") \(item.isPR ? "pr pull request" : "issue") \(state.title)"
        return PaletteCommand(id: "item-" + item.id, section: .items, icon: state.icon, tint: state.color, title: item.title, detail: detail, keywords: keywords) {
            open(item)
        }
    }

    private func open(_ item: SearchItem) {
        if app.forge != nil {
            if app.section == .claude || !app.forgeSupports(app.section) {
                app.section = .prs(app.forgeCaps.pullFilters.first ?? .mine)
            }
            app.forgeSelection = item
        } else {
            app.open(item.route)
        }
    }

    private var repoCommands: [PaletteCommand] {
        guard app.api != nil else { return [] }
        var seen = Set<String>()
        var out: [PaletteCommand] = []
        for route in app.recentRoutes {
            guard case .repo(let repo) = route, seen.insert(repo.full.lowercased()).inserted else { continue }
            let summary = repos.first { $0.nameWithOwner.caseInsensitiveCompare(repo.full) == .orderedSame }
            out.append(repoCommand(repo, locked: summary?.isPrivate ?? false, detail: "Recently viewed"))
        }
        let sorted = repos.filter { !$0.isArchived }.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        for r in sorted {
            guard let ref = r.ref, seen.insert(ref.full.lowercased()).inserted else { continue }
            out.append(repoCommand(ref, locked: r.isPrivate, detail: r.description ?? ""))
        }
        return out
    }

    private func repoCommand(_ repo: RepoRef, locked: Bool, detail: String) -> PaletteCommand {
        PaletteCommand(id: "repo-" + repo.full, section: .repos, icon: locked ? "lock" : "book.closed", tint: .syTeal, title: repo.full, detail: detail, keywords: repo.name) {
            app.open(.repo(repo))
        }
    }

    private var currentURL: String? {
        if app.forge != nil, app.section != .claude { return app.forgeSelection?.url }
        let host = app.api?.host ?? "github.com"
        switch app.frontRoute {
        case .pr(let ref)?:
            if let item = knownItems.first(where: { $0.route == .pr(ref) }) { return item.url }
            return "https://\(host)/\(ref.repo.full)/pull/\(ref.number)"
        case .issue(let ref)?:
            if let item = knownItems.first(where: { $0.route == .issue(ref) }) { return item.url }
            return "https://\(host)/\(ref.repo.full)/issues/\(ref.number)"
        case .repo(let repo)?: return "https://\(host)/\(repo.full)"
        case .commit(let repo, let sha)?: return "https://\(host)/\(repo.full)/commit/\(sha)"
        case .project(let p)?: return p.url
        case nil: return nil
        }
    }

    private var actionCommands: [PaletteCommand] {
        var out: [PaletteCommand] = [
            PaletteCommand(id: "refresh", section: .actions, icon: "arrow.clockwise", tint: .sySky, title: "Refresh", shortcut: "⌘R", keywords: "reload sync") { app.refresh() },
            PaletteCommand(id: "open-link", section: .actions, icon: "link", tint: .sySky, title: "Open by Link…", shortcut: "⌘L", keywords: "url paste") { app.showOpenLink = true },
            PaletteCommand(id: "quick-open", section: .actions, icon: "terminal", tint: .syCoral, title: "Go to Session…", detail: "Agents", shortcut: "⇧⌘K", keywords: "agent session") { app.showQuickOpen = true },
            PaletteCommand(id: "new-agent", section: .actions, icon: "plus.bubble", tint: .syCoral, title: "New Agent Session", detail: "Agents", shortcut: "⌘N", keywords: "agent session new") { app.newAgentSession() },
            PaletteCommand(id: "sidebar", section: .actions, icon: "sidebar.left", tint: .syMuted, title: sidebarHidden ? "Show Sidebar" : "Hide Sidebar", keywords: "toggle sidebar") {
                withAnimation(Motion.smooth) { sidebarHidden.toggle() }
            },
        ]
        if !app.detailPath.isEmpty {
            out.append(PaletteCommand(id: "back", section: .actions, icon: "chevron.left", tint: .syMuted, title: "Back", shortcut: "⌘[") {
                if !app.detailPath.isEmpty { app.detailPath.removeLast() }
            })
        }
        if let url = currentURL {
            out.append(PaletteCommand(id: "browser", section: .actions, icon: "safari", tint: .sySky, title: "Open in Browser", detail: "Current item", keywords: "web github") {
                openInBrowser(url)
            })
            out.append(PaletteCommand(id: "copy-link", section: .actions, icon: "doc.on.doc", tint: .syMuted, title: "Copy Link", detail: "Current item", keywords: "url clipboard") {
                copyToPasteboard(url)
                app.showToast("Copied link")
            })
        }
        if let ref = app.frontItem {
            out.append(PaletteCommand(id: "short-link", section: .actions, icon: "link", tint: .syMuted, title: "Copy Short Link", detail: ShortLink.make(ref), shortcut: "⇧⌘C", keywords: "clipboard") {
                app.copyShortLink(ref)
            })
        }
        let current = AppearanceMode(rawValue: appearance) ?? .auto
        for mode in AppearanceMode.allCases {
            let icon: String
            switch mode {
            case .auto: icon = "circle.lefthalf.filled"
            case .light: icon = "sun.max"
            case .dark: icon = "moon"
            }
            out.append(PaletteCommand(id: "appearance-\(mode.rawValue)", section: .actions, icon: icon, tint: .syAmber, title: "Appearance: \(mode.title)", detail: mode == current ? "Current" : "", keywords: "theme mode light dark auto") {
                appearance = mode.rawValue
            })
        }
        if !app.claude.tabs.contains(where: \.running) {
            for account in GitAccounts.shared.accounts where account.id != app.account?.id {
                out.append(PaletteCommand(id: "account-\(account.id)", section: .actions, icon: "person.crop.circle", tint: .syViolet, title: "Switch to \(account.subtitle)", detail: account.provider.title, keywords: "account switch") {
                    app.requestSwitch(to: account.id)
                })
            }
        }
        let zoom = TextZoom.shared
        if zoom.canZoomIn {
            out.append(PaletteCommand(id: "zoom-in", section: .actions, icon: "plus.magnifyingglass", tint: .syMuted, title: "Zoom In", shortcut: "⌘+", keywords: "text size bigger") { zoom.zoomIn() })
        }
        if zoom.canZoomOut {
            out.append(PaletteCommand(id: "zoom-out", section: .actions, icon: "minus.magnifyingglass", tint: .syMuted, title: "Zoom Out", shortcut: "⌘-", keywords: "text size smaller") { zoom.zoomOut() })
        }
        if !zoom.isDefault {
            out.append(PaletteCommand(id: "zoom-reset", section: .actions, icon: "1.magnifyingglass", tint: .syMuted, title: "Actual Size", shortcut: "⌘0", keywords: "text size zoom reset") { zoom.reset() })
        }
        out.append(PaletteCommand(id: "updates", section: .actions, icon: "arrow.down.circle", tint: .sySky, title: "Check for Updates…", keywords: "version upgrade") {
            openWindow(id: "update")
            Task { await Updater.shared.check(userInitiated: true) }
        })
        return out
    }

    private func loadRepos() async {
        guard app.api != nil, let snap = await ListCache.load([RepoSummary].self, account: app.cacheAccount, key: "repos") else { return }
        repos = snap.value
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let api = app.api, q.count >= 3, GitHubURL.parse(q) == nil else {
            found = []
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        let result = try? await api.search(Demo.query("\(q) involves:@me sort:updated-desc"))
        guard !Task.isCancelled else { return }
        found = result?.nodes ?? []
        searching = false
    }
}
