import AppKit
import SwiftUI

struct ClaudeTerminalHost: NSViewRepresentable {
    let tab: ClaudeTab
    var zoom = TextZoom.shared.scale

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
        let size = TextZoom.shared.size(12.5)
        if tab.terminal.font.pointSize != size {
            tab.terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private func attach(to container: NSView) {
        let term = tab.terminal
        term.removeFromSuperview()
        term.applyAppearance()
        term.frame = container.bounds
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
    }
}

struct ClaudeProjectsColumn: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var collapsedParents: Set<String> = []
    @State private var showArchived = false
    @State private var pickerFor: ClaudeProfile?
    @State private var envDraft: AgentEnvironmentDraft?
    @State private var dropTarget: String?
    @AppStorage("agents.openCollapsed") private var openCollapsed = false
    private var prefs: AgentSessionPrefs { AgentSessionPrefs.shared }
    @State private var ready = false
    @State private var cursor: String?
    @FocusState private var listFocused: Bool

    private var ws: ClaudeWorkspace { app.claude }

    private struct NavTarget {
        let key: String
        let open: () -> Void
    }

    private struct SidebarGroup: Identifiable {
        let id: String
        let title: String
        var project: ClaudeProject?
        var profile: ClaudeProfile?
        let sessions: [ClaudeSessionInfo]
        var count: Int
        var headerless = false
    }

    private func listed(_ sessions: [ClaudeSessionInfo], limit: Int = 40) -> [ClaudeSessionInfo] {
        Array(sessions.filter { (showArchived || !prefs.isArchived($0)) && !prefs.isPinned($0.id) }.prefix(query.isEmpty ? limit : 200))
    }

    private func nodes(_ group: SidebarGroup) -> [SessionTree.Node] {
        SessionTree.build(group.sessions, detached: prefs.detached)
    }

    private var groups: [SidebarGroup] {
        let projects = filtered
        switch prefs.grouping {
        case .folder:
            return prefs.ordered(projects).map { p in
                SidebarGroup(id: p.id, title: p.name, project: p, sessions: listed(p.sessions), count: p.sessions.count)
            }
        case .account:
            let all = projects.flatMap(\.sessions).sorted { $0.modified > $1.modified }
            return ClaudeProfiles.shared.visible.compactMap { profile in
                let mine = all.filter { ($0.profileID ?? ClaudeProfiles.defaultID) == profile.id }
                guard !mine.isEmpty else { return nil }
                return SidebarGroup(id: "account:" + profile.id, title: profile.label, profile: profile, sessions: listed(mine, limit: 60), count: mine.count)
            }
        case .none:
            let all = projects.flatMap(\.sessions).sorted { $0.modified > $1.modified }
            return [SidebarGroup(id: "all", title: "", sessions: listed(all, limit: 80), count: all.count, headerless: true)]
        }
    }

    private func isOpen(_ g: SidebarGroup) -> Bool {
        g.headerless || expanded.contains(g.id) || !query.isEmpty
    }

    private var pinnedSessions: [ClaudeSessionInfo] {
        query.isEmpty
            ? prefs.pinned.compactMap { ws.sessionsByID[$0] }
            : prefs.pinned.compactMap { id in filtered.lazy.flatMap(\.sessions).first { $0.id == id } }
    }

    private var navTargets: [NavTarget] {
        var out = (openCollapsed ? [] : ws.listedTabs).map { tab in NavTarget(key: "tab:\(tab.id.uuidString)") { ws.selectedTabID = tab.id } }
        out += pinnedSessions.map { s in NavTarget(key: s.id) { ws.resume(s) } }
        for group in groups where isOpen(group) {
            for node in nodes(group) {
                let s = node.session
                out.append(NavTarget(key: s.id) { ws.resume(s) })
                guard !collapsedParents.contains(node.id) else { continue }
                out += node.children.map { child in NavTarget(key: child.id) { ws.resume(child) } }
            }
        }
        return out
    }

    private func moveCursor(_ delta: Int) {
        let keys = navTargets.map(\.key)
        guard !keys.isEmpty else { return }
        let start = cursor.flatMap { keys.firstIndex(of: $0) } ?? ws.selectedTabID.flatMap { keys.firstIndex(of: "tab:\($0.uuidString)") }
        let next = start.map { min(max($0 + delta, 0), keys.count - 1) } ?? (delta > 0 ? 0 : keys.count - 1)
        cursor = keys[next]
    }

    private func openCursor() -> Bool {
        guard let target = navTargets.first(where: { $0.key == cursor }) else { return false }
        target.open()
        return true
    }

    private func shortcut(_ key: Character) -> Bool {
        guard let cursor, let s = ws.sessionsByID[cursor] else { return false }
        switch key {
        case "p": withAnimation(Motion.smooth) { prefs.togglePin(s.id) }
        case "u": toggleUnread(s)
        case "r": rename(s)
        case "f": ws.resume(s, fork: true)
        case "a": withAnimation(Motion.smooth) { prefs.setArchived(s.id, !prefs.isArchived(s)) }
        case "d": ws.trash(s)
        default: return false
        }
        return true
    }

    private var accountScoped: [ClaudeProject] {
        guard ws.accountFilter != nil, ClaudeProfiles.shared.hasSeveral else { return ws.projects }
        return ws.projects.compactMap { p in
            let s = ws.visibleSessions(p.sessions)
            return s.isEmpty ? nil : ClaudeProject(id: p.id, path: p.path, sessions: s)
        }
    }

    private var filtered: [ClaudeProject] {
        guard !query.isEmpty else { return accountScoped }
        return accountScoped.compactMap { p in
            if p.name.localizedCaseInsensitiveContains(query) { return p }
            let s = p.sessions.filter { prefs.title($0).localizedCaseInsensitiveContains(query) || ($0.branch ?? "").localizedCaseInsensitiveContains(query) }
            return s.isEmpty ? nil : ClaudeProject(id: p.id, path: p.path, sessions: s)
        }
    }

