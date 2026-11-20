import Foundation

enum BitbucketPR {
    struct Link: Decodable { let href: String? }
    struct Links: Decodable {
        let html: Link?
        let avatar: Link?
    }

    struct User: Decodable {
        let uuid: String?
        let displayName: String?
        let nickname: String?
        let links: Links?

        var login: String { nickname ?? displayName ?? uuid ?? "unknown" }
        var actor: Actor { Actor(login: login, avatarUrl: links?.avatar?.href) }
    }

    struct Rendered: Decodable {
        let raw: String?
        let html: String?
    }

    struct Branch: Decodable { let name: String }
    struct Commit: Decodable { let hash: String }
    struct RepoName: Decodable { let fullName: String? }

    struct Endpoint: Decodable {
        let branch: Branch?
        let commit: Commit?
        let repository: RepoName?
    }

    struct Participant: Decodable {
        let user: User?
        let role: String?
        let approved: Bool?
        let state: String?
        let participatedOn: Date?
    }

    struct Detail: Decodable {
        let id: Int
        let title: String
        let state: String
        let draft: Bool?
        let summary: Rendered?
        let createdOn: Date
        let updatedOn: Date
        let author: User?
        let source: Endpoint?
        let destination: Endpoint?
        let closeSourceBranch: Bool?
        let links: Links?
        let commentCount: Int?
        let taskCount: Int?
        let participants: [Participant]?
        let reviewers: [User]?
    }

    struct Inline: Decodable {
        let path: String?
        let from: Int?
        let to: Int?
        let outdated: Bool?
    }

    struct Parent: Decodable { let id: Int }

    struct Resolution: Decodable {
        let type: String?
        let user: User?
    }

    struct Comment: Decodable {
        let id: Int
        let content: Rendered?
        let user: User?
        let createdOn: Date
        let inline: Inline?
        let parent: Parent?
        let deleted: Bool?
        let pending: Bool?
        let resolution: Resolution?
    }

    struct CommitAuthor: Decodable {
        let raw: String?
        let user: User?
    }

    struct CommitInfo: Decodable {
        let hash: String
        let message: String?
        let date: Date?
        let author: CommitAuthor?
        let links: Links?
    }

    struct Status: Decodable {
        let key: String?
        let name: String?
        let state: String
        let url: String?
        let description: String?
        let createdOn: Date?
        let updatedOn: Date?
    }

    struct DiffPath: Decodable { let path: String }

    struct DiffStat: Decodable {
        let status: String
        let linesAdded: Int?
        let linesRemoved: Int?
        let old: DiffPath?
        let new: DiffPath?

        var path: String { new?.path ?? old?.path ?? "" }
    }

    struct Outcome: Decodable {
        struct Result: Decodable { let name: String? }
        let name: String?
        let result: Result?
    }

    struct Pipeline: Decodable {
        let uuid: String
        let buildNumber: Int?
        let state: Outcome?
    }

    struct Step: Decodable {
        let uuid: String
        let name: String?
        let state: Outcome?
    }

    struct Page<T: Decodable>: Decodable {
        let values: [T]
        let next: String?
    }
}

extension BitbucketClient {
    static func pullPath(_ repo: String, _ id: Int) -> String {
        "/repositories/\(repo.split(separator: "/").map { segment(String($0)) }.joined(separator: "/"))/pullrequests/\(id)"
    }

    static func repoPath(_ repo: String) -> String {
        "/repositories/\(repo.split(separator: "/").map { segment(String($0)) }.joined(separator: "/"))"
    }

