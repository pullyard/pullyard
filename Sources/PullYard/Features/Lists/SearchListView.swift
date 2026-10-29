import SwiftUI

enum StateFilter: String, CaseIterable, Identifiable {
    case open, closed, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .all: return "All"
        }
    }

    var query: String {
        switch self {
        case .open: return "is:open"
        case .closed: return "is:closed"
        case .all: return ""
        }
    }
}

struct EmptyCopy {
    let title: String
    let message: String

    static func prs(_ filter: PRFilter, noun: String = "pull request", state: StateFilter = .open) -> EmptyCopy {
        let nouns = "\(noun)s"
        let lead = nouns.prefix(1).uppercased() + nouns.dropFirst()
        let message: String
        switch filter {
        case .reviewRequested: message = "When someone requests your review, it shows up here."
        case .mine: message = "\(lead) you open show up here."
        case .assigned: message = "\(lead) assigned to you show up here."
        case .mentioned: message = "\(lead) that mention you show up here."
        case .reviewed: message = "\(lead) you’ve reviewed show up here."
        }
        if state == .closed { return EmptyCopy(title: "No closed \(nouns)", message: message) }
        switch filter {
        case .reviewRequested: return EmptyCopy(title: "No reviews waiting", message: message)
        case .mine: return EmptyCopy(title: state == .open ? "No open \(nouns)" : "No \(nouns) yet", message: message)
        case .assigned: return EmptyCopy(title: "Nothing assigned to you", message: message)
        case .mentioned: return EmptyCopy(title: "No mentions", message: message)
        case .reviewed: return EmptyCopy(title: "Nothing reviewed yet", message: message)
        }
    }

    static func issues(_ filter: IssueFilter, state: StateFilter = .open) -> EmptyCopy {
        let message: String
        switch filter {
        case .assigned: message = "Issues assigned to you show up here."
        case .mine: message = "Issues you open show up here."
        case .mentioned: message = "Issues that mention you show up here."
        }
        if state == .closed { return EmptyCopy(title: "No closed issues", message: message) }
        switch filter {
        case .assigned: return EmptyCopy(title: "No issues assigned to you", message: message)
        case .mine: return EmptyCopy(title: state == .open ? "No open issues" : "No issues yet", message: message)
        case .mentioned: return EmptyCopy(title: "No mentions", message: message)
        }
    }

    static func search(kind: String, baseQuery: String, state: StateFilter) -> EmptyCopy {
        if kind == "issue", let f = IssueFilter.allCases.first(where: { $0.query == baseQuery }) { return issues(f, state: state) }
        if kind == "pr", let f = PRFilter.allCases.first(where: { $0.query == baseQuery }) { return prs(f, state: state) }
        let noun = kind == "issue" ? "issues" : "pull requests"
        return EmptyCopy(title: state == .all ? "No \(noun)" : "No \(state.title.lowercased()) \(noun)", message: "Matching \(noun) show up here.")
    }
}

@Observable
@MainActor
final class SearchListModel {
    private struct Snapshot: Codable {
        let items: [SearchItem]
        let total: Int
        let cursor: String?
        let hasMore: Bool
        let updated: Date
    }

    private static var cache: [String: Snapshot] = [:]

    static var cachedItems: [SearchItem] {
        cache.values.flatMap(\.items)
    }

    static func resetCache() {
        cache = [:]
    }

    var items: [SearchItem] = []
    var total = 0
    var loading = false
    var refreshing = false
    var showingCached = false
    var checkingCache = false
    var lastUpdated: Date?
    var error: String?
    private var cursor: String?
    private var hasMore = false
    private var loadingMore = false
    private var currentQuery = ""
    private var currentKey = ""
    private var generation = 0
    let rows: RowAppearTracker

    init(rows: RowAppearTracker) {
        self.rows = rows
    }

