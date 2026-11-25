import Foundation
import WidgetKit
import AppIntents

enum WidgetFetcher {
    private static let query = """
    query {
      review: search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 5) {
        issueCount
        nodes { ... on PullRequest { number title author { login } repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }
      }
      mine: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: 1) { issueCount }
    }
    """

    private struct Response: Decodable {
        let data: DataBlock?
        struct DataBlock: Decodable { let review: Search; let mine: Count }
        struct Count: Decodable { let issueCount: Int }
        struct Search: Decodable { let issueCount: Int; let nodes: [Node?] }
        struct Node: Decodable {
            let number: Int?
            let title: String?
            let author: Author?
            let repository: Repo?
            let commits: Commits?
            struct Author: Decodable { let login: String }
            struct Repo: Decodable { let nameWithOwner: String }
            struct Commits: Decodable { let nodes: [CommitNode?] }
            struct CommitNode: Decodable { let commit: Commit }
            struct Commit: Decodable { let statusCheckRollup: Rollup? }
            struct Rollup: Decodable { let state: String }
        }
    }

    static func fetch() async throws -> WidgetSnapshot {
        guard case let .found(token) = CredentialVault().read() else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PullYard-iOS-Widget", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let block = try JSONDecoder().decode(Response.self, from: data).data else { throw URLError(.badServerResponse) }
        let items = block.review.nodes.compactMap { node -> WidgetItem? in
            guard let node, let number = node.number, let title = node.title, let repo = node.repository?.nameWithOwner else { return nil }
            return WidgetItem(repo: repo, number: number, title: title, author: node.author?.login, ci: node.commits?.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state)
        }
        let unread = WidgetSnapshot.load()?.unread ?? 0
        let snapshot = WidgetSnapshot(updated: .now, needsReview: block.review.issueCount, myOpen: block.mine.issueCount, unread: unread, items: items)
        snapshot.save()
        return snapshot
    }
}

struct RefreshQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh review queue"
    static var description = IntentDescription("Checks GitHub for pull requests waiting for your review.")

    func perform() async throws -> some IntentResult {
        _ = try? await WidgetFetcher.fetch()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

enum PendingLink {
    static let key = "pendingDeepLink"
    static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.groupID) }

    static func set(_ url: URL) { defaults?.set(url.absoluteString, forKey: key) }

    static func take() -> URL? {
        guard let raw = defaults?.string(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return URL(string: raw)
    }
}
