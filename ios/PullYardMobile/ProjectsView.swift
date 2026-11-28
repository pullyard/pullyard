import SwiftUI

enum ProjectsMode: String, CaseIterable, Identifiable {
    case repositories, jira
    var id: String { rawValue }
    static let key = "projects.mode"
}

struct ProjectsHome: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var jira = JiraStore.shared
    @AppStorage(ProjectsMode.key) private var mode: ProjectsMode = .repositories

    private var hasJira: Bool { jira.isConfigured || model.isDemo }

    var body: some View {
        Group {
            if hasJira, mode == .jira {
                JiraBoardView()
            } else {
                ProjectsView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if hasJira {
                Picker("Show", selection: $mode) {
                    Text("Repositories").tag(ProjectsMode.repositories)
                    Text("Jira").tag(ProjectsMode.jira)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var isReordering = false
    @AppStorage("projects.owner") private var owner = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var all: [ProjectSummary] { model.allProjects }
    private static func owner(of name: String) -> String { name.split(separator: "/").first.map(String.init) ?? name }
    private var owners: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for project in all { counts[Self.owner(of: project.nameWithOwner), default: 0] += 1 }
        for name in model.pinnedProjects where counts[Self.owner(of: name)] == nil { counts[Self.owner(of: name)] = 1 }
        let me = model.user?.login
        return counts.map { (name: $0.key, count: $0.value) }.sorted { lhs, rhs in
            if (lhs.name == me) != (rhs.name == me) { return lhs.name == me }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
    private var activeOwner: String? { owners.contains { $0.name == owner } ? owner : nil }
    private func inOwner(_ name: String) -> Bool { activeOwner.map { Self.owner(of: name) == $0 } ?? true }
    private var filtered: [ProjectSummary] {
        let scoped = all.filter { inOwner($0.nameWithOwner) }
        guard !trimmed.isEmpty else { return scoped }
        return scoped.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(trimmed) || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed) }
    }
    private var pinned: [ProjectSummary] {
        let byName = Dictionary(all.map { ($0.nameWithOwner, $0) }, uniquingKeysWith: { first, _ in first })
        return model.pinnedProjects.map { byName[$0] ?? ProjectSummary(nameWithOwner: $0) }
            .filter { inOwner($0.nameWithOwner) && (trimmed.isEmpty || $0.nameWithOwner.localizedCaseInsensitiveContains(trimmed)) }
    }
    private var waiting: [ProjectSummary] {
        filtered.filter { !model.isPinned($0.nameWithOwner) && model.reviewRequests(in: $0.nameWithOwner) > 0 }
            .sorted { model.reviewRequests(in: $0.nameWithOwner) > model.reviewRequests(in: $1.nameWithOwner) }
    }
    private var others: [ProjectSummary] {
        filtered.filter { !model.isPinned($0.nameWithOwner) && model.reviewRequests(in: $0.nameWithOwner) == 0 }
            .sorted { lhs, rhs in
                let left = lhs.openPullRequests ?? 0, right = rhs.openPullRequests ?? 0
                if (left > 0) != (right > 0) { return left > 0 }
                return (lhs.pushedAt ?? .distantPast) > (rhs.pushedAt ?? .distantPast)
            }
    }
    private var typedRepo: String? {
        let candidate = trimmed.replacingOccurrences(of: "https://github.com/", with: "")
        let parts = candidate.split(separator: "/")
        guard parts.count == 2, !all.contains(where: { $0.nameWithOwner.caseInsensitiveCompare(candidate) == .orderedSame }) else { return nil }
        return parts.joined(separator: "/")
    }

    var body: some View {
        List {
            Section {
                FreshnessLabel(state: model.projectsState) { Task { await model.refreshProjects() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .listSectionSeparator(.hidden)

            if owners.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Chip(title: "All", count: all.count, isSelected: activeOwner == nil) { owner = "" }
                            ForEach(owners, id: \.name) { item in
                                Chip(title: item.name, count: item.count, isSelected: activeOwner == item.name) {
                                    owner = activeOwner == item.name ? "" : item.name
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)
            }

            if let typedRepo {
                Section {
                    NavigationLink(value: Route.project(typedRepo)) {
                        Label("Open \(typedRepo)", systemImage: "arrow.right.circle.fill").foregroundStyle(MobileTheme.accent)
                    }
                    .pyRow()
                }
            }

            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { project in projectLink(project) }
                        .onMove { from, to in model.pinnedProjects.move(fromOffsets: from, toOffset: to) }
                } header: {
                    HStack {
                        Label("Pinned", systemImage: "pin.fill")
                        Spacer()
                        if pinned.count > 1 && trimmed.isEmpty {
                            Button(isReordering ? "Done" : "Reorder") { withAnimation { isReordering.toggle() } }.textCase(nil)
                        }
                    }
                }
            }

            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { project in projectLink(project) }
                } header: {
                    Label("Waiting for your review", systemImage: "eye")
                }
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { project in projectLink(project) }
                } header: {
                    Text(pinned.isEmpty && waiting.isEmpty ? "Your projects · \(others.count)" : "All projects · \(others.count)")
                }
            }

            if all.isEmpty {
                Section {
                    Group {
                        switch model.projectsState {
                        case let .failed(message):
                            ErrorStateView(title: "Couldn't load projects", message: message) { Task { await model.refreshProjects() } }
                        case .loaded:
                            PYEmptyState(title: "No projects yet", message: "Repositories you own, collaborate on or belong to through an organization appear here.")
                        default:
                            PullYardLoader(title: "Loading your projects…", size: 72)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else if filtered.isEmpty && pinned.isEmpty && typedRepo == nil {
                Section {
                    PYEmptyState(title: "No matching projects", message: "Type owner/name to open any repository you can access.")
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .pyListStyle()
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .searchable(text: $query, prompt: "Find a project or type owner/name")
        .refreshable { await model.refreshProjects() }
        .pullToRefreshLogo(isRefreshing: model.projectsState == .loading && !all.isEmpty)
        .navigationTitle("Projects")
        .accountButton()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refreshProjects() } } label: { RefreshGlyph(isRefreshing: model.projectsState == .loading) }
                    .disabled(model.projectsState == .loading)
                    .accessibilityLabel("Refresh projects")
            }
        }
        .task {
            if model.projects.isEmpty || model.projectsState == .idle { await model.refreshProjects() }
        }
        .feedbackChrome { Task { await model.refreshProjects() } }
    }

    private func projectLink(_ project: ProjectSummary) -> some View {
        NavigationLink(value: Route.project(project.nameWithOwner)) {
            ProjectRow(project: project, reviewRequests: model.reviewRequests(in: project.nameWithOwner), mine: model.myOpenPulls(in: project.nameWithOwner), pinned: model.isPinned(project.nameWithOwner))
        }
        .pyRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { withAnimation { model.togglePin(project.nameWithOwner) } } label: {
                Label(model.isPinned(project.nameWithOwner) ? "Unpin" : "Pin", systemImage: model.isPinned(project.nameWithOwner) ? "pin.slash" : "pin")
            }
            .tint(MobileTheme.coral)
        }
        .contextMenu {
            Button { withAnimation { model.togglePin(project.nameWithOwner) } } label: {
                Label(model.isPinned(project.nameWithOwner) ? "Unpin" : "Pin to top", systemImage: model.isPinned(project.nameWithOwner) ? "pin.slash" : "pin")
            }
            Link(destination: project.webURL) { Label("Open on GitHub", systemImage: "safari") }
            Button { UIPasteboard.general.url = project.webURL } label: { Label("Copy link", systemImage: "link") }
        }
        .accessibilityActions {
            Button(model.isPinned(project.nameWithOwner) ? "Unpin" : "Pin") { model.togglePin(project.nameWithOwner) }
        }
    }
}

struct ProjectRow: View {
    let project: ProjectSummary
    var reviewRequests = 0
    var mine = 0
    var pinned = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: project.ownerAvatar ?? URL(string: "https://github.com/\(project.owner).png"), size: 38, fallback: project.owner)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    (Text(project.owner + "/").font(.subheadline).foregroundStyle(MobileTheme.muted)
                    + Text(project.name).font(.body.weight(.semibold)).foregroundStyle(MobileTheme.ink))
                        .lineLimit(1)
                    if project.isPrivate { Image(systemName: "lock.fill").mobileFont(size: 10).foregroundStyle(MobileTheme.muted) }
                    if pinned { Image(systemName: "pin.fill").mobileFont(size: 10).foregroundStyle(MobileTheme.coral) }
                }
                .lineLimit(1)
                if let description = project.description, !description.isEmpty {
                    Text(description).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let open = project.openPullRequests {
                        Label("\(open) open", systemImage: "arrow.triangle.pull").foregroundStyle(open > 0 ? MobileTheme.green : MobileTheme.muted)
                    }
                    if mine > 0 { Label("\(mine) mine", systemImage: "person").foregroundStyle(MobileTheme.accent) }
                    if let pushed = project.pushedAt { RelativeTime(date: pushed).foregroundStyle(MobileTheme.muted) }
                }
                .labelStyle(.titleAndIcon)
                .mobileFont(size: 12, weight: .medium)
            }
            Spacer(minLength: 4)
            if reviewRequests > 0 {
                Text("\(reviewRequests)")
                    .mobileFont(size: 13, weight: .bold, design: .rounded)
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .padding(.horizontal, 4)
                    .pyGlassCapsule(tint: MobileTheme.coral, fallback: MobileTheme.coral)
                    .accessibilityLabel("\(reviewRequests) waiting for your review")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDetailView: View {
    let repo: String
    @EnvironmentObject private var model: AppModel
    @State private var status: PRStatusFilter = .open
    @State private var showIssues = false
    @State private var audience: ProjectAudience = .everyone

    private var key: PRListKey { .project(repo, status: status, audience: audience) }
    private var pulls: [PullRequest] { model.pulls(for: key).sorted { $0.updatedAt > $1.updatedAt } }
    private var summary: ProjectSummary? { model.allProjects.first { $0.nameWithOwner == repo } }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)

            if showIssues {
                ProjectIssuesSections(repo: repo, state: status == .open ? "open" : status == .all ? "all" : "closed")
            } else if pulls.isEmpty {
                Section {
                    Group {
                        switch model.listState(key) {
                        case let .failed(message):
                            ErrorStateView(title: "Couldn't load pull requests", message: message) { Task { await model.refreshList(key) } }
                        case .loaded:
                            PYEmptyState(title: "No pull requests", message: emptyMessage) {
                                if status != .all { Button("Show all statuses") { status = .all }.buttonStyle(.bordered) }
                            }
                        default:
                            PullYardLoader(title: "Loading pull requests…", size: 72)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(pulls) { pr in
                        NavigationLink(value: Route.pull(pr.key ?? PRKey(repo: repo, number: pr.number))) {
                            PullRequestRow(pr: pr, hideState: status == .open && pr.displayState == .open, showRepo: false)
                        }
                        .pyRow()
                        .onAppear {
                            if pr.id == pulls.last?.id { Task { await model.loadNextPage(key) } }
                        }
                    }
                    if model.hasMore(key) {
                        HStack { Spacer(); PullYardLoader(size: 28); Spacer() }
                            .pyRow()
                            .onAppear { Task { await model.loadNextPage(key) } }
                    }
                } header: {
                    Text("\(pulls.count) of \(model.listTotals[key].map(String.init) ?? "–")").textCase(nil)
                }
            }
        }
        .pyListStyle()
        .refreshable { await model.refreshList(key) }
        .pullToRefreshLogo(isRefreshing: model.listState(key) == .loading && !pulls.isEmpty)
        .navigationTitle(String(repo.split(separator: "/").last ?? Substring(repo)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(value: Route.newPull(repo: repo, head: nil)) { Label("New pull request", systemImage: "arrow.triangle.pull") }
                    NavigationLink(value: Route.newIssue(repo)) { Label("New issue", systemImage: "smallcircle.filled.circle") }
                    NavigationLink(value: Route.browse(repo: repo, ref: nil, path: "")) { Label("Browse code", systemImage: "folder") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Create")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { model.togglePin(repo) } } label: {
                    Image(systemName: model.isPinned(repo) ? "pin.fill" : "pin").foregroundStyle(model.isPinned(repo) ? MobileTheme.coral : MobileTheme.accent)
                }
                .accessibilityLabel(model.isPinned(repo) ? "Unpin project" : "Pin project")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await model.refreshList(key) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Link(destination: URL(string: "https://github.com/\(repo)/pulls")!) { Label("Open on GitHub", systemImage: "safari") }
                } label: { RefreshGlyph(isRefreshing: model.listState(key) == .loading, symbol: "ellipsis.circle") }
            }
        }
        .task(id: key) {
            if model.pulls(for: key).isEmpty || model.listState(key) == .idle { await model.refreshList(key) }
        }
        .feedbackChrome { Task { await model.refreshList(key) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(url: summary?.ownerAvatar ?? URL(string: "https://github.com/\(repo.split(separator: "/").first ?? "").png"), size: 44, fallback: repo)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(repo).mobileFont(size: 18, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1).truncationMode(.middle)
                    if let description = summary?.description, !description.isEmpty {
                        Text(description).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 20)
            SectionSwitcherBar(showIssues: $showIssues)
                .padding(.horizontal, 16)
            if !showIssues {
            ScrollView(.horizontal, showsIndicators: false) {
                PYGlassGroup {
                    HStack(spacing: 8) {
                        ForEach(ProjectAudience.allCases) { option in
                            Chip(title: option.rawValue, count: count(for: option), isSelected: audience == option, tint: option == .needsMyReview ? MobileTheme.coral : MobileTheme.accentFill) {
                                withAnimation(.snappy) { audience = option }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
            }
            Picker("Status", selection: $status) {
                ForEach(PRStatusFilter.allCases.filter { !showIssues || $0 != .merged }) { Text(L($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            HStack {
                Spacer()
                FreshnessLabel(state: model.listState(key)) { Task { await model.refreshList(key) } }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 6)
    }

    private func count(for option: ProjectAudience) -> Int? {
        switch option {
        case .everyone: return status == .open ? summary?.openPullRequests : model.listTotals[.project(repo, status: status, audience: .everyone)]
        case .needsMyReview: let value = model.reviewRequests(in: repo); return value > 0 ? value : nil
        case .mine: let value = model.myOpenPulls(in: repo); return value > 0 ? value : nil
        }
    }

    private var emptyMessage: String {
        let state = status == .all ? "" : "\(status.rawValue.lowercased()) "
        switch audience {
        case .everyone: return "\(repo) has no \(state)pull requests."
        case .needsMyReview: return "Nothing in \(repo) is waiting for your review."
        case .mine: return "You have no \(state)pull requests in \(repo)."
        }
    }
}

private struct SectionSwitcherBar: View {
    @Binding var showIssues: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            item("Pull requests", symbol: "arrow.triangle.pull", selected: !showIssues) { showIssues = false }
            item("Issues", symbol: "smallcircle.filled.circle", selected: showIssues) { showIssues = true }
        }
        .padding(4)
        .pyGlassCapsule(fallback: MobileTheme.card)
        .sensoryFeedback(.selection, trigger: showIssues)
    }

    private func item(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { action() } } label: {
            Label(L(title), systemImage: symbol)
                .mobileFont(size: 14, weight: .semibold)
                .foregroundStyle(selected ? Color.white : MobileTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background {
                    if selected { Capsule().fill(MobileTheme.accentFill).matchedGeometryEffect(id: "tab", in: namespace) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.pyPlain)
    }
}
