import Foundation

struct BranchRules: Equatable {
    var requiredApprovals = 0
    var codeOwnerReview = false
    var lastPushApproval = false
    var threadResolution = false
    var requiredChecks: Set<String> = []
    var reviewRulesKnown = false
    var checkRulesKnown = false

    static func isClassicProtected(_ branch: Data?) -> Bool {
        guard let branch, let info = try? JSONDecoder().decode(BranchInfo.self, from: branch) else { return false }
        return info.protection?.enabled == true
    }

    static func parse(rules: Data?, branch: Data?, protection: Data?) -> BranchRules {
        var r = BranchRules()
        let decoder = JSONDecoder()
        let ruleset = rules.flatMap { try? decoder.decode([Rule].self, from: $0) }
        let info = branch.flatMap { try? decoder.decode(BranchInfo.self, from: $0) }
        let classic = protection.flatMap { try? decoder.decode(Protection.self, from: $0) }
        for rule in ruleset ?? [] {
            switch rule.type {
            case "pull_request":
                let p = rule.parameters
                r.requiredApprovals = max(r.requiredApprovals, p?.requiredApprovingReviewCount ?? 0)
                r.codeOwnerReview = r.codeOwnerReview || p?.requireCodeOwnerReview == true
                r.lastPushApproval = r.lastPushApproval || p?.requireLastPushApproval == true
                r.threadResolution = r.threadResolution || p?.requiredReviewThreadResolution == true
            case "required_status_checks":
                r.requiredChecks.formUnion(rule.parameters?.requiredStatusChecks?.map(\.context) ?? [])
            default:
                break
            }
        }
        if let checks = info?.protection?.requiredStatusChecks, checks.enforcementLevel != "off" {
            r.requiredChecks.formUnion(checks.names)
        }
        if let classic {
            if let reviews = classic.requiredPullRequestReviews {
                r.requiredApprovals = max(r.requiredApprovals, reviews.requiredApprovingReviewCount ?? 0)
                r.codeOwnerReview = r.codeOwnerReview || reviews.requireCodeOwnerReviews == true
                r.lastPushApproval = r.lastPushApproval || reviews.requireLastPushApproval == true
            }
            r.threadResolution = r.threadResolution || classic.requiredConversationResolution?.enabled == true
            r.requiredChecks.formUnion(classic.requiredStatusChecks?.names ?? [])
        }
        let classicProtected = info?.protection?.enabled == true
        r.reviewRulesKnown = ruleset != nil && (!classicProtected || classic != nil)
        r.checkRulesKnown = ruleset != nil && info != nil
        return r
    }

    private struct Rule: Decodable {
        struct Check: Decodable { let context: String }
        struct Parameters: Decodable {
            let requiredApprovingReviewCount: Int?
            let requireCodeOwnerReview: Bool?
            let requireLastPushApproval: Bool?
            let requiredReviewThreadResolution: Bool?
            let requiredStatusChecks: [Check]?

            enum CodingKeys: String, CodingKey {
                case requiredApprovingReviewCount = "required_approving_review_count"
                case requireCodeOwnerReview = "require_code_owner_review"
                case requireLastPushApproval = "require_last_push_approval"
                case requiredReviewThreadResolution = "required_review_thread_resolution"
                case requiredStatusChecks = "required_status_checks"
            }
        }
        let type: String
        let parameters: Parameters?
    }

    private struct StatusChecks: Decodable {
        struct Check: Decodable { let context: String }
        let enforcementLevel: String?
        let contexts: [String]?
        let checks: [Check]?

        enum CodingKeys: String, CodingKey {
            case enforcementLevel = "enforcement_level", contexts, checks
        }

        var names: Set<String> { Set((contexts ?? []) + (checks ?? []).map(\.context)) }
    }

    private struct BranchInfo: Decodable {
        struct BranchProtection: Decodable {
            let enabled: Bool?
            let requiredStatusChecks: StatusChecks?

            enum CodingKeys: String, CodingKey {
                case enabled, requiredStatusChecks = "required_status_checks"
            }
        }
        let protection: BranchProtection?
    }

