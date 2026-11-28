import SwiftUI

@Observable
@MainActor
final class RepoFocus {
    static let shared = RepoFocus()
    private static let storageKey = "focus.repos"

    private var byAccount: [String: [String]]

    private init() {
        byAccount = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    }

    private func slot(_ account: String?) -> String { account ?? "_" }

    func repos(_ account: String?) -> [String] {
        byAccount[slot(account)] ?? []
    }

    func isActive(_ account: String?) -> Bool {
        !repos(account).isEmpty
    }

    func contains(_ repo: String, account: String?) -> Bool {
        repos(account).contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
    }

    func includes(_ repo: String, account: String?) -> Bool {
        !isActive(account) || contains(repo, account: account)
    }

    func query(_ account: String?) -> String {
        repos(account).map { "repo:\($0)" }.joined(separator: " ")
    }

    func toggle(_ repo: String, account: String?) {
        var list = repos(account)
        if let i = list.firstIndex(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) {
            list.remove(at: i)
        } else {
            list.append(repo)
        }
        set(list, account: account)
    }

    func clear(_ account: String?) {
        set([], account: account)
    }

    private func set(_ list: [String], account: String?) {
        let sorted = list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        byAccount[slot(account)] = sorted.isEmpty ? nil : sorted
        UserDefaults.standard.set(byAccount, forKey: Self.storageKey)
    }

    func summary(_ account: String?) -> String {
        let list = repos(account)
        switch list.count {
        case 0: return "All repositories"
        case 1: return list[0]
        default: return "\(list.count) repositories"
        }
    }
}

