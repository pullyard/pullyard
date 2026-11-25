import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pulling = false

    private var waiting: [PullRequest] { model.pulls(for: .queue(.needsMyReview)) }
    private var reviewKey: PRListKey { OverviewFilter.queue(.needsMyReview).listKey }

    private let tiles: [(OverviewFilter, Color)] = [
        (.queue(.createdByMe), MobileTheme.accent),
        (.readyToMerge, MobileTheme.violet),
        (.failingChecks, MobileTheme.red),
        (.changesRequested, MobileTheme.amber),
        (.queue(.assigned), MobileTheme.sky),
        (.queue(.mentioned), MobileTheme.coral),
        (.queue(.reviewed), MobileTheme.green),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.focusPinnedOnly && !model.pinnedProjects.isEmpty {
                    Label("Focus: pinned projects only", systemImage: "moon.circle.fill")
                        .mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.violet)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .pyGlassCapsule(tint: MobileTheme.violet.opacity(0.15), fallback: MobileTheme.violet.opacity(0.12))
                }
                heroCard
                OutboxCard()
                PushedBranchesCard()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, item in
                        let filter = item.0
                        let tint = item.1
                        NavigationLink(value: Route.list(filter)) {
                            OverviewTile(title: filter.title, symbol: filter.symbol, count: model.count(for: filter), tint: tint)
                        }
                        .buttonStyle(.pyPlain)
                    }
                    if !model.snoozedPulls.isEmpty {
                        NavigationLink(value: Route.list(.snoozed)) {
                            OverviewTile(title: "Snoozed", symbol: "moon.zzz", count: model.snoozedPulls.count, tint: MobileTheme.violet)
                        }
                        .buttonStyle(.pyPlain)
                    }
                    Button { model.selectedTab = .inbox } label: {
                        OverviewTile(title: "Unread inbox", symbol: "tray.full", count: model.inboxState == .idle && model.notifications.isEmpty ? nil : model.unreadCount, tint: MobileTheme.slate)
                    }
                    .buttonStyle(.pyPlain)
                }
                if !model.pinnedProjects.isEmpty { pinnedProjects }
                if !model.savedSearches.isEmpty { savedSearches }
                NavigationLink(value: Route.allPulls) {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(MobileTheme.accent)
                        Text("Browse all pull requests").mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
                    }
                    .padding(16)
                    .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous), interactive: true, fallback: MobileTheme.card)
                }
                .buttonStyle(.pyPlain)
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(BrandBackdrop())
        .refreshable {
            pulling = true
            await model.refreshOverview()
            pulling = false
        }
        .pullToRefreshLogo(isRefreshing: pulling)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refreshOverview() } } label: { RefreshGlyph(isRefreshing: model.isRefreshing) }
                    .disabled(model.isRefreshing)
                    .accessibilityLabel("Refresh")
            }
        }
        .task {
            if let updated = model.lastUpdated, Date.now.timeIntervalSince(updated) < 60 { return }
            await model.refreshOverview()
        }
        .feedbackChrome { Task { await model.refreshOverview() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(greeting)).mobileFont(size: 14, weight: .medium).foregroundStyle(MobileTheme.muted)
                Text(model.user?.name?.split(separator: " ").first.map(String.init) ?? model.user?.login ?? "Reviewer")
                    .mobileFont(size: 22, weight: .semibold, design: .serif).foregroundStyle(MobileTheme.ink)
            }
            Spacer()
            FreshnessLabel(state: model.listState(reviewKey)) { Task { await model.refreshOverview() } }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.list(.queue(.needsMyReview))) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.count(for: .queue(.needsMyReview)).map(String.init) ?? "–")
                        .mobileFont(size: 44, weight: .bold, design: .rounded)
                        .foregroundStyle(waiting.isEmpty ? MobileTheme.green : MobileTheme.coral)
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waiting.count == 1 ? "review waiting" : "reviews waiting").mobileFont(size: 17, weight: .semibold).foregroundStyle(MobileTheme.ink)
                        Text("for you").mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                    }
                    Spacer()
                    if !waiting.isEmpty {
                        Text("See all").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.accent)
                        Image(systemName: "chevron.right").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pyPlain)
            if waiting.isEmpty {
                if model.listState(reviewKey) == .loading || model.listState(reviewKey) == .idle {
                    HStack { Spacer(); PullYardLoader(size: 56); Spacer() }.padding(.vertical, 8)
                } else {
                    HStack(spacing: 12) {
                        PullYardLogoMark(progress: 1, size: 56)
                        Text("Calm waters. Nothing is waiting for your review.").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(waiting.prefix(3).enumerated()), id: \.element.id) { index, pr in
                        if index > 0 { Divider().overlay(MobileTheme.line) }
                        NavigationLink(value: Route.pull(pr.key ?? PRKey(repo: pr.repoName, number: pr.number))) {
                            HStack(spacing: 10) {
                                PullRequestRow(pr: pr, hideState: true)
                                Image(systemName: "chevron.right").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
                            }
                        }
                        .buttonStyle(.pyPlain)
                        .contextMenu { if let key = pr.key { SnoozeMenu(key: key) } }
                    }
                }
            }
        }
        .padding(16)
        .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.large, style: .continuous), tint: waiting.isEmpty ? nil : MobileTheme.coral.opacity(0.08), fallback: MobileTheme.card)
        .overlay(RoundedRectangle(cornerRadius: PYRadius.large, style: .continuous).stroke(GlassSupport.isAvailable ? .clear : MobileTheme.line))
    }

    private var pinnedProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Pinned projects", systemImage: "pin.fill").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.muted)
                Spacer()
                Button("All") { model.selectedTab = .projects }.mobileFont(size: 14, weight: .semibold)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.pinnedProjects, id: \.self) { repo in
                        NavigationLink(value: Route.project(repo)) {
                            VStack(alignment: .leading, spacing: 8) {
                                AvatarView(url: URL(string: "https://github.com/\(repo.split(separator: "/").first ?? "").png"), size: 30, fallback: repo)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(String(repo.split(separator: "/").last ?? Substring(repo))).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                                HStack(spacing: 6) {
                                    let reviews = model.reviewRequests(in: repo)
                                    if reviews > 0 { Text("\(reviews) waiting").foregroundStyle(MobileTheme.coral) }
                                    if let open = model.allProjects.first(where: { $0.nameWithOwner == repo })?.openPullRequests { Text("\(open) open").foregroundStyle(MobileTheme.muted) }
                                }
                                .mobileFont(size: 12, weight: .medium)
                            }
                            .frame(width: 130, alignment: .leading)
                            .padding(12)
                            .pyGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true, fallback: MobileTheme.card)
                        }
                        .buttonStyle(.pyPlain)
                    }
                }
            }
        }
    }

    private var savedSearches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved searches", systemImage: "bookmark.fill").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.muted)
            FlowRow(spacing: 8) {
                ForEach(model.savedSearches, id: \.self) { query in
                    NavigationLink(value: Route.list(.saved(query))) {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill").mobileFont(size: 11)
                            Text(query).mobileFont(size: 13, weight: .semibold).lineLimit(1)
                            if let count = model.count(for: .saved(query)) { Text("\(count)").mobileFont(size: 12, weight: .bold, design: .rounded).foregroundStyle(MobileTheme.muted) }
                        }
                        .foregroundStyle(MobileTheme.violet)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .pyGlassCapsule(tint: MobileTheme.violet.opacity(0.14), interactive: true, fallback: MobileTheme.violet.opacity(0.12))
                    }
                    .buttonStyle(.pyPlain)
                }
            }
        }
    }
}