    func load(api: GitHubAPI?, account: String?, query: String, silent: Bool = false, typing: Bool = false, persist: Bool = false) async {
        guard let api else { return }
        var switched = false
        var cached = false
        let key = "\(account ?? "")|\(query)"
        let diskKey = "search|\(query)"
        if key != currentKey {
            switched = true
            currentQuery = query
            currentKey = key
            error = nil
            if let snap = Self.cache[key] {
                cached = true
                apply(snap, mode: .silent)
            } else {
                items = []
                total = 0
                lastUpdated = nil
            }
        }
        showingCached = cached
        generation += 1
        let gen = generation
        if !silent || switched { loading = true }
        refreshing = true
        async let fetched = api.search(query)
        if switched, !cached, persist {
            checkingCache = true
            let snap = await ListCache.load(Snapshot.self, account: account, key: diskKey)?.value
            checkingCache = false
            guard gen == generation else { return }
            if let snap {
                cached = true
                showingCached = true
                apply(snap, mode: .silent)
            }
        }
        do {
            let r = try await fetched
            guard gen == generation else { return }
            var merged = r.nodes
            var nextCursor = r.pageInfo?.endCursor
            var more = r.pageInfo?.hasNextPage ?? false
            if !switched, items.count > r.nodes.count {
                let fresh = Set(r.nodes.map(\.id))
                merged += items.dropFirst(r.nodes.count).filter { !fresh.contains($0.id) }
                nextCursor = cursor
                more = hasMore
            }
            let snap = Snapshot(items: merged, total: r.issueCount, cursor: nextCursor, hasMore: more, updated: Date())
            Self.cache[key] = snap
            if persist {
                let first = Snapshot(items: r.nodes, total: r.issueCount, cursor: r.pageInfo?.endCursor, hasMore: r.pageInfo?.hasNextPage ?? false, updated: snap.updated)
                ListCache.save(first, account: account, key: diskKey)
            }
            apply(snap, mode: typing ? .silent : (switched && !cached ? .cascade : .refresh))
            error = nil
            loading = false
            refreshing = false
            showingCached = false
        } catch {
            guard gen == generation else { return }
            loading = false
            refreshing = false
            showingCached = false
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ snap: Snapshot, mode: RowAppearMode) {
        rows.ingest(snap.items.map(\.id), mode: mode)
        items = snap.items
        total = snap.total
        cursor = snap.cursor
        hasMore = snap.hasMore
        lastUpdated = snap.updated
    }

    func loadMore(api: GitHubAPI?) async {
        guard let api, hasMore, !loadingMore, let cursor else { return }
        let query = currentQuery
        let key = currentKey
        loadingMore = true
        defer { loadingMore = false }
        if let r = try? await api.search(query, after: cursor), key == currentKey {
            let known = Set(items.map(\.id))
            let added = r.nodes.filter { !known.contains($0.id) }
            rows.ingest(added.map(\.id), mode: .append)
            items += added
            self.cursor = r.pageInfo?.endCursor
            hasMore = r.pageInfo?.hasNextPage ?? false
            Self.cache[key] = Snapshot(items: items, total: total, cursor: self.cursor, hasMore: hasMore, updated: lastUpdated ?? Date())
        }
    }

    func loadAll(api: GitHubAPI?, limit: Int = 400) async {
        while hasMore, items.count < limit, !Task.isCancelled {
            let before = items.count
            await loadMore(api: api)
            if items.count == before { return }
        }
    }

    var groups: [RepoGroup] {
        var order: [String] = []
        var byRepo: [String: [SearchItem]] = [:]
        for item in items {
            let key = item.repository.nameWithOwner
            if byRepo[key] == nil { order.append(key) }
            byRepo[key, default: []].append(item)
        }
        return order.map { RepoGroup(id: $0, items: byRepo[$0] ?? []) }
    }
}

struct RepoGroup: Identifiable {
    let id: String
    let items: [SearchItem]

    var owner: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

struct LoadingBar: View {
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .labelsHidden()
                    .transition(.opacity)
            }
        }
        .frame(height: 4)
        .clipped()
    }
}