struct FocusSidebarRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.sidebarCompact) private var compact
    @State private var showPicker = false
    @State private var hovering = false
    private var focus: RepoFocus { .shared }

    var body: some View {
        let active = focus.isActive(app.cacheAccount)
        Button { showPicker.toggle() } label: {
            Group {
                if compact {
                    SidebarIcon(systemImage: "scope", color: active ? .syAccent : .sySlate)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xs)
                        .overlay(alignment: .topTrailing) {
                            if active {
                                Circle().fill(Color.syAccentFill).frame(width: 7, height: 7).offset(x: -6, y: 2)
                            }
                        }
                } else {
                    HStack(spacing: 8) {
                        SidebarIcon(systemImage: "scope", color: active ? .syAccent : .sySlate)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Focus on")
                                .font(.syCaption)
                                .foregroundStyle(Color.syMuted)
                            Text(focus.summary(app.cacheAccount))
                                .font(.syBody)
                                .fontWeight(active ? .medium : .regular)
                                .foregroundStyle(Color.syText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if active {
                            Button { focus.clear(app.cacheAccount) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim)
                            }
                            .buttonStyle(.plain)
                            .help("Clear focus")
                            .accessibilityLabel("Clear focus")
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.syCaption2.weight(.semibold))
                                .foregroundStyle(Color.syDim)
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, compact ? 0 : 3)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape
                    .fill(active ? Color.syAccent.opacity(0.12) : Color.syText.opacity(hovering ? 0.07 : 0.04))
                    .overlay(shape.strokeBorder(active ? Color.syAccent.opacity(0.35) : Color.syLine, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .popover(isPresented: $showPicker, arrowEdge: .trailing) {
            FocusPicker()
                .environment(app)
        }
        .help("Focus on: \(focus.summary(app.cacheAccount))")
        .accessibilityLabel("Focus on")
        .accessibilityValue(focus.summary(app.cacheAccount))
    }
}

struct FocusPicker: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var accessible: [String] = []
    @State private var loading = false
    @State private var involved: [String] = []
    @State private var owner: String?
    @State private var orgs: [GitHubOwner] = []
    @State private var ownerRepos: [String: [String]] = [:]
    @State private var ownerError: [String: String] = [:]
    @State private var loadingOwner: String?
    private var focus: RepoFocus { .shared }

    /// You, your organizations, then other owners of repositories you can see.
    private var owners: [GitHubOwner] {
        var out: [GitHubOwner] = []
        if let me = app.user { out.append(GitHubOwner(login: me.login, avatarUrl: me.avatarUrl)) }
        for o in orgs where !out.contains(where: { $0.login.lowercased() == o.login.lowercased() }) { out.append(o) }
        var others = 0
        for repo in involved + accessible where others < 6 {
            let login = String(repo.split(separator: "/").first ?? "")
            if !login.isEmpty, !out.contains(where: { $0.login.lowercased() == login.lowercased() }) {
                out.append(GitHubOwner(login: login, avatarUrl: nil))
                others += 1
            }
        }
        return out
    }

    private var ownerRow: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
                OwnerChip(login: "All", avatar: nil, selected: owner == nil) { owner = nil }
                ForEach(owners) { o in
                    OwnerChip(login: o.login, avatar: o.avatarUrl ?? "https://github.com/\(o.login).png?size=40", selected: owner == o.login) {
                        owner = o.login
                        Task { await loadOwner(o.login) }
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func loadOrgs() async {
        let key = app.cacheAccount ?? "_"
        if let cached = OrgCache.orgs[key] { orgs = cached }
        guard app.forge == nil, let api = app.api, let fresh = try? await api.organizations() else { return }
        OrgCache.orgs[key] = fresh
        orgs = fresh
    }

    private func loadOwner(_ login: String) async {
        guard ownerRepos[login] == nil, loadingOwner != login, let api = app.api else { return }
        loadingOwner = login
        defer { if loadingOwner == login { loadingOwner = nil } }
        do {
            var names: [String] = []
            var after: String?
            for _ in 0..<4 {
                guard let page = try await api.ownerRepos(login, after: after) else { break }
                names += page.nodes.filter { !$0.isArchived }.map(\.nameWithOwner)
                guard page.pageInfo.hasNextPage, let next = page.pageInfo.endCursor else { break }
                after = next
            }
            ownerRepos[login] = names
            ownerError[login] = names.isEmpty ? "No repositories visible. If \(login) restricts third-party apps, grant PullYard access in GitHub (Settings → Applications)." : nil
        } catch {
            ownerError[login] = "\(error.localizedDescription). \(login) may need to grant PullYard access in GitHub (Settings → Applications)."
        }
    }

    private func involvedRepos() -> [String] {
        let items = app.reviewRequests + app.myPRs + SearchListModel.cachedItems + ForgeListModel.cachedItems
        var counts: [String: Int] = [:]
        for item in items { counts[item.repository.nameWithOwner, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map(\.key)
    }

    private func matches(_ repo: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        if let owner, !repo.lowercased().hasPrefix(owner.lowercased() + "/") { return false }
        return q.isEmpty || repo.localizedCaseInsensitiveContains(q)
    }

    private var sections: (selected: [String], involved: [String], other: [String]) {
        let selected = focus.repos(app.cacheAccount)
        let chosen = Set(selected.map { $0.lowercased() })
        let inv = involved.filter { !chosen.contains($0.lowercased()) }
        let seen = chosen.union(inv.map { $0.lowercased() })
        var pool = accessible
        if let owner, let extra = ownerRepos[owner] {
            let have = Set(pool.map { $0.lowercased() })
            pool += extra.filter { !have.contains($0.lowercased()) }
        }
        let other = pool.filter { !seen.contains($0.lowercased()) }
        return (selected.filter(matches), inv.filter(matches), other.filter(matches))
    }

    private var typedRepo: String? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard let ref = RepoRef(full: q), !ref.owner.isEmpty, !ref.name.isEmpty else { return nil }
        let known = focus.repos(app.cacheAccount) + involved + accessible
        return known.contains { $0.caseInsensitiveCompare(ref.full) == .orderedSame } ? nil : ref.full
    }

    var body: some View {
        let s = sections
        let account = app.cacheAccount
        let active = focus.isActive(account)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus on").font(.syHeadline).foregroundStyle(Color.syText)
                Text("Pull requests, issues and code show only these repositories.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.syDim)
                TextField("Search or type owner/name", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let typedRepo {
                            focus.toggle(typedRepo, account: account)
                            text = ""
                        }
                    }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.syCallout)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Radius.m).fill(Color.syLine.opacity(0.7)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if app.forge == nil {
                ownerRow
            }
            Rectangle().fill(Color.syLine).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let typedRepo {
                        FocusRepoRow(repo: typedRepo, checked: false, adding: true) {
                            focus.toggle(typedRepo, account: account)
                            text = ""
                        }
                    }
                    if let owner, let err = ownerError[owner] {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.syCaption).foregroundStyle(Color.syAmber)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    section("Focused", s.selected)
                    section("You’re involved", s.involved)
                    section(app.forge == nil ? (owner.map { "\($0) repositories" } ?? "Your repositories") : "Other", s.other)
                    if loading || (owner != nil && loadingOwner == owner) {
                        HStack(spacing: Space.s) {
                            PYLoader(size: 14)
                            Text("Loading repositories…").font(.syCaption).foregroundStyle(Color.syMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    } else if s.selected.isEmpty, s.involved.isEmpty, s.other.isEmpty, typedRepo == nil {
                        Text(text.isEmpty ? "No repositories yet." : "No matches. Type owner/name to add one.")
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(height: 320)
            Rectangle().fill(Color.syLine).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: active ? "scope" : "circle.dashed")
                    .foregroundStyle(active ? Color.syAccent : Color.syDim)
                Text(active ? "Focused on " + plural(focus.repos(account).count, "repository", "repositories") : "Showing all repositories")
                    .foregroundStyle(Color.syMuted)
                Spacer()
                if active {
                    Button("Show all") { focus.clear(account) }
                        .buttonStyle(.link)
                }
            }
            .font(.syCaption)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 380)
        .task(id: app.cacheAccount) {
            involved = involvedRepos()
            if let cached = OrgCache.repos[app.cacheAccount ?? "_"] { accessible = cached }
            if let cached = OrgCache.orgs[app.cacheAccount ?? "_"] { orgs = cached }
            await loadOrgs()
            await loadAccessible()
            OrgCache.repos[app.cacheAccount ?? "_"] = accessible
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ repos: [String]) -> some View {
        if !repos.isEmpty {
            Text(title.uppercased())
                .font(.sy(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.syDim)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 3)
            ForEach(repos, id: \.self) { repo in
                FocusRepoRow(repo: repo, checked: focus.contains(repo, account: app.cacheAccount)) {
                    focus.toggle(repo, account: app.cacheAccount)
                }
            }
        }
    }

    private func loadAccessible() async {
        guard app.forge == nil, let api = app.api else { return }
        let account = app.cacheAccount
        if let snap = await ListCache.load([RepoSummary].self, account: account, key: "repos") {
            accessible = snap.value.filter { !$0.isArchived }.map(\.nameWithOwner)
        }
        loading = accessible.isEmpty
        defer { loading = false }
        var names: [String] = []
        var cursor: String?
        for _ in 0..<6 {
            guard let page = try? await api.repos(after: cursor), app.api === api else { break }
            names += page.nodes.filter { !$0.isArchived }.map(\.nameWithOwner)
            guard page.pageInfo.hasNextPage, let next = page.pageInfo.endCursor else { break }
            cursor = next
        }
        if !names.isEmpty { accessible = names }
    }
}

private struct FocusRepoRow: View {
    let repo: String
    let checked: Bool
    var adding = false
    let action: () -> Void
    @State private var hovering = false

    private var owner: String { repo.split(separator: "/").first.map(String.init) ?? "" }
    private var name: String { repo.split(separator: "/").dropFirst().joined(separator: "/") }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: adding ? "plus.circle.fill" : checked ? "checkmark.square.fill" : "square")
                    .font(.syBody)
                    .foregroundStyle(adding || checked ? Color.syAccent : Color.syDim)
                    .frame(width: 18)
                HStack(spacing: 0) {
                    if adding { Text("Add ").foregroundStyle(Color.syMuted) }
                    Text(owner + "/").foregroundStyle(Color.syMuted)
                    Text(name).foregroundStyle(Color.syText).fontWeight(checked ? .semibold : .medium)
                }
                .font(.syCallout)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Radius.m - 1).fill(hovering ? Color.syHover : checked ? Color.syAccent.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(adding ? "Add \(repo)" : repo)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

struct FocusBanner: View {
    @Environment(AppModel.self) private var app
    private var focus: RepoFocus { .shared }

    var body: some View {
        if focus.isActive(app.cacheAccount) {
            HStack(spacing: 6) {
                Image(systemName: "scope").foregroundStyle(Color.syAccent)
                Text("Focused on \(focus.summary(app.cacheAccount))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(focus.repos(app.cacheAccount).joined(separator: "\n"))
                Spacer(minLength: 4)
                Button("Show all") { focus.clear(app.cacheAccount) }
                    .buttonStyle(.link)
            }
            .font(.syCaption)
            .foregroundStyle(Color.syMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.syAccent.opacity(0.08))
        }
    }
}