private struct OverviewTile: View {
    let title: String
    let symbol: String
    let count: Int?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .mobileFont(size: 15, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.14), in: Circle())
                Spacer()
                Image(systemName: "chevron.right").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.dim)
            }
            Text(count.map(String.init) ?? "–")
                .mobileFont(size: 28, weight: .bold, design: .rounded)
                .foregroundStyle((count ?? 0) > 0 ? MobileTheme.ink : MobileTheme.dim)
                .contentTransition(.numericText())
            Text(L(title)).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.muted).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .pyGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true, fallback: MobileTheme.card)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(GlassSupport.isAvailable ? .clear : MobileTheme.line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count.map(String.init) ?? "loading")")
    }
}

struct FilteredPullsView: View {
    let filter: OverviewFilter
    @EnvironmentObject private var model: AppModel
    @AppStorage("mobile.pulls.groupByProject") private var groupByProject = true
    @State private var collapsed: Set<String> = []

    private var pulls: [PullRequest] { model.pulls(for: filter) }
    private var groups: [(repo: String, pulls: [PullRequest])] {
        let grouped = Dictionary(grouping: pulls) { $0.repoName }
        let pinned = model.pinnedProjects.filter { grouped[$0] != nil }
        let rest = grouped.keys.filter { !pinned.contains($0) }.sorted { (grouped[$0]?.first?.updatedAt ?? .distantPast) > (grouped[$1]?.first?.updatedAt ?? .distantPast) }
        return (pinned + rest).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if pulls.isEmpty {
                Section {
                    Group {
                        switch model.listState(filter.listKey) {
                        case let .failed(message):
                            ErrorStateView(title: "Couldn't load pull requests", message: message) { Task { await model.refreshList(filter.listKey) } }
                        case .loaded:
                            PYEmptyState(title: "Nothing here", message: emptyMessage)
                        default:
                            PullYardLoader(title: "Loading pull requests…", size: 72)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else if groupByProject && groups.count > 1 {
                ForEach(groups, id: \.repo) { group in
                    Section {
                        if !collapsed.contains(group.repo) {
                            ForEach(group.pulls) { row($0, showRepo: false) }
                        }
                    } header: {
                        ProjectSectionHeader(repo: group.repo, count: group.pulls.count, pinned: model.isPinned(group.repo), collapsed: collapsed.contains(group.repo)) {
                            withAnimation(.snappy) { if collapsed.contains(group.repo) { collapsed.remove(group.repo) } else { collapsed.insert(group.repo) } }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(pulls) { row($0, showRepo: true) }
                } header: {
                    Text("\(pulls.count) pull request\(pulls.count == 1 ? "" : "s")").textCase(nil)
                }
            }
        }
        .pyListStyle()
        .refreshable { await model.refreshList(filter.listKey) }
        .pullToRefreshLogo(isRefreshing: model.listState(filter.listKey) == .loading && !pulls.isEmpty)
        .animation(.snappy, value: pulls.map(\.id))
        .navigationTitle(L(filter.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $groupByProject) { Label("Group by project", systemImage: "square.stack.3d.up") }
                    Button { Task { await model.refreshList(filter.listKey) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { RefreshGlyph(isRefreshing: model.listState(filter.listKey) == .loading, symbol: "line.3.horizontal.decrease.circle") }
            }
        }
        .task {
            if model.lists[filter.listKey] == nil { await model.refreshList(filter.listKey) }
        }
        .feedbackChrome { Task { await model.refreshList(filter.listKey) } }
    }

    private func row(_ pr: PullRequest, showRepo: Bool) -> some View {
        NavigationLink(value: Route.pull(pr.key ?? PRKey(repo: pr.repoName, number: pr.number))) {
            PullRequestRow(pr: pr, hideState: pr.displayState == .open, showRepo: showRepo)
        }
        .pyRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let key = pr.key {
                if model.isSnoozed(key) {
                    Button { withAnimation { model.unsnooze(key) } } label: { Label("Unsnooze", systemImage: "bell") }.tint(MobileTheme.accentFill)
                } else if let tomorrow = SnoozeStore.presets().dropFirst(2).first?.1 {
                    Button { withAnimation { model.snooze(key, until: tomorrow) } } label: { Label("Tomorrow", systemImage: "moon.zzz") }.tint(MobileTheme.violetFill)
                }
            }
        }
        .contextMenu {
            if let key = pr.key { SnoozeMenu(key: key) }
            Link(destination: pr.htmlUrl) { Label("Open on GitHub", systemImage: "safari") }
            Button { UIPasteboard.general.url = pr.htmlUrl } label: { Label("Copy link", systemImage: "link") }
            ShareLink(item: pr.htmlUrl) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .queue(.needsMyReview): "Calm waters. Nothing is waiting for your review."
        case .readyToMerge: "None of your open pull requests is approved and green yet."
        case .failingChecks: "All checks on your open pull requests are fine."
        case .changesRequested: "No one has requested changes on your pull requests."
        default: "No open pull requests match."
        }
    }
}
