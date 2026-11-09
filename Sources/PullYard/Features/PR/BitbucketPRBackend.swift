import Foundation

struct BitbucketPRSnapshot {
    let repo: String
    let pr: BitbucketPR.Detail
    let comments: [BitbucketPR.Comment]
    let commits: [BitbucketPR.CommitInfo]
    let statuses: [BitbucketPR.Status]
    let diffstat: [BitbucketPR.DiffStat]
    let viewer: String
}

enum BitbucketReviewMapper {
    static let conflictStatuses: Set<String> = ["merge conflict", "local deleted", "remote deleted", "local and remote deleted", "rename conflict", "rename/delete conflict", "subrepo conflict"]

    static func state(_ raw: String) -> String {
        switch raw {
        case "MERGED": return "MERGED"
        case "OPEN": return "OPEN"
        default: return "CLOSED"
        }
    }

    static func repository(_ s: BitbucketPRSnapshot) -> PRRepository {
        PRRepository(
            viewerPermission: "WRITE",
            mergeCommitAllowed: true,
            squashMergeAllowed: true,
            rebaseMergeAllowed: false,
            deleteBranchOnMerge: s.pr.closeSourceBranch ?? false,
            autoMergeAllowed: false,
            viewerDefaultMergeMethod: "MERGE",
            pullRequest: detail(s)
        )
    }

    static func authorName(_ a: BitbucketPR.CommitAuthor?) -> String? {
        if let name = a?.user?.displayName { return name }
        guard let raw = a?.raw else { return nil }
        return raw.components(separatedBy: " <").first ?? raw
    }

    static func pulse(_ pr: BitbucketPR.Detail) -> String {
        let people: String = (pr.participants ?? []).map { p -> String in
            let who: String = p.user?.uuid ?? ""
            let state: String = p.state ?? (p.approved == true ? "approved" : "")
            return who + ":" + state
        }.sorted().joined(separator: ",")
        var parts: [String] = []
        parts.append(String(pr.updatedOn.timeIntervalSince1970))
        parts.append(pr.state)
        parts.append(String(pr.draft ?? false))
        parts.append(pr.source?.commit?.hash ?? "")
        parts.append(String(pr.commentCount ?? 0))
        parts.append(String(pr.taskCount ?? 0))
        parts.append(people)
        return parts.joined(separator: "|")
    }

    static func checks(_ statuses: [BitbucketPR.Status]) -> [CheckContext] {
        statuses.enumerated().map { index, s in
            let status: String
            let conclusion: String?
            switch s.state {
            case "INPROGRESS": status = "IN_PROGRESS"; conclusion = nil
            case "SUCCESSFUL": status = "COMPLETED"; conclusion = "SUCCESS"
            case "FAILED": status = "COMPLETED"; conclusion = "FAILURE"
            case "STOPPED": status = "COMPLETED"; conclusion = "CANCELLED"
            default: status = "QUEUED"; conclusion = nil
            }
            return CheckContext(
                typename: "BitbucketStatus",
                databaseId: index + 1,
                name: s.name ?? s.key ?? "Build",
                status: status,
                conclusion: conclusion,
                detailsUrl: s.url,
                startedAt: s.createdOn,
                completedAt: conclusion == nil ? nil : s.updatedOn,
                checkSuite: nil,
                context: nil,
                state: nil,
                targetUrl: nil,
                description: s.description
            )
        }
    }

    static func rollupState(_ statuses: [BitbucketPR.Status]) -> String? {
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(where: { $0.state == "FAILED" }) { return "FAILURE" }
        if statuses.contains(where: { $0.state == "INPROGRESS" }) { return "PENDING" }
        if statuses.contains(where: { $0.state == "STOPPED" }) { return "ERROR" }
        return "SUCCESS"
    }

