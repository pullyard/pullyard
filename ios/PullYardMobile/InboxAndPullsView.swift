import SwiftUI

enum InboxFilter: String, CaseIterable, Identifiable {
    case unread = "Unread", all = "All", review = "Review requested", mentions = "Mentions", assigned = "Assigned", ci = "CI"
    var id: String { rawValue }

    func includes(_ item: GHNotification) -> Bool {
        switch self {
        case .unread: item.unread
        case .all: true
        case .review: item.reason == "review_requested"
        case .mentions: item.reason == "mention" || item.reason == "team_mention"
        case .assigned: item.reason == "assign"
        case .ci: item.reason == "ci_activity" || item.subject.type == "CheckSuite"
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mobile.inbox.filter") private var filterRaw = InboxFilter.unread.rawValue
    @State private var confirmMarkAll = false

    private var filter: InboxFilter { InboxFilter(rawValue: filterRaw) ?? .unread }
    private var filtered: [GHNotification] { model.notifications.filter(filter.includes) }
    private var groups: [(title: String, items: [GHNotification])] {
        let calendar = Calendar.current
        let today = filtered.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = filtered.filter { calendar.isDateInYesterday($0.updatedAt) }
        let earlier = filtered.filter { !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt) }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) { Group {
                    PYGlassGroup {
                        HStack(spacing: 8) {
                            ForEach(InboxFilter.allCases) { option in
                                Chip(title: option.rawValue, count: count(option), isSelected: filter == option) {
                                    withAnimation(.snappy) { filterRaw = option.rawValue }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }.background(HorizontalOnly()) }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                FreshnessLabel(state: model.inboxState) { Task { await model.refreshInbox() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .listSectionSeparator(.hidden)

            if filtered.isEmpty {
                Section {
                    emptyContent
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(L(group.title)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item.route) {
                                NotificationRow(item: item)
                            }
                            .pyRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { model.markDone(item) } label: { Label("Done", systemImage: "checkmark") }.tint(MobileTheme.greenFill)
                                Button { Task { await model.mute(item) } } label: { Label("Mute", systemImage: "bell.slash") }.tint(MobileTheme.slate)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if item.unread {
                                    Button { Task { await model.markRead(item) } } label: { Label("Read", systemImage: "envelope.open") }.tint(MobileTheme.accentFill)
                                }
                            }
                            .contextMenu {
                                if item.unread { Button { Task { await model.markRead(item) } } label: { Label("Mark as read", systemImage: "envelope.open") } }
                                Button { model.markDone(item) } label: { Label("Mark as done", systemImage: "checkmark.circle") }
                                Button { Task { await model.mute(item) } } label: { Label("Mute thread", systemImage: "bell.slash") }
                                if let url = item.webURL {
                                    Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
                                    Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "link") }
                                }
                            }
                            .accessibilityActions {
                                Button("Mark as done") { model.markDone(item) }
                                if item.unread { Button("Mark as read") { Task { await model.markRead(item) } } }
                                Button("Mute thread") { Task { await model.mute(item) } }
                            }
                        }
                    }
                }
            }
        }
        .pyListStyle()
        .refreshable { await model.refreshInbox() }
        .pullToRefreshLogo(isRefreshing: model.isRefreshing && !model.notifications.isEmpty)
        .navigationTitle("Inbox")
        .accountButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { confirmMarkAll = true } label: { Label("Mark all as read", systemImage: "envelope.open") }.disabled(model.unreadCount == 0)
                    Button { Task { await model.refreshInbox() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: {
                    RefreshGlyph(isRefreshing: model.isRefreshing, symbol: "ellipsis.circle")
                }
                .accessibilityLabel("Inbox actions")
            }
        }
        .confirmationDialog("Mark all notifications as read?", isPresented: $confirmMarkAll, titleVisibility: .visible) {
            Button("Mark \(model.unreadCount) as read") { Task { await model.markAllRead() } }
            Button("Cancel", role: .cancel) {}
        }
        .feedbackChrome { Task { await model.refreshInbox() } }
    }

    private func count(_ option: InboxFilter) -> Int? {
        let value = model.notifications.filter(option.includes).count
        return option == .all || value == 0 ? nil : value
    }