    private struct Protection: Decodable {
        struct Reviews: Decodable {
            let requiredApprovingReviewCount: Int?
            let requireCodeOwnerReviews: Bool?
            let requireLastPushApproval: Bool?

            enum CodingKeys: String, CodingKey {
                case requiredApprovingReviewCount = "required_approving_review_count"
                case requireCodeOwnerReviews = "require_code_owner_reviews"
                case requireLastPushApproval = "require_last_push_approval"
            }
        }
        struct Enabled: Decodable { let enabled: Bool? }
        let requiredPullRequestReviews: Reviews?
        let requiredConversationResolution: Enabled?
        let requiredStatusChecks: StatusChecks?

        enum CodingKeys: String, CodingKey {
            case requiredPullRequestReviews = "required_pull_request_reviews"
            case requiredConversationResolution = "required_conversation_resolution"
            case requiredStatusChecks = "required_status_checks"
        }
    }
}

enum RulesStatus: Equatable {
    case loading
    case loaded(BranchRules)
    case failed

    var rules: BranchRules? {
        if case .loaded(let r) = self { return r }
        return nil
    }

    var reviewRules: CapabilityState {
        switch self {
        case .loading, .failed: return .unknown
        case .loaded(let r): return r.reviewRulesKnown ? .supported : .unavailable
        }
    }
}

enum RequirementState: Equatable {
    case satisfied, missing, pending, unknown, advisory

    var blocks: Bool { self == .missing || self == .pending }
}

enum RequirementAction: Equatable {
    case requestReview, showChecks, showConversation, showConflicts, updateBranch, readyForReview
}

enum RequirementKind: String {
    case draft, conflicts, behind, changesRequested, approvals, codeOwners, lastPush, checks, optionalChecks, conversations, mergeQueue, rules, otherRules
}

struct MergeRequirement: Identifiable, Equatable {
    let kind: RequirementKind
    let state: RequirementState
    let title: String
    var detail: String?
    var action: RequirementAction?

    var id: String { kind.rawValue }
}

struct CheckBreakdown: Equatable {
    var requiredKnown = false
    var required: [CheckContext] = []
    var optional: [CheckContext] = []
    var notStarted: [String] = []

    var failedRequired: [CheckContext] { required.filter { $0.outcome == .failure } }
    var runningRequired: [CheckContext] { required.filter { $0.outcome == .pending } }
    var failedOptional: [CheckContext] { optional.filter { $0.outcome == .failure } }

    static func == (a: CheckBreakdown, b: CheckBreakdown) -> Bool {
        a.requiredKnown == b.requiredKnown && a.required.map(\.id) == b.required.map(\.id)
            && a.optional.map(\.id) == b.optional.map(\.id) && a.notStarted == b.notStarted
    }
}

enum MergeReadiness {
    static func checks(_ checks: [CheckContext], rules: BranchRules?) -> CheckBreakdown {
        var b = CheckBreakdown()
        let flagged = checks.contains { $0.isRequired != nil }
        let ruleNames = rules?.checkRulesKnown == true ? rules?.requiredChecks : nil
        if flagged {
            b.requiredKnown = true
            b.required = checks.filter { $0.isRequired == true }
            b.optional = checks.filter { $0.isRequired != true }
        } else if let ruleNames {
            b.requiredKnown = true
            b.required = checks.filter { ruleNames.contains($0.title) }
            b.optional = checks.filter { !ruleNames.contains($0.title) }
        } else {
            b.required = checks
        }
        if let ruleNames {
            let reported = Set(checks.map(\.title))
            b.notStarted = ruleNames.subtracting(reported).sorted()
        }
        return b
    }