    private var pickerProfile: ClaudeProfile {
        ClaudeProfiles.shared.profile(id: ws.accountFilter) ?? ClaudeProfiles.shared.active
    }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHeader
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    listContent
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .onChange(of: cursor) { _, key in
                if let key { withAnimation(Motion.fade) { proxy.scrollTo(key) } }
            }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveCursor(1); return .handled }
        .onKeyPress(.upArrow) { moveCursor(-1); return .handled }
        .onKeyPress(.return) { openCursor() ? .handled : .ignored }
        .onKeyPress(characters: CharacterSet(charactersIn: "purfad")) { press in
            guard press.modifiers.subtracting(.capsLock).isEmpty, let key = press.characters.first else { return .ignored }
            return shortcut(key) ? .handled : .ignored
        }
        .surface(.list)
        .overlay { if ws.loadingProjects && ws.projects.isEmpty { PullYardLoader(size: 44) } }
        .liveRefresh(updated: ws.projectsUpdated, refreshing: ws.loadingProjects) { await ws.reloadProjects() }
        .toolbarSearch(text: $query, prompt: "Search sessions")
        .navigationTitle("Agents")
        .panelToolbar {
            ToolbarItemGroup {
                if FixTour.isAvailable {
                    Button { FixTour.shared.start(app: app) } label: { Label("Fixes demo", systemImage: "checkmark.seal") }
                        .help("Walk through the recent chat fixes with mock data")
                }
                Button { pickerFor = pickerProfile } label: { Label("Open project", systemImage: "folder.badge.plus") }
                    .disabled(!ClaudeAccountStore.shared.isLoggedIn && !ClaudeProfiles.shared.hasSeveral)
                    .help("New session in a project…")
            }
        }
        .sheet(item: $pickerFor) { AgentProjectPicker(profile: $0).environment(app) }
        .sheet(item: $envDraft) { d in AgentEnvironmentSheet(editing: d.editing, draftName: d.name, draftFolders: d.folders) }
        .onAppear {
            ws.sessionRows.ingest(cascadeIDs, mode: .cascade)
            ready = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ClaudeAccountStore.shared.refresh() }
        }
        .task {
            ws.restoreOpenTabs()
            await ClaudeAccountStore.shared.refresh()
            await ws.reloadProjects(force: false)
            if expanded.isEmpty, let first = groups.first { expanded.insert(first.id) }
        }
        .onChange(of: app.refreshTick) { Task { await ws.reloadProjects(force: false) } }
        .onChange(of: prefs.grouping) { _, _ in
            if let first = groups.first { expanded.insert(first.id) }
        }
    }

    /// Account switcher and New session stay put while the history scrolls.
    @ViewBuilder
    private var pinnedHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch ClaudeAccountStore.shared.status {
            case .loggedIn(let info):
                AgentAccountSwitcher(info: info) { pickerFor = $0 }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            case .loggedOut:
                Label("Not signed in to Claude — sign in on the right", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.syCallout)
                    .foregroundStyle(Color.syAmber)
                    .padding(8)
                if ClaudeProfiles.shared.visible.count > 1 {
                    AgentAccountSwitcher(info: nil) { pickerFor = $0 }.padding(.horizontal, 4)
                }
            case .notInstalled:
                Label("claude CLI not found — see the right side", systemImage: "exclamationmark.triangle")
                    .font(.syCallout)
                    .foregroundStyle(Color.syAmber)
                    .padding(8)
            default:
                if ClaudeProfiles.shared.hasSeveral {
                    AgentAccountSwitcher(info: nil) { pickerFor = $0 }.padding(.horizontal, 4)
                }
            }
            if ClaudeAccountStore.shared.isLoggedIn || ClaudeProfiles.shared.hasSeveral {
                AgentNewSessionRow { pickerFor = pickerProfile }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if ClaudeAccountStore.shared.isLoggedIn || ClaudeProfiles.shared.hasSeveral {
            if ready { historyContent }
        } else if case .checking = ClaudeAccountStore.shared.status {
            HStack { Spacer(); PullYardLoader(size: 32); Spacer() }.padding(.top, 20)
        } else if case .unknown = ClaudeAccountStore.shared.status {
            HStack { Spacer(); PullYardLoader(size: 32); Spacer() }.padding(.top, 20)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.fill").font(.syTitle3).foregroundStyle(Color.syDim)
                Text("Session history and projects appear after you sign in to Claude.")
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
            }
            .padding(12)
        }
    }

    private var cascadeIDs: [String] {
        let all = groups
        let open = expanded.isEmpty ? Set(all.prefix(1).map(\.id)) : expanded
        return all.filter { $0.headerless || open.contains($0.id) }.flatMap { $0.sessions.prefix(30).map(\.id) }
    }

    @ViewBuilder
    private var historyContent: some View {
        let listedTabs = ws.listedTabs
        if !listedTabs.isEmpty {
            AgentSectionHeader(title: "Open", collapsed: $openCollapsed, count: listedTabs.count) {
                Text(ws.totalMemory > 0 ? ProcessMemory.format(ws.totalMemory) : "0 MB")
                    .font(.syCaption2.monospacedDigit())
                    .foregroundStyle(Color.syDim)
                    .help("Memory used by running Claude processes")
                if ws.awakeCount > 0 {
                    Button { ws.sleepAll() } label: { Image(systemName: "moon.zzz") }
                        .buttonStyle(.borderless)
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .help("Sleep all idle sessions and free memory")
                        .accessibilityLabel("Sleep all idle sessions")
                }
            }
            ForEach(openCollapsed ? [] : listedTabs) { tab in
                OpenTabRow(tab: tab, selected: ws.selectedTabID == tab.id, pinned: prefs.isPinned(tab.sessionId))
                    .padding(.horizontal, 8)
                    .background(AgentRowBackground(selected: ws.selectedTabID == tab.id, focused: listFocused && cursor == "tab:\(tab.id.uuidString)"))
                    .modifier(HoverHighlight(radius: 7))
                    .contentShape(Rectangle())
                    .id("tab:\(tab.id.uuidString)")
                    .onTapGesture {
                        ws.selectedTabID = tab.id
                        cursor = "tab:\(tab.id.uuidString)"
                        listFocused = true
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(ws.selectedTabID == tab.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { ws.selectedTabID = tab.id }
                    .contextMenu { AgentTabMenu(tab: tab, ws: ws) }
                    .transition(.opacity)
            }
        }
        let pinnedSessions = pinnedSessions
        if !pinnedSessions.isEmpty {
            AgentSectionHeader(title: "Pinned")
            ForEach(pinnedSessions) { s in
                sessionRow(s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        if ws.accountFilter != nil, ClaudeProfiles.shared.hasSeveral, query.isEmpty, accountScoped.isEmpty, !ws.loadingProjects {
            AgentAccountEmpty(profile: pickerProfile) { pickerFor = pickerProfile }
                .padding(.horizontal, 8)
                .padding(.top, 6)
        }
        if !groups.isEmpty, !(groups.count == 1 && groups[0].headerless && groups[0].sessions.isEmpty) {
            AgentSectionHeader(title: prefs.grouping == .none ? "Recent" : prefs.grouping == .account ? "Accounts" : "Projects") {
                Menu {
                    groupMenu
                    if prefs.grouping == .folder {
                        Button("Sort A to Z") { withAnimation(Motion.smooth) { prefs.sortAlphabetically(accountScoped) } }
                    }
                    Divider()
                    Button(showArchived ? "Hide archived sessions" : "Show archived sessions") { withAnimation(Motion.smooth) { showArchived.toggle() } }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Color.syMuted)
                .help("Group, sort and filter")
                .accessibilityLabel("Group, sort and filter")
            }
        }
        ForEach(groups) { group in
            let open = isOpen(group)
            VStack(alignment: .leading, spacing: 0) {
                if let project = group.project {
                    ProjectHeader(project: project, expanded: open) {
                        toggle(group)
                    } onNew: {
                        ws.newSession(folder: project.path, profileID: ws.accountFilter)
                    }
                    .padding(.horizontal, 4)
                    .contextMenu { projectMenu(project) }
                    .draggable(project.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first, id != project.id else { return false }
                        withAnimation(Motion.smooth) { prefs.place(id, before: project.id, in: accountScoped) }
                        return true
                    } isTargeted: { on in
                        if on { dropTarget = project.id } else if dropTarget == project.id { dropTarget = nil }
                    }
                    .overlay(alignment: .top) {
                        if dropTarget == project.id {
                            Capsule().fill(Color.syAgentAccent).frame(height: 2).padding(.horizontal, 10)
                        }
                    }
                } else if let profile = group.profile {
                    AgentAccountGroupHeader(profile: profile, count: group.count, expanded: open) { toggle(group) } onNew: { pickerFor = profile }
                        .padding(.horizontal, 4)
                        .contextMenu { groupMenu }
                }
                Collapsible(open: open) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(nodes(group)) { node in
                            sessionRow(node.session, children: node.children.count, indent: group.headerless ? 0 : 8)
                            if !node.children.isEmpty {
                                Collapsible(open: !collapsedParents.contains(node.id)) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                                            sessionRow(child, depth: 1, last: index == node.children.count - 1, indent: group.headerless ? 0 : 8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        if ws.projects.isEmpty, !ws.loadingProjects {
            Text("No agent sessions yet").font(.syBody).foregroundStyle(Color.syMuted).padding(12)
        } else {
            Button(showArchived ? "Hide archived sessions" : "Show archived sessions") { withAnimation(Motion.smooth) { showArchived.toggle() } }
                .buttonStyle(.link)
                .font(.syCaption)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
        }
    }

    private func toggle(_ group: SidebarGroup) {
        withAnimation(Motion.smooth) {
            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
        }
    }

    @ViewBuilder
    private var groupMenu: some View {
        Picker("Group by", selection: Binding(get: { prefs.grouping }, set: { g in withAnimation(Motion.smooth) { prefs.grouping = g } })) {
            ForEach(AgentGrouping.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Button("Collapse all") { withAnimation(Motion.smooth) { expanded = [] } }
        Button("Expand all") { withAnimation(Motion.smooth) { expanded = Set(groups.map(\.id)) } }
    }

    @ViewBuilder
    private func projectMenu(_ project: ClaudeProject) -> some View {
        Button("New session") { ws.newSession(folder: project.path, profileID: ws.accountFilter) }
            .disabled(!project.exists)
        Button("Save as environment…") { envDraft = AgentEnvironmentDraft(name: project.name, folders: [project.path]) }
            .disabled(!project.exists)
        if ClaudeProfiles.shared.hasSeveral {
            Menu("New session as") {
                ForEach(ClaudeProfiles.shared.visible) { p in
                    Button(p.label) { ws.newSession(folder: project.path, profileID: p.id) }
                }
            }
            .disabled(!project.exists)
            Menu("Move to account") {
                ForEach(ClaudeProfiles.shared.visible) { p in
                    let movable = ws.sessionsToMove(project, to: p).count
                    Button(movable == 0 ? p.label : "\(p.label) (\(movable))") { ws.moveProject(project, to: p) }
                        .disabled(movable == 0)
                }
            }
        }
        Divider()
        let order = prefs.ordered(accountScoped).map(\.id)
        Button("Move up") { withAnimation(Motion.smooth) { prefs.move(project.id, by: -1, in: accountScoped) } }
            .disabled(order.first == project.id)
        Button("Move down") { withAnimation(Motion.smooth) { prefs.move(project.id, by: 1, in: accountScoped) } }
            .disabled(order.last == project.id)
        Button("Sort A to Z") { withAnimation(Motion.smooth) { prefs.sortAlphabetically(accountScoped) } }
        Divider()
        groupMenu
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            .disabled(!project.exists)
        Button("Copy path") { copyToPasteboard(project.path) }
        Divider()
        let live = project.sessions.filter { !prefs.isArchived($0) }
        Button("Archive all (\(live.count))") {
            withAnimation(Motion.smooth) { for s in live { prefs.setArchived(s.id, true) } }
        }
        .disabled(live.isEmpty)
        Button("Delete all sessions (\(project.sessions.count))", role: .destructive) { ws.trashAll(project.sessions, in: project.name) }
    }

    private func sessionRow(_ s: ClaudeSessionInfo, children: Int = 0, depth: Int = 0, last: Bool = false, indent: CGFloat = 0) -> some View {
        SessionRow(
            session: prefs.titles[s.id] == nil ? s : s.retitled(prefs.title(s)),
            open: ws.tab(forSession: s.id) != nil,
            indicator: ws.indicator(for: s),
            childCount: children,
            collapsed: collapsedParents.contains(s.id),
            depth: depth,
            last: last,
            showAccount: prefs.grouping != .account && ws.accountFilter == nil && ClaudeProfiles.shared.hasSeveral,
            onToggle: {
                withAnimation(Motion.smooth) {
                    if collapsedParents.contains(s.id) { collapsedParents.remove(s.id) } else { collapsedParents.insert(s.id) }
                }
            }
        )
        .padding(.leading, indent)
        .padding(.horizontal, 8)
        .background(AgentRowBackground(selected: ws.selectedTab.map { !$0.sessionId.isEmpty && $0.sessionId == s.id } ?? false, focused: listFocused && cursor == s.id))
        .modifier(HoverHighlight(radius: 7))
        .rowAppear(s.id, ws.sessionRows)
        .contentShape(Rectangle())
        .id(s.id)
        .onTapGesture {
            cursor = s.id
            listFocused = true
            ws.resume(s)
        }
        .contextMenu { sessionMenu(s, children: children) }
    }

    @ViewBuilder
    private func sessionMenu(_ s: ClaudeSessionInfo, children: Int) -> some View {
        Menu("Open in") {
            Button("Chat") { ws.resume(s, kind: .chat) }
            Button("Terminal tab") { ws.resume(s, kind: .terminal) }
            Button("Terminal app") {
                try? ClaudeLauncher.launch(prompt: "", folder: s.cwd, target: .terminal, mode: .standard, sessionName: prefs.title(s), resumeId: s.id, configDir: ClaudeProfiles.shared.profile(id: s.profileID)?.configDir)
            }
            if let local = s.desktopId, DesktopSessionIndex.isInstalled {
                Button("Claude Desktop") { DesktopSessionIndex.open(localID: local) }
            }
            Divider()
            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)]) }
        }
        Divider()
        Button(prefs.isPinned(s.id) ? "Unpin" : "Pin") { withAnimation(Motion.smooth) { prefs.togglePin(s.id) } }
            .keyboardShortcut("p", modifiers: [])
        Button(isUnread(s) ? "Mark as read" : "Mark as unread") { toggleUnread(s) }
            .keyboardShortcut("u", modifiers: [])
        Button("Rename") { rename(s) }
            .keyboardShortcut("r", modifiers: [])
        Button("Fork") { ws.resume(s, fork: true) }
            .keyboardShortcut("f", modifiers: [])
        if children > 0 {
            Button(collapsedParents.contains(s.id) ? "Show nested sessions" : "Hide nested sessions") {
                withAnimation(Motion.smooth) {
                    if collapsedParents.contains(s.id) { collapsedParents.remove(s.id) } else { collapsedParents.insert(s.id) }
                }
            }
        }
        if s.parentId != nil {
            Divider()
            Button(prefs.isDetached(s.id) ? "Nest under parent" : "Detach to top level") {
                withAnimation(Motion.smooth) { prefs.setDetached(s.id, !prefs.isDetached(s.id)) }
            }
        }
        Divider()
        Button("Copy session ID") { copyToPasteboard(s.id) }
        Button("Copy resume command") { copyToPasteboard("cd \(ClaudeLauncher.shellQuote(s.cwd)) && claude --resume \(s.id)") }
        Button("Reveal transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.file]) }
        if let pr = s.prURL { Button("Open PR") { if let r = GitHubURL.parse(pr) { app.section = .prs(.mine); app.open(r) } } }
        Divider()
        Button(prefs.isArchived(s) ? "Unarchive" : "Archive") { withAnimation(Motion.smooth) { prefs.setArchived(s.id, !prefs.isArchived(s)) } }
            .keyboardShortcut("a", modifiers: [])
        Button("Delete", role: .destructive) { ws.trash(s) }
            .keyboardShortcut("d", modifiers: [])
    }

    private func isUnread(_ s: ClaudeSessionInfo) -> Bool {
        ws.indicator(for: s) == .done
    }

    private func toggleUnread(_ s: ClaudeSessionInfo) {
        if isUnread(s) {
            SessionSeen.shared.mark(s.id)
            ws.tab(forSession: s.id)?.unread = false
        } else if let tab = ws.tab(forSession: s.id) {
            ws.markUnread(tab)
        } else {
            SessionSeen.shared.markUnread(s.id)
        }
    }

    private func rename(_ s: ClaudeSessionInfo) {
        guard let name = AgentRename.ask(title: "Rename session", info: "The new name is only shown in PullYard.", current: prefs.title(s)) else { return }
        if let tab = ws.tab(forSession: s.id) { ws.rename(tab, to: name) } else { prefs.rename(s.id, to: name) }
    }
}

struct AgentEnvironmentDraft: Identifiable {
    let id = UUID()
    var editing: AgentEnvironment?
    var name = ""
    var folders: [String] = []
}

struct AgentTabMenu: View {
    let tab: ClaudeTab
    let ws: ClaudeWorkspace

    var body: some View {
        let prefs = AgentSessionPrefs.shared
        Button(prefs.isPinned(tab.sessionId) ? "Unpin" : "Pin") { withAnimation(Motion.smooth) { prefs.togglePin(tab.sessionId) } }
            .disabled(tab.sessionId.isEmpty)
        Button("Rename") { AgentTabMenu.rename(tab, ws: ws) }
        Button("Mark as unread") { ws.markUnread(tab) }
            .disabled(tab.sessionId.isEmpty)
        if let s = ws.sessionsByID[tab.sessionId] {
            Button("Fork") { ws.resume(s, fork: true) }
        }
        Divider()
        if tab.running {
            Button("Free memory (sleep)") { tab.sleepNow() }
                .disabled(tab.state == .working || tab.state == .waiting)
        } else {
            Button("Wake up") { ws.restart(tab) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.folder)]) }
        Button("Copy session ID") { copyToPasteboard(tab.sessionId) }
            .disabled(tab.sessionId.isEmpty)
        Divider()
        Button("Close") { ws.requestClose(tab) }
        Button("Close other tabs") {
            for other in ws.tabs where other.id != tab.id && !AgentSessionPrefs.shared.isPinned(other.sessionId) { ws.requestClose(other) }
        }
        .disabled(ws.tabs.count < 2)
    }

    static func rename(_ tab: ClaudeTab, ws: ClaudeWorkspace) {
        guard let name = AgentRename.ask(title: "Rename session", info: "The new name is only shown in PullYard.", current: tab.title) else { return }
        ws.rename(tab, to: name)
    }
}

struct AgentAccountGroupHeader: View {
    let profile: ClaudeProfile
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onNew: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.syCaption2.weight(.bold))
                .foregroundStyle(Color.syDim)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            ProfileBadge(profile: profile, size: 18)
            Text(profile.label).font(.syBody.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
            Text(verbatim: "\(count)").font(.syCaption2.monospacedDigit()).foregroundStyle(Color.syDim)
            Spacer(minLength: 4)
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.syCaption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.syMuted)
            .opacity(hover ? 1 : 0)
            .help("New session as \(profile.label)")
            .accessibilityLabel("New session as \(profile.label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.syText.opacity(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.micro)) { hover = h } }
        .help(profile.email ?? profile.label)
        .padding(.top, 4)
    }
}

struct AgentAccountEmpty: View {
    let profile: ClaudeProfile
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProfileBadge(profile: profile, size: 24)
                Text("No sessions as \(profile.label) yet").font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText)
            }
            Text("Pick a project to start the first session with this account.")
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpen) { Label("Open project…", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent)
                .tint(.syAgentFill)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }
}

struct AgentProjectPicker: View {
    private let initialProfile: ClaudeProfile
    @State private var profileID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var envDraft: AgentEnvironmentDraft?
    @FocusState private var searchFocused: Bool

    init(profile: ClaudeProfile) {
        initialProfile = profile
        _profileID = State(initialValue: profile.id)
    }

    /// The account the new session starts as. Starts at the one the sheet was
    /// opened for and can be changed from the header before opening.
    private var profile: ClaudeProfile {
        ClaudeProfiles.shared.profile(id: profileID) ?? initialProfile
    }

    @ViewBuilder
    private var accountLine: some View {
        let text = Text("New session as \(profile.label)" + (profile.email.map { " · \($0)" } ?? ""))
            .font(.syCaption)
            .lineLimit(1)
        let others = ClaudeProfiles.shared.visible
        if others.count > 1 {
            Menu {
                Picker("Account", selection: $profileID) {
                    ForEach(others) { p in
                        Text(p.label + (p.email.map { " — \($0)" } ?? "")).tag(p.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    text
                    Image(systemName: "chevron.up.chevron.down").font(.syCaption2.weight(.semibold))
                }
                .foregroundStyle(Color.syMuted)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which Claude account this session uses")
        } else {
            text.foregroundStyle(Color.syMuted)
        }
    }

    private var environments: [AgentEnvironment] {
        let all = AgentEnvironments.shared.items
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var projects: [ClaudeProject] {
        let all = app.claude.projects.filter(\.exists)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProfileBadge(profile: profile, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open a project").font(.syHeadline).foregroundStyle(Color.syText)
                    accountLine
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.syDim)
                TextField("Search projects", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = projects.first { open(first.path) } }
            }
            .font(.syBody)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.sySunken))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(searchFocused ? Color.syLineStrong : Color.syLine))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !environments.isEmpty {
                        sectionTitle("Environments")
                        ForEach(environments) { env in
                            environmentRow(env)
                        }
                        sectionTitle("Projects")
                    }
                    ForEach(projects) { p in
                        row(p)
                    }
                    if projects.isEmpty {
                        Text(query.isEmpty ? "No projects yet. Choose a folder below." : "No projects match “\(query)”.")
                            .font(.syCallout)
                            .foregroundStyle(Color.syMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(4)
            }
            .frame(height: 300)
            .card(radius: 10, fill: .sySunken)
            HStack {
                Group {
                    Button { chooseFolder() } label: { Label("Choose folder…", systemImage: "folder") }
                    Button { envDraft = AgentEnvironmentDraft() } label: { Label("New environment…", systemImage: "square.stack.3d.up") }
                }
                .tint(Color.syText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .tint(Color.syText)
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    guard let selection else { return }
                    if selection.hasPrefix("env:"), let env = AgentEnvironments.shared.environment(id: String(selection.dropFirst(4))) { start(env) } else { open(selection) }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.syAgentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .surface(.panel)
        .tint(Color.syAgentAccent)
        .onAppear { searchFocused = true }
        .sheet(item: $envDraft) { d in AgentEnvironmentSheet(editing: d.editing, draftName: d.name, draftFolders: d.folders) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.syCaption.weight(.semibold))
            .foregroundStyle(Color.syMuted)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func environmentRow(_ env: AgentEnvironment) -> some View {
        let key = "env:" + env.id
        let selected = selection == key
        return HStack(spacing: 10) {
            Image(systemName: env.icon)
                .font(.syIcon(11))
                .foregroundStyle(Color.syAgentAccent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.syAgentAccent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(env.name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                Text(environmentDetail(env)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.syText.opacity(0.1) : Color.clear))
        .modifier(HoverHighlight(radius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { start(env) }
        .simultaneousGesture(TapGesture().onEnded { selection = key })
        .contextMenu {
            Button("Start session") { start(env) }
            Button("Edit…") { envDraft = AgentEnvironmentDraft(editing: env) }
            Divider()
            Button("Delete", role: .destructive) { AgentEnvironments.shared.remove(env.id) }
        }
    }

    private func environmentDetail(_ env: AgentEnvironment) -> String {
        var parts: [String] = []
        if let first = env.startFolder { parts.append((first as NSString).lastPathComponent) }
        if env.folders.count > 1 { parts.append("+\(env.folders.count - 1) folders") }
        if !env.variableNames.isEmpty { parts.append("\(env.variableNames.count) variables") }
        return parts.isEmpty ? "Choose a folder when starting" : parts.joined(separator: " · ")
    }

    private func start(_ env: AgentEnvironment) {
        dismiss()
        DispatchQueue.main.async { app.claude.newSession(in: env, profileID: profile.id) }
    }

    private func row(_ p: ClaudeProject) -> some View {
        let selected = selection == p.path
        let tint = ProjectPalette.color(for: p.path)
        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.syIcon(11))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                Text(p.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(Fmt.rel(p.lastActivity)).font(.syCaption).foregroundStyle(Color.syDim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.syText.opacity(0.1) : Color.clear))
        .modifier(HoverHighlight(radius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(p.path) }
        .simultaneousGesture(TapGesture().onEnded { selection = p.path })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url.path)
    }

    private func open(_ path: String) {
        app.claude.newSession(folder: path, profileID: profile.id)
        dismiss()
    }
}

struct ProjectHeader: View {
    let project: ClaudeProject
    let expanded: Bool
    let onToggle: () -> Void
    let onNew: () -> Void
    @State private var hover = false

    var body: some View {
        let tint = project.exists ? ProjectPalette.color(for: project.path) : Color.syDim
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.syCaption2.weight(.bold))
                .foregroundStyle(Color.syDim)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: expanded ? "folder.fill" : "folder")
                .font(.syCallout)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(project.name)
                .font(.syBody.weight(.semibold))
                .foregroundStyle(project.exists ? Color.syText : Color.syMuted)
                .lineLimit(1)
            Text(verbatim: "\(project.sessions.count)")
                .font(.syCaption2.monospacedDigit())
                .foregroundStyle(Color.syDim)
            Spacer(minLength: 4)
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.syCaption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.syMuted)
            .opacity(hover ? 1 : 0)
            .help("New session in \(project.name)")
            .accessibilityLabel("New session in \(project.name)")
            .disabled(!project.exists)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.syText.opacity(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.micro)) { hover = h } }
        .help(project.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
        .textCase(nil)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(project.name), \(project.sessions.count) sessions, \(expanded ? "expanded" : "collapsed")")
    }
}

enum SessionTree {
    struct Node: Identifiable {
        let session: ClaudeSessionInfo
        let children: [ClaudeSessionInfo]
        var id: String { session.id }
    }

    static func build(_ sessions: [ClaudeSessionInfo], detached: Set<String> = []) -> [Node] {
        let ids = Set(sessions.map(\.id))
        var children: [String: [ClaudeSessionInfo]] = [:]
        var roots: [ClaudeSessionInfo] = []
        for s in sessions {
            if let p = s.parentId, p != s.id, ids.contains(p), !detached.contains(s.id) { children[p, default: []].append(s) } else { roots.append(s) }
        }
        return roots
            .map { Node(session: $0, children: (children[$0.id] ?? []).sorted { $0.modified > $1.modified }) }
            .sorted { ($0.children.first?.modified ?? $0.session.modified).max($0.session.modified) > ($1.children.first?.modified ?? $1.session.modified).max($1.session.modified) }
    }
}

private extension Date {
    func max(_ other: Date) -> Date { self > other ? self : other }
}

struct SessionTreeGuide: View {
    let last: Bool

    var body: some View {
        GeometryReader { g in
            Path { p in
                let x: CGFloat = 0.5
                let mid = g.size.height / 2
                p.move(to: CGPoint(x: x, y: 0))
                if last {
                    p.addLine(to: CGPoint(x: x, y: mid - 6))
                    p.addQuadCurve(to: CGPoint(x: x + 8, y: mid), control: CGPoint(x: x, y: mid))
                } else {
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                }
            }
            .stroke(Color.syLineStrong, lineWidth: 1)
        }
        .frame(width: 10)
    }
}

struct SessionRow: View {
    let session: ClaudeSessionInfo
    let open: Bool
    var indicator: SessionIndicator = .none
    var childCount = 0
    var collapsed = false
    var depth = 0
    var last = false
    var showAccount = false
    var onToggle: () -> Void = {}
    @State private var expired = false

    var body: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                SessionTreeGuide(last: last).padding(.leading, 6)
            }
            SessionIndicatorDot(indicator: expired ? SessionIndicator(closed: session) : indicator)
                .task(id: indicator == .working && !open) {
                    guard indicator == .working && !open else { return }
                    let left = 15 - Date().timeIntervalSince(session.modified)
                    if left > 0 { try? await Task.sleep(for: .seconds(left + 0.2)) }
                    expired = true
                }
            Text(session.title)
                .font(.syBody)
                .fontWeight(open ? .medium : .regular)
                .foregroundStyle(depth > 0 ? Color.syMuted : Color.syText)
                .lineLimit(1)
            if childCount > 0 {
                Button(action: onToggle) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.down")
                            .font(.syCaption2.weight(.semibold))
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                        Text(verbatim: "\(childCount)").font(.syCaption2.monospacedDigit())
                    }
                    .foregroundStyle(Color.syDim)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show nested sessions" : "Hide nested sessions")
                .accessibilityLabel(collapsed ? "Show nested sessions" : "Hide nested sessions")
            }
            Spacer(minLength: 6)
            if let worktree = session.worktreeName {
                Image(systemName: "arrow.triangle.branch")
                    .font(.syCaption2)
                    .foregroundStyle(Color.syDim)
                    .help("Worktree " + worktree)
                    .accessibilityLabel("Worktree " + worktree)
            }
            if let n = session.prNumber {
                Text(verbatim: "#\(n)")
                    .font(.syCaption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.syViolet)
                    .accessibilityLabel("Pull request \(n)")
            }
            if showAccount, let profile = ClaudeProfiles.shared.profile(id: session.profileID) {
                Circle()
                    .fill(AgentAccountChip.color(for: profile.id))
                    .frame(width: 6, height: 6)
                    .help(profile.label)
                    .accessibilityLabel("Account \(profile.label)")
            }
            Text(Self.age(session.modified))
                .font(.syCaption2.monospacedDigit())
                .foregroundStyle(Color.syDim)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .frame(minHeight: 28)
        .help(details)
    }

    static func age(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<604_800: return "\(s / 86_400)d"
        default: return "\(s / 604_800)w"
        }
    }

    private var details: String {
        var parts = ["Updated " + Fmt.rel(session.modified)]
        if let b = session.branch { parts.append("Branch: " + b) }
        if let w = session.worktreeName { parts.append("Worktree: " + w) }
        if let n = session.prNumber { parts.append("PR #\(n)") }
        return parts.joined(separator: "\n")
    }
}

struct OpenTabRow: View {
    let tab: ClaudeTab
    let selected: Bool
    var pinned = false

    var body: some View {
        HStack(spacing: 8) {
            if tab.unread && tab.state != .working && tab.state != .waiting {
                SessionIndicatorDot(indicator: .done)
            } else {
                SessionStateGlyph(state: tab.state).frame(width: 14, height: 14)
            }
            Text(tab.title)
                .font(.syBody)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(Color.syText)
                .lineLimit(1)
            Spacer(minLength: 6)
            if pinned {
                Image(systemName: "pin.fill").font(.syCaption2).foregroundStyle(Color.syDim)
            }
            Text(tab.projectName)
                .font(.syCaption)
                .foregroundStyle(Color.syDim)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.leading, 2)
        .frame(minHeight: 28)
        .help(tab.state.help)
    }
}

struct SessionStateGlyph: View {
    let state: ClaudeTabState

    var body: some View {
        Group {
            switch state {
            case .working: PYLoader(size: 11, label: "Working")
            case .waiting: Circle().fill(Color.syAmber).frame(width: 7, height: 7)
            case .active: Circle().fill(Color.syMuted).frame(width: 5, height: 5)
            case .sleeping, .stopped: Circle().strokeBorder(Color.syDim, lineWidth: 1).frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
        .help(state.help)
        .accessibilityLabel(state.title)
    }
}

struct ClaudeRowHighlight: View {
    let selected: Bool
    var color: Color = .syText

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)).padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}

struct ClaudeHairline: View {
    var body: some View {
        Rectangle().fill(Color.syLine).frame(height: 1)
    }
}

struct ClaudeBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.isBrand {
            content
                .background(Color.syBar)
                .overlay(alignment: .bottom) { ClaudeHairline() }
        } else {
            content.background(.bar)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct ClaudeWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("agents.inspectorWidth") private var inspectorWidth: Double = 380
    @State private var inspectorExpanded = false

    private static let inspectorMin: Double = 280
    private static let inspectorDefault: Double = 380

    var body: some View {
        let ws = app.claude
        let account = ClaudeAccountStore.shared
        Group {
            if case .loggedOut = account.status, !FixTour.shared.active {
                ClaudeAuthView()
            } else if case .notInstalled = account.status, !FixTour.shared.active {
                ClaudeAuthView()
            } else if let tab = ws.selectedTab {
                GeometryReader { geo in
                    let maxWidth = max(Self.inspectorMin, min(Double(geo.size.width) * 0.6, Double(geo.size.width) - 421))
                    let width = min(max(inspectorWidth, Self.inspectorMin), maxWidth)
                    let expanded = inspectorExpanded && ws.showInspector
                    ZStack(alignment: .trailing) {
                        VStack(spacing: 0) {
                            ClaudeTabBar()
                            ClaudeControlBar(tab: tab)
                            if !Theme.isBrand { Divider() }
                            Group {
                                if let chat = tab.chat {
                                    ChatView(tab: tab, chat: chat)
                                } else {
                                    ZStack {
                                        ClaudeTerminalHost(tab: tab)
                                        if !tab.running {
                                            VStack(spacing: 10) {
                                                if tab.terminalSleeping {
                                                    Label("Session is sleeping — memory freed", systemImage: "moon.zzz").foregroundStyle(Color.syMuted)
                                                } else {
                                                    Text("Session ended" + (tab.exitCode.map { " (\($0))" } ?? "")).foregroundStyle(Color.syMuted)
                                                }
                                                HStack {
                                                    Button("Resume session") { ws.restart(tab) }.buttonStyle(.borderedProminent).tint(.syAgentFill)
                                                    Button("Close tab") { ws.close(tab) }
                                                }
                                            }
                                            .padding(16)
                                            .card(radius: 12)
                                            .transition(.pop)
                                        }
                                    }
                                    .animation(Motion.spring, value: tab.running)
                                }
                            }
                            .id(tab.id)
                        }
                        .frame(minWidth: ws.showInspector ? max(0, min(420, geo.size.width - width - 1)) : 0, maxWidth: .infinity)
                        .surface(.panel)
                        .padding(.trailing, ws.showInspector ? width + 1 : 0)
                        .allowsHitTesting(!expanded)
                        .accessibilityHidden(expanded)
                        if ws.showInspector {
                            HStack(spacing: 0) {
                                if !expanded {
                                    ColumnResizeHandle(
                                        width: Binding(get: { width }, set: { inspectorWidth = $0 }),
                                        range: Self.inspectorMin...maxWidth,
                                        edge: .trailing,
                                        reset: Self.inspectorDefault
                                    )
                                }
                                ClaudeInspector(tab: tab, expanded: expanded, onToggleExpand: toggleExpanded)
                            }
                            .frame(width: expanded ? geo.size.width : width + 1)
                            .background {
                                if expanded {
                                    Button("Collapse inspector") { toggleExpanded() }
                                        .keyboardShortcut(.cancelAction)
                                        .frame(width: 0, height: 0)
                                        .opacity(0)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .edgeReveal(.trailing, enabled: !ws.showInspector, width: width) {
                        ClaudeInspector(tab: tab)
                            .surface(.panel)
                            .environment(app)
                            .font(.syBody)
                            .tint(Color.syAccent)
                            .environment(\.locale, .app)
                    }
                }
            } else {
                ClaudeEmptyState()
            }
        }
        .navigationTitle(ws.selectedTab?.title ?? "Agents")
        .navigationSubtitle(ws.selectedTab?.folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") ?? "")
        .panelToolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if ws.selectedTab != nil {
                    Button { toggleInspector() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help(ws.showInspector ? "Hide changes panel" : "Show changes panel")
                }
            }
        }
    }

    private func toggleInspector() {
        if app.claude.showInspector { inspectorExpanded = false }
        app.claude.showInspector.toggle()
    }

    private func toggleExpanded() {
        withAnimation(Motion.smooth) { inspectorExpanded.toggle() }
    }
}

struct ClaudeEmptyState: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ws = app.claude
        let projects = Array(ws.projects.filter(\.exists).prefix(6))
        ZStack {
            if Theme.isBrand { BrandAurora().opacity(0.8) }
            VStack(spacing: 18) {
                ZStack(alignment: .bottom) {
                    HarborWaves().frame(width: 180, height: 20).offset(y: 14)
                    DrawnLogoMark(key: "agents-empty", size: 88)
                }
                .padding(.bottom, 10)
                Text("Agents on deck")
                    .font(.system(size: TextZoom.shared.size(26), weight: .semibold, design: .serif))
                    .foregroundStyle(Color.syText)
                Text("Runs Claude Code, installed on this Mac. Start a new session in a project or resume one from the history on the left.")
                    .foregroundStyle(Color.syMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if !projects.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(projects) { p in
                            AgentProjectCard(name: p.name, path: p.path, last: p.lastActivity) { ws.newSession(folder: p.path) }
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(.top, 6)
                }
                HStack(spacing: 16) {
                    HStack(spacing: 6) { Keycap(key: "⌘N"); Text("New session").font(.syCaption).foregroundStyle(Color.syMuted) }
                    HStack(spacing: 6) { Keycap(key: "⇧⌘K"); Text("Go to session").font(.syCaption).foregroundStyle(Color.syMuted) }
                }
                .padding(.top, 4)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .surface(.panel)
    }
}

private struct AgentProjectCard: View {
    let name: String
    let path: String
    let last: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.syIcon(13))
                    .foregroundStyle(Color.syCoral)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.syCoral.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                    Text(Fmt.rel(last)).font(.syCaption).foregroundStyle(Color.syMuted)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus")
                    .font(.syIcon(11))
                    .foregroundStyle(hovering ? Color.syCoralInk : Color.syDim)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.syRaised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Color.syCoral.opacity(0.45) : Color.syLine))
            .shadow(color: .black.opacity(hovering ? 0.07 : 0.03), radius: hovering ? 10 : 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.fast)) { hovering = h } }
        .help("New session in \(path)")
    }
}