    static func conversation(_ comments: [BitbucketPR.Comment], base: String, headPaths: Set<String>) -> ([TimelineItem], [ReviewThread]) {
        let visible = comments.filter { $0.deleted != true && $0.pending != true }
        var children: [Int: [BitbucketPR.Comment]] = [:]
        var roots: [BitbucketPR.Comment] = []
        let ids = Set(visible.map(\.id))
        for c in visible {
            if let parent = c.parent?.id, ids.contains(parent) {
                children[parent, default: []].append(c)
            } else {
                roots.append(c)
            }
        }
        func descendants(_ id: Int) -> [BitbucketPR.Comment] {
            let direct = (children[id] ?? []).sorted { $0.createdOn < $1.createdOn }
            return direct.flatMap { [$0] + descendants($0.id) }
        }
        var timeline: [TimelineItem] = []
        var threads: [ReviewThread] = []
        for root in roots.sorted(by: { $0.createdOn < $1.createdOn }) {
            let replies = descendants(root.id)
            if root.inline == nil, replies.isEmpty {
                timeline.append(item("IssueComment", id: "bb-c-\(root.id)", author: root.user?.actor, body: root.content?.raw, html: html(root, base: base), date: root.createdOn))
                continue
            }
            let review = "bb-t-\(root.id)"
            let inline = root.inline
            let line = inline?.to ?? inline?.from
            let outdated = inline?.outdated == true || (inline?.path.map { !headPaths.isEmpty && !headPaths.contains($0) } ?? false)
            let resolved = root.resolution != nil
            threads.append(ReviewThread(
                id: String(root.id),
                isResolved: resolved,
                isOutdated: outdated,
                path: inline?.path ?? "",
                line: outdated ? nil : line,
                originalLine: line,
                diffSide: inline?.to == nil && inline?.from != nil ? "LEFT" : "RIGHT",
                viewerCanResolve: !resolved,
                viewerCanUnresolve: resolved,
                viewerCanReply: true,
                comments: Nodes(nodes: ([root] + replies).map { c in
                    ThreadComment(id: String(c.id), author: c.user?.actor, body: c.content?.raw ?? "", bodyHTML: html(c, base: base), createdAt: c.createdOn, diffHunk: nil, pullRequestReview: IDOnly(id: review))
                })
            ))
            timeline.append(item("PullRequestReview", id: review, author: root.user?.actor, body: nil, html: nil, date: root.createdOn, state: "DISCUSSION"))
        }
        return (timeline, threads)
    }

    private static func html(_ c: BitbucketPR.Comment, base: String) -> String {
        if let h = c.content?.html, !h.isEmpty { return MarkdownHTML.absolutizeHTML(h, base: base) }
        return MarkdownHTML.render(c.content?.raw ?? "", base: base)
    }

    private static func item(_ type: String, id: String, author: Actor?, body: String?, html: String?, date: Date, state: String? = nil) -> TimelineItem {
        TimelineItem(typename: type, id: id, author: author, actor: nil, body: body, bodyHTML: html, createdAt: date, url: nil, state: state, label: nil, source: nil, previousTitle: nil, currentTitle: nil, commit: nil, mergeRefName: nil, requestedReviewer: nil)
    }

    static func reviewDecision(_ pr: BitbucketPR.Detail) -> String? {
        let people = pr.participants ?? []
        if people.contains(where: { $0.state == "changes_requested" }) { return "CHANGES_REQUESTED" }
        if people.contains(where: { $0.approved == true }) { return "APPROVED" }
        return nil
    }

