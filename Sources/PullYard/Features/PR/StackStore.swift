import Foundation

@MainActor
enum StackStore {
    static let ttl: TimeInterval = 120
    private static var memory: [String: (nodes: [StackNode], at: Date)] = [:]
    private static var fetches: [String: Task<[StackNode]?, Never>] = [:]
    private static var invalidated: Set<String> = []

    private static func key(_ api: GitHubAPI, _ repo: RepoRef, _ account: String?) -> String {
        "\(account ?? "")|\(api.host)|\(repo.full.lowercased())"
    }

    private static func diskKey(_ api: GitHubAPI, _ repo: RepoRef) -> String {
        "stack|\(api.host)|\(repo.full.lowercased())"
    }

    static func memoryNodes(api: GitHubAPI, repo: RepoRef, account: String?) -> [StackNode]? {
        memory[key(api, repo, account)]?.nodes
    }

    static func cached(api: GitHubAPI, repo: RepoRef, account: String?) async -> (nodes: [StackNode], fresh: Bool)? {
        let k = key(api, repo, account)
        if let hit = memory[k] {
            return (hit.nodes, Date().timeIntervalSince(hit.at) < ttl)
        }
        guard let snap = await ListCache.load([StackNode].self, account: account, key: diskKey(api, repo)) else { return nil }
        if let hit = memory[k] {
            return (hit.nodes, Date().timeIntervalSince(hit.at) < ttl)
        }
        if invalidated.contains(k) { return (snap.value, false) }
        memory[k] = (snap.value, snap.saved)
        return (snap.value, Date().timeIntervalSince(snap.saved) < ttl)
    }

    static func nodes(api: GitHubAPI, repo: RepoRef, account: String?, force: Bool = false) async -> [StackNode]? {
        if !force, let hit = await cached(api: api, repo: repo, account: account), hit.fresh { return hit.nodes }
        return await fetch(api: api, repo: repo, account: account)
    }

    static func fetch(api: GitHubAPI, repo: RepoRef, account: String?) async -> [StackNode]? {
        let k = key(api, repo, account)
        let task: Task<[StackNode]?, Never>
        if let running = fetches[k] {
            task = running
        } else {
            task = Task { try? await api.openStackNodes(repo) }
            fetches[k] = task
        }
        let nodes = await task.value
        if fetches[k] == task { fetches[k] = nil }
        guard let nodes else { return nil }
        if memory[k].map({ $0.nodes != nodes }) ?? true {
            ListCache.save(nodes, account: account, key: diskKey(api, repo))
        }
        memory[k] = (nodes, Date())
        invalidated.remove(k)
        return nodes
    }

    static func reset() {
        fetches.values.forEach { $0.cancel() }
        fetches = [:]
        memory = [:]
        invalidated = []
    }

    static func invalidate(api: GitHubAPI, repo: RepoRef, account: String?) {
        let k = key(api, repo, account)
        memory[k] = nil
        invalidated.insert(k)
    }
}