    @ViewBuilder private var emptyContent: some View {
        if model.notifications.isEmpty {
            switch model.inboxState {
            case .loading, .idle:
                PullYardLoader(title: "Checking GitHub…", size: 72)
            case let .failed(message):
                ErrorStateView(title: "Couldn't load your inbox", message: message) { Task { await model.refreshInbox() } }
            case .loaded:
                PYEmptyState(title: "Inbox zero", message: "Notifications from the last two weeks appear here.") {
                    Button("View pull requests") { model.selectedTab = .pulls }.buttonStyle(.borderedProminent).tint(MobileTheme.accentFill)
                }
            }
        } else {
            PYEmptyState(title: filter == .unread ? "All caught up" : "Nothing here", message: filter == .unread ? "You've read every notification." : "No \(filter.rawValue.lowercased()) notifications in the last two weeks.") {
                Button("Show all") { filterRaw = InboxFilter.all.rawValue }.buttonStyle(.bordered)
            }
        }
    }
}

struct NotificationRow: View {
    let item: GHNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(url: ownerAvatar, size: 38, fallback: item.repository.fullName)
                Image(systemName: symbol)
                    .mobileFont(size: 10, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(item.unread ? MobileTheme.accentFill : MobileTheme.slate, in: Circle())
                    .overlay(Circle().stroke(MobileTheme.card, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.repository.fullName).mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    RelativeTime(date: item.updatedAt).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                }
                Text(item.subject.title).mobileFont(size: 15, weight: item.unread ? .semibold : .regular).foregroundStyle(item.unread ? MobileTheme.ink : MobileTheme.muted).lineLimit(2)
                ReasonChip(reason: item.reason)
            }
            if item.unread { Circle().fill(MobileTheme.accent).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true) }
        }
        .padding(.vertical, 4)
        .opacity(item.unread ? 1 : 0.78)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.unread ? "Unread" : "Read")
    }

    private var ownerAvatar: URL? {
        guard let owner = item.repository.fullName.split(separator: "/").first else { return nil }
        return URL(string: "https://github.com/\(owner).png")
    }

    private var symbol: String {
        switch item.subject.type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Release": "tag.fill"
        case "CheckSuite": "checkmark.seal.fill"
        case "Discussion": "bubble.left.and.bubble.right.fill"
        case "Commit": "smallcircle.circle"
        default: "bell.fill"
        }
    }
}

struct ReasonChip: View {
    let reason: String

    var body: some View {
        Text(title)
            .mobileFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var title: String { L(rawTitle) }

    private var rawTitle: String {
        switch reason {
        case "review_requested": "Review requested"
        case "mention": "Mentioned"
        case "team_mention": "Team mention"
        case "assign": "Assigned"
        case "author": "Your thread"
        case "comment": "Comment"
        case "ci_activity": "CI activity"
        case "security_alert": "Security alert"
        case "state_change": "State changed"
        case "subscribed": "Watching"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var color: Color {
        switch reason {
        case "review_requested": MobileTheme.coral
        case "mention", "team_mention": MobileTheme.violet
        case "assign": MobileTheme.sky
        case "ci_activity": MobileTheme.amber
        case "security_alert": MobileTheme.red
        default: MobileTheme.slate
        }
    }
}

struct NotificationFallbackView: View {
    let item: GHNotification
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            PYEmptyState(title: item.subject.title, message: "\(item.repository.fullName)\nThis \(item.subject.type?.lowercased() ?? "notification") opens on GitHub.") {
                VStack(spacing: 10) {
                    if let url = item.webURL { Link("Open on GitHub", destination: url).buttonStyle(.borderedProminent).tint(MobileTheme.accentFill) }
                    Button("Mark as done") { model.markDone(item) }.buttonStyle(.bordered)
                }
            }
            .padding(.top, 60)
        }
        .background(MobileTheme.canvas)
        .navigationTitle(item.subject.type ?? "Notification")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.markRead(item) }
    }
}

