import SwiftUI

enum JiraLook {
    static func statusColor(_ category: String) -> Color {
        switch category {
        case "done": MobileTheme.green
        case "indeterminate": MobileTheme.accent
        default: MobileTheme.slate
        }
    }

    static func typeSymbol(_ type: String?) -> String {
        let name = type?.lowercased() ?? ""
        if name.contains("bug") { return "ladybug.fill" }
        if name.contains("epic") { return "bolt.fill" }
        if name.contains("story") { return "bookmark.fill" }
        if name.contains("sub") { return "square.split.2x1.fill" }
        return "checkmark.square.fill"
    }

    static func typeColor(_ type: String?) -> Color {
        let name = type?.lowercased() ?? ""
        if name.contains("bug") { return MobileTheme.red }
        if name.contains("epic") { return MobileTheme.violet }
        if name.contains("story") { return MobileTheme.green }
        return MobileTheme.accent
    }

    static func prioritySymbol(_ priority: String) -> String {
        switch priority.lowercased() {
        case "highest", "blocker", "critical": "chevron.up.2"
        case "high", "major": "chevron.up"
        case "medium": "equal"
        case "low", "minor": "chevron.down"
        default: "chevron.down.2"
        }
    }

    static func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "highest", "blocker", "critical": MobileTheme.red
        case "high", "major": MobileTheme.coral
        case "medium": MobileTheme.amber
        default: MobileTheme.muted
        }
    }

    static func initials(_ name: String) -> String {
        name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

struct JiraBoardView: View {
    @ObservedObject private var store = JiraBoardStore.shared
    @ObservedObject private var jira = JiraStore.shared
    @AppStorage("jira.board.tab") private var tab: JiraBoardTab = .sprint
    @AppStorage("jira.board.onlyMe") private var onlyMe = true
    @State private var query = ""
    @State private var person: String?
    @State private var column: String?
    @State private var opened: JiraCard?
    @State private var collapsed: Set<String> = []

    var body: some View {
        Group {
            if !jira.isConfigured, !store.isDemo {
                PYEmptyState(title: "Connect Jira", message: "Add a Jira site in Settings, or pair with PullYard on your Mac to bring your Jira connections over.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BrandBackdrop())
            } else {
                VStack(spacing: 0) {
                    controls
                    if tab == .sprint {
                        JiraKanban(groups: store.grouped(store.sprintCards.filter(matches)), focus: $column, onOpen: { opened = $0 })
                            .overlay { overlayState }
                    } else {
                        content
                    }
                }
                .background(BrandBackdrop())
            }
        }
        .navigationTitle(store.board?.name ?? L("Jira board"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .searchable(text: $query, prompt: Text(searchPrompt))
        .task(id: "\(store.siteID ?? "")|\(store.board?.id ?? 0)|\(tab.rawValue)") { await store.load(tab) }
        .refreshable { await store.load(tab, force: true) }
        .environment(\.jiraRefresh, { await store.load(tab, force: true) })
        .sheet(item: $opened) { card in
            JiraCardSheet(key: card.key).pySheetStyle()
        }
        .onChange(of: tab) { column = nil }
    }

    private var searchPrompt: String {
        switch tab {
        case .sprint: L("Search board")
        case .backlog: L("Search backlog")
        case .list: L("Search work")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if jira.sites.count > 1 {
                    Picker("Jira site", selection: Binding(get: { store.siteID ?? jira.sites.first?.id ?? "" }, set: { store.select(site: $0) })) {
                        ForEach(jira.sites) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Board", selection: Binding(get: { store.board?.id ?? 0 }, set: { id in
                    if let next = store.boards.first(where: { $0.id == id }) { store.select(board: next) }
                })) {
                    ForEach(store.boards) { board in
                        Text([board.name, board.projectKey].compactMap { $0 }.joined(separator: " · ")).tag(board.id)
                    }
                }
            } label: {
                Image(systemName: "rectangle.split.3x1")
            }
            .disabled(store.boards.isEmpty)
            .accessibilityLabel("Choose a board")
        }
    }

    private func matches(_ card: JiraCard) -> Bool {
        if let person {
            if card.assignee ?? JiraBoardStore.unassigned != person { return false }
        } else if onlyMe, let me = store.me, card.assignee != me {
            return false
        }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        return card.key.lowercased().contains(text) || card.summary.lowercased().contains(text) || card.labels.contains { $0.lowercased().contains(text) }
    }

    private var people: [String] {
        let source: [JiraCard]
        switch tab {
        case .sprint: source = store.sprintCards
        case .backlog: source = store.backlog.flatMap(\.cards)
        case .list: source = store.list
        }
        return Array(Set(source.compactMap(\.assignee))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $tab) {
                ForEach(JiraBoardTab.allCases) { Text(L($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            filterBar
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .mobileFont(size: 13).foregroundStyle(MobileTheme.red)
                    .padding(.horizontal, 16)
                    .onTapGesture { store.error = nil }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var overlayState: some View {
        if store.loading && !loaded {
            PullYardLoader(title: L("Loading Jira…"))
        } else if loaded, store.boards.isEmpty {
            PYEmptyState(title: "No boards", message: "This Jira site has no boards you can see.")
        } else if loaded, tab == .sprint, store.sprintCards.isEmpty {
            PYEmptyState(title: "Nothing on this board", message: store.board?.isScrum == true ? "There is no active sprint, or it has no issues." : "This board has no open issues.")
        }
    }

    private var content: some View {
        List {
            switch tab {
            case .sprint: EmptyView()
            case .backlog: backlogSections
            case .list: listSection
            }
        }
        .pyListStyle()
        .listSectionSpacing(14)
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay { overlayState }
    }

    private var loaded: Bool {
        switch tab {
        case .sprint: store.loadedSprint
        case .backlog: store.loadedBacklog
        case .list: store.loadedList
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if store.me != nil {
                    Chip(title: "Only me", symbol: "person.fill", isSelected: onlyMe && person == nil) {
                        person = nil
                        onlyMe.toggle()
                    }
                }
                Menu {
                    Button("Everyone") { person = nil; onlyMe = false }
                    ForEach(people, id: \.self) { name in
                        Button(name) { person = name }
                    }
                    Button("Unassigned") { person = JiraBoardStore.unassigned }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").mobileFont(size: 12, weight: .semibold)
                        Text(person == nil ? L("People") : (person == JiraBoardStore.unassigned ? L("Unassigned") : person ?? ""))
                            .mobileFont(size: 14, weight: .semibold).lineLimit(1)
                        Image(systemName: "chevron.down").mobileFont(size: 10, weight: .bold)
                    }
                    .foregroundStyle(person == nil ? MobileTheme.ink : Color.white)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .pyGlassCapsule(tint: person == nil ? nil : MobileTheme.accent, interactive: true, fallback: person == nil ? MobileTheme.card : MobileTheme.accent)
                }
                if tab == .sprint, let sprint = store.sprint {
                    let done = store.sprintCards.filter { $0.statusCategory == "done" }.count
                    HStack(spacing: 6) {
                        Image(systemName: "flag.checkered").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.accent)
                        Text(sprint.name).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                        Text("\(done)/\(store.sprintCards.count)").mobileFont(size: 12, weight: .bold, design: .rounded).foregroundStyle(MobileTheme.muted).monospacedDigit()
                    }
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .pyGlassCapsule(fallback: MobileTheme.card)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var sprintSections: some View {
        let groups = store.grouped(store.sprintCards.filter(matches))
        if store.loadedSprint {
            if groups.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Chip(title: "All", count: groups.reduce(0) { $0 + $1.cards.count }, isSelected: column == nil) { column = nil }
                            ForEach(groups, id: \.column.id) { group in
                                Chip(title: group.column.name, count: group.cards.count, isSelected: column == group.column.id) {
                                    column = column == group.column.id ? nil : group.column.id
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            ForEach(groups.filter { column == nil || $0.column.id == column }, id: \.column.id) { group in
                cardSection(id: "col." + group.column.id, title: group.column.name, subtitle: nil, cards: group.cards, tint: tint(group.cards))
            }
            if store.sprintCards.isEmpty {
                emptyRow(store.board?.isScrum == true ? "There is no active sprint, or it has no issues." : "This board has no open issues.")
            }
        }
    }

    @ViewBuilder
    private var backlogSections: some View {
        if store.loadedBacklog {
            ForEach(store.backlog) { group in
                cardSection(id: group.id, title: group.title, subtitle: group.subtitle, cards: group.cards.filter(matches), tint: group.active ? MobileTheme.accent : MobileTheme.slate)
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if store.loadedList {
            let cards = store.list.filter(matches)
            Section {
                ForEach(cards) { row($0, showStatus: true) }
                if cards.isEmpty { emptyRow("Nothing matches.") }
                if store.hasMoreList {
                    HStack {
                        Spacer()
                        if store.loadingMore { PullYardLoader(size: 22) } else { Text("Load more").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.accent) }
                        Spacer()
                    }
                    .pyRow()
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await store.loadMoreList() } }
                    .onAppear { Task { await store.loadMoreList() } }
                }
            } header: {
                Text(String(format: L("%d of %d work items"), store.list.count, store.listTotal)).textCase(nil)
            }
        }
    }

    private func tint(_ cards: [JiraCard]) -> Color {
        var tally: [String: Int] = [:]
        for card in cards { tally[card.statusCategory, default: 0] += 1 }
        return JiraLook.statusColor(tally.max { $0.value < $1.value }?.key ?? "new")
    }

    private func cardSection(id: String, title: String, subtitle: String?, cards: [JiraCard], tint: Color) -> some View {
        let open = !collapsed.contains(id)
        return Section {
            if open {
                ForEach(cards) { row($0, showStatus: tab != .sprint) }
                if cards.isEmpty { emptyRow("Nothing here.") }
            }
        } header: {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { if open { collapsed.insert(id) } else { collapsed.remove(id) } }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(title).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                    Text("\(cards.count)")
                        .mobileFont(size: 12, weight: .bold, design: .rounded).foregroundStyle(MobileTheme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(MobileTheme.line, in: Capsule())
                    if let subtitle { Text(subtitle).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1) }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.dim)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pyPlain)
            .textCase(nil)
            .accessibilityLabel("\(title), \(cards.count)")
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(L(text)).mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .pyRow()
    }

    private func row(_ card: JiraCard, showStatus: Bool) -> some View {
        Button { opened = card } label: {
            JiraCardRow(card: card, showStatus: showStatus, busy: store.moving.contains(card.key))
        }
        .buttonStyle(.pyPlain)
        .pyRow()
        .contextMenu {
            Link(destination: card.url) { Label("Open in Jira", systemImage: "safari") }
            Button { UIPasteboard.general.string = card.key } label: { Label("Copy key", systemImage: "doc.on.doc") }
            Button { UIPasteboard.general.url = card.url } label: { Label("Copy link", systemImage: "link") }
        }
    }
}

struct JiraCardRow: View {
    let card: JiraCard
    var showStatus = false
    var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: JiraLook.typeSymbol(card.type))
                    .mobileFont(size: 12, weight: .semibold)
                    .foregroundStyle(JiraLook.typeColor(card.type))
                Text(card.key)
                    .mobileFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(MobileTheme.muted)
                    .strikethrough(card.statusCategory == "done")
                Spacer(minLength: 4)
                if busy { PullYardLoader(size: 16) }
                if showStatus {
                    Text(card.status)
                        .mobileFont(size: 11, weight: .semibold)
                        .foregroundStyle(JiraLook.statusColor(card.statusCategory))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(JiraLook.statusColor(card.statusCategory).opacity(0.14), in: Capsule())
                        .lineLimit(1)
                }
                if let priority = card.priority {
                    Image(systemName: JiraLook.prioritySymbol(priority))
                        .mobileFont(size: 11, weight: .bold)
                        .foregroundStyle(JiraLook.priorityColor(priority))
                        .accessibilityLabel(String(format: L("Priority %@"), priority))
                }
            }
            Text(card.summary)
                .mobileFont(size: 15, weight: .medium)
                .foregroundStyle(card.statusCategory == "done" ? MobileTheme.muted : MobileTheme.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if card.assignee != nil || !card.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(card.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .mobileFont(size: 11, weight: .medium)
                            .foregroundStyle(MobileTheme.muted)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(MobileTheme.line, in: Capsule())
                            .lineLimit(1)
                    }
                    if card.labels.count > 2 { Text("+\(card.labels.count - 2)").mobileFont(size: 11).foregroundStyle(MobileTheme.dim) }
                    Spacer(minLength: 4)
                    if let assignee = card.assignee {
                        Text(assignee).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1)
                        JiraInitials(name: assignee, size: 22)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(busy ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct JiraInitials: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Text(JiraLook.initials(name))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(MobileTheme.ink)
            .frame(width: size, height: size)
            .background(MobileTheme.line, in: Circle())
            .accessibilityHidden(true)
    }
}

struct JiraCardSheet: View {
    let key: String
    @ObservedObject private var store = JiraBoardStore.shared
    @State private var moves: [JiraMove]?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if let card = store.card(key) {
                    detail(card)
                } else {
                    PYEmptyState(title: "Ticket not found", message: "It may have moved off this board.")
                }
            }
            .navigationTitle(key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                if let card = store.card(key) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { openURL(card.url) } label: { Image(systemName: "safari") }
                            .accessibilityLabel("Open in Jira")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: key) {
            if let card = store.card(key) { moves = await store.moves(for: card) }
        }
    }

    private func detail(_ card: JiraCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: JiraLook.typeSymbol(card.type)).foregroundStyle(JiraLook.typeColor(card.type))
                    Text(card.type ?? L("Issue")).mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                }
                Text(card.summary).mobileFont(size: 20, weight: .semibold).foregroundStyle(MobileTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 12) {
                    field("Status") {
                        Text(card.status)
                            .mobileFont(size: 13, weight: .semibold)
                            .foregroundStyle(JiraLook.statusColor(card.statusCategory))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(JiraLook.statusColor(card.statusCategory).opacity(0.14), in: Capsule())
                    }
                    field("Assignee") {
                        if let assignee = card.assignee {
                            HStack(spacing: 8) {
                                JiraInitials(name: assignee, size: 22)
                                Text(assignee).mobileFont(size: 15).foregroundStyle(MobileTheme.ink)
                            }
                        } else {
                            Text("Unassigned").mobileFont(size: 15).foregroundStyle(MobileTheme.muted)
                        }
                    }
                    if let priority = card.priority {
                        field("Priority") {
                            HStack(spacing: 6) {
                                Image(systemName: JiraLook.prioritySymbol(priority)).mobileFont(size: 12, weight: .bold).foregroundStyle(JiraLook.priorityColor(priority))
                                Text(priority).mobileFont(size: 15).foregroundStyle(MobileTheme.ink)
                            }
                        }
                    }
                    if !card.labels.isEmpty {
                        field("Labels") {
                            Text(card.labels.joined(separator: ", ")).mobileFont(size: 15).foregroundStyle(MobileTheme.ink)
                        }
                    }
                    if let updated = card.updated {
                        field("Updated") {
                            Text(updated.formatted(.relative(presentation: .named))).mobileFont(size: 15).foregroundStyle(MobileTheme.ink)
                        }
                    }
                }
                .pyCard()
                moveSection(card)
            }
            .padding(20)
        }
    }

    private func field<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L(title)).mobileFont(size: 14).foregroundStyle(MobileTheme.muted).frame(width: 84, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func moveSection(_ card: JiraCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move to").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
            if let moves {
                if moves.isEmpty {
                    Text("This ticket has no moves available to you.").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
                }
                ForEach(moves) { move in
                    Button {
                        Task {
                            if await store.apply(move, to: card), let fresh = store.card(key) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                self.moves = await store.moves(for: fresh)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(JiraLook.statusColor(move.toCategory)).frame(width: 8, height: 8)
                            Text(move.toName).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.ink)
                            if move.name != move.toName { Text(move.name).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1) }
                            Spacer(minLength: 4)
                            if move.toID == card.statusID { Image(systemName: "checkmark").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.accent) }
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: PYRadius.small, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: PYRadius.small, style: .continuous).stroke(MobileTheme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pyPlain)
                    .disabled(store.moving.contains(card.key) || move.toID == card.statusID)
                }
                if let error = store.error {
                    Text(error).mobileFont(size: 13).foregroundStyle(MobileTheme.red)
                }
            } else {
                PullYardLoader(size: 22)
            }
        }
    }
}

