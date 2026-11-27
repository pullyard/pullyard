import SwiftUI

/// Every pull request in one of your projects, not only yours, filtered by author — like a repo's PR page on GitHub.
struct AllPRsView: View {
    @Environment(AppModel.self) private var app
    @State private var repos: [RepoSummary] = []
    @State private var pinned: [String] = []
    @State private var repo: String?
    @State private var author: String?
    @State private var authors: [Actor] = []
    @State private var loadingRepos = false
    @State private var loadingAuthors = false
    @State private var showProjects = false
    @State private var showAuthors = false
    @State private var error: String?

    private var account: String { app.cacheAccount ?? "_" }
    private var repoKey: String { "allPRs.repo.\(account)" }
    private var pinnedKey: String { "allPRs.projects.\(account)" }
    private func authorKey(_ repo: String) -> String { "allPRs.author.\(account).\(repo)" }

    private var baseQuery: String {
        guard let repo else { return "" }
        return "repo:\(repo)" + (author.map { " author:\($0)" } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                projectsBar
                if repo != nil { authorBar }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            if let repo {
                SearchListView(title: "All PRs · \(Self.short(repo))", kind: "pr", baseQuery: baseQuery, ignoresFocus: true)
                    .id("all-prs|\(baseQuery)")
            } else {
                Spacer()
                if loadingRepos && repos.isEmpty {
                    PullYardLoader(size: 40)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.stack").font(.system(size: 30)).foregroundStyle(Color.syDim)
                        Text("Choose your projects").font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText)
                        Text(error ?? "Pick which repositories show up here, then switch between them to see every pull request.")
                            .font(.syCallout).foregroundStyle(Color.syMuted).multilineTextAlignment(.center).frame(maxWidth: 320)
                        Button("Choose projects…") { showProjects = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
            }
        }
        .task(id: account) { await loadRepos() }
        .task(id: repo) { await loadAuthors() }
    }

    static func short(_ repo: String) -> String { repo.split(separator: "/").last.map(String.init) ?? repo }
    static func ownerAvatar(_ repo: String) -> String? {
        repo.split(separator: "/").first.map { "https://github.com/\($0).png?size=40" }
    }

    // MARK: Projects

    private var projectsBar: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(pinned, id: \.self) { name in
                ProjectSegment(repo: name, count: repos.first { $0.nameWithOwner == name }?.pullRequests.totalCount,
                               twin: pinned.filter { Self.short($0) == Self.short(name) }.count > 1,
                               selected: repo == name) { select(repo: name) }
                    .contextMenu {
                        Button("Remove from All PRs") { toggle(name) }
                        Button("Open on GitHub") { if let u = URL(string: "https://github.com/\(name)/pulls") { NSWorkspace.shared.open(u) } }
                    }
            }
            Button { showProjects.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: pinned.isEmpty ? "plus" : "slider.horizontal.3")
                    Text(pinned.isEmpty ? "Choose projects" : "Projects")
                }
                .font(.syCallout)
                .foregroundStyle(Color.syMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose which projects show up here")
            .popover(isPresented: $showProjects, arrowEdge: .bottom) {
                PickerPanel(title: "PROJECTS", placeholder: "Filter projects", items: repos.map { r in
                    PickerPanel.Item(id: r.nameWithOwner, title: Self.short(r.nameWithOwner), subtitle: r.nameWithOwner,
                                     avatar: Self.ownerAvatar(r.nameWithOwner), icon: nil,
                                     trailing: r.pullRequests.totalCount > 0 ? "\(r.pullRequests.totalCount)" : nil)
                }, isSelected: { pinned.contains($0) }, loading: loadingRepos && repos.isEmpty) { id in
                    toggle(id)
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.syText.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.syLine))
    }

    // MARK: Author