    static func detail(_ s: BitbucketPRSnapshot) -> PullRequestDetail {
        let pr = s.pr
        let repoName = pr.destination?.repository?.fullName ?? s.repo
        let base = "https://bitbucket.org/\(repoName)"
        let state = state(pr.state)
        let conflicted = s.diffstat.contains { conflictStatuses.contains($0.status) }
        let failed = s.statuses.contains { $0.state == "FAILED" }
        let changesRequested = (pr.participants ?? []).contains { $0.state == "changes_requested" }
        let openTasks = pr.taskCount ?? 0
        let mergeable = conflicted ? "CONFLICTING" : "MERGEABLE"
        let mergeState: String
        if pr.draft == true {
            mergeState = "DRAFT"
        } else if conflicted {
            mergeState = "DIRTY"
        } else if failed || changesRequested || openTasks > 0 {
            mergeState = "UNSTABLE"
        } else {
            mergeState = "CLEAN"
        }
        let headSha = pr.source?.commit?.hash ?? ""
        let paths = Set(s.diffstat.map(\.path))
        let (timeline, threads) = conversation(s.comments, base: base, headPaths: paths)
        let commits = s.commits.reversed().map { c in
            CommitInfoNode(commit: CommitInfo(
                oid: c.hash,
                abbreviatedOid: String(c.hash.prefix(7)),
                messageHeadline: (c.message ?? "").components(separatedBy: "\n").first ?? "",
                committedDate: c.date ?? pr.createdOn,
                url: c.links?.html?.href ?? "\(base)/commits/\(c.hash)",
                author: GitActor(name: authorName(c.author), avatarUrl: c.author?.user?.links?.avatar?.href, user: nil),
                statusCheckRollup: nil
            ))
        }
        let contexts = checks(s.statuses)
        let rollup = rollupState(s.statuses).map { StatusRollup(state: $0, contexts: Nodes(nodes: contexts, totalCount: contexts.count)) }
        let me = s.viewer.lowercased()
        let participants = pr.participants ?? []
        let mine = participants.first { $0.user?.uuid?.lowercased() == me }
        let isAuthor = !me.isEmpty && pr.author?.uuid?.lowercased() == me
        let reviews = participants.compactMap { p -> LatestReview? in
            guard let user = p.user else { return nil }
            if p.approved == true || p.state == "approved" { return LatestReview(state: "APPROVED", submittedAt: p.participatedOn, commit: nil, author: user.actor) }
            if p.state == "changes_requested" { return LatestReview(state: "CHANGES_REQUESTED", submittedAt: p.participatedOn, commit: nil, author: user.actor) }
            return nil
        }
        let decided = Set(reviews.compactMap { $0.author?.login })
        let pending = (pr.reviewers ?? []).filter { !decided.contains($0.login) }
        let additions = s.diffstat.reduce(0) { $0 + ($1.linesAdded ?? 0) }
        let deletions = s.diffstat.reduce(0) { $0 + ($1.linesRemoved ?? 0) }
        let blocker: String? = conflicted ? nil : changesRequested ? "Changes requested" : failed ? "A build failed" : openTasks > 0 ? (openTasks == 1 ? "1 open task" : "\(openTasks) open tasks") : nil
        let summaryHTML = pr.summary?.html.flatMap { $0.isEmpty ? nil : MarkdownHTML.absolutizeHTML($0, base: base) }
        return PullRequestDetail(
            id: "bitbucket-pr-\(repoName)-\(pr.id)",
            number: pr.id,
            title: pr.title,
            url: pr.links?.html?.href ?? "\(base)/pull-requests/\(pr.id)",
            state: state,
            isDraft: pr.draft ?? false,
            merged: state == "MERGED",
            mergeable: mergeable,
            mergeStateStatus: mergeState,
            body: pr.summary?.raw ?? "",
            bodyHTML: summaryHTML ?? MarkdownHTML.render(pr.summary?.raw ?? "", base: base),
            createdAt: pr.createdOn,
            author: pr.author?.actor,
            headRefName: pr.source?.branch?.name ?? "",
            baseRefName: pr.destination?.branch?.name ?? "",
            headRefOid: headSha,
            baseRef: pr.destination?.commit.map { BaseRef(target: BaseRef.Target(oid: $0.hash)) },
            headRepository: pr.source?.repository?.fullName.map { RepoName(nameWithOwner: $0, defaultBranchRef: nil) },
            headRef: state == "OPEN" ? pr.source?.branch.map { HeadRef(name: $0.name) } : nil,
            additions: additions,
            deletions: deletions,
            changedFiles: s.diffstat.count,
            reviewDecision: reviewDecision(pr),
            viewerCanUpdate: true,
            viewerDidAuthor: isAuthor,
            autoMergeRequest: nil,
            labels: Nodes(nodes: []),
            assignees: Nodes(nodes: []),
            reviewRequests: Nodes(nodes: pending.map { ReviewRequest(requestedReviewer: Reviewer(typename: "User", login: $0.login, avatarUrl: $0.links?.avatar?.href, name: $0.displayName)) }),
            latestOpinionatedReviews: Nodes(nodes: reviews),
            lastCommit: Nodes(nodes: [LastCommitNode(commit: LastCommit(oid: headSha, committedDate: commits.last?.commit.committedDate, statusCheckRollup: rollup))]),
            allCommits: Nodes(nodes: commits, totalCount: commits.count),
            files: nil,
            timelineItems: Nodes(nodes: timeline),
            reviewThreads: Nodes(nodes: threads),
            viewerCanApprove: !isAuthor,
            viewerApproved: mine?.approved == true,
            mergeBlocker: blocker,
            forgeMerge: ForgeMergeInfo(status: pr.draft == true ? "draft" : conflicted ? "conflict" : "open", approvalsRequired: nil, approvalsLeft: nil, openTasks: openTasks, provider: "bitbucket")
        )
    }