private struct JiraRefreshKey: EnvironmentKey {
    static let defaultValue: (@Sendable () async -> Void)? = nil
}

extension EnvironmentValues {
    var jiraRefresh: (@Sendable () async -> Void)? {
        get { self[JiraRefreshKey.self] }
        set { self[JiraRefreshKey.self] = newValue }
    }
}

struct JiraKanban: View {
    let groups: [(column: JiraColumnInfo, cards: [JiraCard])]
    @Binding var focus: String?
    let onOpen: (JiraCard) -> Void
    @ObservedObject private var store = JiraBoardStore.shared
    @State private var visible: String?

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { chips in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups, id: \.column.id) { group in
                            Chip(title: group.column.name, count: group.cards.count, isSelected: visible == group.column.id) {
                                withAnimation(.snappy) { visible = group.column.id }
                            }
                            .id(group.column.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .onChange(of: visible) { _, id in withAnimation(.snappy) { chips.scrollTo(id, anchor: .center) } }
            }
            GeometryReader { geo in
                let width = min(geo.size.width - 44, 360)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(groups, id: \.column.id) { group in
                            JiraKanbanColumn(column: group.column, cards: group.cards, tint: tint(group.cards), columns: groups.map(\.column), onOpen: onOpen)
                                .frame(width: width, height: geo.size.height)
                                .id(group.column.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $visible)
            }
        }
        .onAppear { if visible == nil { visible = firstBusy } }
        .onChange(of: groups.map(\.column.id)) { _, ids in if visible == nil || !ids.contains(visible ?? "") { visible = firstBusy } }
    }