struct PullRequestsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mobile.pulls.groupByProject") private var groupByProject = true
    @State private var showingProjects = false
    @State private var collapsed: Set<String> = []

    private var projectCounts: [String: Int] {
        Dictionary(grouping: model.currentPulls) { $0.repo ?? "Other" }.mapValues(\.count)
    }
    private var orderedProjects: [String] {
        let available = Set(projectCounts.keys)
        let saved = model.projectOrder.filter { available.contains($0) }
        return saved + available.subtracting(saved).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var visiblePulls: [PullRequest] {
        model.currentPulls.filter { model.selectedProject.isEmpty || $0.repo == model.selectedProject }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var groupedPulls: [(repo: String, pulls: [PullRequest])] {
        let groups = Dictionary(grouping: visiblePulls) { $0.repoName }
        let pinned = model.pinnedProjects.filter { groups[$0] != nil }
        let saved = model.projectOrder.filter { groups[$0] != nil && !pinned.contains($0) }
        let rest = groups.keys.filter { !pinned.contains($0) && !saved.contains($0) }
            .sorted { (groups[$0]?.first?.updatedAt ?? .distantPast) > (groups[$1]?.first?.updatedAt ?? .distantPast) }
        return (pinned + saved + rest).map { ($0, groups[$0] ?? []) }
    }
    private var isGrouped: Bool { groupByProject && model.selectedProject.isEmpty }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)

            if visiblePulls.isEmpty {
                Section {
                    emptyContent
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .listRowBackground(Color.clear)
                }
            } else if isGrouped {
                ForEach(groupedPulls, id: \.repo) { group in
                    Section {
                        if !collapsed.contains(group.repo) {
                            ForEach(group.pulls) { pr in pullRow(pr, showRepo: false) }
                        }
                    } header: {
                        ProjectSectionHeader(repo: group.repo, count: group.pulls.count, pinned: model.isPinned(group.repo), collapsed: collapsed.contains(group.repo)) {
                            withAnimation(.snappy) {
                                if collapsed.contains(group.repo) { collapsed.remove(group.repo) } else { collapsed.insert(group.repo) }
                            }
                        }
                    }
                }
                Section { discoveryFooter }
            } else {
                Section {
                    ForEach(visiblePulls) { pr in pullRow(pr, showRepo: model.selectedProject.isEmpty) }
                    discoveryFooter
                } header: {
                    Text("\(visiblePulls.count) of \(model.listTotals[model.currentListKey].map(String.init) ?? "–")").textCase(nil)
                }
            }
        }
        .pyListStyle()
        .refreshable { await model.refreshCurrentList() }
        .pullToRefreshLogo(isRefreshing: model.isRefreshing && !model.currentPulls.isEmpty)
        .animation(.snappy, value: visiblePulls.map(\.id))
        .navigationTitle("Pull requests")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Status", selection: $model.statusFilter) {
                        ForEach(PRStatusFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle(isOn: $groupByProject) { Label("Group by project", systemImage: "square.stack.3d.up") }
                    Button { showingProjects = true } label: { Label("Choose project…", systemImage: "folder") }
                    if !model.selectedProject.isEmpty {
                        Button { model.selectedProject = "" } label: { Label("Show all projects", systemImage: "square.grid.2x2") }
                    }
                } label: {
                    Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filters")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.refreshAll() } label: { RefreshGlyph(isRefreshing: model.isRefreshing) }
                    .disabled(model.isRefreshing)
                    .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh")
            }
        }
        .feedbackChrome { model.refreshAll() }
        .sheet(isPresented: $showingProjects) {
            ProjectPickerSheet(projects: orderedProjects, counts: projectCounts, selectedProject: $model.selectedProject, projectOrder: $model.projectOrder, isDiscovering: model.isDiscoveringCurrentList)
                .pySheetStyle()
                .presentationDetents([.medium, .large])
        }
    }

    private func pullRow(_ pr: PullRequest, showRepo: Bool) -> some View {
        let key = pr.key ?? PRKey(repo: pr.repoName, number: pr.number)
        return NavigationLink(value: Route.pull(key)) { PullRequestRow(pr: pr, hideState: pr.displayState == .open && model.statusFilter == .open, showRepo: showRepo) }
            .pyRow()
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let key = pr.key, let tomorrow = SnoozeStore.presets().dropFirst(2).first?.1 {
                    Button { withAnimation { model.snooze(key, until: tomorrow) } } label: { Label("Tomorrow", systemImage: "moon.zzz") }.tint(MobileTheme.violetFill)
                }
            }
            .contextMenu {
                if let key = pr.key { SnoozeMenu(key: key) }
                PullRowMenu(pr: pr)
            } preview: {
                PullRequestPreview(pr: pr)
            }
            .accessibilityActions {
                Button("Open on GitHub") { UIApplication.shared.open(pr.htmlUrl) }
                Button("Copy link") { UIPasteboard.general.url = pr.htmlUrl }
            }
    }

    @ViewBuilder private var discoveryFooter: some View {
                    if model.isDiscoveringCurrentList {
                        HStack(spacing: 10) {
                            PullYardLoader(size: 26)
                            Text("Loading more pull requests…").mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                        }
                        .pyRow()
                    } else if model.hasMore(model.currentListKey) {
                        Button { model.startDiscovery(for: model.currentListKey) } label: {
                            Text("Load more pull requests").mobileFont(size: 14, weight: .semibold).frame(maxWidth: .infinity)
                        }
                        .pyRow()
                    }
    }

    private var isFiltered: Bool { model.statusFilter != .open || !model.selectedProject.isEmpty }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) { Group {
                PYGlassGroup {
                    HStack(spacing: 8) {
                        ForEach(PRQueue.allCases) { queue in
                            Chip(title: queue.rawValue, count: model.openCount(for: queue), symbol: queue.symbol, isSelected: model.queue == queue && model.activeSavedSearch == nil, tint: queue == .needsMyReview ? MobileTheme.coral : MobileTheme.accentFill) {
                                withAnimation(.snappy) { model.activeSavedSearch = nil; model.queue = queue }
                            }
                        }
                        ForEach(model.savedSearches, id: \.self) { query in
                            Chip(title: query, count: model.activeSavedSearch == query ? model.listTotals[model.currentListKey] : nil, symbol: "bookmark.fill", isSelected: model.activeSavedSearch == query, tint: MobileTheme.violetFill) {
                                withAnimation(.snappy) { model.activeSavedSearch = query }
                            }
                            .contextMenu {
                                Button(role: .destructive) { withAnimation { model.toggleSaved(query) } } label: { Label("Remove saved search", systemImage: "bookmark.slash") }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }.background(HorizontalOnly()) }
            HStack(spacing: 8) {
                if model.statusFilter != .open {
                    RemovableChip(title: model.statusFilter.rawValue, symbol: "line.3.horizontal.decrease") { model.statusFilter = .open }
                }
                if !model.selectedProject.isEmpty {
                    RemovableChip(title: model.selectedProject, symbol: "folder") { model.selectedProject = "" }
                }
                Spacer(minLength: 0)
                FreshnessLabel(state: model.currentListState) { model.refreshAll() }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var emptyContent: some View {
        if model.currentPulls.isEmpty, case let .failed(message) = model.currentListState {
            ErrorStateView(title: "Couldn't load pull requests", message: message) { model.refreshAll() }
        } else if model.currentPulls.isEmpty && (model.currentListState == .loading || model.currentListState == .idle) {
            PullYardLoader(title: "Loading pull requests…", size: 72)
        } else if !model.selectedProject.isEmpty && model.isDiscoveringCurrentList {
            VStack(spacing: 18) {
                PullYardLoader(title: "Searching your other projects…", size: 64)
                Button("Show all projects") { model.selectedProject = "" }.buttonStyle(.bordered)
            }
        } else {
            PYEmptyState(title: emptyTitle, message: emptyDescription) {
                if !model.selectedProject.isEmpty {
                    Button("Show all projects") { model.selectedProject = "" }.buttonStyle(.borderedProminent).tint(MobileTheme.accentFill)
                } else if model.statusFilter != .all {
                    Button("Show all statuses") { model.statusFilter = .all }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var emptyTitle: String {
        if !model.selectedProject.isEmpty { return "Nothing in this project" }
        if model.queue == .needsMyReview && model.statusFilter == .open { return "No reviews waiting" }
        return "No pull requests"
    }

    private var emptyDescription: String {
        let status = model.statusFilter == .all ? "" : "\(model.statusFilter.rawValue.lowercased()) "
        if !model.selectedProject.isEmpty {
            return "There are no \(status)pull requests for \(model.selectedProject) in \(model.queue.rawValue)."
        }
        if model.queue == .needsMyReview && model.statusFilter == .open {
            return "Calm waters. When someone requests your review, it will appear here."
        }
        return "No \(status)pull requests in \(model.queue.rawValue)."
    }
}

private struct RemovableChip: View {
    let title: String
    let symbol: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol).mobileFont(size: 11, weight: .semibold)
                Text(title).mobileFont(size: 13, weight: .semibold).lineLimit(1)
                Image(systemName: "xmark").mobileFont(size: 10, weight: .bold)
            }
            .foregroundStyle(MobileTheme.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .pyGlassCapsule(tint: MobileTheme.accent.opacity(0.18), interactive: true, fallback: MobileTheme.accent.opacity(0.12))
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel("Remove filter \(title)")
    }
}

struct FreshnessLabel: View {
    let state: LoadState
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            HStack(spacing: 5) {
                switch state {
                case let .loaded(date):
                    Circle().fill(Date.now.timeIntervalSince(date) > 900 ? MobileTheme.amber : MobileTheme.green).frame(width: 6, height: 6)
                    RelativeTime(date: date, prefix: "Updated")
                case .loading:
                    Text("Updating…")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MobileTheme.amber)
                    Text("Update failed · Retry")
                case .idle:
                    Text("Pull down to refresh")
                }
            }
            .mobileFont(size: 12, weight: .medium)
            .foregroundStyle(MobileTheme.muted)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .pyGlassCapsule(interactive: true, fallback: MobileTheme.card.opacity(0.7))
        }
        .buttonStyle(.pyPlain)
        .accessibilityHint("Double-tap to refresh")
    }
}

struct RefreshGlyph: View {
    let isRefreshing: Bool
    var symbol = "arrow.clockwise"

    var body: some View {
        Image(systemName: symbol)
            .opacity(isRefreshing ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.2), value: isRefreshing)
    }
}

private struct ProjectPickerSheet: View {
    let projects: [String]
    let counts: [String: Int]
    @Binding var selectedProject: String
    @Binding var projectOrder: [String]
    let isDiscovering: Bool
    @State private var query = ""
    @State private var isReordering = false
    @Environment(\.dismiss) private var dismiss

    private var filteredProjects: [String] {
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    projectRow(name: "", title: "All projects", count: counts.values.reduce(0, +), symbol: "square.grid.2x2")
                    ForEach(filteredProjects, id: \.self) { name in
                        projectRow(name: name, title: name, count: counts[name] ?? 0, symbol: "folder")
                    }
                    .onMove(perform: moveProjects)
                } header: {
                    Text(isReordering ? "Drag projects into your preferred order" : "Choose a project").textCase(nil)
                } footer: {
                    if isDiscovering {
                        HStack(spacing: 8) {
                            PullYardLoader(size: 24)
                            Text("Finding the rest of your projects…")
                        }
                    }
                }
                .pyRow()
            }
            .pyListStyle()
            .searchable(text: $query, prompt: "Search projects")
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isReordering ? "Done" : "Reorder") { withAnimation { isReordering.toggle() } }
                        .disabled(!query.isEmpty || projects.count < 2)
                }
            }
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        }
    }

    @ViewBuilder private func projectRow(name: String, title: String, count: Int, symbol: String) -> some View {
        Button {
            selectedProject = name
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(MobileTheme.accent).frame(width: 24)
                Text(title).mobileFont(size: 15, weight: name == selectedProject ? .semibold : .regular).foregroundStyle(MobileTheme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(isDiscovering && name.isEmpty ? "\(count)…" : "\(count)").mobileFont(size: 13, weight: .medium).foregroundStyle(MobileTheme.muted).monospacedDigit()
                if name == selectedProject { Image(systemName: "checkmark").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pyPlain)
        .disabled(isReordering)
    }

    private func moveProjects(from source: IndexSet, to destination: Int) {
        guard query.isEmpty else { return }
        var reordered = projects
        reordered.move(fromOffsets: source, toOffset: destination)
        projectOrder = reordered
    }
}

struct PullRequestRow: View {
    let pr: PullRequest
    var hideState = false
    var showRepo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(showRepo ? "\(pr.repoName) · #\(pr.number)" : "#\(pr.number)").mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                RelativeTime(date: pr.updatedAt).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if VisitStore.hasUnseenActivity(pr) {
                    Circle().fill(MobileTheme.coral).frame(width: 8, height: 8).accessibilityLabel("New activity")
                }
                Text(pr.title).mobileFont(size: 16, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 7) {
                AvatarView(url: pr.user?.avatarUrl, size: 20, fallback: pr.user?.login)
                Text(pr.user?.login ?? "unknown").mobileFont(size: 13, weight: .medium).foregroundStyle(MobileTheme.muted).lineLimit(1)
                if !hideState || pr.displayState != .open { PRStatePill(state: pr.displayState) }
                if let review = pr.reviewState, review != .reviewRequired { ReviewChip(decision: review) }
                Spacer(minLength: 0)
                if let comments = pr.comments, comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble").labelStyle(.titleAndIcon).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).monospacedDigit()
                }
                if let ci = pr.ciState { CIDot(state: ci) }
            }
            if let labels = pr.labels, !labels.isEmpty {
                HStack(spacing: 5) { ForEach(labels.prefix(2), id: \.name) { LabelChip(label: $0) } }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = ["\(pr.title)", "\(pr.repoName) number \(pr.number)", "by \(pr.user?.login ?? "unknown")", pr.displayState.title]
        if let review = pr.reviewState { parts.append(review.title) }
        if let ci = pr.ciState { parts.append(ci.title) }
        if let comments = pr.comments, comments > 0 { parts.append("\(comments) comments") }
        return parts.joined(separator: ", ")
    }
}