    static func files(_ stats: [BitbucketPR.DiffStat], diff: String) -> [PRFile] {
        let patches = splitDiff(diff)
        return stats.map { s in
            let path = s.path
            let status: String
            switch s.status {
            case "added": status = "added"
            case "removed": status = "removed"
            case "renamed": status = "renamed"
            default: status = "modified"
            }
            return PRFile(filename: path, status: status, additions: s.linesAdded ?? 0, deletions: s.linesRemoved ?? 0, patch: patches[path] ?? s.old.flatMap { patches[$0.path] },
                          previousFilename: s.status == "renamed" ? s.old?.path : nil)
        }
    }

    static func splitDiff(_ diff: String) -> [String: String] {
        var out: [String: String] = [:]
        var path: String?
        var oldPath: String?
        var hunk: [Substring] = []
        func flush() {
            if let key = path ?? oldPath, !hunk.isEmpty { out[key] = hunk.joined(separator: "\n") }
            hunk = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                path = nil
                oldPath = nil
                if let r = line.range(of: " b/", options: .backwards) { path = String(line[r.upperBound...]) }
                continue
            }
            if hunk.isEmpty {
                if line.hasPrefix("+++ ") {
                    let p = line.dropFirst(4)
                    if p != "/dev/null" { path = String(p.hasPrefix("b/") ? p.dropFirst(2) : p) }
                    continue
                }
                if line.hasPrefix("--- ") {
                    let p = line.dropFirst(4)
                    if p != "/dev/null" { oldPath = String(p.hasPrefix("a/") ? p.dropFirst(2) : p) }
                    continue
                }
                if !line.hasPrefix("@@") { continue }
            }
            hunk.append(line)
        }
        flush()
        for key in out.keys { out[key] = out[key]?.trimmingCharacters(in: .newlines) }
        return out
    }

    static func inline(_ comment: PendingComment) -> [String: Any] {
        comment.side == "LEFT" ? ["path": comment.path, "from": comment.line] : ["path": comment.path, "to": comment.line]
    }
}

@MainActor
final class BitbucketPRBackend: PRBackend {
    let client: BitbucketClient
    let features = PRFeatures.bitbucket

    init(client: BitbucketClient) {
        self.client = client
    }

    func load(_ ref: ItemRef) async throws -> PRLoad {
        let repo = ref.repo.full
        async let prTask = client.pullRequest(repo, id: ref.number)
        async let commentsTask = client.comments(repo, id: ref.number)
        async let commitsTask = try? client.pullCommits(repo, id: ref.number)
        async let statusesTask = try? client.statuses(repo, id: ref.number)
        async let diffstatTask = try? client.diffstat(repo, id: ref.number)
        async let viewerTask = try? client.userID()
        let snapshot = BitbucketPRSnapshot(
            repo: repo,
            pr: try await prTask,
            comments: try await commentsTask,
            commits: await commitsTask ?? [],
            statuses: await statusesTask ?? [],
            diffstat: await diffstatTask ?? [],
            viewer: await viewerTask ?? ""
        )
        return PRLoad(viewer: snapshot.viewer, repository: BitbucketReviewMapper.repository(snapshot), pulse: .fingerprint(BitbucketReviewMapper.pulse(snapshot.pr)))
    }

    func pulse(_ ref: ItemRef) async throws -> PRPulseToken? {
        .fingerprint(BitbucketReviewMapper.pulse(try await client.pullRequest(ref.repo.full, id: ref.number)))
    }

    func files(_ ref: ItemRef, pr: PullRequestDetail) async throws -> [PRFile] {
        async let stats = client.diffstat(ref.repo.full, id: ref.number)
        async let text = try? client.diff(ref.repo.full, id: ref.number)
        return BitbucketReviewMapper.files(try await stats, diff: await text ?? "")
    }

