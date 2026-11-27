import SwiftUI

/// Loads one Jira board (columns, active sprint and its issues) for one connection.
@MainActor
@Observable
final class JiraBoardModel {
    static let connectionKey = "jira.board.connection"
    static func boardKey(_ connection: String) -> String { "jira.board.selected.\(connection)" }

    var connectionID: String? {
        didSet {
            guard connectionID != oldValue else { return }
            UserDefaults.standard.set(connectionID, forKey: Self.connectionKey)
            boards = []
            board = nil
            columns = []
            issues = []
            sprint = nil
            error = nil
        }
    }

    private(set) var boards: [JiraBoard] = []
    private(set) var board: JiraBoard?
    private(set) var columns: [JiraBoardColumn] = []
    private(set) var sprint: JiraSprint?
    private(set) var issues: [JiraIssue] = []
    private(set) var loading = false
    private(set) var loadedOnce = false
    var error: String?
    var moving: Set<String> = []

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.connectionKey)
        let all = JiraConnections.shared.connections
        connectionID = all.contains { $0.id == saved } ? saved : all.first?.id
    }

    private var client: JiraClient? { JiraConnections.shared.client(for: connectionID) }

    /// Keeps the selected connection valid when connections are added or removed in Settings.
    func syncConnections() {
        let all = JiraConnections.shared.connections
        if connectionID == nil || !all.contains(where: { $0.id == connectionID }) {
            connectionID = all.first?.id
        }
    }

    func selectBoard(_ board: JiraBoard) async {
        guard let id = connectionID else { return }
        UserDefaults.standard.set(board.id, forKey: Self.boardKey(id))
        self.board = board
        await loadBoard()
    }

    func load() async {
        guard let client, let id = connectionID else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            if boards.isEmpty {
                let list = try await client.boards()
                guard id == connectionID else { return }
                boards = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            if board == nil {
                let saved = UserDefaults.standard.integer(forKey: Self.boardKey(id))
                let mine = Set(JiraConnections.shared.connection(id)?.projectKeys ?? [])
                board = boards.first { $0.id == saved }
                    ?? boards.first { $0.isScrum && $0.projectKey.map(mine.contains) == true }
                    ?? boards.first { $0.isScrum }
                    ?? boards.first
            }
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return
        }
        await loadBoard()
    }

    func loadBoard() async {
        guard let client, let board, let id = connectionID else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            async let cols = client.columns(board: board.id)
            let sprints: [JiraSprint] = board.isScrum ? ((try? await client.activeSprints(board: board.id)) ?? []) : []
            let current = sprints.first
            let list = try await client.boardIssues(board: board.id, sprint: current?.id)
            let loadedColumns = (try? await cols) ?? []
            guard id == connectionID, board.id == self.board?.id else { return }
            columns = loadedColumns.filter { !$0.statusIDs.isEmpty }
            sprint = current
            issues = list.map { var i = $0; i.connectionID = id; return i }
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
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

    /// Moves an issue into a column by running the first workflow transition that lands in it.
    func move(_ key: String, to column: JiraBoardColumn) async {
        guard let client, let index = issues.firstIndex(where: { $0.key == key }) else { return }
        let issue = issues[index]
        if let status = issue.statusID, column.statusIDs.contains(status) { return }
        moving.insert(key)
        defer { moving.remove(key) }
        do {
            let transitions = try await client.transitions(key)
            guard let t = transitions.first(where: { $0.toID.map(column.statusIDs.contains) == true }) else {
                error = "\(key) can't move to \(column.name) from \(issue.status) — the workflow has no such transition."
                return
            }
            try await client.transition(key, to: t.id)
            if let i = issues.firstIndex(where: { $0.key == key }) {
                var updated = issues[i]
                updated = JiraIssue(key: updated.key, summary: updated.summary, status: t.to, statusCategory: t.toCategory,
                                    type: updated.type, priority: updated.priority, assignee: updated.assignee,
                                    assigneeAvatar: updated.assigneeAvatar, reporter: updated.reporter,
                                    description: updated.description, url: updated.url, updated: Date(),
                                    parentKey: updated.parentKey, parentSummary: updated.parentSummary,
                                    attachments: updated.attachments, connectionID: updated.connectionID,
                                    statusID: t.toID, labels: updated.labels)
                issues[i] = updated
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func replace(_ issue: JiraIssue) {
        guard let i = issues.firstIndex(where: { $0.key == issue.key }) else { return }
        var merged = issue
        merged.connectionID = connectionID
        if merged.labels.isEmpty { merged.labels = issues[i].labels }
        issues[i] = merged
    }

    var boardURL: String? {
        guard let board, let base = JiraConnections.shared.connection(connectionID)?.baseURL else { return nil }
        return base.absoluteString + "/secure/RapidBoard.jspa?rapidView=\(board.id)"
    }
}

struct JiraBoardView: View {
    @State private var model = JiraBoardModel()
    @State private var search = ""
    @State private var assignee: String?
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
        .task(id: model.connectionID) { await model.load() }
        .onChange(of: connections.connections.map(\.id)) { _, _ in model.syncConnections() }
        .onChange(of: model.connectionID) { _, _ in assignee = nil }
        .sheet(item: $opened) { issue in
            JiraBoardIssueSheet(issue: issue) { model.replace($0) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if connections.hasSeveral {
                    JiraAccountTabs(selection: $model.connectionID)
                        .frame(maxWidth: 480, alignment: .leading)
                }
                Spacer(minLength: 8)
                if model.loading { WakeLoader() }
                Button { Task { await model.loadBoard() } } label: { Image(systemName: "arrow.clockwise") }
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
                if let sprint = model.sprint {
                    Label(sprint.name, systemImage: "arrow.triangle.2.circlepath")
                        .font(.syCallout.weight(.medium))
                        .foregroundStyle(Color.syMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.syLine))
                        .help(sprint.endDate.map { "Ends \($0.formatted(date: .abbreviated, time: .omitted))" } ?? sprint.name)
                }
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

    private func boardLabel(_ board: JiraBoard) -> String {
        [board.name, board.projectKey, board.type.capitalized].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var people: [(name: String, avatar: String?)] {
        var seen = Set<String>()
        return model.issues.compactMap { i in
            guard let n = i.assignee, seen.insert(n).inserted else { return nil }
            return (n, i.assigneeAvatar)
        }.sorted { $0.name < $1.name }
    }

    private var assigneeFilter: some View {
        HStack(spacing: -4) {
            ForEach(people, id: \.name) { person in
                let on = assignee == person.name
                Button {
                    withAnimation(Motion.fade) { assignee = on ? nil : person.name }
                } label: {
                    Avatar(url: person.avatar, size: 24)
                        .overlay(Circle().strokeBorder(on ? Color.syAccent : Color.syPanel, lineWidth: 2))
                        .zIndex(on ? 1 : 0)
                }
                .buttonStyle(.plain)
                .help(on ? "Show everyone" : "Only \(person.name)")
                .accessibilityLabel(person.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Columns

    private var visibleIssues: [JiraIssue] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.issues.filter { i in
            (assignee == nil || i.assignee == assignee)
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
                            JiraBoardColumnView(column: entry.column, issues: entry.issues, moving: model.moving, canDrop: !model.columns.isEmpty) { opened = $0 } onDrop: { key in
                                Task { await model.move(key, to: entry.column) }
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
    @Binding var selection: String?
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(JiraConnections.shared.connections) { c in
                let selected = selection == c.id
                Button {
                    withAnimation(Motion.smooth) { selection = c.id }
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
    let onDrop: (String) -> Void
    @State private var targeted = false

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
            onDrop(key)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 14)
            ScrollView {
                JiraIssueCard(issue: full ?? issue) { updated in
                    full = updated
                    onChange(updated)
                }
                .padding(16)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).padding(.horizontal, 16)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 620)
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