struct SearchListView: View {
    let title: String
    let kind: String
    let baseQuery: String
    let grouped: Bool
    @Environment(AppModel.self) private var app
    @State private var model: SearchListModel
    @State private var stateFilter: StateFilter = .open
    @State private var text = ""
    @State private var loadedText = ""
    @State private var collapsed: Set<String> = []

    init(title: String, kind: String, baseQuery: String, grouped: Bool = false) {
        self.title = title
        self.kind = kind
        self.baseQuery = baseQuery
        self.grouped = grouped
        _model = State(initialValue: SearchListModel(rows: .shared("search|\(kind)|\(baseQuery)\(grouped ? "|grouped" : "")")))
    }

    private var query: String {
        [baseQuery, "is:\(kind)", stateFilter.query, "archived:false", "sort:updated-desc", text]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: $stateFilter) {
                ForEach(StateFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            LoadingBar(active: model.loading && !model.showingCached && !model.items.isEmpty)
            Divider()
            List(selection: Binding(get: { app.detailRoot }, set: { app.select($0) })) {
                if grouped {
                    ForEach(model.groups) { group in
                        let open = !collapsed.contains(group.id) || !text.isEmpty
                        Section {
                            if open {
                                ForEach(group.items) { row($0) }
                            }
                        } header: {
                            RepoGroupHeader(group: group, expanded: open) {
                                withAnimation(Motion.quick) { if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) } }
                            }
                        }
                    }
                } else {
                    ForEach(model.items) { row($0) }
                }
            }
            .opacity(model.loading && !model.showingCached && !model.items.isEmpty ? 0.55 : 1)
            .animation(.easeOut(duration: 0.15), value: model.loading)
            .overlay {
                if model.loading && !model.checkingCache && model.items.isEmpty {
                    PullYardLoader(size: 44)
                } else if let e = model.error, model.items.isEmpty {
                    ListErrorNote(message: e, centered: true) { await reload() }
                } else if model.items.isEmpty, !model.loading {
                    let copy = EmptyCopy.search(kind: kind, baseQuery: baseQuery, state: stateFilter)
                    ListEmptyNote(title: copy.title, message: copy.message, filter: text.trimmingCharacters(in: .whitespaces)) { text = "" }
                }
            }
            .liveRefresh(updated: model.lastUpdated, refreshing: model.refreshing, error: model.items.isEmpty ? nil : model.error) {
                await reload(silent: true)
            }
        }
        .toolbarSearch(text: $text, prompt: "Filter: text, repo:org/name, label:bug")
        .navigationTitle(title)
        .navigationSubtitle(model.total > 0 ? "\(model.total)" : "")
        .task(id: "\(query)|\(app.cacheAccount ?? "")|\(app.api != nil)") {
            if !text.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            let typing = text != loadedText
            loadedText = text
            await reload(typing: typing)
        }
        .onChange(of: app.refreshTick) { Task { await reload(silent: !model.items.isEmpty) } }
        .onLiveTick { await reload(silent: true) }
    }

    private func row(_ item: SearchItem) -> some View {
        ItemRow(item: item, showRepo: !grouped)
            .rowAppear(item.id, model.rows)
            .tag(item.route)
            .listRowSeparator(.visible)
            .listRowSeparatorTint(Color.syLine)
            .onAppear {
                if !grouped, item.id == model.items.last?.id { Task { await model.loadMore(api: app.api) } }
            }
            .contextMenu { ItemContextMenu(item: item) }
    }

    private func reload(silent: Bool = false, typing: Bool = false) async {
        await model.load(api: app.api, account: app.cacheAccount, query: query, silent: silent, typing: typing, persist: text.isEmpty)
        if grouped { await model.loadAll(api: app.api) }
    }
}

