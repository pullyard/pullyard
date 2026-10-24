import Foundation

struct PendingComment: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let line: Int
    let side: String
    let body: String
}

extension GitHubAPI {
    func currentUser() async throws -> (RESTUser, [String]) {
        let (data, response) = try await restRaw("GET", "/user")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let user = try decoder.decode(RESTUser.self, from: data)
        let scopes = (response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (user, scopes)
    }

    func search(_ query: String, after: String? = nil) async throws -> SearchConnection {
        let r: SearchResponse = try await graphQL(Q.search, ["q": query, "after": after])
        return r.search
    }

    func repoPullRequests(_ repo: RepoRef, headRefName: String? = nil, states: [String], first: Int = 30) async throws -> [SearchItem] {
        struct R: Decodable {
            struct Repo: Decodable {
                struct Conn: Decodable { let nodes: [SearchItem] }
                let pullRequests: Conn
            }
            let repository: Repo?
        }
        let r: R = try await graphQL(Q.repoPullRequests, ["o": repo.owner, "n": repo.name, "b": headRefName, "states": states, "first": first])
        return r.repository?.pullRequests.nodes ?? []
    }

    func pullRequestItem(_ ref: ItemRef) async throws -> SearchItem? {
        struct R: Decodable {
            struct Repo: Decodable { let pullRequest: SearchItem? }
            let repository: Repo?
        }
        let r: R = try await graphQL(Q.prItem, ["o": ref.repo.owner, "n": ref.repo.name, "num": ref.number])
        return r.repository?.pullRequest
    }

    func openStackNodes(_ repo: RepoRef, pages: Int = 3) async throws -> [StackNode] {
        struct R: Decodable {
            struct Commit: Decodable {
                struct Rollup: Decodable { let state: String }
                let abbreviatedOid: String
                let messageHeadline: String
                let statusCheckRollup: Rollup?
            }
            struct CommitNode: Decodable { let commit: Commit }
            struct Login: Decodable { let login: String }
            struct HeadRepo: Decodable { let nameWithOwner: String }
            struct PR: Decodable {
                let number: Int
                let title: String
                let state: String
                let isDraft: Bool
                let headRefName: String
                let baseRefName: String
                let updatedAt: Date?
                let reviewDecision: String?
                let author: Login?
                let headRepository: HeadRepo?
                let commits: Nodes<CommitNode>
            }
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Page: Decodable { let pageInfo: PageInfo; let nodes: [PR] }
            struct Repo: Decodable { let pullRequests: Page }
            let repository: Repo?
        }
        var out: [StackNode] = []
        var after: String?
        for _ in 0..<pages {
            let r: R = try await graphQL(Q.repoStack, ["o": repo.owner, "n": repo.name, "after": after])
            guard let page = r.repository?.pullRequests else { throw APIError(message: "Can't read pull requests of \(repo.full)") }
            out += page.nodes.map { pr in
                let c = pr.commits.nodes.first?.commit
                return StackNode(number: pr.number, title: pr.title, state: pr.state, isDraft: pr.isDraft,
                                 headRefName: pr.headRefName, baseRefName: pr.baseRefName, headRepo: pr.headRepository?.nameWithOwner,
                                 author: pr.author?.login, updatedAt: pr.updatedAt, reviewDecision: pr.reviewDecision,
                                 ci: c?.statusCheckRollup?.state, commitOid: c?.abbreviatedOid, commitHeadline: c?.messageHeadline)
            }
            guard page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor else { break }
            after = cursor
        }
        return out
    }

    func badges() async throws -> BadgeResponse {
        try await graphQL(Q.badges)
    }

    func pullRequest(_ ref: ItemRef) async throws -> PRDetailResponse {
        try await graphQL(Q.pullRequest, ["owner": ref.repo.owner, "name": ref.repo.name, "number": ref.number])
    }

    func pullRequestPulse(_ ref: ItemRef) async throws -> PRPulse? {
        let r: PRPulseResponse = try await graphQL(Q.prPulse, ["owner": ref.repo.owner, "name": ref.repo.name, "number": ref.number])
        return r.repository?.pullRequest
    }

    func issue(_ ref: ItemRef) async throws -> IssueDetailResponse {
        try await graphQL(Q.issue, ["owner": ref.repo.owner, "name": ref.repo.name, "number": ref.number])
    }

    func pullRequestFiles(_ ref: ItemRef) async throws -> [PRFile] {
        var all: [PRFile] = []
        var page = 1
        while page <= 30 {
            let batch: [PRFile] = try await rest("GET", "/repos/\(ref.repo.full)/pulls/\(ref.number)/files?per_page=100&page=\(page)")
            all += batch
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }

    func commit(_ repo: RepoRef, sha: String) async throws -> CommitDetailREST {
        try await rest("GET", "/repos/\(repo.full)/commits/\(sha)")
    }

    func repos(after: String?) async throws -> RepoConnection {
        let r: ReposResponse = try await graphQL(Q.repos, ["after": after])
        return r.viewer.repositories
    }

    func repoInfo(_ repo: RepoRef) async throws -> RepoInfoResponse.R? {
        let r: RepoInfoResponse = try await graphQL(Q.repoInfo, ["owner": repo.owner, "name": repo.name])
        return r.repository
    }

    func projects() async throws -> [ProjectSummary] {
        let r: ProjectsResponse = try await graphQL(Q.projects)
        var seen = Set<String>()
        let all = r.viewer.projectsV2.nodes + r.viewer.organizations.nodes.flatMap { $0.projectsV2?.nodes ?? [] }
        return all.filter { seen.insert($0.id).inserted }
    }

    func project(_ id: String) async throws -> (ProjectDetail, [ProjectItem]) {
        var after: String?
        var items: [ProjectItem] = []
        var detail: ProjectDetail?
        for _ in 0..<10 {
            let r: ProjectDetailResponse = try await graphQL(Q.project, ["id": id, "after": after])
            guard let node = r.node else { throw APIError(message: "Project not found") }
            detail = detail ?? node
            items += node.items.nodes
            guard node.items.pageInfo.hasNextPage else { break }
            after = node.items.pageInfo.endCursor
        }
        return (detail!, items)
    }

    func moveProjectItem(project: String, item: String, field: String, option: String?) async throws {
        if let option {
            let _: EmptyData = try await graphQL(Q.moveProjectItem, ["p": project, "i": item, "f": field, "o": option], strict: true)
        } else {
            let _: EmptyData = try await graphQL(Q.clearProjectItem, ["p": project, "i": item, "f": field], strict: true)
        }
    }

    func notifications(all: Bool, live: Bool = false) async throws -> [NotificationThread] {
        if Demo.isOn { return [] }
        return try await restPolled("/notifications?all=\(all)&per_page=50", live: live)
    }

    func unreadNotificationCount(live: Bool = false) async throws -> Int {
        try await notifications(all: false, live: live).count
    }

    func markNotificationRead(_ id: String) async throws {
        defer { forgetPolled(prefix: "/notifications") }
        try await send("PATCH", "/notifications/threads/\(id)")
    }

    func markNotificationDone(_ id: String) async throws {
        defer { forgetPolled(prefix: "/notifications") }
        try await send("DELETE", "/notifications/threads/\(id)")
    }

    func markAllNotificationsRead() async throws {
        defer { forgetPolled(prefix: "/notifications") }
        try await send("PUT", "/notifications", body: ["read": true])
    }

    func mutate(_ query: String, _ vars: [String: Any?]) async throws {
        let _: EmptyData = try await graphQL(query, vars, strict: true)
    }

    func addComment(subject: String, body: String) async throws {
        try await mutate(Q.addComment, ["id": subject, "b": body])
    }

    func addReview(pr: String, event: String, body: String?, comments: [PendingComment]) async throws {
        let threads: [[String: Any]] = comments.map { ["path": $0.path, "line": $0.line, "side": $0.side, "body": $0.body] }
        try await mutate(Q.addReview, ["id": pr, "e": event, "b": body?.isEmpty == true ? nil : body, "th": threads.isEmpty ? nil : threads])
    }

    func requestReviewers(_ ref: ItemRef, logins: [String]) async throws {
        let teams = logins.filter { $0.contains("/") }.compactMap { $0.split(separator: "/").last.map(String.init) }
        let users = logins.filter { !$0.contains("/") }
        var body: [String: [String]] = [:]
        if !users.isEmpty { body["reviewers"] = users }
        if !teams.isEmpty { body["team_reviewers"] = teams }
        try await send("POST", "/repos/\(ref.repo.full)/pulls/\(ref.number)/requested_reviewers", body: body)
    }

    func deleteBranch(repo: String, branch: String) async throws {
        let encoded = branch.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        try await send("DELETE", "/repos/\(repo)/git/refs/heads/\(encoded)")
    }

    func rerunFailedJobs(repo: RepoRef, runId: Int) async throws {
        try await send("POST", "/repos/\(repo.full)/actions/runs/\(runId)/rerun-failed-jobs")
    }

    func jobLog(repo: RepoRef, jobId: Int) async throws -> String {
        let target = try await redirectTarget("/repos/\(repo.full)/actions/jobs/\(jobId)/logs")
        return try await plain(target)
    }

    func jobLogTail(repo: RepoRef, jobId: Int, maxBytes: Int) async throws -> String {
        let target = try await redirectTarget("/repos/\(repo.full)/actions/jobs/\(jobId)/logs")
        return try await plainTail(target, maxBytes: maxBytes)
    }
}