    func pages<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], limit: Int = 10) async throws -> [T] {
        var all: [T] = []
        var next: String? = nil
        var page: BitbucketPR.Page<T> = try await http.get(path, query + [URLQueryItem(name: "pagelen", value: "100")])
        all += page.values
        next = page.next
        var count = 1
        while let url = next, count < limit {
            page = try await http.get(url)
            all += page.values
            next = page.next
            count += 1
        }
        return all
    }

    func pullRequest(_ repo: String, id: Int) async throws -> BitbucketPR.Detail {
        try await http.get(Self.pullPath(repo, id))
    }

    func comments(_ repo: String, id: Int) async throws -> [BitbucketPR.Comment] {
        try await pages(Self.pullPath(repo, id) + "/comments", limit: 20)
    }

    func pullCommits(_ repo: String, id: Int) async throws -> [BitbucketPR.CommitInfo] {
        try await pages(Self.pullPath(repo, id) + "/commits", limit: 3)
    }

    func statuses(_ repo: String, id: Int) async throws -> [BitbucketPR.Status] {
        try await pages(Self.pullPath(repo, id) + "/statuses", limit: 3)
    }

    func diffstat(_ repo: String, id: Int) async throws -> [BitbucketPR.DiffStat] {
        try await pages(Self.pullPath(repo, id) + "/diffstat", limit: 30)
    }

    func diff(_ repo: String, id: Int) async throws -> String {
        try await http.text(Self.pullPath(repo, id) + "/diff")
    }

    func addComment(_ repo: String, id: Int, body: String, inline: [String: Any]? = nil, parent: Int? = nil) async throws {
        var json: [String: Any] = ["content": ["raw": body]]
        if let inline { json["inline"] = inline }
        if let parent { json["parent"] = ["id": parent] }
        try await http.post(Self.pullPath(repo, id) + "/comments", json: json)
    }

    func setResolved(_ repo: String, id: Int, comment: Int, resolved: Bool) async throws {
        try await http.post(Self.pullPath(repo, id) + "/comments/\(comment)/resolve", method: resolved ? "POST" : "DELETE")
    }

    func approve(_ repo: String, id: Int, on: Bool) async throws {
        try await http.post(Self.pullPath(repo, id) + "/approve", method: on ? "POST" : "DELETE")
    }

    func requestChanges(_ repo: String, id: Int, on: Bool) async throws {
        try await http.post(Self.pullPath(repo, id) + "/request-changes", method: on ? "POST" : "DELETE")
    }

    func merge(_ repo: String, id: Int, strategy: String, message: String?, closeBranch: Bool) async throws {
        var json: [String: Any] = ["type": "pullrequest", "merge_strategy": strategy, "close_source_branch": closeBranch]
        if let message { json["message"] = message }
        try await http.post(Self.pullPath(repo, id) + "/merge", json: json)
    }

    func decline(_ repo: String, id: Int) async throws {
        try await http.post(Self.pullPath(repo, id) + "/decline")
    }

    func updatePull(_ repo: String, id: Int, fields: [String: Any]) async throws {
        try await http.post(Self.pullPath(repo, id), method: "PUT", json: fields)
    }

    func commit(_ repo: String, sha: String) async throws -> CommitDetailREST {
        async let detail: BitbucketPR.CommitInfo = http.get(Self.repoPath(repo) + "/commit/\(sha)")
        async let stats: [BitbucketPR.DiffStat] = pages(Self.repoPath(repo) + "/diffstat/\(sha)", limit: 10)
        async let text = try? http.text(Self.repoPath(repo) + "/diff/\(sha)")
        let c = try await detail
        let files = BitbucketReviewMapper.files(try await stats, diff: await text ?? "")
        return CommitDetailREST(
            sha: c.hash,
            htmlUrl: c.links?.html?.href ?? "https://bitbucket.org/\(repo)/commits/\(c.hash)",
            commit: .init(message: c.message ?? "", author: .init(name: BitbucketReviewMapper.authorName(c.author), date: c.date)),
            author: nil,
            stats: .init(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions }),
            files: files
        )
    }

    static func buildNumber(_ link: String?) -> Int? {
        guard let link, let r = link.range(of: #"(pipelines/results/|#!/results/)(\d+)"#, options: .regularExpression) else { return nil }
        return Int(link[r].split(separator: "/").last ?? "")
    }

    func pipeline(_ repo: String, build: Int) async throws -> BitbucketPR.Pipeline {
        do {
            return try await http.get(Self.repoPath(repo) + "/pipelines/\(build)")
        } catch let e as APIError where e.status == 404 || e.status == 400 {
            let page: BitbucketPR.Page<BitbucketPR.Pipeline> = try await http.get(Self.repoPath(repo) + "/pipelines/", [URLQueryItem(name: "sort", value: "-created_on"), URLQueryItem(name: "pagelen", value: "100")])
            guard let hit = page.values.first(where: { $0.buildNumber == build }) else { throw e }
            return hit
        }
    }

    func sourceFile(_ repo: String, commit: String, path: String) async throws -> String? {
        let encoded = path.split(separator: "/").map { Self.segment(String($0)) }.joined(separator: "/")
        do {
            return try await http.text(Self.repoPath(repo) + "/src/\(Self.segment(commit))/\(encoded)")
        } catch let e as APIError where e.status == 404 {
            return nil
        }
    }

    func pipelineSteps(_ repo: String, pipeline: String) async throws -> [BitbucketPR.Step] {
        try await pages(Self.repoPath(repo) + "/pipelines/\(Self.segment(pipeline))/steps/", limit: 3)
    }

    func stepLog(_ repo: String, pipeline: String, step: String) async throws -> String {
        try await http.download(Self.repoPath(repo) + "/pipelines/\(Self.segment(pipeline))/steps/\(Self.segment(step))/log")
    }

    func reviewBackend() -> PRBackend? {
        BitbucketPRBackend(client: self)
    }
}
