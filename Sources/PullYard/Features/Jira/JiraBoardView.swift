import SwiftUI

/// What one Jira account's board looked like the last time it was fetched.
struct JiraBoardSnapshot: Codable, Equatable {
    var boards: [JiraBoard] = []
    var board: JiraBoard?
    var columns: [JiraBoardColumn] = []
    var sprint: JiraSprint?
    var issues: [JiraIssue] = []
    var fetchedAt: Date?
    /// The connected Jira user, so "you" is in the people filter even with nothing assigned.
    var meName: String?
    var meAvatar: String?
}

/// Loads Jira boards per account. Every fetch is cached in memory and on disk, so switching
/// accounts or coming back to the section shows the last board at once while a fresh fetch runs.
@MainActor
@Observable
final class JiraBoardModel {
    static let shared = JiraBoardModel()
    static let connectionKey = "jira.board.connection"
    static func boardKey(_ connection: String) -> String { "jira.board.selected.\(connection)" }

    private(set) var connectionID: String?
    private(set) var snap = JiraBoardSnapshot()
    private(set) var loading = false
    var error: String?
    var moving: Set<String> = []

    @ObservationIgnored private var cache: [String: JiraBoardSnapshot] = [:]
    @ObservationIgnored private var generation = 0
    private let directory: URL

    var boards: [JiraBoard] { snap.boards }
    var board: JiraBoard? { snap.board }
    var columns: [JiraBoardColumn] { snap.columns }
    var sprint: JiraSprint? { snap.sprint }
    var issues: [JiraIssue] { snap.issues }
    var loadedOnce: Bool { snap.fetchedAt != nil }
    var me: JiraPerson? {
        let name = snap.meName ?? JiraConnections.shared.connection(connectionID)?.displayName
        return name.map { JiraPerson(name: $0, avatar: snap.meAvatar) }
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullYard/jira-board", isDirectory: true)
        let saved = UserDefaults.standard.string(forKey: Self.connectionKey)
        let all = JiraConnections.shared.connections
        let id = all.contains { $0.id == saved } ? saved : all.first?.id
        connectionID = id
        if let id { snap = cached(id) }
    }

    private var client: JiraClient? { JiraConnections.shared.client(for: connectionID) }

    /// Switches account: shows that account's cached board right away; the caller fetches fresh data.
    func select(_ id: String?) {
        guard id != connectionID else { return }
        if let current = connectionID { cache[current] = snap }
        connectionID = id
        UserDefaults.standard.set(id, forKey: Self.connectionKey)
        snap = id.map(cached) ?? JiraBoardSnapshot()
        error = nil
        moving = []
    }

    /// Keeps the selected connection valid when connections are added or removed in Settings.
    func syncConnections() {
        let all = JiraConnections.shared.connections
        if connectionID == nil || !all.contains(where: { $0.id == connectionID }) {
            select(all.first?.id)
        }
    }

    func selectBoard(_ board: JiraBoard) async {
        guard let id = connectionID, board.id != snap.board?.id else { return }
        UserDefaults.standard.set(board.id, forKey: Self.boardKey(id))
        snap.board = board
        snap.columns = []
        snap.sprint = nil
        snap.issues = []
        await loadBoard()
    }