    static func requirements(_ pr: PullRequestDetail, rules status: RulesStatus) -> [MergeRequirement] {
        guard pr.isOpen else { return [] }
        if let merge = pr.forgeMerge { return merge.provider == "bitbucket" ? bitbucket(pr, merge: merge) : gitlab(pr, merge: merge) }
        let rules = status.rules
        var out: [MergeRequirement] = []

        if pr.isDraft {
            out.append(MergeRequirement(kind: .draft, state: .missing, title: "Draft pull request", detail: "Mark it ready for review before merging", action: .readyForReview))
        }

        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            out.append(MergeRequirement(kind: .conflicts, state: .missing, title: "Conflicts with \(pr.baseRefName)", detail: "Resolve them before merging", action: .showConflicts))
        } else if pr.mergeable == "UNKNOWN" {
            out.append(MergeRequirement(kind: .conflicts, state: .pending, title: "Checking for conflicts…"))
        } else {
            out.append(MergeRequirement(kind: .conflicts, state: .satisfied, title: "No conflicts with \(pr.baseRefName)"))
        }

        if pr.mergeStateStatus == "BEHIND" {
            out.append(MergeRequirement(kind: .behind, state: .missing, title: "Branch is behind \(pr.baseRefName)", detail: "The base branch requires it to be up to date", action: .updateBranch))
        }

        out += reviewRequirements(pr, rules: rules, access: status.reviewRules, loading: status == .loading)
        out += checkRequirements(pr, rules: rules)
        if let c = conversationRequirement(pr, rules: rules, loading: status == .loading) { out.append(c) }

        if let entry = pr.mergeQueueEntry {
            out.append(MergeRequirement(kind: .mergeQueue, state: entry.failing ? .missing : .pending, title: entry.summary,
                                        detail: entry.failing ? "Fix the failing checks or conflicts and add it again" : nil))
        } else if pr.isMergeQueueEnabled == true {
            out.append(MergeRequirement(kind: .mergeQueue, state: .advisory, title: "Merges through a merge queue",
                                        detail: "Add it from the merge sheet with “Add to merge queue”"))
        }