    func comment(_ ref: ItemRef, pr: PullRequestDetail, body: String) async throws {
        try await client.addComment(ref.repo.full, id: ref.number, body: body)
    }

    func submitReview(_ ref: ItemRef, pr: PullRequestDetail, event: String, body: String, comments: [PendingComment], files: [DiffFile]) async throws {
        let repo = ref.repo.full
        for c in comments {
            try await client.addComment(repo, id: ref.number, body: c.body, inline: BitbucketReviewMapper.inline(c))
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            try await client.addComment(repo, id: ref.number, body: text)
        }
        switch event {
        case "APPROVE": try await client.approve(repo, id: ref.number, on: true)
        case "REQUEST_CHANGES": try await client.requestChanges(repo, id: ref.number, on: true)
        default: break
        }
    }

    func reply(_ ref: ItemRef, thread: String, body: String) async throws {
        guard let parent = Int(thread) else { throw APIError(message: "Unknown comment thread") }
        try await client.addComment(ref.repo.full, id: ref.number, body: body, parent: parent)
    }

    func setResolved(_ ref: ItemRef, thread: String, resolved: Bool) async throws {
        guard let id = Int(thread) else { throw APIError(message: "Unknown comment thread") }
        try await client.setResolved(ref.repo.full, id: ref.number, comment: id, resolved: resolved)
    }

    func merge(_ ref: ItemRef, pr: PullRequestDetail, method: String, title: String?, body: String?, deleteBranch: Bool) async throws -> String? {
        let message: String? = title != nil || body != nil ? [title ?? pr.title, body].compactMap { $0 }.joined(separator: "\n\n") : nil
        try await client.merge(ref.repo.full, id: ref.number, strategy: method == "SQUASH" ? "squash" : "merge_commit", message: message, closeBranch: deleteBranch)
        return nil
    }

    func enableAutoMerge(_ ref: ItemRef, pr: PullRequestDetail, method: String) async throws {
        throw PRBackendUnsupported(provider: features.provider)
    }

    func perform(_ action: PRAction, ref: ItemRef, pr: PullRequestDetail) async throws {
        let repo = ref.repo.full
        switch action {
        case .close: try await client.decline(repo, id: ref.number)
        case .readyForReview: try await client.updatePull(repo, id: ref.number, fields: ["draft": false])
        case .convertToDraft: try await client.updatePull(repo, id: ref.number, fields: ["draft": true])
        case .reopen, .updateBranch, .disableAutoMerge: throw PRBackendUnsupported(provider: features.provider)
        }
    }

    func edit(_ ref: ItemRef, pr: PullRequestDetail, title: String, body: String) async throws {
        try await client.updatePull(ref.repo.full, id: ref.number, fields: ["title": title, "description": body])
    }

    func revokeApproval(_ ref: ItemRef, pr: PullRequestDetail) async throws {
        try await client.approve(ref.repo.full, id: ref.number, on: false)
    }

    func canShowLog(_ check: CheckContext) -> Bool {
        check.outcome != .pending && BitbucketClient.buildNumber(check.link) != nil
    }

    func jobLog(_ ref: ItemRef, check: CheckContext) async throws -> String {
        guard let build = BitbucketClient.buildNumber(check.link) else {
            throw APIError(message: "Only Bitbucket Pipelines builds have a log here. Open this build in the browser.")
        }
        let repo = ref.repo.full
        let pipeline = try await client.pipeline(repo, build: build)
        let steps = try await client.pipelineSteps(repo, pipeline: pipeline.uuid)
        guard !steps.isEmpty else { return "Pipeline #\(build) has no steps." }
        var parts: [String] = []
        for step in steps {
            let result = step.state?.result?.name ?? step.state?.name ?? ""
            let header = "=== \(step.name ?? "Step")" + (result.isEmpty ? "" : " (\(result.lowercased()))") + " ==="
            let text: String
            do {
                text = CILogExcerpt.clean(try await client.stepLog(repo, pipeline: pipeline.uuid, step: step.uuid))
            } catch {
                text = "Log unavailable: \(error.localizedDescription)"
            }
            parts.append(header + "\n" + text.trimmingCharacters(in: .newlines))
        }
        return parts.joined(separator: "\n\n")
    }
}