    /// Fetches the board list and the selected board again. Cached data stays on screen meanwhile.
    func refresh() async {
        guard let client, let id = connectionID else { return }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            async let who = try? client.me()
            let list = try await client.boards()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let me = await who
            guard id == connectionID else { return }
            if let me {
                snap.meName = me.name
                snap.meAvatar = me.avatar
            }
            snap.boards = list
            let saved = UserDefaults.standard.integer(forKey: Self.boardKey(id))
            let mine = Set(JiraConnections.shared.connection(id)?.projectKeys ?? [])
            snap.board = list.first { $0.id == snap.board?.id }
                ?? list.first { $0.id == saved }
                ?? list.first { $0.isScrum && $0.projectKey.map(mine.contains) == true }
                ?? list.first { $0.isScrum }
                ?? list.first
            if snap.board == nil { snap.fetchedAt = Date(); store(id) }
            error = nil
        } catch {
            if !(error is CancellationError), id == connectionID { self.error = error.localizedDescription }
            return
        }
        await loadBoard()
    }

    func loadBoard() async {
        guard let client, let board, let id = connectionID else { return }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            async let cols = client.columns(board: board.id)
            let sprints: [JiraSprint] = board.isScrum ? ((try? await client.activeSprints(board: board.id)) ?? []) : []
            let current = sprints.first
            let list = try await client.boardIssues(board: board.id, sprint: current?.id)
            let loadedColumns = (try? await cols) ?? []
            guard id == connectionID, board.id == snap.board?.id else { return }
            if !loadedColumns.isEmpty || snap.columns.isEmpty {
                snap.columns = loadedColumns.filter { !$0.statusIDs.isEmpty }
            }
            snap.sprint = current
            snap.issues = list.map { var i = $0; i.connectionID = id; return i }
            snap.fetchedAt = Date()
            store(id)
            error = nil
        } catch {
            if !(error is CancellationError), id == connectionID { self.error = error.localizedDescription }
        }
    }

    /// Issues for each column; if the board config could not be read, columns fall back to status names.
    func grouped(_ visible: [JiraIssue]) -> [(column: JiraBoardColumn, issues: [JiraIssue])] {
        if columns.isEmpty {
            var order: [String] = []
            var byStatus: [String: [JiraIssue]] = [:]
            for issue in visible {
                if byStatus[issue.status] == nil { order.append(issue.status) }
                byStatus[issue.status, default: []].append(issue)
            }
            return order.map { (JiraBoardColumn(name: $0, statusIDs: []), byStatus[$0] ?? []) }
        }
        return columns.map { column in
            (column, visible.filter { $0.statusID.map(column.statusIDs.contains) == true })
        }
    }

    /// Drops an issue on a column, before another card (`before`) or at the end of the column.
    /// A new column runs the first workflow transition that lands in it; the place in the column
    /// is saved as the issue's rank in Jira.
    func move(_ key: String, to column: JiraBoardColumn, before: String? = nil) async {
        guard let client, let id = connectionID, let issue = issues.first(where: { $0.key == key }), before != key else { return }
        let sameColumn = issue.statusID.map(column.statusIDs.contains) == true
        let columnKeys = issues.filter { $0.statusID.map(column.statusIDs.contains) == true && $0.key != key }.map(\.key)
        let after = before == nil ? columnKeys.last : nil
        if sameColumn, before == nil, columnKeys.last == nil { return }
        if sameColumn, let before, let i = columnKeys.firstIndex(of: before), i > 0, columnKeys[i - 1] == key { return }
        let undo = snap.issues
        // Optimistic: the card lands in its new column and place at once, with a spinner,
        // and goes back only if Jira refuses.
        withAnimation(Motion.smooth) {
            reorder(key, before: before, after: after)
            if !sameColumn, let i = snap.issues.firstIndex(where: { $0.key == key }), let target = column.statusIDs.first {
                snap.issues[i] = Self.with(snap.issues[i], status: column.name, category: issue.statusCategory, statusID: target)
            }
        }
        moving.insert(key)
        defer { moving.remove(key) }
        do {
            if !sameColumn {
                let transitions = try await client.transitions(key)
                guard let t = transitions.first(where: { $0.toID.map(column.statusIDs.contains) == true }) else {
                    if id == connectionID { withAnimation(Motion.smooth) { snap.issues = undo } }
                    error = "\(key) can't move to \(column.name) from \(issue.status) — the workflow has no such transition."
                    return
                }
                try await client.transition(key, to: t.id)
                guard id == connectionID, let i = snap.issues.firstIndex(where: { $0.key == key }) else { return }
                snap.issues[i] = Self.with(snap.issues[i], status: t.to, category: t.toCategory, statusID: t.toID)
            }
            do {
                try await client.rank(key, before: before, after: after)
            } catch where !sameColumn {
                // The status changed; a board that isn't ranked just keeps Jira's order.
            }
            if id == connectionID { store(id) }
            error = nil
        } catch {
            if id == connectionID { withAnimation(Motion.smooth) { snap.issues = undo } }
            self.error = error.localizedDescription
        }
    }

    private static func with(_ u: JiraIssue, status: String, category: String, statusID: String?) -> JiraIssue {
        JiraIssue(key: u.key, summary: u.summary, status: status, statusCategory: category,
                  type: u.type, priority: u.priority, assignee: u.assignee,
                  assigneeAvatar: u.assigneeAvatar, reporter: u.reporter,
                  description: u.description, url: u.url, updated: Date(),
                  parentKey: u.parentKey, parentSummary: u.parentSummary,
                  attachments: u.attachments, connectionID: u.connectionID,
                  statusID: statusID, labels: u.labels)
    }

    /// Local, optimistic reorder so the card lands where it was dropped before Jira answers.
    private func reorder(_ key: String, before: String?, after: String?) {
        guard let from = snap.issues.firstIndex(where: { $0.key == key }) else { return }
        let moved = snap.issues.remove(at: from)
        if let before, let to = snap.issues.firstIndex(where: { $0.key == before }) {
            snap.issues.insert(moved, at: to)
        } else if let after, let to = snap.issues.firstIndex(where: { $0.key == after }) {
            snap.issues.insert(moved, at: to + 1)
        } else {
            snap.issues.append(moved)
        }
    }

    func replace(_ issue: JiraIssue) {
        guard let id = connectionID, let i = snap.issues.firstIndex(where: { $0.key == issue.key }) else { return }
        var merged = issue
        merged.connectionID = id
        if merged.labels.isEmpty { merged.labels = snap.issues[i].labels }
        if merged.statusID == nil { merged.statusID = snap.issues[i].statusID }
        snap.issues[i] = merged
        store(id)
    }

    var boardURL: String? {
        guard let board, let base = JiraConnections.shared.connection(connectionID)?.baseURL else { return nil }
        return base.absoluteString + "/secure/RapidBoard.jspa?rapidView=\(board.id)"
    }

    // MARK: Cache

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id.filter { $0.isLetter || $0.isNumber || $0 == "-" }).json")
    }

    private func cached(_ id: String) -> JiraBoardSnapshot {
        if let hit = cache[id] { return hit }
        guard let data = try? Data(contentsOf: file(id)),
              let snapshot = try? JSONDecoder().decode(JiraBoardSnapshot.self, from: data) else { return JiraBoardSnapshot() }
        cache[id] = snapshot
        return snapshot
    }

    private func store(_ id: String) {
        cache[id] = snap
        let snapshot = snap
        let url = file(id)
        let dir = directory
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct JiraBoardView: View {
    @State private var model = JiraBoardModel.shared
    @State private var search = ""
    @State private var assignees: Set<String> = []
    @State private var showPeople = false
    @State private var opened: JiraIssue?
    @State private var work = JiraWorkModel.shared
    @AppStorage(JiraBoardTab.storageKey) private var tab: JiraBoardTab = .sprint
    @Environment(\.openSettings) private var openSettings

    private var connections: JiraConnections { .shared }

    var body: some View {
        Group {
            if !connections.isConfigured {
                notConnected
            } else {
                VStack(spacing: 0) {
                    header
                    switch tab {
                    case .sprint: content
                    case .backlog: backlogContent
                    case .list: listContent
                    }
                }
                .background { PYBackdrop(tints: boardTints).equatable() }
            }
        }
        .task(id: model.connectionID) { await model.refresh() }
        .task(id: workTaskID) { await loadWork() }
        .onChange(of: connections.connections.map(\.id)) { _, _ in model.syncConnections() }
        .onAppear { assignees = JiraBoardFilter.load(model.connectionID, me: model.me?.name) }
        .onChange(of: model.connectionID) { _, id in assignees = JiraBoardFilter.load(id, me: model.me?.name) }
        .onChange(of: model.me?.name) { _, name in
            // "Only me" by default, as soon as we know who "me" is; a saved choice wins.
            if !JiraBoardFilter.hasSaved(model.connectionID), let name { assignees = [name] }
        }
        .overlay {
            if let issue = opened {
                JiraIssueOverlay(issue: issue) {
                    withAnimation(Motion.fade) { opened = nil }
                } onChange: { model.replace($0); work.replace($0) }
                .id(issue.key)
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: opened?.key)
    }

    // MARK: Header

    private var header: some View {
        PYGlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if connections.hasSeveral {
                        JiraAccountTabs(selection: model.connectionID) { model.select($0) }
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    if loading { WakeLoader() }
                    HStack(spacing: 2) {
                        Button { Task { await refreshTab() } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 28, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh")
                        .keyboardShortcut("r", modifiers: .command)
                        .accessibilityLabel("Refresh board")
                        if let url = model.boardURL {
                            Button { openInBrowser(url) } label: {
                                Image(systemName: "arrow.up.right.square").frame(width: 28, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help("Open board in Jira")
                            .accessibilityLabel("Open board in Jira")
                        }
                    }
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 4)
                    .pyGlassCapsule(interactive: true)
                }
                HStack(spacing: 10) {
                    boardMenu
                    JiraBoardTabsBar(selection: $tab)
                    if tab == .sprint { sprintPill }
                    Spacer(minLength: 8)
                    assigneeFilter
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .pyGlassCapsule()
                    searchField
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var sprintPill: some View {
        let total = model.issues.count
        let done = model.issues.filter { $0.statusCategory == "done" }.count
        let progress = total == 0 ? 0 : Double(done) / Double(total)
        return Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.sprint == nil ? "arrow.triangle.2.circlepath" : "flag.checkered")
                    .foregroundStyle(model.sprint == nil ? Color.syMuted : Color.syAccent)
                Text(model.sprint?.name ?? "Refresh")
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                if total > 0 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.syText.opacity(0.10))
                        Capsule().fill(LinearGradient(colors: [.syAccent, .syGreen], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, 64 * progress))
                    }
                    .frame(width: 64, height: 5)
                    .animation(Motion.smooth, value: progress)
                    Text("\(done)/\(total)")
                        .monospacedDigit()
                        .foregroundStyle(Color.syMuted)
                        .contentTransition(.numericText())
                }
            }
            .font(.syCaption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pyGlassCapsule(interactive: true)
        .disabled(model.loading)
        .help(refreshHelp)
        .accessibilityLabel(model.sprint.map { "\($0.name), \(done) of \(total) done" } ?? "Refresh")
    }

    private var searchField: some View {
        PYSearchPill(text: $search, prompt: searchPrompt)
    }

    private var boardTints: [Color] {
        let count = max(model.columns.count, 1)
        return (0..<min(count, 4)).map { JiraStyle.columnTint(index: $0, count: count, issues: []) }
    }

    private var searchPrompt: String {
        switch tab {
        case .sprint: return "Search board"
        case .backlog: return "Search backlog"
        case .list: return "Search work"
        }
    }

    private var loading: Bool {
        switch tab {
        case .sprint: return model.loading
        case .backlog: return model.loading || work.loadingBacklog
        case .list: return model.loading || work.loadingList
        }
    }

    // MARK: Backlog and List

    private struct WorkTaskID: Equatable {
        let tab: JiraBoardTab
        let connection: String?
        let board: Int?
    }

    private var workTaskID: WorkTaskID { WorkTaskID(tab: tab, connection: model.connectionID, board: model.board?.id) }

    /// Shows the tab's cached data for this account and board at once, then fetches it fresh.
    private func loadWork() async {
        work.show(connection: model.connectionID, board: model.board)
        switch tab {
        case .sprint: break
        case .backlog: await work.loadBacklog()
        case .list: await work.loadList()
        }
    }

    private func refreshTab() async {
        switch tab {
        case .sprint: await model.refresh()
        case .backlog: await work.loadBacklog()
        case .list: await work.loadList()
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = work.error ?? model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.syCaption)
                .foregroundStyle(Color.syRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .onTapGesture { work.error = nil; model.error = nil }
        }
    }

    @ViewBuilder
    private var backlogContent: some View {
        if work.backlog.fetchedAt == nil, work.error == nil, model.board != nil || !model.loadedOnce {
            JiraBacklogSkeleton()
        } else if let error = work.error, work.backlog.fetchedAt == nil {
            PYEmptyState(title: "Couldn't load the backlog", message: error, aurora: false)
        } else if model.loadedOnce, model.boards.isEmpty {
            PYEmptyState(title: "No boards", message: "This Jira account has no boards you can see.", aurora: false)
        } else {
            VStack(spacing: 0) {
                errorBanner
                JiraBacklogView(
                    snapshot: work.backlog,
                    isScrum: model.board?.isScrum == true,
                    moving: work.moving,
                    assignees: assignees,
                    query: search,
                    onOpen: { opened = $0 },
                    onMove: { key, sprint in Task { await work.move(key, toSprint: sprint) } }
                )
                .equatable()
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if work.list.fetchedAt == nil, work.error == nil, model.board != nil || !model.loadedOnce {
            JiraListSkeleton()
        } else if let error = work.error, work.list.fetchedAt == nil {
            PYEmptyState(title: "Couldn't load work items", message: error, aurora: false)
        } else if model.loadedOnce, model.boards.isEmpty {
            PYEmptyState(title: "No boards", message: "This Jira account has no boards you can see.", aurora: false)
        } else if work.list.issues.isEmpty {
            PYEmptyState(title: "No work items", message: "This project has no work items yet.", aurora: false)
        } else {
            VStack(spacing: 0) {
                errorBanner
                JiraIssueListView(
                    issues: JiraIssueFilter.filter(work.list.issues, assignees: assignees, query: search),
                    total: work.list.issues.count,
                    hasMore: work.list.next != nil,
                    loadingMore: work.loadingMore,
                    onOpen: { opened = $0 },
                    onLoadMore: { Task { await work.loadMore() } }
                )
                .equatable()
            }
        }
    }

    private var boardMenu: some View {
        Menu {
            ForEach(model.boards) { board in
                Button {
                    Task { await model.selectBoard(board) }
                } label: {
                    if board.id == model.board?.id {
                        Label(boardLabel(board), systemImage: "checkmark")
                    } else {
                        Text(boardLabel(board))
                    }
                }
            }
        } label: {
            Text(model.board?.name ?? (model.loadedOnce ? "No boards" : "Loading…"))
                .font(.syTitle2.weight(.bold))
                .foregroundStyle(Color.syText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.boards.isEmpty)
        .help("Choose a board")
    }

    private var refreshHelp: String {
        var parts: [String] = []
        if let end = model.sprint?.endDate { parts.append("Sprint ends \(end.formatted(date: .abbreviated, time: .omitted))") }
        if let at = model.snap.fetchedAt { parts.append("Updated \(at.formatted(.relative(presentation: .named)))") }
        parts.append("Click to refresh")
        return parts.joined(separator: " · ")
    }

    private func boardLabel(_ board: JiraBoard) -> String {
        [board.name, board.projectKey, board.type.capitalized].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Everyone with an issue on the board, you first (even with nothing assigned), then by name.
    private var people: [JiraPerson] {
        var seen = Set<String>()
        var list = filterSource.compactMap { i -> JiraPerson? in
            guard let n = i.assignee, seen.insert(n).inserted else { return nil }
            return JiraPerson(name: n, avatar: i.assigneeAvatar)
        }
        for name in assignees where name != JiraPeopleFilter.unassigned && !seen.contains(name) && name != model.me?.name {
            list.append(JiraPerson(name: name, avatar: nil))
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let me = model.me {
            let mine = list.first { $0.name == me.name }
            list.removeAll { $0.name == me.name }
            list.insert(JiraPerson(name: me.name, avatar: me.avatar ?? mine?.avatar), at: 0)
        }
        return list
    }

    private var hasUnassigned: Bool { filterSource.contains { $0.assignee == nil } }

    /// The issues the current tab shows, whose assignees make up the people filter.
    private var filterSource: [JiraIssue] {
        switch tab {
        case .sprint: return model.issues
        case .backlog: return work.backlog.allIssues
        case .list: return work.list.issues
        }
    }

    private var assigneeFilter: some View {
        let all = people
        // Selected people come first so a choice made in the list stays visible.
        let ordered = all.filter { assignees.contains($0.name) } + all.filter { !assignees.contains($0.name) }
        let shown = Array(ordered.prefix(JiraPeopleFilter.inline))
        let hidden = all.count - shown.count
        let hiddenSelected = assignees.subtracting(shown.map(\.name)).count
        return HStack(spacing: -6) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, person in
                let on = assignees.contains(person.name)
                Button {
                    withAnimation(Motion.fade) { toggle(person.name) }
                } label: {
                    AvatarStackItem(selected: on) { JiraPersonAvatar(person: person, size: 26) }
                }
                .buttonStyle(.plain)
                .zIndex(on ? 100 : Double(shown.count - index))
                .help(on ? "Show everyone" : "Only \(person.name)")
                .accessibilityLabel(person.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if hidden > 0 || hasUnassigned {
                Button { showPeople.toggle() } label: {
                    AvatarStackItem(selected: hiddenSelected > 0 || showPeople) {
                        Group {
                            if hidden > 0 {
                                Text("+\(hidden)")
                                    .font(.system(size: hidden >= 10 ? 10 : 11, weight: .semibold).monospacedDigit())
                                    .minimumScaleFactor(0.7)
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
                            }
                        }
                        .foregroundStyle(Color.syText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.syRaised))
                        .overlay(Circle().strokeBorder(Color.syLineStrong))
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .help("All assignees")
                .accessibilityLabel("All assignees")
                .popover(isPresented: $showPeople, arrowEdge: .bottom) {
                    JiraPeopleFilter(people: all, me: model.me?.name, unassigned: hasUnassigned, selection: Binding(
                        get: { assignees },
                        set: { setAssignees($0) }
                    ))
                }
            }
            if !assignees.isEmpty {
                Button { withAnimation(Motion.fade) { setAssignees([]) } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .help("Clear assignee filter")
                .accessibilityLabel("Clear assignee filter")
            }
        }
    }

    private func toggle(_ name: String) {
        var next = assignees
        if next.contains(name) { next.remove(name) } else { next.insert(name) }
        setAssignees(next)
    }

    /// A choice the user made: applied and remembered for this Jira account.
    private func setAssignees(_ value: Set<String>) {
        assignees = value
        JiraBoardFilter.save(value, for: model.connectionID)
    }

    // MARK: Columns

    private var visibleIssues: [JiraIssue] {
        JiraIssueFilter.filter(model.issues, assignees: assignees, query: search)
    }

    @ViewBuilder
    private var content: some View {
        if model.issues.isEmpty, model.error == nil, model.loading || !model.loadedOnce {
            JiraBoardSkeleton(columns: model.columns.map(\.name))
        } else if let error = model.error, model.issues.isEmpty {
            PYEmptyState(title: "Couldn't load the board", message: error, aurora: false)
        } else if model.loadedOnce, model.boards.isEmpty {
            PYEmptyState(title: "No boards", message: "This Jira account has no boards you can see.", aurora: false)
        } else if model.issues.isEmpty, model.columns.isEmpty {
            PYEmptyState(title: "Nothing on this board", message: model.board?.isScrum == true ? "There is no active sprint, or it has no issues." : "This board has no open issues.", aurora: false)
        } else {
            VStack(spacing: 0) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.syCaption)
                        .foregroundStyle(Color.syRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .onTapGesture { model.error = nil }
                }
                ScrollView(.horizontal) {
                    let groups = model.grouped(visibleIssues)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(groups.enumerated()), id: \.element.column.id) { index, entry in
                            JiraBoardColumnView(column: entry.column, issues: entry.issues, tint: JiraStyle.columnTint(index: index, count: groups.count, issues: entry.issues), moving: model.moving, canDrop: !model.columns.isEmpty) { opened = $0 } onDrop: { key, before in
                                Task { await model.move(key, to: entry.column, before: before) }
                            }
                            .equatable()
                        }
                    }
                    .padding(18)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 14) {
            PYEmptyState(title: "Connect Jira", message: "Add a Jira account in Settings → Integrations to see your boards here.", aurora: false)
                .frame(maxHeight: 260)
            Button("Open Settings") {
                UserDefaults.standard.set("integrations", forKey: "settings.tab")
                openSettings()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tab per Jira connection, like the Claude account tabs in Agents.
struct JiraAccountTabs: View {
    let selection: String?
    let onSelect: (String) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(JiraConnections.shared.connections) { c in
                let selected = selection == c.id
                Button {
                    withAnimation(Motion.smooth) { onSelect(c.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "ticket.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.sySky)
                        Text(c.name).font(.syCaption.weight(selected ? .semibold : .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? Color.syText : Color.syMuted)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.syRaised)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.syLineStrong))
                                .matchedGeometryEffect(id: "selected", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.email.isEmpty ? c.host : "\(c.host) · \(c.email)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.syText.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.syLine))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jira accounts")
    }
}

struct JiraBoardColumnView: View, Equatable {
    let column: JiraBoardColumn
    let issues: [JiraIssue]
    var tint: Color = .sySky
    let moving: Set<String>
    let canDrop: Bool
    let onOpen: (JiraIssue) -> Void
    /// Dragged key, and the card it was dropped on (nil: the column's empty space, i.e. the end).
    let onDrop: (String, String?) -> Void
    @State private var targeted = false
    @State private var targetCard: String?
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    static func == (a: Self, b: Self) -> Bool {
        a.column == b.column && a.issues == b.issues && a.tint == b.tint && a.canDrop == b.canDrop
            && a.moving.filter { key in a.issues.contains { $0.key == key } } == b.moving.filter { key in b.issues.contains { $0.key == key } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PYGlowDot(color: tint)
                Text(column.name)
                    .font(.syCallout.weight(.semibold))
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PYCountBadge(count: issues.count, tint: tint)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    if issues.isEmpty { emptySlot }
                    ForEach(issues) { issue in
                        JiraBoardCard(issue: issue, busy: moving.contains(issue.key)) { onOpen(issue) }
                            .draggable(issue.key) {
                                JiraBoardCard(issue: issue) {}.frame(width: 268)
                            }
                            .overlay(alignment: .top) {
                                if targetCard == issue.key {
                                    Capsule()
                                        .fill(tint)
                                        .frame(height: 3)
                                        .shadow(color: tint.opacity(0.8), radius: 4)
                                        .offset(y: -6.5)
                                        .allowsHitTesting(false)
                                        .transition(.opacity)
                                }
                            }
                            .dropDestination(for: String.self) { keys, _ in
                                guard canDrop, let key = keys.first, key != issue.key else { return false }
                                onDrop(key, issue.key)
                                return true
                            } isTargeted: { on in
                                if on { targetCard = issue.key } else if targetCard == issue.key { targetCard = nil }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .animation(Motion.fade, value: targetCard)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 292)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(targeted ? 0.30 : (scheme == .dark ? 0.16 : 0.12)), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .allowsHitTesting(false)
        }
        .background(shape.fill(Color.syPanel.opacity(scheme == .dark ? 0.55 : 0.6)))
        .clipShape(shape)
        .overlay { shape.strokeBorder(targeted ? tint : Color.syLine, lineWidth: targeted ? 1.5 : 1) }
        .animation(Motion.fade, value: targeted)
        .dropDestination(for: String.self) { keys, _ in
            guard canDrop, let key = keys.first else { return false }
            onDrop(key, nil)
            return true
        } isTargeted: { targeted = canDrop && $0 }
    }

    private var emptySlot: some View {
        PYEmptySlot(title: "Nothing here", active: targeted, activeTitle: "Drop to move here", tint: tint)
    }
}

struct JiraBoardCard: View {
    let issue: JiraIssue
    var busy = false
    let onOpen: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    private var done: Bool { issue.statusCategory == "done" }

    var body: some View {
        let typeColor = JiraStyle.typeColor(issue.type)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: JiraStyle.typeIcon(issue.type))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(typeColor)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(typeColor.opacity(0.15)))
                    .help(issue.type ?? "Issue")
                Text(issue.key)
                    .font(.syCaption.weight(.semibold).monospaced())
                    .foregroundStyle(done ? Color.syDim : Color.syMuted)
                    .strikethrough(done)
                Spacer(minLength: 4)
                if busy { WakeLoader() }
                if let p = issue.priority {
                    Image(systemName: priorityIcon(p))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(JiraStyle.priorityColor(p))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(JiraStyle.priorityColor(p).opacity(0.12)))
                        .help("Priority: \(p)")
                }
            }
            Text(issue.summary)
                .font(.syBody.weight(.medium))
                .foregroundStyle(done ? Color.syMuted : Color.syText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 6) {
                if !issue.labels.isEmpty {
                    FlowLabels(labels: issue.labels)
                }
                Spacer(minLength: 4)
                if issue.assignee != nil {
                    Avatar(url: issue.assigneeAvatar, size: 22)
                        .overlay(Circle().strokeBorder(Color.white.opacity(scheme == .dark ? 0.18 : 0.9), lineWidth: 1.5))
                        .help(issue.assignee ?? "")
                } else {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.syDim)
                        .help("Unassigned")
                }
            }
        }
        .padding(12)
        .pyCardSurface(hover: hover, accent: typeColor)
        .opacity(busy ? 0.6 : 1)
        .contentShape(shape)
        // A tap gesture, not a Button: a Button swallows the mouse-down and the card could not be dragged.
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", onOpen)
        .onHover { h in withAnimation(Motion.fade) { hover = h } }
        .help("\(issue.key) · \(issue.status)")
        .contextMenu {
            Button("Open in Jira") { openInBrowser(issue.url) }
            Button("Copy Key") { copyToPasteboard(issue.key) }
            Button("Copy Link") { copyToPasteboard(issue.url) }
        }
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.status)")
    }

    private func priorityIcon(_ p: String) -> String {
        switch p.lowercased() {
        case "highest", "blocker", "critical": return "chevron.up.2"
        case "high", "major": return "chevron.up"
        case "medium": return "equal"
        case "low", "minor": return "chevron.down"
        default: return "chevron.down.2"
        }
    }
}

private struct FlowLabels: View {
    let labels: [String]

    var body: some View {
        ChipFlow(spacing: 4) { chips(labels) }
    }

    @ViewBuilder
    private func chips(_ list: [String]) -> some View {
        ForEach(list, id: \.self) { label in
            Text(label)
                .font(.syCaption2.weight(.medium))
                .foregroundStyle(Color.syIndigo)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.syIndigo.opacity(0.12)))
        }
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Full ticket for a board card, shown over the board. Clicking outside or pressing Esc closes it.
struct JiraIssueOverlay: View {
    let issue: JiraIssue
    let onClose: () -> Void
    let onChange: (JiraIssue) -> Void
    @State private var full: JiraIssue?
    @State private var error: String?
    @State private var implementing = false

    var body: some View {
        GeometryReader { geo in
            let maxHeight = max(320, geo.size.height - 64)
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Close")
                    .accessibilityAddTraits(.isButton)
                panel(maxHeight: maxHeight)
                    .frame(width: min(920, geo.size.width - 64))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.syRaised))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.syLineStrong))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction).hidden()
        }
        .task {
            guard let client = JiraConnections.shared.client(for: issue.connectionID) else { return }
            do {
                var loaded = try await client.issue(issue.key)
                loaded.connectionID = issue.connectionID
                full = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func panel(maxHeight: CGFloat) -> some View {
        if implementing {
            JiraImplementForm(issue: full ?? issue) {
                withAnimation(Motion.fade) { implementing = false }
            } onStarted: {
                onClose()
            }
            .frame(height: min(maxHeight, 860))
        } else {
            // Sized to the ticket, scrolling only when it is taller than the window.
            FitHeightLayout(maxHeight: maxHeight) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        JiraIssueCard(
                            issue: full ?? issue,
                            flat: true,
                            onImplement: { withAnimation(Motion.fade) { implementing = true } },
                            onClose: onClose,
                            loadingDetails: full == nil && error == nil,
                            editable: true
                        ) { updated in
                            full = updated
                            onChange(updated)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed)
                                .padding(.horizontal, 18).padding(.bottom, 12)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

/// Gives its one child (a ScrollView) the child's natural height, capped at `maxHeight`,
/// so a short ticket gets a short panel and a long one scrolls.
private struct FitHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width
        let natural = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}


struct JiraPerson: Identifiable, Hashable {
    let name: String
    let avatar: String?
    var id: String { name }

    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

struct JiraPersonAvatar: View {
    let person: JiraPerson
    var size: CGFloat = 24

    var body: some View {
        if person.avatar != nil {
            Avatar(url: person.avatar, size: size)
        } else {
            Text(person.initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.syIndigo))
        }
    }
}

/// The full assignee list behind the "+N" button: tick people to show only their issues.
struct JiraPeopleFilter: View {
    static let inline = 5
    static let unassigned = "\u{0}unassigned"

    let people: [JiraPerson]
    var me: String?
    let unassigned: Bool
    @Binding var selection: Set<String>
    @State private var query = ""

    private var filtered: [JiraPerson] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? people : people.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if people.count > 8 {
                TextField("Filter people", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { person in
                        row(key: person.name, title: person.name, note: person.name == me ? "you" : nil) { JiraPersonAvatar(person: person, size: 26) }
                    }
                    if unassigned, query.isEmpty {
                        row(key: Self.unassigned, title: "Unassigned") {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.syMuted)
                                .frame(width: 26, height: 26)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
            if !selection.isEmpty {
                Divider()
                Button("Clear") { selection = [] }
                    .buttonStyle(.borderless)
                    .padding(10)
            }
        }
        .frame(width: 300)
    }

    private func row<Icon: View>(key: String, title: String, note: String? = nil, @ViewBuilder icon: () -> Icon) -> some View {
        let on = selection.contains(key)
        return Button {
            if on { selection.remove(key) } else { selection.insert(key) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.syAccent : Color.syDim)
                    .font(.system(size: 16))
                icon()
                Text(title).font(.syBody).foregroundStyle(Color.syText).lineLimit(1)
                if let note {
                    Text(note)
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(Color.syAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.syAccent.opacity(0.14)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.syAccent.opacity(0.12) : Color.clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(JiraPeopleRowStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct JiraPeopleRowStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.syText.opacity(configuration.isPressed ? 0.1 : hover ? 0.06 : 0))
            .onHover { hover = $0 }
    }
}

/// Placeholder columns and cards shown while a board loads for the first time.
struct JiraBoardSkeleton: View {
    var columns: [String] = []

    var body: some View {
        let names = columns.isEmpty ? Array(repeating: "", count: 5) : columns
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        VStack(alignment: .leading, spacing: 10) {
                            Group {
                                if name.isEmpty {
                                    ShimmerBar(width: 90, height: 12)
                                } else {
                                    Text(name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syMuted)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                            ForEach(0..<max(1, 4 - index % 3), id: \.self) { card in
                                VStack(alignment: .leading, spacing: 8) {
                                    ShimmerBar(width: 64, height: 10)
                                    ShimmerBar(height: 11)
                                    ShimmerBar(width: card % 2 == 0 ? 170 : 120, height: 11)
                                    HStack {
                                        Spacer()
                                        Circle().fill(Color.syLine).frame(width: 22, height: 22)
                                    }
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.syRaised.opacity(0.8)))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.syLine))
                            }
                        }
                        .padding(10)
                        .frame(width: 292, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.syPanel.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.syLine))
                    }
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollDisabled(true)
        .accessibilityElement()
        .accessibilityLabel("Loading board")
    }
}

extension JiraStyle {
    static func columnTint(index: Int, count: Int, issues: [JiraIssue]) -> Color {
        if !issues.isEmpty {
            var tally: [String: Int] = [:]
            for i in issues { tally[i.statusCategory, default: 0] += 1 }
            switch tally.max(by: { $0.value < $1.value })?.key {
            case "done": return .syGreen
            case "indeterminate": return index.isMultiple(of: 2) ? .sySky : .syViolet
            default: return .sySlate
            }
        }
        if index == 0 { return .sySlate }
        if index == count - 1 { return .syGreen }
        return index.isMultiple(of: 2) ? .sySky : .syViolet
    }
}

/// One circle in an overlapping avatar stack: a clean gap ring around the picture, accent when selected.
struct AvatarStackItem<Content: View>: View {
    var selected = false
    var size: CGFloat = 26
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .padding(2)
            .background(Circle().fill(selected ? Color.syAccent : Color.syPanel))
            .scaleEffect(hover ? 1.08 : 1)
            .animation(Motion.fade, value: hover)
            .onHover { hover = $0 }
            .contentShape(Circle())
    }
}

/// The board's assignee filter per Jira account. With nothing saved it starts as "only me" —
/// the user the account was connected with — and after that it remembers the last choice.
enum JiraBoardFilter {
    static func key(_ connection: String) -> String { "jira.board.assignees.v2.\(connection)" }

    static func load(_ connection: String?, me: String?, defaults: UserDefaults = .standard) -> Set<String> {
        guard let connection else { return [] }
        if let saved = defaults.stringArray(forKey: key(connection)) { return Set(saved) }
        guard let me, !me.isEmpty else { return [] }
        return [me]
    }

    static func hasSaved(_ connection: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let connection else { return false }
        return defaults.object(forKey: key(connection)) != nil
    }

    static func save(_ value: Set<String>, for connection: String?, defaults: UserDefaults = .standard) {
        guard let connection else { return }
        defaults.set(value.sorted(), forKey: key(connection))
    }
}