struct ClaudeTabBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ws = app.claude
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ws.orderedTabs) { tab in
                    ClaudeTabChip(tab: tab, selected: tab.id == ws.selectedTabID, pinned: AgentSessionPrefs.shared.isPinned(tab.sessionId))
                }
                Menu {
                    if let current = ws.selectedTab {
                        Button("Chat in \(current.projectName)") { ws.newSession(folder: current.folder, kind: .chat, profileID: current.profile?.id) }
                        Button("Terminal in \(current.projectName)") { ws.newSession(folder: current.folder, kind: .terminal, profileID: current.profile?.id) }
                        if ClaudeProfiles.shared.hasSeveral {
                            Menu("New Chat As") {
                                ForEach(ClaudeProfiles.shared.visible) { p in
                                    Button(p.email.map { "\(p.label) · \($0)" } ?? p.label) { ws.newSession(folder: current.folder, kind: .chat, profileID: p.id) }
                                }
                            }
                        }
                        Divider()
                    }
                    if !AgentEnvironments.shared.items.isEmpty {
                        Menu("Environments") {
                            ForEach(AgentEnvironments.shared.items) { env in
                                Button { ws.newSession(in: env) } label: { Label(env.name, systemImage: env.icon) }
                            }
                        }
                        Divider()
                    }
                    ForEach(ws.projects.filter(\.exists).prefix(12)) { p in
                        Button(p.name) { ws.newSession(folder: p.path) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session")
                .accessibilityLabel("New session")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ClaudeBarBackground())
    }
}

