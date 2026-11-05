import Foundation
import StackNotesKit

enum PRContextPublisher {
    static func snapshot(ref: ItemRef, pr: PullRequestDetail, requirements: [MergeRequirement], ownership: OwnershipSummary?, files: [String], reviewed: ReviewedCommit?) -> PRContextSnapshot {
        let status = pr.isOpen ? MergeStatusBar.status(pr, requirements: requirements).text : (pr.merged ? "Merged" : pr.state.capitalized)
        return PRContextSnapshot(
            repo: ref.repo.full,
            number: pr.number,
            title: pr.title,
            url: pr.url,
            state: pr.state,
            isDraft: pr.isDraft,
            author: pr.author?.login,
            baseRef: pr.baseRefName,
            headRef: pr.headRefName,
            headOid: pr.headRefOid,
            body: pr.body,
            mergeStatus: status,
            requirements: requirements.map { .init(state: label($0.state), title: $0.title, detail: $0.detail) },
            checks: pr.checks.map { c in .init(name: c.workflowName.map { "\($0) / \(c.title)" } ?? c.title, outcome: outcome(c.outcome), required: c.isRequired, url: c.link) },
            reviews: pr.latestOpinionatedReviews.nodes.compactMap { r in r.author.map { .init(login: $0.login, state: r.state) } }
                + pr.reviewRequests.nodes.compactMap { $0.requestedReviewer.map { .init(login: $0.display, state: "REVIEW_REQUESTED") } },
            threads: pr.reviewThreads.nodes.map { t in
                .init(path: t.path, line: t.line ?? t.originalLine, resolved: t.isResolved, outdated: t.isOutdated,
                      comments: t.comments.nodes.map { .init(author: $0.author?.login ?? "ghost", body: $0.body) })
            },
            files: files,
            codeOwners: ownership.map { $0.groups.map { .init(owners: $0.owners.map { "@" + $0.handle }, files: $0.files) } },
            unownedFiles: ownership?.unowned,
            reviewedOid: reviewed?.oid,
            commitsSinceReview: reviewed?.commitsSince
        )
    }

    private static func label(_ s: RequirementState) -> String {
        switch s {
        case .satisfied: return "met"
        case .missing: return "blocking"
        case .pending: return "in progress"
        case .unknown: return "unknown"
        case .advisory: return "does not block"
        }
    }

    private static func outcome(_ o: CheckOutcome) -> String {
        switch o {
        case .failure: return "failure"
        case .pending: return "pending"
        case .neutral: return "neutral"
        case .skipped: return "skipped"
        case .success: return "success"
        }
    }
}
