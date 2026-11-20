import XCTest
@testable import PullYard

@MainActor
final class MergeReadinessTests: XCTestCase {
    private func pr(_ overrides: [String: Any] = [:]) throws -> PullRequestDetail {
        var json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/o/r/pull/7", "state": "OPEN",
            "isDraft": false, "merged": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "baseRefName": "main", "headRefOid": "head",
            "additions": 1, "deletions": 1, "changedFiles": 1,
            "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []],
            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": []], "allCommits": ["nodes": []],
            "timelineItems": ["nodes": []], "reviewThreads": ["nodes": []]
        ]
        json.merge(overrides) { $1 }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PullRequestDetail.self, from: data)
    }

    private func checks(_ nodes: [[String: Any]]) -> [String: Any] {
        ["lastCommit": ["nodes": [["commit": ["oid": "head", "statusCheckRollup": ["state": "FAILURE", "contexts": ["nodes": nodes]]]]]]]
    }

    private func run(_ name: String, conclusion: String? = "SUCCESS", required: Bool? = nil) -> [String: Any] {
        var n: [String: Any] = ["__typename": "CheckRun", "databaseId": abs(name.hashValue % 100000), "name": name,
                                "status": conclusion == nil ? "IN_PROGRESS" : "COMPLETED"]
        if let conclusion { n["conclusion"] = conclusion }
        if let required { n["isRequired"] = required }
        return n
    }

    private func review(_ login: String, _ state: String, oid: String = "head") -> [String: Any] {
        ["state": state, "commit": ["oid": oid], "author": ["login": login, "avatarUrl": ""]]
    }

    private func kinds(_ list: [MergeRequirement], _ state: RequirementState) -> [RequirementKind] {
        list.filter { $0.state == state }.map(\.kind)
    }

    func testParsesRulesetsAndClassicChecks() {
        let rules = #"""
        [{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_code_owner_review":false,"require_last_push_approval":true,"required_review_thread_resolution":true}},
         {"type":"pull_request","parameters":{"required_approving_review_count":2,"require_code_owner_review":true}},
         {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}},
         {"type":"deletion"}]
        """#
        let branch = #"{"name":"main","protected":true,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"everyone","contexts":["lint"],"checks":[{"context":"lint","app_id":1}]}}}"#
        let r = BranchRules.parse(rules: Data(rules.utf8), branch: Data(branch.utf8), protection: nil)
        XCTAssertEqual(r.requiredApprovals, 2)
        XCTAssertTrue(r.codeOwnerReview)
        XCTAssertTrue(r.lastPushApproval)
        XCTAssertTrue(r.threadResolution)
        XCTAssertEqual(r.requiredChecks, ["build", "lint"])
        XCTAssertTrue(r.reviewRulesKnown)
        XCTAssertTrue(r.checkRulesKnown)
    }

    func testClassicProtectionUnknownWithoutAdminAccess() {
        let branch = #"{"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"off","contexts":["ci"]}}}"#
        XCTAssertTrue(BranchRules.isClassicProtected(Data(branch.utf8)))
        let r = BranchRules.parse(rules: Data("[]".utf8), branch: Data(branch.utf8), protection: nil)
        XCTAssertFalse(r.reviewRulesKnown)
        XCTAssertEqual(r.requiredChecks, [])
        let protection = #"{"required_pull_request_reviews":{"required_approving_review_count":3,"require_code_owner_reviews":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"contexts":["ci"]}}"#
        let admin = BranchRules.parse(rules: Data("[]".utf8), branch: Data(branch.utf8), protection: Data(protection.utf8))
        XCTAssertTrue(admin.reviewRulesKnown)
        XCTAssertEqual(admin.requiredApprovals, 3)
        XCTAssertTrue(admin.codeOwnerReview)
        XCTAssertTrue(admin.threadResolution)
        XCTAssertEqual(admin.requiredChecks, ["ci"])
    }

    func testRulesUnreadableLeavesEverythingUnknown() {
        let r = BranchRules.parse(rules: nil, branch: nil, protection: nil)
        XCTAssertFalse(r.reviewRulesKnown)
        XCTAssertFalse(r.checkRulesKnown)
        XCTAssertEqual(r, BranchRules())
    }

    func testOptionalFailureDoesNotBlock() throws {
        let p = try pr(checks([run("build", required: true), run("coverage", conclusion: "FAILURE", required: false)]).merging(["mergeStateStatus": "UNSTABLE"]) { $1 })
        let list = MergeReadiness.requirements(p, rules: .loaded(BranchRules(reviewRulesKnown: true, checkRulesKnown: true)))
        XCTAssertEqual(list.first { $0.kind == .checks }?.state, .satisfied)
        XCTAssertEqual(list.first { $0.kind == .optionalChecks }?.state, .advisory)
        XCTAssertFalse(list.contains { $0.state.blocks })
        XCTAssertTrue(MergeStatusBar.status(p, requirements: list).ready)
    }

    func testRequiredFailureAndNotStartedChecks() throws {
        let p = try pr(checks([run("build", conclusion: "FAILURE", required: true), run("lint", required: false)]))
        var rules = BranchRules(reviewRulesKnown: true, checkRulesKnown: true)
        rules.requiredChecks = ["build", "deploy-preview"]
        let b = MergeReadiness.checks(p.checks, rules: rules)
        XCTAssertEqual(b.failedRequired.map(\.title), ["build"])
        XCTAssertEqual(b.notStarted, ["deploy-preview"])
        let list = MergeReadiness.requirements(p, rules: .loaded(rules))
        let row = try XCTUnwrap(list.first { $0.kind == .checks })
        XCTAssertEqual(row.state, .missing)
        XCTAssertEqual(row.title, "1 required check failed")
        XCTAssertEqual(row.action, .showChecks)
    }

    func testNotStartedRequiredCheckIsPending() throws {
        let p = try pr(checks([run("build", required: true)]))
        var rules = BranchRules(reviewRulesKnown: true, checkRulesKnown: true)
        rules.requiredChecks = ["build", "e2e"]
        let row = try XCTUnwrap(MergeReadiness.requirements(p, rules: .loaded(rules)).first { $0.kind == .checks })
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.detail, "Not started: e2e")
    }

    func testLegacyServerWithoutRequiredFlagTreatsAllChecksAsBlocking() throws {
        let p = try pr(checks([run("build", conclusion: "FAILURE")]))
        let b = MergeReadiness.checks(p.checks, rules: nil)
        XCTAssertFalse(b.requiredKnown)
        XCTAssertEqual(b.failedRequired.count, 1)
        XCTAssertEqual(MergeStatusBar.status(p).text, "1 check failed")
    }

    func testApprovalCountAndChangesRequested() throws {
        var rules = BranchRules(reviewRulesKnown: true, checkRulesKnown: true)
        rules.requiredApprovals = 2
        let one = try pr(["latestOpinionatedReviews": ["nodes": [review("alice", "APPROVED")]]])
        let row = try XCTUnwrap(MergeReadiness.requirements(one, rules: .loaded(rules)).first { $0.kind == .approvals })
        XCTAssertEqual(row.state, .missing)
        XCTAssertEqual(row.title, "1 of 2 required approvals")
        XCTAssertEqual(row.detail, "Needs 1 more approval")
        XCTAssertEqual(row.action, .requestReview)

        let blocked = try pr(["latestOpinionatedReviews": ["nodes": [review("alice", "APPROVED"), review("bob", "CHANGES_REQUESTED")]]])
        let list = MergeReadiness.requirements(blocked, rules: .loaded(rules))
        XCTAssertEqual(list.first { $0.kind == .changesRequested }?.detail, "By bob")
        XCTAssertEqual(MergeStatusBar.status(blocked, requirements: list).text, list.first { $0.state == .missing }?.title)
    }

    func testReviewRequiredFallsBackToReviewDecision() throws {
        let p = try pr(["reviewDecision": "REVIEW_REQUIRED"])
        let row = try XCTUnwrap(MergeReadiness.requirements(p, rules: .failed).first { $0.kind == .approvals })
        XCTAssertEqual(row.state, .missing)
        XCTAssertNotNil(row.detail)
        XCTAssertTrue(MergeReadiness.requirements(p, rules: .failed).contains { $0.kind == .rules && $0.state == .unknown })
    }

    func testLastPushApprovalAndCodeOwners() throws {
        var rules = BranchRules(reviewRulesKnown: true, checkRulesKnown: true)
        rules.requiredApprovals = 1
        rules.lastPushApproval = true
        rules.codeOwnerReview = true
        let p = try pr([
            "latestOpinionatedReviews": ["nodes": [review("alice", "APPROVED", oid: "old")]],
            "reviewRequests": ["nodes": [["asCodeOwner": true, "requestedReviewer": ["__typename": "Team", "name": "Core", "combinedSlug": "o/core"]]]]
        ])
        let list = MergeReadiness.requirements(p, rules: .loaded(rules))
        XCTAssertEqual(list.first { $0.kind == .lastPush }?.state, .missing)
        XCTAssertEqual(list.first { $0.kind == .codeOwners }?.detail, "Waiting for o/core")
        XCTAssertEqual(list.first { $0.kind == .approvals }?.state, .satisfied)
    }

    func testUnresolvedConversations() throws {
        let threads: [String: Any] = ["reviewThreads": ["nodes": [
            ["id": "t1", "isResolved": false, "isOutdated": true, "path": "a", "diffSide": "RIGHT", "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": ["nodes": []]],
            ["id": "t2", "isResolved": true, "isOutdated": false, "path": "a", "diffSide": "RIGHT", "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": ["nodes": []]]
        ]]]
        let p = try pr(threads)
        var rules = BranchRules(reviewRulesKnown: true, checkRulesKnown: true)
        XCTAssertEqual(MergeReadiness.requirements(p, rules: .loaded(rules)).first { $0.kind == .conversations }?.state, .advisory)
        rules.threadResolution = true
        let row = try XCTUnwrap(MergeReadiness.requirements(p, rules: .loaded(rules)).first { $0.kind == .conversations })
        XCTAssertEqual(row.state, .missing)
        XCTAssertEqual(row.title, "1 unresolved conversation")
        XCTAssertEqual(row.action, .showConversation)
    }

    func testConflictsBehindDraftAndHiddenRule() throws {
        let conflicted = try pr(["mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"])
        XCTAssertEqual(MergeReadiness.requirements(conflicted, rules: .loading).first { $0.kind == .conflicts }?.action, .showConflicts)
        let behind = try pr(["mergeStateStatus": "BEHIND"])
        XCTAssertEqual(MergeReadiness.requirements(behind, rules: .loading).first { $0.kind == .behind }?.action, .updateBranch)
        let draft = try pr(["isDraft": true])
        XCTAssertEqual(MergeReadiness.requirements(draft, rules: .loading).first?.kind, .draft)
        let hidden = try pr()
        let list = MergeReadiness.requirements(hidden, rules: .loaded(BranchRules(reviewRulesKnown: true, checkRulesKnown: true)))
        XCTAssertTrue(list.contains { $0.kind == .otherRules && $0.state == .unknown })
        let closed = try pr(["state": "MERGED"])
        XCTAssertTrue(MergeReadiness.requirements(closed, rules: .loading).isEmpty)
    }

    func testTeamReviewerUsesCombinedSlug() throws {
        let p = try pr(["reviewRequests": ["nodes": [
            ["asCodeOwner": true, "requestedReviewer": ["__typename": "Team", "name": "Core", "combinedSlug": "o/core", "avatarUrl": "x"]],
            ["requestedReviewer": ["__typename": "User", "login": "alice"]]
        ]]])
        let team = try XCTUnwrap(p.reviewRequests.nodes.first?.requestedReviewer)
        XCTAssertTrue(team.isTeam)
        XCTAssertEqual(team.display, "o/core")
        XCTAssertEqual(p.reviewRequests.nodes.first?.asCodeOwner, true)
        XCTAssertNil(p.reviewRequests.nodes.last?.asCodeOwner)
    }

    func testFilesPageCursor() throws {
        let json = #"{"totalCount":150,"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"path":"a","viewerViewedState":"VIEWED"},{"path":"b","viewerViewedState":"UNVIEWED"},null]}"#
        let page = try JSONDecoder().decode(FileViewedPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.viewedPaths, ["a"])
        XCTAssertEqual(page.nextCursor, "c1")
        let last = try JSONDecoder().decode(FileViewedPage.self, from: Data(#"{"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[]}"#.utf8))
        XCTAssertNil(last.nextCursor)
    }

    func testLegacyQueryDropsNewFields() {
        XCTAssertTrue(Q.pullRequest.contains("isRequired(pullRequestNumber: $number)"))
        XCTAssertFalse(Q.pullRequestLegacy.contains("isRequired"))
        XCTAssertFalse(Q.pullRequestLegacy.contains("asCodeOwner"))
        XCTAssertFalse(Q.pullRequestLegacy.contains("combinedSlug"))
        XCTAssertTrue(Q.pullRequestLegacy.contains("files(first: 100)"))
    }

    func testReviewRulesCapabilityStates() throws {
        XCTAssertEqual(RulesStatus.loading.reviewRules, .unknown)
        XCTAssertEqual(RulesStatus.failed.reviewRules, .unknown)
        XCTAssertEqual(RulesStatus.loaded(BranchRules(reviewRulesKnown: true)).reviewRules, .supported)
        XCTAssertEqual(RulesStatus.loaded(BranchRules()).reviewRules, .unavailable)
        let p = try pr(["reviewDecision": "REVIEW_REQUIRED"])
        let hidden = try XCTUnwrap(MergeReadiness.requirements(p, rules: .loaded(BranchRules())).first { $0.kind == .approvals })
        XCTAssertEqual(hidden.detail, "The exact number of approvals isn’t visible with your access")
        XCTAssertNil(MergeReadiness.requirements(p, rules: .loading).first { $0.kind == .approvals }?.detail)
    }

    private func gitlab(_ status: String, required: Int? = nil, left: Int? = nil, _ overrides: [String: Any] = [:]) throws -> [MergeRequirement] {
        var p = try pr(overrides)
        p.forgeMerge = ForgeMergeInfo(status: status, approvalsRequired: required, approvalsLeft: left)
        return MergeReadiness.requirements(p, rules: .loading)
    }

    func testGitLabRequirementsFromDetailedStatus() throws {
        let ready = try gitlab("mergeable", required: 2, left: 0, ["latestOpinionatedReviews": ["nodes": [review("a", "APPROVED"), review("b", "APPROVED")]]])
        XCTAssertEqual(ready.map(\.title), ["No conflicts with main", "2 of 2 required approvals"])
        XCTAssertFalse(ready.contains { $0.state.blocks })

        let approvals = try XCTUnwrap(try gitlab("not_approved", required: 2, left: 1).first { $0.kind == .approvals })
        XCTAssertEqual(approvals.title, "1 of 2 required approvals")
        XCTAssertEqual(approvals.detail, "Needs 1 more approval")
        XCTAssertEqual(approvals.state, .missing)
        XCTAssertNil(approvals.action)

        XCTAssertEqual(try gitlab("conflict").first?.state, .missing)
        XCTAssertEqual(try gitlab("checking").first?.state, .pending)
        XCTAssertEqual(try gitlab("need_rebase").first { $0.kind == .behind }?.action, .updateBranch)
        XCTAssertNil(try gitlab("mergeable").first { $0.kind == .rules || $0.kind == .otherRules })
    }

    func testGitLabPipelineAndThreads() throws {
        let failing = try gitlab("ci_must_pass", checks([run("test", conclusion: "FAILURE")]))
        let ci = try XCTUnwrap(failing.first { $0.kind == .checks })
        XCTAssertEqual(ci.title, "1 job failed")
        XCTAssertEqual(ci.state, .missing)
        XCTAssertEqual(try gitlab("ci_must_pass").first { $0.kind == .checks }?.title, "A pipeline must run and succeed")
        XCTAssertEqual(try gitlab("ci_still_running", checks([run("build", conclusion: nil)])).first { $0.kind == .checks }?.state, .pending)
        XCTAssertEqual(try gitlab("mergeable", checks([run("lint", conclusion: "FAILURE")])).first { $0.kind == .checks }?.state, .advisory)

        let thread: [String: Any] = ["id": "t", "isResolved": false, "isOutdated": false, "path": "a", "line": 1, "diffSide": "RIGHT",
                                     "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": ["nodes": []]]
        let blocking = try XCTUnwrap(try gitlab("discussions_not_resolved", ["reviewThreads": ["nodes": [thread]]]).first { $0.kind == .conversations })
        XCTAssertEqual(blocking.title, "1 unresolved thread")
        XCTAssertEqual(blocking.state, .missing)
        XCTAssertEqual(try gitlab("mergeable", ["reviewThreads": ["nodes": [thread]]]).first { $0.kind == .conversations }?.state, .advisory)
    }

    func testGitLabUnknownBlockerIsShown() throws {
        var p = try pr(["mergeStateStatus": "BLOCKED"])
        p.mergeBlocker = "Title or description must reference a Jira issue"
        p.forgeMerge = ForgeMergeInfo(status: "jira_association_missing", approvalsRequired: nil, approvalsLeft: nil)
        let other = try XCTUnwrap(MergeReadiness.requirements(p, rules: .loading).first { $0.kind == .otherRules })
        XCTAssertEqual(other.title, "Title or description must reference a Jira issue")
        XCTAssertEqual(other.state, .missing)
    }

    func testMergeQueueStatus() throws {
        XCTAssertEqual(MergeQueueEntry(position: 3, state: "QUEUED", estimatedTimeToMerge: 290).summary, "Queued to merge · #3 in line · about 5 min")
        XCTAssertEqual(MergeQueueEntry(position: 1, state: "QUEUED").summary, "Queued to merge · next in line")
        XCTAssertEqual(MergeQueueEntry(position: 2, state: "AWAITING_CHECKS").summary, "Merge queue: waiting for checks · #2 in line")
        XCTAssertTrue(MergeQueueEntry(position: 1, state: "UNMERGEABLE").failing)

        let enabled = try pr(["isMergeQueueEnabled": true, "mergeStateStatus": "CLEAN"])
        let note = try XCTUnwrap(MergeReadiness.requirements(enabled, rules: .loading).first { $0.kind == .mergeQueue })
        XCTAssertEqual(note.state, .advisory)
        XCTAssertEqual(note.title, "Merges through a merge queue")

        let queued = try pr(["isMergeQueueEnabled": true, "isInMergeQueue": true, "mergeQueueEntry": ["position": 2, "state": "QUEUED", "estimatedTimeToMerge": 600]])
        XCTAssertEqual(MergeReadiness.requirements(queued, rules: .loading).first { $0.kind == .mergeQueue }?.state, .pending)
        XCTAssertEqual(MergeStatusBar.status(queued).text, "Queued to merge · #2 in line · about 10 min")
        XCTAssertFalse(MergeStatusBar.status(queued).ready)

        let removed = try pr(["mergeQueueEntry": ["position": 1, "state": "UNMERGEABLE"]])
        XCTAssertEqual(MergeReadiness.requirements(removed, rules: .loading).first { $0.kind == .mergeQueue }?.state, .missing)
        XCTAssertEqual(MergeStatusBar.status(removed).color, .ghRed)
        XCTAssertNil(MergeReadiness.requirements(try pr(), rules: .loading).first { $0.kind == .mergeQueue })
    }

    func testLegacyQueryDropsMergeQueueFields() {
        XCTAssertTrue(Q.pullRequest.contains("mergeQueueEntry { position state enqueuedAt estimatedTimeToMerge }"))
        XCTAssertFalse(Q.pullRequestLegacy.contains("mergeQueue"))
        XCTAssertFalse(Q.pullRequestLegacy.contains("isInMergeQueue"))
        XCTAssertTrue(Q.prPulse.contains("mergeQueueEntry { position state }"))
        XCTAssertFalse(Q.prPulseLegacy.contains("mergeQueue"))
    }

    func testGitLabMergeTrain() throws {
        XCTAssertEqual(GitLabReviewMapper.trainEntry(nil), nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let running = try decoder.decode(GitLabMR.TrainCar.self, from: Data(#"{"status":"fresh","pipeline":{"id":1,"status":"running"}}"#.utf8))
        XCTAssertEqual(GitLabReviewMapper.trainEntry(running)?.state, "AWAITING_CHECKS")
        let merging = try decoder.decode(GitLabMR.TrainCar.self, from: Data(#"{"status":"merging"}"#.utf8))
        XCTAssertEqual(GitLabReviewMapper.trainEntry(merging)?.state, "MERGEABLE")
        let done = try decoder.decode(GitLabMR.TrainCar.self, from: Data(#"{"status":"merged"}"#.utf8))
        XCTAssertNil(GitLabReviewMapper.trainEntry(done))

        var p = try pr()
        p.forgeMerge = ForgeMergeInfo(status: "mergeable", approvalsRequired: nil, approvalsLeft: nil)
        p.isMergeQueueEnabled = true
        XCTAssertEqual(MergeReadiness.requirements(p, rules: .loading).first { $0.kind == .mergeQueue }?.title, "Merges through a merge train")
        p.mergeQueueEntry = MergeQueueEntry(position: nil, state: "QUEUED")
        XCTAssertEqual(MergeReadiness.requirements(p, rules: .loading).first { $0.kind == .mergeQueue }?.title, "In the merge train")
    }

    func testForgeDefaultsDoNotClaimReviewSupport() {
        let caps = ForgeCapabilities(pullFilters: [.mine])
        XCTAssertEqual(caps.pullRequestReview, .unsupported)
        XCTAssertEqual(caps.mergeRequirements, .unsupported)
    }
}