struct ClaudeControlBar: View {
    @Environment(AppModel.self) private var app
    let tab: ClaudeTab

    var body: some View {
        let ws = app.claude
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(tab.projectName).fontWeight(.semibold).foregroundStyle(Color.syText).lineLimit(1)
                    .layoutPriority(2)
                AgentAccountChip(profile: tab.profile)
                if let env = tab.environment {
                    Label(env.name, systemImage: env.icon)
                        .labelStyle(CompactLabelStyle())
                        .font(.syCaption.weight(.medium))
                        .foregroundStyle(Color.syAgentAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.syAgentAccent.opacity(0.12)))
                        .help("Environment: " + env.name)
                }
                let pr = ws.pullRequest(for: tab)
                ViewThatFits(in: .horizontal) {
                    AgentBranchMenu(tab: tab, pr: pr, style: .full)
                    AgentBranchMenu(tab: tab, pr: pr, style: .compact)
                    AgentBranchMenu(tab: tab, pr: pr, style: .minimal)
                }
                TabStateBadge(state: tab.state, memory: tab.memoryBytes)
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if tab.kind == .terminal {
            ControlMenu(icon: "cpu", title: ws.defaults.modelTitle, help: "Model") {
                Button { ws.defaults.model = "" } label: { checkLabel("Default", ws.defaults.model.isEmpty) }
                ForEach(ws.defaults.modelChoices) { m in
                    Button { ws.defaults.model = m.value } label: { checkLabel(m.displayName, ws.defaults.model == m.value) }
                }
                Divider()
                Button("Apply to current session (/model)") { ws.applyModelToCurrent() }
                    .disabled(!tab.running || ws.defaults.model.isEmpty)
            }
            ControlMenu(icon: "gauge.with.dots.needle.50percent", title: ws.effort == .standard ? "Effort" : ws.effort.rawValue, help: "Effort") {
                ForEach(ClaudeEffort.allCases) { e in
                    Button { ws.effort = e } label: { checkLabel(e.title, ws.effort == e) }
                }
            }
            ControlMenu(icon: "hand.raised", title: ws.mode.title, help: "Permission mode") {
                ForEach(ClaudeMode.allCases) { m in
                    Button { ws.mode = m } label: { checkLabel(m.title, ws.mode == m) }
                }
            }
            } else if let chat = tab.chat, chat.totalCost > 0 || chat.sessionId != nil {
                Text(chat.model.replacingOccurrences(of: "claude-", with: "")).font(.syCaption).foregroundStyle(Color.syMuted)
                if chat.totalCost > 0, SessionCost.billedPerUse || SessionCost.budget > 0 {
                    Text(SessionCost.format(chat.totalCost))
                        .font(.syCaption.monospacedDigit())
                        .foregroundStyle(chat.budgetPaused ? Color.syAmber : Color.syMuted)
                        .help(SessionCost.budget > 0 ? "Session cost · limit \(SessionCost.format(SessionCost.budget))" : "Session cost")
                        .accessibilityLabel("Session cost \(SessionCost.format(chat.totalCost))")
                }
            }
            OpenInMenu(folder: tab.folder)
            Picker("", selection: Binding(get: { tab.kind }, set: { k in
                if k == .terminal && tab.kind == .chat { ws.openInTerminal(tab) }
                if k == .chat && tab.kind == .terminal { ws.openInChat(tab) }
            })) {
                Image(systemName: "bubble.left.and.text.bubble.right").accessibilityLabel("Chat").tag(ClaudeTabKind.chat)
                Image(systemName: "terminal").accessibilityLabel("Terminal").tag(ClaudeTabKind.terminal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(tab.sessionId.isEmpty)
            .help("Chat or terminal (same session)")
            .accessibilityLabel("Chat or terminal")
            Menu {
                Button("Restart with new settings") {
                    if tab.kind == .chat { tab.chat?.stop() } else if tab.running { tab.terminal.terminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ws.restart(tab) }
                }
                Button("Free memory now") { tab.sleepNow() }
                    .disabled(!tab.running || tab.state == .working || tab.state == .waiting)
                Menu("Sleep after idle") {
                    ForEach([0, 5, 15, 30, 60], id: \.self) { m in
                        Button { ws.idleMinutes = m } label: { checkLabel(m == 0 ? "Never" : "\(m) min", ws.idleMinutes == m) }
                    }
                }
                Menu("Open new sessions as") {
                    Button { ws.preferredKind = .chat } label: { checkLabel("Chat", ws.preferredKind == .chat) }
                    Button { ws.preferredKind = .terminal } label: { checkLabel("Terminal", ws.preferredKind == .terminal) }
                }
                Divider()
                Button("Continue in Terminal") {
                    try? ClaudeLauncher.launch(prompt: "", folder: tab.folder, target: .terminal, mode: .standard, sessionName: tab.title, resumeId: tab.sessionId, configDir: tab.configDir)
                }
                if DesktopSessionIndex.isInstalled, let local = ws.sessionsByID[tab.sessionId]?.desktopId {
                    Button("Open in Claude Desktop") { DesktopSessionIndex.open(localID: local) }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.folder)]) }
                Button("Copy session ID") { copyToPasteboard(tab.sessionId) }
                if let chat = tab.chat {
                    Divider()
                    Button("Copy conversation as Markdown") { copyToPasteboard(chat.markdownTranscript(title: tab.title)) }
                        .disabled(chat.items.isEmpty)
                    Button("Export conversation…") { ws.exportTranscript(tab) }
                        .disabled(chat.items.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .font(.syCallout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .clipped()
        .modifier(ClaudeBarBackground())
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct ControlMenu<Content: View>: View {
    let icon: String
    let title: String
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(help + " — " + "applies to new and restarted sessions")
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, tasks, files, pr
    var id: String { rawValue }
}

struct ClaudeInspector: View {
    let tab: ClaudeTab
    var expanded = false
    var onToggleExpand: (() -> Void)?
    @AppStorage("agents.inspectorTab") private var selection: InspectorTab = .changes

    private var tabs: [TabItem<InspectorTab>] {
        var items = [TabItem(id: InspectorTab.changes, title: "Changes", icon: "plusminus", badge: tab.git.changes.isEmpty ? nil : "\(tab.git.changes.count)", badgeColor: .syAmber)]
        if let chat = tab.chat {
            let running = chat.taskCalls.filter { ChatTaskState($0) == .running }.count
            items.append(TabItem(id: InspectorTab.tasks, title: "Tasks", icon: "terminal", badge: running > 0 ? "\(running)" : nil, badgeColor: .sySky))
        }
        items.append(TabItem(id: InspectorTab.files, title: "Files", icon: "folder"))
        items.append(TabItem(id: InspectorTab.pr, title: "PR", icon: "arrow.triangle.pull"))
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabStrip(items: tabs, selection: $selection)
                if let onToggleExpand {
                    Button(action: onToggleExpand) {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.syMuted)
                    .padding(.trailing, 10)
                    .help(expanded ? "Collapse (Esc)" : "Expand over the chat")
                    .accessibilityLabel(expanded ? "Collapse inspector" : "Expand inspector")
                }
            }
            .padding(.top, 4)
            ClaudeHairline()
            switch selection {
            case .changes: ChangesPanel(tab: tab)
            case .tasks:
                if let chat = tab.chat { ChatTasksPanel(chat: chat) } else { ChangesPanel(tab: tab) }
            case .files: LocalFilesPanel(root: tab.folder)
            case .pr: BranchPRPanel(tab: tab)
            }
        }
        .background(Theme.isBrand ? Color.syPanel : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { if Theme.isBrand { Rectangle().fill(Color.syLine).frame(width: 1) } }
    }
}

struct ChangesPanel: View {
    let tab: ClaudeTab
    @State private var collapsed: Set<String> = []
    @State private var target: String?

    var body: some View {
        let git = tab.git
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if git.loading { PYLoader(size: 12) }
                Text(git.changes.isEmpty ? "No uncommitted changes" : plural(git.changes.count, "file changed", "files changed"))
                    .font(.syCaption.weight(.medium)).foregroundStyle(git.changes.isEmpty ? Color.syMuted : Color.syText)
                if !git.changes.isEmpty {
                    DiffStat(additions: git.changes.reduce(0) { $0 + $1.additions }, deletions: git.changes.reduce(0) { $0 + $1.deletions })
                }
                Spacer()
                Button { Task { await git.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if !git.unpushed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.syCoral)
                        Text(plural(git.unpushed.count, "unpushed commit", "unpushed commits"))
                            .font(.sy(size: 10, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Color.syCoralInk)
                    }
                    ForEach(git.unpushed.prefix(6)) { c in
                        HStack(spacing: 6) {
                            Text(c.short)
                                .font(.syCaption2.monospaced())
                                .foregroundStyle(Color.syMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.syText.opacity(0.05)))
                            Text(c.subject).font(.syCaption).foregroundStyle(Color.syText).lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.syCoral.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syCoral.opacity(0.2)))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            ClaudeHairline()
            if git.changes.isEmpty {
                InspectorEmptyState(icon: "checkmark.seal", title: "Working tree clean", message: "Changes the agent makes will show up here automatically.")
            } else {
                PlainDiffList(files: git.changes, collapsed: $collapsed, scrollTarget: target) { path in
                    NSWorkspace.shared.open(URL(fileURLWithPath: tab.folder + "/" + path))
                }
            }
        }
        .task(id: tab.id) { await git.refresh() }
    }
}

struct LocalFilesPanel: View {
    let root: String
    @State private var dir = ""
    @State private var entries: [TreeEntry] = []
    @State private var file: String?
    @State private var content: String?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { if !dir.isEmpty { dir = (dir as NSString).deletingLastPathComponent } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .disabled(dir.isEmpty)
                        .help("Parent folder")
                        .accessibilityLabel("Parent folder")
                    Text(dir.isEmpty ? (root as NSString).lastPathComponent : dir).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                ClaudeHairline()
                List(entries) { e in
                    EntryRow(entry: e)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if e.isDir { dir = e.path } else { file = e.path }
                        }
                        .listRowBackground(ClaudeRowHighlight(selected: file == e.path))
                }
                .listStyle(.plain)
                .surface(.panel)
            }
            .frame(minHeight: 140, idealHeight: 220)
            Group {
                if let file, let content {
                    CodeTextView(text: content, ext: (file as NSString).pathExtension.isEmpty ? (file as NSString).lastPathComponent : (file as NSString).pathExtension)
                } else if file != nil {
                    Text("Binary or large file").foregroundStyle(Color.syMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Pick a file").foregroundStyle(Color.syDim).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 160)
        }
        .task(id: dir) { load() }
        .task(id: file) {
            guard let file else { content = nil; return }
            let full = root + "/" + file
            content = await Task.detached {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: full), (attrs[.size] as? Int ?? 0) < 2_000_000 else { return nil }
                return try? String(contentsOfFile: full, encoding: .utf8)
            }.value
        }
    }

    private func load() {
        let fm = FileManager.default
        let base = dir.isEmpty ? root : root + "/" + dir
        let names = (try? fm.contentsOfDirectory(atPath: base)) ?? []
        entries = names.filter { $0 != ".git" && $0 != ".DS_Store" }.compactMap { name in
            var isDir: ObjCBool = false
            let full = base + "/" + name
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? nil
            return TreeEntry(name: name, path: dir.isEmpty ? name : dir + "/" + name, type: isDir.boolValue ? "tree" : "blob", object: BlobMeta(byteSize: isDir.boolValue ? nil : size, isBinary: nil))
        }
        .sorted { a, b in a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
}

enum PRListScope: String, CaseIterable, Identifiable {
    case open, merged, mine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .merged: return "Merged"
        case .mine: return "Mine"
        }
    }
}

struct BranchPRPanel: View {
    @Environment(AppModel.self) private var app
    let tab: ClaudeTab
    @State private var branchPRs: [SearchItem] = []
    @State private var linked: SearchItem?
    @State private var list: [SearchItem] = []
    @State private var scope: PRListScope = .open
    @State private var branchLoading = false
    @State private var listLoading = false
    @State private var branchError: String?
    @State private var error: String?
    @State private var lastUpdated: Date?
    @State private var selected: ItemRef?
    @State private var rows = RowAppearTracker()
    @State private var listScope: PRListScope?