struct ReviewChip: View {
    let decision: ReviewDecision

    var body: some View {
        let color = decision == .approved ? MobileTheme.green : MobileTheme.red
        Label(decision == .approved ? "Approved" : "Changes", systemImage: decision.symbol)
            .labelStyle(.titleAndIcon)
            .mobileFont(size: 11, weight: .semibold, design: .rounded)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct CIDot: View {
    let state: CIState

    var body: some View {
        Image(systemName: state.symbol)
            .mobileFont(size: 14, weight: .semibold)
            .foregroundStyle(state == .passing ? MobileTheme.green : state == .failing ? MobileTheme.red : MobileTheme.amber)
            .symbolEffect(.pulse, isActive: state == .pending)
            .accessibilityLabel(state.title)
    }
}

private struct PullRowMenu: View {
    let pr: PullRequest

    var body: some View {
        Link(destination: pr.htmlUrl) { Label("Open on GitHub", systemImage: "safari") }
        Button { UIPasteboard.general.url = pr.htmlUrl } label: { Label("Copy link", systemImage: "link") }
        ShareLink(item: pr.htmlUrl) { Label("Share", systemImage: "square.and.arrow.up") }
    }
}

private struct PullRequestPreview: View {
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PullRequestRow(pr: pr)
            HStack(spacing: 14) {
                if let additions = pr.additions { Text("+\(additions)").foregroundStyle(MobileTheme.green) }
                if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(MobileTheme.red) }
                if let files = pr.changedFiles { Text("\(files) files").foregroundStyle(MobileTheme.muted) }
                Spacer()
                if let ci = pr.ciState { Label(ci.title, systemImage: ci.symbol).foregroundStyle(MobileTheme.muted) }
            }
            .mobileFont(size: 13, weight: .semibold)
        }
        .padding(18)
        .frame(width: 340)
        .background(MobileTheme.card)
    }
}

struct ProjectSectionHeader: View {
    let repo: String
    let count: Int
    let pinned: Bool
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .mobileFont(size: 11, weight: .bold)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(MobileTheme.muted)
                    AvatarView(url: URL(string: "https://github.com/\(repo.split(separator: "/").first ?? "").png"), size: 20, fallback: repo)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(repo).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1).truncationMode(.middle)
                    if pinned { Image(systemName: "pin.fill").mobileFont(size: 10).foregroundStyle(MobileTheme.coral) }
                    Text("\(count)")
                        .mobileFont(size: 12, weight: .bold, design: .rounded)
                        .foregroundStyle(MobileTheme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(MobileTheme.line, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pyPlain)
            .accessibilityLabel("\(repo), \(count) pull requests, \(collapsed ? "collapsed" : "expanded")")
            Spacer(minLength: 4)
            NavigationLink(value: Route.project(repo)) {
                Text("All PRs").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.accent)
            }
            .accessibilityLabel("Open all pull requests in \(repo)")
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}
