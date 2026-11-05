import Foundation

enum DiffScope: Equatable {
    case all, sinceReview
}

struct ReviewedCommit: Equatable {
    let oid: String
    let date: Date?
    let commitsSince: Int?

    var rewritten: Bool { commitsSince == nil }
}

struct CompareResult: Decodable {
    let status: String?
    let aheadBy: Int?
    let behindBy: Int?
    let files: [PRFile]?
}

enum Interdiff {
    static func lastReviewed(_ pr: PullRequestDetail, viewer: String) -> ReviewedCommit? {
        guard !viewer.isEmpty else { return nil }
        let me = viewer.lowercased()
        var best: (oid: String, date: Date?)?
        for item in pr.timelineItems.nodes where item.typename == "PullRequestReview" && item.state != "PENDING" {
            guard item.author?.login.lowercased() == me, let oid = item.commit?.oid else { continue }
            if best == nil || (item.createdAt ?? .distantPast) >= (best?.date ?? .distantPast) { best = (oid, item.createdAt) }
        }
        for r in pr.latestOpinionatedReviews.nodes where r.author?.login.lowercased() == me {
            guard let oid = r.commit?.oid else { continue }
            if best == nil || (r.submittedAt ?? .distantPast) > (best?.date ?? .distantPast) { best = (oid, r.submittedAt) }
        }
        guard let best, best.oid != pr.headRefOid else { return nil }
        let oids = pr.allCommits.nodes.map(\.commit.oid)
        let since = oids.lastIndex(of: best.oid).map { oids.count - 1 - $0 }
        return ReviewedCommit(oid: best.oid, date: best.date, commitsSince: since)
    }
}