struct RepoGroupHeader: View {
    let group: RepoGroup
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let color = ProjectPalette.color(for: group.id)
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.syCaption2.weight(.bold)).foregroundStyle(Color.syDim).frame(width: 10)
            IconTile(systemImage: "book.closed.fill", color: color, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                Text(group.owner).font(.syCaption2).foregroundStyle(Color.syDim).lineLimit(1)
            }
            Spacer()
            Text("\(group.items.count)")
                .font(.syCaption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.14)))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .textCase(nil)
        .padding(.vertical, 3)
        .help(group.id)
    }
}

struct ItemContextMenu: View {
    let item: SearchItem
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open in Browser") { openInBrowser(item.url) }
        Button("Copy Link") { copyToPasteboard(item.url) }
        Button("Copy Short Link") { app.copyShortLink(item.ref) }
        if item.isPR {
            Button("Copy “gh pr checkout”") { copyToPasteboard("gh pr checkout \(item.number) -R \(item.repository.nameWithOwner)") }
        }
    }
}

struct ItemRow: View {
    let item: SearchItem
    var showRepo = true
    var numberPrefix = "#"

    private var reference: String {
        showRepo ? "\(item.repository.nameWithOwner)\(numberPrefix)\(item.number)" : "\(numberPrefix)\(item.number)"
    }

    private var spokenLabel: String {
        var parts = [item.title, "\(item.repository.nameWithOwner)\(numberPrefix)\(item.number)"]
        if let login = item.author?.login, !login.isEmpty { parts.append("by \(login)") }
        parts.append(item.visualState.title)
        if item.isPR {
            switch item.ciState {
            case "SUCCESS": parts.append("checks passed")
            case "FAILURE", "ERROR": parts.append("checks failed")
            case "PENDING", "EXPECTED": parts.append("checks running")
            default: break
            }
            switch item.reviewDecision {
            case "APPROVED": parts.append("approved")
            case "CHANGES_REQUESTED": parts.append("changes requested")
            case "REVIEW_REQUIRED": parts.append("review required")
            default: break
            }
        }
        if let comments = item.comments?.totalCount, comments > 0 { parts.append(plural(comments, "comment", "comments")) }
        parts.append("updated \(Fmt.rel(item.updatedAt))")
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateBadge(state: item.visualState, compact: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.syBody.weight(.medium))
                    .foregroundStyle(Color.syText)
                    .lineLimit(2)
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(reference).lineLimit(1).truncationMode(.middle)
                    Text("·").foregroundStyle(Color.syDim)
                    Text(Fmt.rel(item.updatedAt)).lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    if item.isPR, let a = item.additions, let d = item.deletions { DiffStat(additions: a, deletions: d) }
                }
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                HStack(spacing: 6) {
                    Avatar(url: item.author?.avatarUrl, size: 18, ring: true)
                    Text(item.author?.login ?? "").lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 8) {
                        if item.isPR {
                            CIIcon(state: item.ciState)
                            reviewBadge
                        }
                        if let comments = item.comments?.totalCount, comments > 0 {
                            Label("\(comments)", systemImage: "bubble.left").labelStyle(.titleAndIcon).monospacedDigit()
                        }
                    }
                    .fixedSize()
                }
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                if let base = item.stackedOn {
                    Label("stacked on \(base)", systemImage: "square.stack.3d.up")
                        .font(.syCaption)
                        .foregroundStyle(Color.syIndigo)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(base)
                }
                if let labels = item.labels?.nodes, !labels.isEmpty {
                    HStack(spacing: 4) { ForEach(labels.prefix(4), id: \.name) { LabelChip(label: $0) } }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .hoverHighlight(radius: 7)
        .padding(.horizontal, -6)
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch item.reviewDecision {
        case "APPROVED": Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.ghGreen).font(.syCaption).help("Approved")
        case "CHANGES_REQUESTED": Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color.ghRed).font(.syCaption).help("Changes requested")
        case "REVIEW_REQUIRED": Image(systemName: "eye").foregroundStyle(Color.syMuted).font(.syCaption).help("Review required")
        default: EmptyView()
        }
    }
}
