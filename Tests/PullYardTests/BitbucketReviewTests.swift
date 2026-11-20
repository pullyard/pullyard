import XCTest
@testable import PullYard

@MainActor
final class BitbucketReviewTests: XCTestCase {
    private let ref = ItemRef(repo: RepoRef(owner: "acme", name: "api"), number: 5)

    override func setUp() {
        StubProtocol.routes = [:]
        StubProtocol.queryRoutes = []
        StubProtocol.requests = []
        ForgeHTTP.protocolClasses = [StubProtocol.self]
    }

    override func tearDown() {
        ForgeHTTP.protocolClasses = []
    }

    private func backend() -> BitbucketPRBackend {
        let account = GitAccount(id: "test", provider: .bitbucket, host: "bitbucket.org", login: "sofia", email: "s@example.com", userID: "{u-sofia}", keychainKey: "test")
        return BitbucketPRBackend(client: BitbucketClient(account: account, credential: GitCredential(token: "tok")))
    }

    private func requests(_ method: String, _ suffix: String) -> [URLRequest] {
        StubProtocol.requests.filter { $0.httpMethod == method && ($0.url?.path ?? "").hasSuffix(suffix) }
    }

    private func json(_ request: URLRequest?) -> [String: Any] {
        guard let stream = request?.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    nonisolated private static let detail = """
    {"id":5,"title":"Add billing","state":"OPEN","draft":false,
     "summary":{"raw":"Adds **billing**","html":"<p>Adds <strong>billing</strong> <a href=\\"/acme/api/issues/2\\">#2</a></p>"},
     "created_on":"2026-10-01T10:00:00.000000+00:00","updated_on":"2026-10-03T12:00:00.123456+00:00",
     "author":{"uuid":"{u-max}","display_name":"Max","nickname":"max","links":{"avatar":{"href":"https://a/max.png"}}},
     "source":{"branch":{"name":"feature/billing"},"commit":{"hash":"head2"},"repository":{"full_name":"acme/api"}},
     "destination":{"branch":{"name":"main"},"commit":{"hash":"base1"},"repository":{"full_name":"acme/api"}},
     "close_source_branch":true,"links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/5"}},
     "comment_count":4,"task_count":1,
     "participants":[
       {"user":{"uuid":"{u-lea}","nickname":"lea"},"role":"REVIEWER","approved":true,"state":"approved","participated_on":"2026-10-02T10:00:00+00:00"},
       {"user":{"uuid":"{u-ivo}","nickname":"ivo"},"role":"REVIEWER","approved":false,"state":"changes_requested"},
       {"user":{"uuid":"{u-sofia}","nickname":"sofia"},"role":"REVIEWER","approved":false,"state":null}],
     "reviewers":[{"uuid":"{u-lea}","nickname":"lea"},{"uuid":"{u-ivo}","nickname":"ivo"},{"uuid":"{u-sofia}","nickname":"sofia"}]}
    """

    nonisolated private static let comments = """
    {"values":[
      {"id":10,"content":{"raw":"Looks good","html":"<p>Looks good</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T11:00:00+00:00"},
      {"id":20,"content":{"raw":"Rename this","html":"<p>Rename this</p>"},"user":{"nickname":"ivo"},"created_on":"2026-10-02T09:00:00+00:00","inline":{"path":"b.swift","from":null,"to":9}},
      {"id":21,"content":{"raw":"Done","html":"<p>Done</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T10:00:00+00:00","parent":{"id":20}},
      {"id":22,"content":{"raw":"Thanks","html":""},"user":{"nickname":"ivo"},"created_on":"2026-10-02T11:00:00+00:00","parent":{"id":21}},
      {"id":30,"content":{"raw":"Old","html":"<p>Old</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:00:00+00:00","inline":{"path":"a.swift","from":4,"to":null,"outdated":true},"resolution":{"type":"resolved"}},
      {"id":40,"content":{"raw":"Gone","html":""},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:30:00+00:00","deleted":true},
      {"id":50,"content":{"raw":"Question?","html":"<p>Question?</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-02T12:00:00+00:00"},
      {"id":51,"content":{"raw":"Answer","html":"<p>Answer</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T13:00:00+00:00","parent":{"id":50}}
    ],"next":null}
    """

    nonisolated private static let diff = """
    diff --git a/a.swift b/a.swift
    index 1..2 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,2 @@
    -let a = 1
    +let a = 2
     let b = 3
    diff --git a/b.swift b/b.swift
    new file mode 100644
    --- /dev/null
    +++ b/b.swift
    @@ -0,0 +1 @@
    +print(1)
    """

    private func stub() {
        StubProtocol.routes = [
            "/pullrequests/5": (200, Self.detail),
            "/pullrequests/5/comments": (200, Self.comments),
            "/pullrequests/5/commits": (200, #"{"values":[{"hash":"head2abcdef","message":"Second\n\nbody","date":"2026-10-02T08:00:00+00:00","author":{"raw":"Max <max@x>"}},{"hash":"c1","message":"First","date":"2026-10-01T08:00:00+00:00","author":{"raw":"Max <max@x>","user":{"display_name":"Max M"}}}]}"#),
            "/pullrequests/5/statuses": (200, #"{"values":[{"key":"ci","name":"CI","state":"FAILED","url":"https://ci/1"},{"key":"lint","state":"SUCCESSFUL"},{"key":"e2e","name":"E2E","state":"INPROGRESS"}]}"#),
            "/pullrequests/5/diffstat": (200, #"{"values":[{"status":"modified","lines_added":1,"lines_removed":1,"old":{"path":"a.swift"},"new":{"path":"a.swift"}},{"status":"added","lines_added":1,"lines_removed":0,"old":null,"new":{"path":"b.swift"}}]}"#),
            "/pullrequests/5/diff": (200, Self.diff),
            "/pullrequests/5/approve": (200, "{}"),
            "/pullrequests/5/request-changes": (200, "{}"),
            "/pullrequests/5/merge": (200, "{}"),
            "/pullrequests/5/decline": (200, "{}"),
            "/comments/20/resolve": (200, "{}")
        ]
    }

    func testLoadMapsPullRequest() async throws {
        stub()
        let load = try await backend().load(ref)
        let repo = try XCTUnwrap(load.repository)
        let pr = try XCTUnwrap(repo.pullRequest)
        XCTAssertEqual(load.viewer, "{u-sofia}")
        XCTAssertEqual(pr.state, "OPEN")
        XCTAssertEqual(pr.mergeable, "MERGEABLE")
        XCTAssertEqual(pr.mergeStateStatus, "UNSTABLE")
        XCTAssertEqual(pr.mergeBlocker, "Changes requested")
        XCTAssertEqual(pr.reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(pr.headRefName, "feature/billing")
        XCTAssertEqual(pr.headRefOid, "head2")
        XCTAssertEqual(pr.additions, 2)
        XCTAssertEqual(pr.deletions, 1)
        XCTAssertEqual(pr.changedFiles, 2)
        XCTAssertTrue(pr.bodyHTML.contains(#"href="https://bitbucket.org/acme/api/issues/2""#), pr.bodyHTML)
        XCTAssertEqual(Set(pr.latestOpinionatedReviews.nodes.map { "\($0.author?.login ?? ""):\($0.state)" }), ["lea:APPROVED", "ivo:CHANGES_REQUESTED"])
        XCTAssertEqual(pr.reviewRequests.nodes.compactMap { $0.requestedReviewer?.display }, ["sofia"])
        XCTAssertEqual(pr.viewerApproved, false)
        XCTAssertEqual(pr.viewerCanApprove, true)
        XCTAssertEqual(repo.deleteBranchOnMerge, true)
        XCTAssertFalse(repo.autoMergeAllowed)
        XCTAssertEqual(pr.allCommits.nodes.map(\.commit.messageHeadline), ["First", "Second"])
        XCTAssertEqual(pr.allCommits.nodes.first?.commit.author?.name, "Max M")
        XCTAssertEqual(pr.allCommits.nodes.last?.commit.abbreviatedOid, "head2ab")

        let checks = pr.checks
        XCTAssertEqual(checks.map(\.title), ["CI", "lint", "E2E"])
        XCTAssertEqual(checks.map(\.outcome), [.failure, .success, .pending])
        XCTAssertEqual(pr.rollup?.state, "FAILURE")

        let threads = pr.reviewThreads.nodes
        XCTAssertEqual(threads.map(\.id), ["30", "20", "50"])
        let inline = try XCTUnwrap(threads.first { $0.id == "20" })
        XCTAssertEqual(inline.path, "b.swift")
        XCTAssertEqual(inline.line, 9)
        XCTAssertEqual(inline.diffSide, "RIGHT")
        XCTAssertFalse(inline.isResolved)
        XCTAssertTrue(inline.viewerCanResolve)
        XCTAssertEqual(inline.comments.nodes.map(\.body), ["Rename this", "Done", "Thanks"])
        let old = try XCTUnwrap(threads.first { $0.id == "30" })
        XCTAssertTrue(old.isResolved)
        XCTAssertTrue(old.isOutdated)
        XCTAssertNil(old.line)
        XCTAssertEqual(old.diffSide, "LEFT")
        XCTAssertTrue(old.viewerCanUnresolve)
        let general = try XCTUnwrap(threads.first { $0.id == "50" })
        XCTAssertEqual(general.path, "")
        XCTAssertEqual(general.comments.nodes.count, 2)
        let plain = pr.timelineItems.nodes.filter { $0.typename == "IssueComment" }
        XCTAssertEqual(plain.map(\.id), ["bb-c-10"])
        XCTAssertFalse(pr.timelineItems.nodes.contains { $0.id == "bb-c-40" })
    }

    func testRequirementsAreAdvisoryExceptConflicts() async throws {
        stub()
        let loaded = try await backend().load(ref)
        let pr = try XCTUnwrap(loaded.repository?.pullRequest)
        let reqs = MergeReadiness.requirements(pr, rules: .loading)
        XCTAssertEqual(reqs.first { $0.kind == .conflicts }?.state, .satisfied)
        XCTAssertEqual(reqs.first { $0.kind == .changesRequested }?.state, .advisory)
        XCTAssertEqual(reqs.first { $0.kind == .approvals }?.title, "Approved")
        XCTAssertEqual(reqs.first { $0.kind == .checks }?.title, "1 build failed")
        XCTAssertEqual(reqs.first { $0.kind == .conversations }?.title, "1 open task")
        XCTAssertEqual(reqs.last?.kind, .otherRules)
        XCTAssertFalse(reqs.contains { $0.state == .missing })

        let conflicted = Self.detail.replacingOccurrences(of: #""task_count":1"#, with: #""task_count":0"#)
        StubProtocol.routes["/pullrequests/5"] = (200, conflicted)
        StubProtocol.routes["/pullrequests/5/diffstat"] = (200, #"{"values":[{"status":"merge conflict","old":{"path":"a.swift"},"new":{"path":"a.swift"}}]}"#)
        let reloaded = try await backend().load(ref)
        let bad = try XCTUnwrap(reloaded.repository?.pullRequest)
        XCTAssertEqual(bad.mergeStateStatus, "DIRTY")
        XCTAssertEqual(MergeReadiness.requirements(bad, rules: .loading).first { $0.kind == .conflicts }?.state, .missing)
    }

    func testFilesSplitUnifiedDiff() async throws {
        stub()
        let loaded = try await backend().load(ref)
        let pr = try XCTUnwrap(loaded.repository?.pullRequest)
        let files = try await backend().files(ref, pr: pr)
        XCTAssertEqual(files.map(\.filename), ["a.swift", "b.swift"])
        XCTAssertEqual(files.map(\.status), ["modified", "added"])
        XCTAssertEqual(files.first?.patch, "@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n let b = 3")
        XCTAssertEqual(files.last?.patch, "@@ -0,0 +1 @@\n+print(1)")
        XCTAssertEqual(BitbucketReviewMapper.splitDiff("").count, 0)
    }

    func testSubmitReviewPostsInlineCommentsThenDecision() async throws {
        stub()
        let b = backend()
        let loaded = try await b.load(ref)
        let pr = try XCTUnwrap(loaded.repository?.pullRequest)
        let right = PendingComment(path: "a.swift", line: 1, side: "RIGHT", body: "nit")
        let left = PendingComment(path: "a.swift", line: 1, side: "LEFT", body: "was this needed?")
        StubProtocol.requests = []
        try await b.submitReview(ref, pr: pr, event: "REQUEST_CHANGES", body: "Please fix", comments: [right, left], files: [])
        let posts = requests("POST", "/pullrequests/5/comments")
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(json(posts[0])["inline"] as? [String: AnyHashable], ["path": "a.swift", "to": 1])
        XCTAssertEqual(json(posts[1])["inline"] as? [String: AnyHashable], ["path": "a.swift", "from": 1])
        XCTAssertEqual((json(posts[2])["content"] as? [String: String])?["raw"], "Please fix")
        XCTAssertEqual(requests("POST", "/request-changes").count, 1)
        XCTAssertTrue(requests("POST", "/approve").isEmpty)

        try await b.submitReview(ref, pr: pr, event: "APPROVE", body: "", comments: [], files: [])
        XCTAssertEqual(requests("POST", "/approve").count, 1)
        try await b.revokeApproval(ref, pr: pr)
        XCTAssertEqual(requests("DELETE", "/approve").count, 1)
    }

    func testThreadActionsMergeAndState() async throws {
        stub()
        let b = backend()
        let loaded = try await b.load(ref)
        let pr = try XCTUnwrap(loaded.repository?.pullRequest)
        StubProtocol.requests = []
        try await b.reply(ref, thread: "20", body: "ok")
        XCTAssertEqual((json(requests("POST", "/pullrequests/5/comments").first)["parent"] as? [String: Int])?["id"], 20)
        try await b.setResolved(ref, thread: "20", resolved: true)
        try await b.setResolved(ref, thread: "20", resolved: false)
        XCTAssertEqual(requests("POST", "/comments/20/resolve").count, 1)
        XCTAssertEqual(requests("DELETE", "/comments/20/resolve").count, 1)

        let warning = try await b.merge(ref, pr: pr, method: "SQUASH", title: "Billing", body: nil, deleteBranch: true)
        XCTAssertNil(warning)
        let merge = json(requests("POST", "/pullrequests/5/merge").first)
        XCTAssertEqual(merge["merge_strategy"] as? String, "squash")
        XCTAssertEqual(merge["close_source_branch"] as? Bool, true)
        XCTAssertEqual(merge["message"] as? String, "Billing")

        try await b.perform(.convertToDraft, ref: ref, pr: pr)
        XCTAssertEqual(json(requests("PUT", "/pullrequests/5").last)["draft"] as? Bool, true)
        try await b.edit(ref, pr: pr, title: "T", body: "B")
        XCTAssertEqual(json(requests("PUT", "/pullrequests/5").last)["description"] as? String, "B")
        try await b.perform(.close, ref: ref, pr: pr)
        XCTAssertEqual(requests("POST", "/decline").count, 1)
        do {
            try await b.perform(.reopen, ref: ref, pr: pr)
            XCTFail("reopen should be unsupported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not available for Bitbucket yet")
        }
    }

    func testFeaturesAndCapabilities() async {
        let f = PRFeatures.bitbucket
        XCTAssertTrue(f.requestChanges)
        XCTAssertFalse(f.reopen)
        XCTAssertFalse(f.viewedFiles)
        XCTAssertFalse(f.updateBranch)
        XCTAssertEqual(f.checksTitle, "Builds")
        let account = GitAccount(id: "t", provider: .bitbucket, host: "bitbucket.org", login: "s", email: "s@x", userID: "{u}", keychainKey: "t")
        let caps = await BitbucketClient(account: account, credential: GitCredential(token: "t")).capabilities()
        XCTAssertEqual(caps.pullRequestReview, .supported)
        XCTAssertEqual(caps.mergeRequirements, .unavailable)
    }
}