    private var repo: RepoRef? { tab.git.repo }

    var body: some View {
        Group {
            if let selected {
                InspectorPRDetail(tab: tab, ref: selected) { self.selected = nil }
            } else if repo == nil, let remote = tab.git.remote {
                ForgeBranchPanel(tab: tab, remote: remote)
            } else if repo == nil {
                VStack(spacing: 8) {
                    Image(systemName: "link.badge.plus").font(.syTitle2).foregroundStyle(Color.syDim)
                    Text("Folder isn't linked to a remote repository").foregroundStyle(Color.syMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.api == nil {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.syTitle2).foregroundStyle(Color.syDim)
                    Text("Switch to a GitHub account to see pull requests for \(repo?.full ?? "this repository")")
                        .foregroundStyle(Color.syMuted)
                        .multilineTextAlignment(.center)
                    if let remote = tab.git.remote { Button("Open in Browser") { openInBrowser(remote.webURL + "/pulls") }.controlSize(.small) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listView
            }
        }
        .task(id: "\(repo?.full ?? "")|\(tab.git.branch ?? "")") { await loadBranch() }
        .task(id: "\(repo?.full ?? "")|\(scope.rawValue)") { await loadList() }
        .onLiveTick { if selected == nil { await load() } }
        .onChange(of: app.refreshTick) { if selected == nil { Task { await load() } } }
        .onChange(of: tab.busy) { _, busy in if !busy { Task { await loadBranch() } } }
        .onChange(of: tab.git.ahead) { Task { await loadBranch() } }
    }

    private var listView: some View {
        List {
            Section {
                if let branchError, branchPRs.isEmpty {
                    Text(branchError).font(.syCaption).foregroundStyle(Color.syRed)
                } else if branchPRs.isEmpty && linked == nil && !branchLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No PR for branch \(tab.git.branch ?? "?")")
                            .font(.syCallout).foregroundStyle(Color.syMuted)
                        if let repo, let b = tab.git.branch, b != "HEAD" {
                            HStack(spacing: 8) {
                                Button("Open PR with Agent") {
                                    app.claude.send(AgentShip.openPRPrompt(branch: b, defaultBranch: nil, hasChanges: !tab.git.changes.isEmpty, ahead: tab.git.ahead, remote: tab.git.remote), to: tab)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.syAgentFill)
                                .disabled(tab.busy)
                                Button("Create in Browser") { openInBrowser("https://github.com/\(repo.full)/pull/new/\(b)") }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(branchPRs) { item in row(item) }
                if let linked, !branchPRs.contains(where: { $0.number == linked.number }) {
                    row(linked, note: "from this session")
                }
            } header: {
                HStack(spacing: 6) {
                    Text("This branch").font(.sySubheadline.weight(.semibold))
                    if let b = tab.git.branch { BranchTag(name: b) }
                }
                .textCase(nil)
            }
            Section {
                Picker("", selection: $scope) {
                    ForEach(PRListScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
                if let error { Text(error).font(.syCaption).foregroundStyle(Color.syRed) }
                if list.isEmpty, !listLoading, error == nil {
                    ListEmptyNote(title: scope == .mine ? "No pull requests by you" : "No \(scope.title.lowercased()) pull requests", compact: true)
                }
                ForEach(list) { item in row(item) }
            } header: {
                HStack {
                    Text(repo?.full ?? "").font(.sySubheadline.weight(.semibold))
                    Spacer()
                    RefreshStatus(updated: lastUpdated, refreshing: branchLoading || listLoading, error: branchError ?? error, compact: true) {
                        Task { await load() }
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.inset)
        .surface(.panel)
        .liveRefresh(updated: lastUpdated, refreshing: branchLoading || listLoading, footer: false, button: false) { await load() }
    }

    private func row(_ item: SearchItem, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                StateBadge(state: item.visualState, compact: true)
                Text(item.title).font(.syBody).lineLimit(2).fontWeight(.medium).foregroundStyle(Color.syText)
            }
            HStack(spacing: 6) {
                Text("#\(item.number)").foregroundStyle(Color.syMuted)
                Text(item.author?.login ?? "").foregroundStyle(Color.syMuted)
                CIIcon(state: item.ciState)
                if let a = item.additions, let d = item.deletions { DiffStat(additions: a, deletions: d) }
                if let note { Text(note).foregroundStyle(Color.syMuted) }
                Spacer()
                Text(Fmt.rel(item.updatedAt)).foregroundStyle(Color.syDim)
            }
            .font(.syCaption)
        }
        .padding(.vertical, 2)
        .rowAppear(item.id, rows)
        .contentShape(Rectangle())
        .onTapGesture { selected = item.ref }
        .contextMenu {
            Button("Open in PR section") { app.section = .prs(.mine); app.open(item.route) }
            Button("Open in browser") { openInBrowser(item.url) }
            Button("Copy link") { copyToPasteboard(item.url) }
            Button("Copy short link") { app.copyShortLink(item.ref) }
        }
    }

    private func load() async {
        async let b: Void = loadBranch()
        async let l: Void = loadList()
        _ = await (b, l)
    }

    private func loadBranch() async {
        guard let api = app.api, let repo else { return }
        let branch = tab.git.branch
        branchLoading = true
        defer { branchLoading = false }
        do {
            var found: [SearchItem] = []
            if let branch, branch != "HEAD" {
                found = try await api.repoPullRequests(repo, headRefName: branch, states: ["OPEN", "MERGED", "CLOSED"], first: 5)
            }
            var linkedItem: SearchItem?
            if let number = app.claude.sessionsByID[tab.sessionId]?.prNumber,
               !found.contains(where: { $0.number == number }) {
                linkedItem = try? await api.pullRequestItem(ItemRef(repo: repo, number: number))
            }
            guard branch == tab.git.branch, repo == self.repo else { return }
            rows.ingest((found + [linkedItem].compactMap { $0 }).map(\.id), mode: .refresh)
            branchPRs = found
            linked = linkedItem
            branchError = nil
            lastUpdated = Date()
        } catch {
            if isCancellation(error) { return }
            branchError = error.localizedDescription
        }
    }

    private func loadList() async {
        guard let api = app.api, let repo else { return }
        let scope = scope
        listLoading = true
        defer { listLoading = false }
        do {
            let items: [SearchItem]
            switch scope {
            case .open: items = try await api.repoPullRequests(repo, states: ["OPEN"])
            case .merged: items = try await api.repoPullRequests(repo, states: ["MERGED"])
            case .mine: items = try await api.search("repo:\(repo.full) is:pr author:@me sort:updated-desc").nodes
            }
            guard scope == self.scope, repo == self.repo else { return }
            rows.ingest(items.map(\.id), mode: listScope == scope ? .refresh : .cascade)
            listScope = scope
            list = items
            error = nil
            lastUpdated = Date()
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }
}

struct ForgeBranchPanel: View {
    @Environment(AppModel.self) private var app
    let tab: ClaudeTab
    let remote: GitRemote
    @State private var items: [SearchItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var lastUpdated: Date?

    private var client: ForgeClient? {
        guard let forge = app.forge, forge.host.lowercased() == remote.host.lowercased() else { return nil }
        return forge
    }

    private var kind: GitRemote.Kind { remote.kind(for: client?.provider) }
    private var noun: String { remote.requestNoun(kind) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let b = tab.git.branch, b != "HEAD" {
                        HStack(spacing: 8) {
                            Button("Open \(kind == .gitlab ? "MR" : "PR") with Agent") {
                                app.claude.send(AgentShip.openPRPrompt(branch: b, defaultBranch: nil, hasChanges: !tab.git.changes.isEmpty, ahead: tab.git.ahead, remote: remote.with(kind: kind)), to: tab)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.syAgentFill)
                            .disabled(tab.busy)
                            Button("Create in Browser") { openInBrowser(remote.newRequestURL(branch: b, kind: kind)) }
                        }
                        .controlSize(.small)
                    }
                    Button("Open \(remote.with(kind: kind).service)") { openInBrowser(remote.webURL) }
                        .buttonStyle(.link)
                        .font(.syCaption)
                }
                .padding(.vertical, 4)
            } header: {
                HStack(spacing: 6) {
                    Text("This branch").font(.sySubheadline.weight(.semibold))
                    if let b = tab.git.branch { BranchTag(name: b) }
                }
                .textCase(nil)
            }
            Section {
                if client == nil {
                    Text("Switch to an account on \(remote.host) to list your \(noun)s here.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                }
                if let error { Text(error).font(.syCaption).foregroundStyle(Color.syRed) }
                if client != nil, items.isEmpty, !loading, error == nil {
                    ListEmptyNote(title: "No open \(noun)s by you or awaiting your review", compact: true)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 6) {
                            StateBadge(state: item.visualState, compact: true)
                            Text(item.title).font(.syBody).lineLimit(2).fontWeight(.medium).foregroundStyle(Color.syText)
                        }
                        HStack(spacing: 6) {
                            Text("#\(item.number)").foregroundStyle(Color.syMuted)
                            Text(item.author?.login ?? "").foregroundStyle(Color.syMuted)
                            Spacer()
                            Text(Fmt.rel(item.updatedAt)).foregroundStyle(Color.syDim)
                        }
                        .font(.syCaption)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { openInBrowser(item.url) }
                    .contextMenu {
                        Button("Open in browser") { openInBrowser(item.url) }
                        Button("Copy link") { copyToPasteboard(item.url) }
                    }
                }
            } header: {
                HStack {
                    Text(remote.path).font(.sySubheadline.weight(.semibold))
                    Spacer()
                    RefreshStatus(updated: lastUpdated, refreshing: loading, error: error, compact: true) {
                        Task { await load() }
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.inset)
        .surface(.panel)
        .task(id: "\(remote.host)/\(remote.path)|\(client == nil)") { await load() }
        .onLiveTick { await load() }
        .onChange(of: tab.busy) { _, busy in if !busy { Task { await load() } } }
    }

    private func load() async {
        guard let client else {
            items = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            var found: [SearchItem] = []
            for filter in [PRFilter.mine, .reviewRequested] where app.forgeCaps.pullFilters.contains(filter) {
                found += try await client.pullRequests(filter, state: .open)
            }
            let path = remote.path.lowercased()
            var seen = Set<String>()
            items = found.filter { $0.repository.nameWithOwner.lowercased() == path && seen.insert($0.id).inserted }
            error = nil
            lastUpdated = Date()
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }
}

struct InspectorPRDetail: View {
    @Environment(AppModel.self) private var app
    let tab: ClaudeTab
    let ref: ItemRef
    let onBack: () -> Void
    @State private var model: PRDetailModel?
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                if let model {
                    RefreshStatus(updated: model.lastUpdated, refreshing: model.loading, error: model.refreshError, compact: true) {
                        Task { await model.load(full: true) }
                    }
                }
                Button { openInBrowser("https://github.com/\(ref.repo.full)/pull/\(ref.number)") } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                    .accessibilityLabel("Open in browser")
                Button("Open full") { app.section = .prs(.mine); app.open(.pr(ref)) }
                    .controlSize(.small)
            }
            .padding(10)
            ClaudeHairline()
            if let pr = model?.pr {
                ScrollView { content(pr).padding(12) }
                    .liveRefresh(updated: model?.lastUpdated, refreshing: model?.loading ?? false, footer: false, button: false) { await model?.load(full: true) }
            } else if let e = model?.error {
                ErrorStateView(message: e) { Task { await model?.load() } }
            } else {
                LoadingView()
            }
        }
        .task(id: ref) {
            model?.inspectorFilesVisible = false
            let m = app.prModel(ref)
            model = m
            m?.inspectorFilesVisible = showFiles
            await m?.load(live: m?.pr != nil)
        }
        .onLiveTick { await model?.load(live: true) }
        .onChange(of: app.refreshTick) { Task { await model?.load(full: true) } }
        .onChange(of: tab.busy) { _, busy in if !busy { Task { await model?.load(live: true) } } }
        .alert("Error", isPresented: Binding(get: { model?.actionError != nil }, set: { if !$0 { model?.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model?.actionError ?? "")
        }
    }

    @ViewBuilder
    private func content(_ pr: PullRequestDetail) -> some View {
        let unresolved = pr.reviewThreads.nodes.filter { !$0.isResolved }
        let fix = FixPromptExtractor.latest(in: pr)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title).font(.syHeadline).textSelection(.enabled)
                HStack(spacing: 6) {
                    StateBadge(state: pr.visualState)
                    Text("#\(pr.number)").foregroundStyle(Color.syMuted)
                    DiffStat(additions: pr.additions, deletions: pr.deletions)
                }
                HStack(spacing: 4) {
                    BranchTag(name: pr.baseRefName)
                    Image(systemName: "arrow.left").font(.syCaption2).foregroundStyle(Color.syMuted)
                    BranchTag(name: pr.headRefName)
                }
            }
            if let m = model, pr.isOpen {
                MergeStatusBar(model: m, pr: pr, onMerge: { app.section = .prs(.mine); app.open(.pr(ref)) })
                ReReviewBanner(model: m, pr: pr, inset: false) { app.section = .prs(.mine); app.open(.pr(ref)) }
            }
            HStack(spacing: 14) {
                let checks = pr.checks
                Label("\(checks.filter { $0.outcome == .success }.count)/\(checks.count)", systemImage: "checklist")
                    .foregroundStyle(checks.contains { $0.outcome == .failure } ? Color.syRed : Color.syMuted)
                    .accessibilityLabel("\(checks.filter { $0.outcome == .success }.count) of \(checks.count) checks passed")
                Label("\(unresolved.count)", systemImage: "text.bubble")
                    .foregroundStyle(unresolved.isEmpty ? Color.syMuted : Color.syAmber)
                    .help("Unresolved comments")
                    .accessibilityLabel("\(unresolved.count) unresolved comments")
                if !model!.reviewers.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(model!.reviewers, id: \.login) { ReviewerBadge(login: $0.login, avatar: $0.avatar, state: $0.state) }
                    }
                }
            }
            .font(.syCaption)
            if tab.chat != nil || tab.running {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Send to this session").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                    if let fix {
                        Button {
                            app.claude.send(FixPromptExtractor.wrap(fix, pr: pr, options: FixOptions()), to: tab)
                        } label: {
                            Label("Fix prompt by @\(fix.author)", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Button {
                        app.claude.send(FixPrompt.build(pr: pr, repo: ref.repo, threads: unresolved, general: FixPrompt.generalFeedback(pr), options: FixOptions()), to: tab)
                    } label: {
                        Label("Unresolved comments (\(unresolved.count))", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(unresolved.isEmpty)
                    Button {
                        app.claude.send("Review PR #\(pr.number) (\(pr.url)) and briefly summarize what it does and any problems.", to: tab)
                    } label: {
                        Label("Ask Claude to review this PR", systemImage: "text.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tint(.syAgentFill)
                }
                .controlSize(.small)
            }
            if !unresolved.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unresolved comments").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                    ForEach(unresolved) { th in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(th.path)\((th.line ?? th.originalLine).map { ":\($0)" } ?? "")")
                                .font(.syCaption.monospaced()).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.head)
                            if let c = th.comments.nodes.first {
                                HStack(alignment: .top, spacing: 5) {
                                    Avatar(url: c.author?.avatarUrl, size: 14)
                                    MarkdownText(text: c.body).font(.syCallout).lineLimit(4)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: 8, fill: .sySunken)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showFiles) {
                VStack(alignment: .leading, spacing: 3) {
                    if let m = model, m.filesLoaded {
                        ForEach(m.files) { f in
                            HStack(spacing: 6) {
                                Text(f.statusLetter).font(.syCaption2.weight(.bold).monospaced()).foregroundStyle(Color.syMuted)
                                Text(f.id).font(.syCaption.monospaced()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                DiffStat(additions: f.additions, deletions: f.deletions)
                            }
                        }
                    } else {
                        PullYardLoader(size: 28).frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Files changed · \(pr.changedFiles)").font(.syCaption.weight(.semibold))
            }
            .onChange(of: showFiles) { _, open in model?.inspectorFilesVisible = open }
            .onDisappear { model?.inspectorFilesVisible = false }
        }
    }
}

struct AgentBranchMenu: View {
    /// How much of the label to show; the control bar falls back to a
    /// shorter one when the full label doesn't fit its column.
    enum Style { case full, compact, minimal }

    let tab: ClaudeTab
    let pr: (number: Int, url: String)?
    var style: Style = .full
    @Environment(AppModel.self) private var app
    @State private var hover = false

    var body: some View {
        let git = tab.git
        if git.isRepo, let branch = git.branch {
            Menu {
                Section("Switch branch") {
                    ForEach(git.localBranches.prefix(20), id: \.self) { b in
                        Button { switchTo(b) } label: {
                            if b == branch { Label(b, systemImage: "checkmark") } else { Text(b) }
                        }
                        .disabled(b == branch || tab.state == .working)
                    }
                }
                Button("New Branch…") { newBranch() }
                    .disabled(tab.state == .working)
                Divider()
                if branch != "HEAD" {
                    Button("Copy Branch Name") { copyToPasteboard(branch) }
                }
                if let worktree = git.worktree {
                    Button("Reveal Worktree “\(worktree)” in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.folder)]) }
                }
                if let pr {
                    Button("Open Pull Request #\(pr.number)") {
                        if let r = GitHubURL.parse(pr.url) { app.section = .prs(.mine); app.open(r) }
                    }
                    if !git.changes.isEmpty {
                        Button("Commit and Push with Agent") { app.claude.send(AgentShip.commitPrompt(pr: pr.number), to: tab) }
                            .disabled(tab.state == .working)
                    }
                } else if branch != "HEAD", let remote = git.remote {
                    Button(remote.kind == .gitlab ? "Open Merge Request with Agent" : "Open Pull Request with Agent") {
                        app.claude.send(AgentShip.openPRPrompt(branch: branch, defaultBranch: nil, hasChanges: !git.changes.isEmpty, ahead: git.ahead, remote: remote), to: tab)
                    }
                    .disabled(tab.state == .working)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    if style != .minimal {
                        Text(branch == "HEAD" ? "Detached HEAD" : branch).lineLimit(1).truncationMode(.middle).frame(maxWidth: style == .full ? 240 : 150, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if let worktree = git.worktree {
                        if style != .minimal { Text("·").foregroundStyle(Color.syDim) }
                        Image(systemName: "square.stack.3d.up").imageScale(.small)
                        if style == .full {
                            Text(worktree).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let pr, style != .minimal {
                        Text("·").foregroundStyle(Color.syDim)
                        Text("#\(pr.number)")
                    }
                    Image(systemName: "chevron.down").font(.syCaption2.weight(.semibold)).foregroundStyle(Color.syDim)
                }
                .font(.syCallout)
                .foregroundStyle(Color.syMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.syText.opacity(hover ? 0.08 : 0.04)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hover = $0 }
            .help(branch + (git.worktree.map { " · worktree " + $0 } ?? "") + (pr.map { " · #\($0.number)" } ?? ""))
        }
    }

    private func switchTo(_ branch: String, create: Bool = false) {
        Task {
            if let error = await tab.git.switchBranch(branch, create: create) {
                let alert = NSAlert()
                alert.messageText = "Couldn't switch to \(branch)"
                alert.informativeText = error
                alert.runModal()
            }
        }
    }

    private func newBranch() {
        let alert = NSAlert()
        alert.messageText = "New branch"
        alert.informativeText = "Creates the branch from the current HEAD and switches to it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "feature/name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switchTo(name, create: true)
    }
}

struct Collapsible<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: () -> Content
    @State private var mounted: Bool
    @State private var unmount: DispatchWorkItem?

    init(open: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.content = content
        _mounted = State(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mounted || open { content() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: open ? nil : 0, alignment: .top)
        .clipped()
        .opacity(open ? 1 : 0)
        .onChange(of: open) { _, now in
            unmount?.cancel()
            if now {
                mounted = true
            } else {
                let item = DispatchWorkItem { mounted = false }
                unmount = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
            }
        }
    }
}

private struct ClaudeTabChip: View {
    let tab: ClaudeTab
    let selected: Bool
    var pinned = false
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let ws = app.claude
        let waiting = tab.state == .waiting
        HStack(spacing: 6) {
            if pinned {
                Image(systemName: "pin.fill").font(.syCaption2).foregroundStyle(Color.syDim)
            }
            SessionStateGlyph(state: tab.state)
            Text(tab.title)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .foregroundStyle(selected ? Color.syText : Color.syMuted)
                .fontWeight(selected ? .medium : .regular)
            AgentAccountChip(profile: tab.profile, compact: true)
            if waiting {
                Text("Needs you")
                    .font(.sy(size: 10, weight: .semibold))
                    .foregroundStyle(Color.syCoralInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.syCoral.opacity(0.14)))
            } else {
                Text(tab.projectName).font(.syCaption).foregroundStyle(Color.syDim).lineLimit(1)
            }
            Button { ws.requestClose(tab) } label: { Image(systemName: "xmark").font(.syCaption2.weight(.bold)).frame(width: 16, height: 16).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.syMuted)
                .opacity(selected || hovering ? 1 : 0)
                .help("Close \(tab.title)")
                .accessibilityLabel("Close \(tab.title)")
        }
        .font(.syCallout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Radius.m)
                .fill(selected ? Color.syRaised : (hovering ? Color.syHover : Color.clear))
                .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 4, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.m)
                .strokeBorder(selected ? Color.syLineStrong : (waiting ? Color.syCoral.opacity(0.4) : Color.clear))
        }
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(Color.syAgentAccent).frame(height: 2).padding(.horizontal, 10).offset(y: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ws.selectedTabID = tab.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { AgentTabMenu.rename(tab, ws: ws) })
        .contextMenu { AgentTabMenu(tab: tab, ws: ws) }
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.micro)) { hovering = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.title), \(tab.projectName), \(tab.state.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { ws.selectedTabID = tab.id }
    }
}

struct InspectorEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.syIcon(18))
                .foregroundStyle(Color.syAgentAccent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.syAgentAccent.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.syAgentAccent.opacity(0.2)))
            Text(title)
                .font(.system(size: TextZoom.shared.size(15), weight: .semibold, design: .serif))
                .foregroundStyle(Color.syText)
            Text(message)
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            HarborWaves().frame(width: 90, height: 12).opacity(0.7)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentAccountChip: View {
    let profile: ClaudeProfile?
    var compact = false

    static func color(for id: String) -> Color {
        let palette: [Color] = [.sySky, .syViolet, .syTeal, .syAmberInk, .syIndigo, .syCoralInk]
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[id == ClaudeProfiles.defaultID ? 0 : 1 + sum % (palette.count - 1)]
    }

    var body: some View {
        if ClaudeProfiles.shared.hasSeveral, let profile {
            let tint = Self.color(for: profile.id)
            Text(compact ? profile.initial : profile.label)
                .font(.sy(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, compact ? 5 : 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.14)))
                .help(profile.email.map { "\(profile.label) · \($0)" } ?? profile.label)
                .accessibilityLabel("Account \(profile.label)")
        }
    }
}

struct AgentAccountFilter: View {
    @Environment(AppModel.self) private var app
    var onOpenProject: (ClaudeProfile) -> Void = { _ in }

    var body: some View {
        let ws = app.claude
        HStack(spacing: 4) {
            filterButton(title: "All", id: nil, tint: .syMuted, selected: ws.accountFilter == nil)
            ForEach(ClaudeProfiles.shared.visible) { p in
                filterButton(title: AgentAccountFilter.name(p), id: p.id, tint: AgentAccountChip.color(for: p.id), selected: ws.accountFilter == p.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenProject(p) })
                    .contextMenu {
                        Button("Open project as \(p.label)…") { onOpenProject(p) }
                        Button("Rename “\(p.label)”…") { AgentRename.account(p) }
                        if p.id != ClaudeProfiles.shared.activeID {
                            Divider()
                            Button("Make default for new sessions") { app.switchClaudeProfile(to: p.id) }
                        }
                    }
            }
            Spacer(minLength: 0)
        }
    }

    static func name(_ p: ClaudeProfile) -> String {
        let twins = ClaudeProfiles.shared.visible.filter { $0.label == p.label }.count > 1
        guard twins, let user = p.email?.split(separator: "@").first else { return p.label }
        return "\(p.label) · \(user)"
    }

    private func filterButton(title: String, id: String?, tint: Color, selected: Bool) -> some View {
        Button {
            app.claude.accountFilter = id
            if let id { app.switchClaudeProfile(to: id) }
        } label: {
            HStack(spacing: 4) {
                if id != nil { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(title).lineLimit(1)
            }
            .font(.syCaption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.syText : Color.syMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.syRaised : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.syLineStrong : Color.syLine))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(id == nil ? "Sessions from all accounts" : "Only sessions from \(title). Double-click to open a project as \(title).")
    }
}
