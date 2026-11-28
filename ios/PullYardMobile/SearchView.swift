import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mobile.search.recent") private var recentRaw = ""
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var results: [PullRequest] = []
    @State private var totalCount = 0
    @State private var cursor: String?
    @State private var isLoadingMore = false
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private let shortcuts: [(title: String, query: String, symbol: String)] = [
        ("Open, needs my review", "is:open review-requested:@me", "eye"),
        ("My open pull requests", "is:open author:@me", "person"),
        ("Recently merged by me", "is:merged author:@me", "arrow.triangle.merge"),
        ("Mentioning me", "is:open mentions:@me", "at"),
    ]

    var body: some View {
        List {
            if let route = DeepLink.route(fromText: query) {
                Section {
                    NavigationLink(value: route) {
                        Label(linkTitle(route), systemImage: "arrow.right.circle.fill").foregroundStyle(MobileTheme.accent)
                    }
                    .pyRow()
                }
            }
            if activeQuery.isEmpty && results.isEmpty && !isSearching {
                if !recent.isEmpty {
                    Section {
                        ForEach(recent, id: \.self) { item in
                            Button { run(item) } label: { Label(item, systemImage: "clock.arrow.circlepath").foregroundStyle(MobileTheme.ink) }
                                .pyRow()
                        }
                        .onDelete { offsets in
                            var items = recent; items.remove(atOffsets: offsets); recentRaw = items.joined(separator: "\n")
                        }
                    } header: {
                        HStack { Text("Recent"); Spacer(); Button("Clear") { recentRaw = "" }.textCase(nil) }
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section("Saved") {
                        ForEach(model.savedSearches, id: \.self) { item in
                            Button { run(item) } label: { Label(item, systemImage: "bookmark.fill").foregroundStyle(MobileTheme.ink) }
                                .pyRow()
                        }
                        .onDelete { offsets in offsets.map { model.savedSearches[$0] }.forEach(model.toggleSaved) }
                    }
                }
                Section("Shortcuts") {
                    ForEach(shortcuts, id: \.query) { item in
                        Button { run(item.query) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol).foregroundStyle(MobileTheme.accent).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.ink)
                                    Text(item.query).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted)
                                }
                            }
                        }
                        .pyRow()
                    }
                }
                Section {
                    Text("Search by title, repository (repo:owner/name), author (author:login) or any GitHub search qualifier.")
                        .mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                        .listRowBackground(Color.clear)
                }
            } else if isSearching && results.isEmpty {
                PullYardLoader(title: "Searching GitHub…", size: 72)
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                    .listRowBackground(Color.clear)
            } else if let error, results.isEmpty {
                ErrorStateView(title: "Search failed", message: error) { run(activeQuery) }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
            } else if results.isEmpty {
                PYEmptyState(title: "No pull requests", message: "Nothing matches “\(activeQuery)”. Try fewer words or another qualifier.")
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { pr in
                        NavigationLink(value: Route.pull(pr.key ?? PRKey(repo: pr.repoName, number: pr.number))) { PullRequestRow(pr: pr) }
                            .pyRow()
                    }
                    if cursor != nil && results.count < totalCount {
                        HStack { Spacer(); PullYardLoader(size: 28); Spacer() }
                            .pyRow()
                            .onAppear { Task { await loadMore() } }
                    }
                } header: {
                    Text("\(totalCount) result\(totalCount == 1 ? "" : "s")").textCase(nil)
                }
            }
        }
        .pyListStyle()
        .refreshable { if !activeQuery.isEmpty { await search(activeQuery) } }
        .pullToRefreshLogo(isRefreshing: isSearching && !results.isEmpty)
        .navigationTitle("Search")
        .accountButton()
        .searchable(text: $query, prompt: "Pull requests, repos, authors")
        .searchSuggestions {
            if trimmedQuery.count >= 1 {
                ForEach(["is:open", "author:@me", "review-requested:@me", "is:merged"].filter { !query.contains($0) }, id: \.self) { qualifier in
                    Text("\(trimmedQuery) \(qualifier)").searchCompletion("\(trimmedQuery) \(qualifier)")
                }
            }
        }
        .onSubmit(of: .search) { run(trimmedQuery) }
        .toolbar {
            if !activeQuery.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    let saved = model.savedSearches.contains(activeQuery)
                    Button { withAnimation { model.toggleSaved(activeQuery) }; model.feedback.success(saved ? "Removed from Pull requests" : "Saved · shows as a chip in Pull requests") } label: {
                        Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(saved ? "Remove saved search" : "Save search")
                }
            }
        }
        .onChange(of: query) { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            searchTask?.cancel()
            if trimmed.isEmpty { activeQuery = ""; results = []; error = nil; return }
            guard trimmed.count >= 3 else { return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                await search(trimmed)
            }
        }
        .feedbackChrome()
    }

    private func linkTitle(_ route: Route) -> String {
        switch route {
        case let .pull(key), let .files(key): "Open \(key.repo) #\(key.number)"
        case let .project(repo): "Open project \(repo)"
        default: "Open link"
        }
    }

    private func run(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if query != trimmed { query = trimmed }
        searchTask?.cancel()
        searchTask = Task { await search(trimmed) }
        remember(trimmed)
    }

    private func remember(_ value: String) {
        var items = recent.filter { $0 != value }
        items.insert(value, at: 0)
        recentRaw = items.prefix(8).joined(separator: "\n")
    }

    private func search(_ value: String) async {
        isSearching = true; error = nil
        defer { isSearching = false }
        do {
            let page = try await model.search(value)
            guard !Task.isCancelled, value == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            activeQuery = value
            withAnimation(.snappy) { results = page.items }
            totalCount = page.totalCount
            cursor = page.nextCursor
        } catch {
            guard !error.isCancellation else { return }
            activeQuery = value
            if results.isEmpty { self.error = error.localizedDescription } else { model.feedback.error(error, key: "search") }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let current = cursor, !activeQuery.isEmpty else { return }
        let value = activeQuery
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await model.search(value, cursor: current)
            guard value == activeQuery else { return }
            results = PullListMerger.appendPage(existing: results, page: page.items)
            totalCount = page.totalCount
            cursor = page.nextCursor
        } catch {
            model.feedback.error(error, key: "search-more")
        }
    }
}
