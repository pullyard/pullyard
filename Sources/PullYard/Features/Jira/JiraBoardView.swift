import SwiftUI

/// What one Jira account's board looked like the last time it was fetched.
struct JiraBoardSnapshot: Codable, Equatable {
    var boards: [JiraBoard] = []
    var board: JiraBoard?
    var columns: [JiraBoardColumn] = []
    var sprint: JiraSprint?
    var issues: [JiraIssue] = []
    var fetchedAt: Date?
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
            let list = try await client.boards()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard id == connectionID else { return }
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
        reorder(key, before: before, after: after)
        moving.insert(key)
        defer { moving.remove(key) }
        do {
            if !sameColumn {
                let transitions = try await client.transitions(key)
                guard let t = transitions.first(where: { $0.toID.map(column.statusIDs.contains) == true }) else {
                    snap.issues = undo
                    error = "\(key) can't move to \(column.name) from \(issue.status) — the workflow has no such transition."
                    return
                }
                try await client.transition(key, to: t.id)
                guard id == connectionID, let i = snap.issues.firstIndex(where: { $0.key == key }) else { return }
                let u = snap.issues[i]
                snap.issues[i] = JiraIssue(key: u.key, summary: u.summary, status: t.to, statusCategory: t.toCategory,
                                           type: u.type, priority: u.priority, assignee: u.assignee,
                                           assigneeAvatar: u.assigneeAvatar, reporter: u.reporter,
                                           description: u.description, url: u.url, updated: Date(),
                                           parentKey: u.parentKey, parentSummary: u.parentSummary,
                                           attachments: u.attachments, connectionID: u.connectionID,
                                           statusID: t.toID, labels: u.labels)
            }
            do {
                try await client.rank(key, before: before, after: after)
            } catch where !sameColumn {
                // The status changed; a board that isn't ranked just keeps Jira's order.
            }
            if id == connectionID { store(id) }
            error = nil
        } catch {
            if id == connectionID, sameColumn { snap.issues = undo }
            self.error = error.localizedDescription
        }
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
    @Environment(\.openSettings) private var openSettings

    private var connections: JiraConnections { .shared }