    private var authorBar: some View {
        HStack(spacing: 6) {
            Button { showAuthors.toggle() } label: {
                HStack(spacing: 5) {
                    if let author {
                        Avatar(url: authors.first(where: { $0.login == author })?.avatarUrl ?? "https://github.com/\(author).png?size=40", size: 16)
                        Text(author).lineLimit(1)
                    } else {
                        Image(systemName: "person.2.fill").foregroundStyle(Color.syMuted)
                        Text("Author: anyone").lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.syDim)
                }
                .font(.syCallout.weight(.medium))
                .foregroundStyle(Color.syText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.syText.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.syLine))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Filter by author")
            .popover(isPresented: $showAuthors, arrowEdge: .bottom) {
                PickerPanel(title: "FILTER BY AUTHOR", placeholder: "Filter authors",
                            items: [PickerPanel.Item(id: "", title: "Anyone", subtitle: nil, avatar: nil, icon: "person.2")]
                                + authors.map { a in
                                    PickerPanel.Item(id: a.login, title: a.login, subtitle: a.login == app.user?.login ? "you" : nil,
                                                     avatar: a.avatarUrl ?? "", icon: nil)
                                },
                            isSelected: { $0 == (author ?? "") }, loading: loadingAuthors && authors.isEmpty) { id in
                    showAuthors = false
                    setAuthor(id.isEmpty ? nil : id)
                }
            }
            if author != nil {
                Button { setAuthor(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim)
                }
                .buttonStyle(.plain)
                .help("Show every author")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: State

    private func setAuthor(_ login: String?) {
        author = login
        guard let repo else { return }
        UserDefaults.standard.set(login, forKey: authorKey(repo))
    }

    private func select(repo id: String) {
        guard id != repo else { return }
        repo = id
        UserDefaults.standard.set(id, forKey: repoKey)
        author = UserDefaults.standard.string(forKey: authorKey(id))
        authors = []
    }

    private func toggle(_ id: String) {
        if let i = pinned.firstIndex(of: id) {
            pinned.remove(at: i)
            if repo == id {
                repo = nil
                if let next = pinned.first { select(repo: next) } else { UserDefaults.standard.removeObject(forKey: repoKey) }
            }
        } else {
            pinned.append(id)
            if repo == nil { select(repo: id) }
        }
        UserDefaults.standard.set(pinned, forKey: pinnedKey)
    }

    private func loadRepos() async {
        pinned = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
        let saved = UserDefaults.standard.string(forKey: repoKey)
        if repo == nil, let pick = saved.flatMap({ pinned.contains($0) ? $0 : nil }) ?? pinned.first {
            repo = pick
            author = UserDefaults.standard.string(forKey: authorKey(pick))
        }
        guard let api = app.api else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        do {
            var all: [RepoSummary] = []
            var after: String?
            for _ in 0..<4 {
                let page = try await api.repos(after: after)
                all += page.nodes
                guard page.pageInfo.hasNextPage, let next = page.pageInfo.endCursor else { break }
                after = next
            }
            repos = all.filter { !$0.isArchived }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if pinned.isEmpty && repo == nil { showProjects = true }
    }

    /// Authors of the project's recent pull requests, you first, then the busiest.
    private func loadAuthors() async {
        guard let api = app.api, let repo else { return }
        loadingAuthors = true
        defer { loadingAuthors = false }
        guard let result = try? await api.search("repo:\(repo) is:pr archived:false sort:updated-desc") else { return }
        var seen = Set<String>()
        var list: [Actor] = []
        if let me = app.user {
            list.append(Actor(login: me.login, avatarUrl: me.avatarUrl))
            seen.insert(me.login)
        }
        let all = result.nodes.compactMap(\.author)
        let counts = Dictionary(grouping: all, by: \.login).mapValues(\.count)
        for a in all.sorted(by: { counts[$0.login, default: 0] > counts[$1.login, default: 0] }) where !seen.contains(a.login) {
            seen.insert(a.login)
            list.append(a)
        }
        if let author, !seen.contains(author) { list.append(Actor(login: author, avatarUrl: nil)) }
        authors = list
    }
}

/// One project in the All PRs bar, styled like the account switcher.
private struct ProjectSegment: View {
    let repo: String
    let count: Int?
    let twin: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Avatar(url: AllPRsView.ownerAvatar(repo), size: 20)
                Text(twin ? repo : AllPRsView.short(repo))
                    .font(.syCallout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.syText : Color.syMuted)
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.syCaption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.syText : Color.syDim)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.syText.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.syRaised : (hover ? Color.syText.opacity(0.05) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.syLineStrong : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(count.map { "\(repo) · \($0) open" } ?? repo)
    }
}

/// A searchable list in a popover, in the app's panel style.
struct PickerPanel: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        /// Non-nil shows an avatar (empty string = placeholder).
        let avatar: String?
        let icon: String?
        var trailing: String? = nil
    }

    let title: String
    let placeholder: String
    let items: [Item]
    let isSelected: (String) -> Bool
    var loading = false
    let onPick: (String) -> Void
    @State private var query = ""

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) || ($0.subtitle ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if loading {
                        VStack(alignment: .leading, spacing: 10) {
                            ShimmerBar(width: 180, height: 12)
                            ShimmerBar(width: 140, height: 12)
                            ShimmerBar(width: 200, height: 12)
                        }
                        .padding(10)
                    }
                    ForEach(shown) { item in
                        PickerPanelRow(item: item, selected: isSelected(item.id)) { onPick(item.id) }
                    }
                    if !loading && shown.isEmpty {
                        Text("Nothing matches").font(.syCaption).foregroundStyle(Color.syMuted).padding(10)
                    }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: 320)
    }
}

private struct PickerPanelRow: View {
    let item: PickerPanel.Item
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let avatar = item.avatar {
                        Avatar(url: avatar.isEmpty ? nil : avatar, size: 22)
                    } else if let icon = item.icon {
                        Image(systemName: icon).foregroundStyle(selected ? Color.syAgentAccent : Color.syMuted)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.syCallout.weight(selected ? .semibold : .regular)).foregroundStyle(Color.syText).lineLimit(1)
                        if item.subtitle == "you" {
                            Text("you").font(.syCaption2.weight(.semibold)).foregroundStyle(Color.syAgentAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.syAgentAccent.opacity(0.14)))
                        }
                    }
                    if let subtitle = item.subtitle, subtitle != "you", subtitle != item.title {
                        Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let trailing = item.trailing {
                    Text(trailing).font(.syCaption.monospacedDigit()).foregroundStyle(Color.syDim)
                }
                if selected {
                    Image(systemName: "checkmark").font(.syCaption.weight(.bold)).foregroundStyle(Color.syAgentAccent).frame(width: 14)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && !selected ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