        if status == .failed {
            out.append(MergeRequirement(kind: .rules, state: .unknown, title: "Branch rules couldn’t be read", detail: "Showing what GitHub reports for this pull request"))
        }
        if pr.mergeStateStatus == "BLOCKED", !out.contains(where: { $0.state.blocks }) {
            out.append(MergeRequirement(kind: .otherRules, state: .unknown, title: "Blocked by a rule PullYard can’t see", detail: "For example deployments, signed commits or a merge queue. Check the pull request on GitHub"))
        }
        return out
    }

    private static func reviewRequirements(_ pr: PullRequestDetail, rules: BranchRules?, access: CapabilityState, loading: Bool) -> [MergeRequirement] {
        var out: [MergeRequirement] = []
        let reviews = pr.latestOpinionatedReviews.nodes
        let approvals = reviews.filter { $0.state == "APPROVED" }
        let blockers = reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login }
        let known = access == .supported
        let required = rules?.requiredApprovals ?? 0

        if !blockers.isEmpty {
            out.append(MergeRequirement(kind: .changesRequested, state: .missing, title: "Changes requested", detail: "By " + blockers.joined(separator: ", "), action: .requestReview))
        }

        if required > 0 {
            if approvals.count >= required {
                out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: "\(approvals.count) of \(required) required approvals"))
            } else {
                let more = required - approvals.count
                out.append(MergeRequirement(kind: .approvals, state: .missing, title: "\(approvals.count) of \(required) required approvals",
                                            detail: more == 1 ? "Needs 1 more approval" : "Needs \(more) more approvals", action: .requestReview))
            }
        } else if pr.reviewDecision == "REVIEW_REQUIRED" {
            let detail: String?
            switch access {
            case .supported: detail = nil
            case .unavailable: detail = "The exact number of approvals isn’t visible with your access"
            case .unknown, .unsupported: detail = loading ? nil : "Branch rules couldn’t be read"
            }
            out.append(MergeRequirement(kind: .approvals, state: .missing, title: "Review required", detail: detail, action: .requestReview))
        } else if pr.reviewDecision == "APPROVED" {
            out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: approvals.count == 1 ? "Approved" : "Approved by \(approvals.count) reviewers"))
        } else if known, blockers.isEmpty {
            out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: "No approvals required"))
        } else if loading {
            out.append(MergeRequirement(kind: .approvals, state: .pending, title: "Reading review rules…"))
        }

        if rules?.codeOwnerReview == true {
            let waiting = pr.reviewRequests.nodes.filter { $0.asCodeOwner == true }.compactMap { $0.requestedReviewer?.display }
            if !waiting.isEmpty {
                out.append(MergeRequirement(kind: .codeOwners, state: .missing, title: "Code owner review required", detail: "Waiting for " + waiting.joined(separator: ", "), action: .requestReview))
            } else if pr.reviewDecision == "REVIEW_REQUIRED", approvals.count >= max(required, 1) {
                out.append(MergeRequirement(kind: .codeOwners, state: .missing, title: "Code owner review required", detail: "No code owner has approved yet", action: .requestReview))
            } else if !approvals.isEmpty {
                out.append(MergeRequirement(kind: .codeOwners, state: .satisfied, title: "Code owner review"))
            }
        }

        if rules?.lastPushApproval == true, !approvals.isEmpty {
            if approvals.contains(where: { $0.commit?.oid == pr.headRefOid }) {
                out.append(MergeRequirement(kind: .lastPush, state: .satisfied, title: "Latest push approved"))
            } else {
                out.append(MergeRequirement(kind: .lastPush, state: .missing, title: "Latest push isn’t approved", detail: "Approvals were given before the last commit", action: .requestReview))
            }
        }
        return out
    }

    private static func checkRequirements(_ pr: PullRequestDetail, rules: BranchRules?) -> [MergeRequirement] {
        let b = checks(pr.checks, rules: rules)
        var out: [MergeRequirement] = []
        let label = b.requiredKnown ? "required check" : "check"
        let failed = b.failedRequired
        let running = b.runningRequired
        if !failed.isEmpty {
            out.append(MergeRequirement(kind: .checks, state: .missing, title: count(failed.count, label) + " failed",
                                        detail: names(failed.map(\.title)), action: .showChecks))
        } else if !running.isEmpty || !b.notStarted.isEmpty {
            var parts: [String] = []
            if !running.isEmpty { parts.append("Running: " + names(running.map(\.title))) }
            if !b.notStarted.isEmpty { parts.append("Not started: " + names(b.notStarted)) }
            out.append(MergeRequirement(kind: .checks, state: .pending, title: "Waiting for " + count(running.count + b.notStarted.count, label),
                                        detail: parts.joined(separator: " · "), action: .showChecks))
        } else if !b.required.isEmpty {
            out.append(MergeRequirement(kind: .checks, state: .satisfied, title: b.required.count == 1 ? "1 \(label) passed" : "All \(b.required.count) \(label)s passed", action: .showChecks))
        } else if b.requiredKnown {
            out.append(MergeRequirement(kind: .checks, state: .satisfied, title: "No required checks"))
        }
        if b.requiredKnown, !b.failedOptional.isEmpty {
            out.append(MergeRequirement(kind: .optionalChecks, state: .advisory, title: count(b.failedOptional.count, "optional check") + " failed",
                                        detail: "Doesn’t block merging", action: .showChecks))
        }
        return out
    }

    private static func conversationRequirement(_ pr: PullRequestDetail, rules: BranchRules?, loading: Bool) -> MergeRequirement? {
        let open = pr.reviewThreads.nodes.filter { !$0.isResolved }.count
        let title = open == 1 ? "1 unresolved conversation" : "\(open) unresolved conversations"
        if rules?.threadResolution == true {
            if open == 0 { return MergeRequirement(kind: .conversations, state: .satisfied, title: "All conversations resolved") }
            return MergeRequirement(kind: .conversations, state: .missing, title: title, detail: "Branch rules require resolving them", action: .showConversation)
        }
        guard open > 0 else { return nil }
        let detail = rules?.reviewRulesKnown == true ? "Not required to merge" : loading ? nil : "May not block merging"
        return MergeRequirement(kind: .conversations, state: .advisory, title: title, detail: detail, action: .showConversation)
    }

    static func bitbucket(_ pr: PullRequestDetail, merge: ForgeMergeInfo) -> [MergeRequirement] {
        var out: [MergeRequirement] = []
        if pr.isDraft {
            out.append(MergeRequirement(kind: .draft, state: .missing, title: "Draft pull request", detail: "Mark it ready for review before merging", action: .readyForReview))
        }
        if pr.mergeable == "CONFLICTING" {
            out.append(MergeRequirement(kind: .conflicts, state: .missing, title: "Conflicts with \(pr.baseRefName)", detail: "Resolve them before merging"))
        } else {
            out.append(MergeRequirement(kind: .conflicts, state: .satisfied, title: "No conflicts with \(pr.baseRefName)"))
        }
        let reviews = pr.latestOpinionatedReviews.nodes
        let blockers = reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login }
        let approvals = reviews.filter { $0.state == "APPROVED" }.count
        if !blockers.isEmpty {
            out.append(MergeRequirement(kind: .changesRequested, state: .advisory, title: "Changes requested", detail: "By " + blockers.joined(separator: ", ")))
        }
        if approvals > 0 {
            out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: approvals == 1 ? "Approved" : "Approved by \(approvals) reviewers"))
        } else {
            out.append(MergeRequirement(kind: .approvals, state: .advisory, title: "No approvals yet", detail: "Branch restrictions may require them"))
        }
        let failed = pr.checks.filter { $0.outcome == .failure }
        let running = pr.checks.filter { $0.outcome == .pending }
        if !failed.isEmpty {
            out.append(MergeRequirement(kind: .checks, state: .advisory, title: count(failed.count, "build") + " failed", detail: names(failed.map(\.title)), action: .showChecks))
        } else if !running.isEmpty {
            out.append(MergeRequirement(kind: .checks, state: .pending, title: "Waiting for " + count(running.count, "build"), detail: names(running.map(\.title)), action: .showChecks))
        } else if !pr.checks.isEmpty {
            out.append(MergeRequirement(kind: .checks, state: .satisfied, title: pr.checks.count == 1 ? "1 build passed" : "All \(pr.checks.count) builds passed", action: .showChecks))
        }
        if let tasks = merge.openTasks, tasks > 0 {
            out.append(MergeRequirement(kind: .conversations, state: .advisory, title: count(tasks, "open task"), detail: "Merge checks may require resolving them", action: .showConversation))
        }
        out.append(MergeRequirement(kind: .otherRules, state: .unknown, title: "Merge checks aren’t visible", detail: "Bitbucket rejects the merge if a required check fails"))
        return out
    }

    static func gitlab(_ pr: PullRequestDetail, merge: ForgeMergeInfo) -> [MergeRequirement] {
        var out: [MergeRequirement] = []
        if pr.isDraft {
            out.append(MergeRequirement(kind: .draft, state: .missing, title: "Draft merge request", detail: "Mark it as ready before merging", action: .readyForReview))
        }
        switch merge.status {
        case "conflict", "broken_status":
            out.append(MergeRequirement(kind: .conflicts, state: .missing, title: "Conflicts with \(pr.baseRefName)", detail: "Resolve them before merging"))
        case "checking", "unchecked", "preparing", "approvals_syncing":
            out.append(MergeRequirement(kind: .conflicts, state: .pending, title: "Checking for conflicts…"))
        default:
            out.append(MergeRequirement(kind: .conflicts, state: .satisfied, title: "No conflicts with \(pr.baseRefName)"))
        }
        if merge.status == "need_rebase" {
            out.append(MergeRequirement(kind: .behind, state: .missing, title: "Needs a rebase onto \(pr.baseRefName)", detail: "The project allows only fast-forward merges", action: .updateBranch))
        }

        let approvers = pr.latestOpinionatedReviews.nodes.filter { $0.state == "APPROVED" }.count
        if merge.status == "requested_changes" {
            out.append(MergeRequirement(kind: .changesRequested, state: .missing, title: "Changes requested", detail: "A reviewer asked for changes"))
        }
        if let required = merge.approvalsRequired, required > 0 {
            let left = merge.approvalsLeft ?? max(required - approvers, 0)
            let given = max(required - left, 0)
            if left == 0 {
                out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: "\(given) of \(required) required approvals"))
            } else {
                out.append(MergeRequirement(kind: .approvals, state: .missing, title: "\(given) of \(required) required approvals",
                                            detail: left == 1 ? "Needs 1 more approval" : "Needs \(left) more approvals"))
            }
        } else if merge.status == "not_approved" {
            out.append(MergeRequirement(kind: .approvals, state: .missing, title: "Approval required", detail: merge.approvalsLeft.map { $0 == 1 ? "Needs 1 more approval" : "Needs \($0) more approvals" }))
        } else if merge.approvalsRequired != nil {
            out.append(MergeRequirement(kind: .approvals, state: .satisfied, title: approvers > 0 ? (approvers == 1 ? "Approved" : "Approved by \(approvers) reviewers") : "No approvals required"))
        }

        let failed = pr.checks.filter { $0.outcome == .failure }
        let running = pr.checks.filter { $0.outcome == .pending }
        switch merge.status {
        case "ci_must_pass", "ci_still_running":
            if !failed.isEmpty {
                out.append(MergeRequirement(kind: .checks, state: .missing, title: count(failed.count, "job") + " failed", detail: "The pipeline must succeed", action: .showChecks))
            } else if pr.checks.isEmpty, merge.status == "ci_must_pass" {
                out.append(MergeRequirement(kind: .checks, state: .missing, title: "A pipeline must run and succeed", action: .showChecks))
            } else {
                out.append(MergeRequirement(kind: .checks, state: .pending, title: "Pipeline is still running",
                                            detail: running.isEmpty ? nil : "Running: " + names(running.map(\.title)), action: .showChecks))
            }
        default:
            if !failed.isEmpty {
                out.append(MergeRequirement(kind: .checks, state: .advisory, title: count(failed.count, "job") + " failed", detail: "Doesn’t block merging", action: .showChecks))
            } else if !running.isEmpty {
                out.append(MergeRequirement(kind: .checks, state: .pending, title: "Pipeline is running", detail: "Running: " + names(running.map(\.title)), action: .showChecks))
            } else if !pr.checks.isEmpty {
                out.append(MergeRequirement(kind: .checks, state: .satisfied, title: "Pipeline passed", action: .showChecks))
            }
        }

        let open = pr.reviewThreads.nodes.filter { !$0.isResolved }.count
        let threads = open == 1 ? "1 unresolved thread" : "\(open) unresolved threads"
        if merge.status == "discussions_not_resolved" {
            out.append(MergeRequirement(kind: .conversations, state: .missing, title: open > 0 ? threads : "All threads must be resolved", detail: "The project requires resolving them", action: .showConversation))
        } else if open > 0 {
            out.append(MergeRequirement(kind: .conversations, state: .advisory, title: threads, detail: "Not required to merge", action: .showConversation))
        }

        if let entry = pr.mergeQueueEntry {
            out.append(MergeRequirement(kind: .mergeQueue, state: .pending, title: entry.summary.replacingOccurrences(of: "Merge queue", with: "Merge train").replacingOccurrences(of: "Queued to merge", with: "In the merge train")))
        } else if pr.isMergeQueueEnabled == true {
            out.append(MergeRequirement(kind: .mergeQueue, state: .advisory, title: "Merges through a merge train", detail: "Merging starts or joins the train"))
        }

        let covered: Set<String> = ["mergeable", "conflict", "broken_status", "need_rebase", "checking", "unchecked", "preparing", "approvals_syncing",
                                    "draft_status", "not_open", "not_approved", "requested_changes", "ci_must_pass", "ci_still_running", "discussions_not_resolved"]
        if !covered.contains(merge.status) {
            out.append(MergeRequirement(kind: .otherRules, state: .missing, title: pr.mergeBlocker ?? "Blocked by a project rule", detail: "Reported by GitLab"))
        }
        return out
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    private static func names(_ list: [String]) -> String {
        list.count > 4 ? list.prefix(4).joined(separator: ", ") + " +\(list.count - 4)" : list.joined(separator: ", ")
    }
}