    var body: some View {
        Group {
            if !connections.isConfigured {
                notConnected
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .task(id: model.connectionID) { await model.refresh() }
        .onChange(of: connections.connections.map(\.id)) { _, _ in model.syncConnections() }
        .onChange(of: model.connectionID) { _, _ in assignees = [] }
        .sheet(item: $opened) { issue in
            JiraBoardIssueSheet(issue: issue) { model.replace($0) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if connections.hasSeveral {
                    JiraAccountTabs(selection: model.connectionID) { model.select($0) }
                        .frame(maxWidth: 480, alignment: .leading)
                }
                Spacer(minLength: 8)
                if model.loading { WakeLoader() }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityLabel("Refresh board")
                if let url = model.boardURL {
                    Button { openInBrowser(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help("Open board in Jira")
                        .accessibilityLabel("Open board in Jira")
                }
            }
            HStack(spacing: 10) {
                boardMenu
                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(model.loading ? 360 : 0))
                            .animation(model.loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.loading)
                        Text(model.sprint?.name ?? "Refresh")
                    }
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Color.syLine))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.loading)
                .help(refreshHelp)
                Spacer(minLength: 8)
                assigneeFilter
                TextField("Search board", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                .font(.syTitle3.weight(.semibold))
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

    private var people: [JiraPerson] {
        var seen = Set<String>()
        return model.issues.compactMap { i in
            guard let n = i.assignee, seen.insert(n).inserted else { return nil }
            return JiraPerson(name: n, avatar: i.assigneeAvatar)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hasUnassigned: Bool { model.issues.contains { $0.assignee == nil } }

    private var assigneeFilter: some View {
        let all = people
        // Selected people come first so a choice made in the list stays visible.
        let ordered = all.filter { assignees.contains($0.name) } + all.filter { !assignees.contains($0.name) }
        let shown = Array(ordered.prefix(JiraPeopleFilter.inline))
        let hidden = all.count - shown.count
        let hiddenSelected = assignees.subtracting(shown.map(\.name)).count
        return HStack(spacing: -5) {
            ForEach(shown) { person in
                let on = assignees.contains(person.name)
                Button {
                    withAnimation(Motion.fade) { toggle(person.name) }
                } label: {
                    JiraPersonAvatar(person: person, size: 26)
                        .overlay(Circle().strokeBorder(on ? Color.syAccent : Color.syPanel, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .zIndex(on ? 1 : 0)
                .help(on ? "Hide \(person.name)'s issues filter" : "Only \(person.name)")
                .accessibilityLabel(person.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if hidden > 0 || hasUnassigned {
                Button { showPeople.toggle() } label: {
                    Text(hidden > 0 ? "+\(hidden)" : "\u{2026}")
                        .font(.syCaption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.syText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.syRaised))
                        .overlay(Circle().strokeBorder(hiddenSelected > 0 || showPeople ? Color.syAccent : Color.syLineStrong, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.leading, 9)
                .help("All assignees")
                .accessibilityLabel("All assignees")
                .popover(isPresented: $showPeople, arrowEdge: .bottom) {
                    JiraPeopleFilter(people: all, unassigned: hasUnassigned, selection: $assignees)
                }
            }
            if !assignees.isEmpty {
                Button { withAnimation(Motion.fade) { assignees = [] } } label: {
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
        if assignees.contains(name) { assignees.remove(name) } else { assignees.insert(name) }
    }

    // MARK: Columns

    private var visibleIssues: [JiraIssue] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.issues.filter { i in
            (assignees.isEmpty || assignees.contains(i.assignee ?? JiraPeopleFilter.unassigned))
                && (q.isEmpty || i.key.lowercased().contains(q) || i.summary.lowercased().contains(q) || i.labels.contains { $0.lowercased().contains(q) })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error, model.issues.isEmpty {
            PYEmptyState(title: "Couldn't load the board", message: error, aurora: false)
        } else if model.loadedOnce, model.boards.isEmpty {
            PYEmptyState(title: "No boards", message: "This Jira account has no boards you can see.", aurora: false)
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
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.grouped(visibleIssues), id: \.column.id) { entry in
                            JiraBoardColumnView(column: entry.column, issues: entry.issues, moving: model.moving, canDrop: !model.columns.isEmpty) { opened = $0 } onDrop: { key, before in
                                Task { await model.move(key, to: entry.column, before: before) }
                            }
                        }
                    }
                    .padding(16)
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

struct JiraBoardColumnView: View {
    let column: JiraBoardColumn
    let issues: [JiraIssue]
    let moving: Set<String>
    let canDrop: Bool
    let onOpen: (JiraIssue) -> Void
    /// Dragged key, and the card it was dropped on (nil: the column's empty space, i.e. the end).
    let onDrop: (String, String?) -> Void
    @State private var targeted = false
    @State private var targetCard: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                Text("\(issues.count)").font(.syCallout.monospacedDigit()).foregroundStyle(Color.syMuted)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { issue in
                        JiraBoardCard(issue: issue, busy: moving.contains(issue.key)) { onOpen(issue) }
                            .draggable(issue.key)
                            .overlay(alignment: .top) {
                                if targetCard == issue.key {
                                    Capsule().fill(Color.syAccent).frame(height: 3).offset(y: -5.5).allowsHitTesting(false)
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
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(8)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.syText.opacity(targeted ? 0.08 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.syAccent : Color.clear, lineWidth: 1.5))
        .dropDestination(for: String.self) { keys, _ in
            guard canDrop, let key = keys.first else { return false }
            onDrop(key, nil)
            return true
        } isTargeted: { targeted = canDrop && $0 }
    }
}

struct JiraBoardCard: View {
    let issue: JiraIssue
    var busy = false
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                Text(issue.summary)
                    .font(.syBody)
                    .foregroundStyle(Color.syText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !issue.labels.isEmpty {
                    FlowLabels(labels: issue.labels)
                }
                HStack(spacing: 6) {
                    Image(systemName: JiraStyle.typeIcon(issue.type))
                        .font(.syCaption)
                        .foregroundStyle(JiraStyle.typeColor(issue.type))
                    Text(issue.key)
                        .font(.syCaption.weight(.semibold).monospaced())
                        .foregroundStyle(issue.statusCategory == "done" ? Color.syDim : Color.syMuted)
                        .strikethrough(issue.statusCategory == "done")
                    Spacer(minLength: 4)
                    if busy { WakeLoader() }
                    if let p = issue.priority {
                        Image(systemName: priorityIcon(p))
                            .font(.syCaption.weight(.bold))
                            .foregroundStyle(JiraStyle.priorityColor(p))
                            .help("Priority: \(p)")
                    }
                    if issue.assignee != nil {
                        Avatar(url: issue.assigneeAvatar, size: 22).help(issue.assignee ?? "")
                    } else {
                        Image(systemName: "person.crop.circle.dashed").foregroundStyle(Color.syDim).help("Unassigned")
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? Color.syLineStrong : Color.syLine))
            .contentShape(Rectangle())
            .opacity(busy ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips(labels) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(stride(from: 0, to: labels.count, by: 2)), id: \.self) { i in
                    HStack(spacing: 4) { chips(Array(labels[i..<min(i + 2, labels.count)])) }
                }
            }
        }
    }

    @ViewBuilder
    private func chips(_ list: [String]) -> some View {
        ForEach(list, id: \.self) { label in
            Text(label)
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.syLineStrong))
        }
    }
}

/// Full ticket for a board card: loads description and attachments, and lets the status be changed.
struct JiraBoardIssueSheet: View {
    let issue: JiraIssue
    let onChange: (JiraIssue) -> Void
    @State private var full: JiraIssue?
    @State private var error: String?
    @State private var implementing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if implementing {
                JiraImplementForm(issue: full ?? issue) {
                    withAnimation(Motion.fade) { implementing = false }
                } onStarted: {
                    dismiss()
                }
            } else {
                details
            }
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 640, idealHeight: 820)
        .background(Color.syRaised)
        .presentationBackground(Color.syRaised)
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
                        row(key: person.name, title: person.name) { JiraPersonAvatar(person: person, size: 26) }
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

    private func row<Icon: View>(key: String, title: String, @ViewBuilder icon: () -> Icon) -> some View {
        let on = selection.contains(key)
        return Button {
            if on { selection.remove(key) } else { selection.insert(key) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.syAccent : Color.syMuted)
                    .font(.system(size: 15))
                icon()
                Text(title).font(.syBody).foregroundStyle(Color.syText).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

private extension JiraBoardIssueSheet {
    var details: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 14)
            ScrollView {
                JiraIssueCard(issue: full ?? issue, flat: true, onImplement: { withAnimation(Motion.fade) { implementing = true } }) { updated in
                    full = updated
                    onChange(updated)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).padding(.horizontal, 16)
                }
            }
        }
    }
}
