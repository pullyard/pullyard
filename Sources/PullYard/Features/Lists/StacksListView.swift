import SwiftUI

struct StackEntry: Identifiable, Equatable {
    let repo: RepoRef
    let tree: StackTree
    let mine: [Int]
    let updated: Date

    var id: String { "\(repo.full)#\(tree.root)" }
    var ref: ItemRef { ItemRef(repo: repo, number: tree.current) }

    var ordered: [StackNode] {
        var out: [StackNode] = []
        var queue = [tree.root]
        while !queue.isEmpty {
            let n = queue.removeFirst()
            if let node = tree.nodes[n] { out.append(node) }
            queue += tree.children[n] ?? []
        }
        return out
    }

    static func collect(repo: RepoRef, mine: [Int], open: [StackNode]) -> [StackEntry] {
        var byRoot: [Int: StackEntry] = [:]
        let index = Dictionary(open.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        for number in mine {
            guard let node = index[number], let tree = StackTree.build(current: node, open: open, repo: repo.full) else { continue }
            let mineHere = mine.filter { tree.nodes[$0] != nil }
            let updated = tree.nodes.values.compactMap(\.updatedAt).max() ?? .distantPast
            if byRoot[tree.root] == nil {
                byRoot[tree.root] = StackEntry(repo: repo, tree: tree, mine: mineHere, updated: updated)
            }
        }
        return byRoot.values.sorted { $0.updated > $1.updated }
    }
}

@Observable
@MainActor
final class StacksModel {
    static let maxRepos = 8
    private static var last: (account: String?, entries: [StackEntry], at: Date)?

    var entries: [StackEntry] = []
    var loading = false
    var refreshing = false
    var error: String?
    var lastUpdated: Date?
    @ObservationIgnored private var generation = 0

    static func reset() {
        last = nil
    }

    func restore(account: String?) {
        guard let last = Self.last, last.account == account else {
            entries = []
            lastUpdated = nil
            error = nil
            return
        }
        entries = last.entries
        lastUpdated = last.at
    }

    func load(api: GitHubAPI?, account: String?, force: Bool = false) async {
        guard let api else { return }
        generation += 1
        let mine = generation
        loading = true
        refreshing = !entries.isEmpty
        defer {
            if generation == mine {
                loading = false
                refreshing = false
            }
        }
        do {
            let query = [PRFilter.mine.query, "is:pr", "is:open", "archived:false", "sort:updated-desc"].joined(separator: " ")
            let items = try await api.search(query).nodes.filter(\.isPR)
            var repos: [(repo: RepoRef, stacked: Bool, numbers: [Int])] = []
            for item in items {
                if let i = repos.firstIndex(where: { $0.repo == item.repo }) {
                    repos[i].numbers.append(item.number)
                    repos[i].stacked = repos[i].stacked || item.stackedOn != nil
                } else {
                    repos.append((item.repo, item.stackedOn != nil, [item.number]))
                }
            }
            let picked = (repos.filter(\.stacked) + repos.filter { !$0.stacked }).prefix(Self.maxRepos)
            var found: [StackEntry] = []
            for r in picked {
                guard let nodes = await StackStore.nodes(api: api, repo: r.repo, account: account, force: force) else { continue }
                found += StackEntry.collect(repo: r.repo, mine: r.numbers, open: nodes)
            }
            found.sort { $0.updated > $1.updated }
            guard !Task.isCancelled, generation == mine else { return }
            if found != entries { entries = found }
            error = nil
            lastUpdated = Date()
            Self.last = (account, found, lastUpdated!)
        } catch {
            if isCancellation(error) || generation != mine { return }
            self.error = error.localizedDescription
        }
    }
}

struct StacksListView: View {
    @Environment(AppModel.self) private var app
    @State private var model = StacksModel()
    @State private var loaded = false

    var body: some View {
        List(selection: Binding(get: { app.detailRoot }, set: select)) {
            if let e = model.error, model.entries.isEmpty {
                Text(e).foregroundStyle(.red).font(.caption)
            }
            ForEach(model.entries) { entry in
                StackRow(entry: entry)
                    .tag(Route.pr(entry.ref))
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Color.syLine)
            }
            if model.entries.isEmpty, !model.loading, model.error == nil, loaded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No stacked pull requests").foregroundStyle(Color.syMuted)
                    Text("Open a pull request on another pull request's branch and it shows up here.")
                        .font(.caption)
                        .foregroundStyle(Color.syDim)
                }
                .padding(.vertical, 6)
            }
        }
        .overlay {
            if model.loading && model.entries.isEmpty { ProgressView().controlSize(.small) }
        }
        .liveRefresh(updated: model.lastUpdated, refreshing: model.refreshing, error: model.entries.isEmpty ? nil : model.error) {
            await model.load(api: app.api, account: app.cacheAccount, force: true)
        }
        .navigationTitle("Stacks")
        .navigationSubtitle(model.entries.isEmpty ? "" : "\(model.entries.count)")
        .task(id: "\(app.cacheAccount ?? "")|\(app.api != nil)") {
            model.restore(account: app.cacheAccount)
            await model.load(api: app.api, account: app.cacheAccount)
            loaded = true
        }
        .onChange(of: app.refreshTick) { Task { await model.load(api: app.api, account: app.cacheAccount, force: true) } }
        .onLiveTick { await model.load(api: app.api, account: app.cacheAccount) }
    }

    private func select(_ route: Route?) {
        if case .pr(let ref) = route { app.prModel(ref)?.tab = .stack }
        app.select(route)
    }
}

private struct StackRow: View {
    let entry: StackEntry

    var body: some View {
        let nodes = entry.ordered
        let root = entry.tree.nodes[entry.tree.root]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.syIndigo)
                Text(root.map { "#\($0.number) \($0.title)" } ?? "").fontWeight(.semibold).lineLimit(1)
            }
            HStack(spacing: 5) {
                Text(entry.repo.full).lineLimit(1)
                Text("·")
                Text("on \(entry.tree.base)").lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(Fmt.rel(entry.updated)).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Color.syMuted)
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(nodes) { n in
                        Capsule()
                            .fill(n.status.color.opacity(entry.mine.contains(n.number) ? 0.9 : 0.4))
                            .frame(width: 12, height: 5)
                            .help("#\(n.number) \(n.title) — \(n.status.title)")
                    }
                }
                Text(plural(nodes.count, "PR", "PRs")).font(.caption).foregroundStyle(Color.syMuted)
                if entry.mine.count < nodes.count {
                    Text("· \(entry.mine.count) yours").font(.caption).foregroundStyle(Color.syDim)
                }
                let failing = nodes.filter { $0.status == .ciFailed || $0.status == .changesRequested }.count
                if failing > 0 {
                    Label("\(failing)", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.syRed)
                        .help(plural(failing, "pull request needs attention", "pull requests need attention"))
                }
            }
        }
        .padding(.vertical, 4)
    }
}