    private var firstBusy: String? {
        (groups.first { !$0.cards.isEmpty } ?? groups.first)?.column.id
    }

    private func tint(_ cards: [JiraCard]) -> Color {
        var tally: [String: Int] = [:]
        for card in cards { tally[card.statusCategory, default: 0] += 1 }
        return JiraLook.statusColor(tally.max { $0.value < $1.value }?.key ?? "new")
    }
}

private struct JiraKanbanColumn: View {
    let column: JiraColumnInfo
    let cards: [JiraCard]
    let tint: Color
    let columns: [JiraColumnInfo]
    let onOpen: (JiraCard) -> Void
    @ObservedObject private var store = JiraBoardStore.shared
    @Environment(\.jiraRefresh) private var refresh
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(column.name).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(cards.count)")
                    .mobileFont(size: 12, weight: .bold, design: .rounded).foregroundStyle(MobileTheme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(MobileTheme.line, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if cards.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: targeted ? "arrow.down.circle.fill" : "tray").mobileFont(size: 20)
                            Text(targeted ? L("Drop to move here") : L("Nothing here")).mobileFont(size: 13)
                        }
                        .foregroundStyle(targeted ? MobileTheme.accent : MobileTheme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(targeted ? MobileTheme.accent : MobileTheme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    ForEach(cards) { card in
                        Button { onOpen(card) } label: {
                            JiraCardRow(card: card, busy: store.moving.contains(card.key))
                                .padding(12)
                                .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MobileTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.pyPlain)
                        .draggable(card.key) {
                            JiraCardRow(card: card).padding(12).frame(width: 280)
                                .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .contextMenu {
                            Menu {
                                ForEach(columns.filter { $0.id != column.id }) { target in
                                    Button(target.name) { move(card, to: target) }
                                }
                            } label: { Label("Move to", systemImage: "arrow.right.square") }
                            Link(destination: card.url) { Label("Open in Jira", systemImage: "safari") }
                            Button { UIPasteboard.general.string = card.key } label: { Label("Copy key", systemImage: "doc.on.doc") }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .refreshable { await refresh?() }
        }
        .background(MobileTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(targeted ? MobileTheme.accent : MobileTheme.line, lineWidth: targeted ? 1.5 : 1))
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first, let card = store.card(key) else { return false }
            move(card, to: column)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func move(_ card: JiraCard, to target: JiraColumnInfo) {
        Task {
            if await store.move(card, to: target) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
