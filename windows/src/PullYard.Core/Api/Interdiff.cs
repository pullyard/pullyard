namespace PullYard.Core.Api;

public enum DiffScope { All, SinceReview }

public sealed record ReviewedCommit(string Oid, DateTimeOffset? Date, int? CommitsSince)
{
    public bool Rewritten => CommitsSince is null;
}

public sealed class CompareResult
{
    public string? Status { get; set; }
    public int? AheadBy { get; set; }
    public int? BehindBy { get; set; }
    public List<PRFile>? Files { get; set; }
}

public static class Interdiff
{
    public static ReviewedCommit? LastReviewed(PullRequestDetail pr, string viewer)
    {
        if (string.IsNullOrEmpty(viewer)) return null;
        string? bestOid = null;
        DateTimeOffset? bestDate = null;
        foreach (var item in pr.TimelineItems.Items)
        {
            if (item.Typename != "PullRequestReview" || item.State == "PENDING") continue;
            if (!string.Equals(item.Author?.Login, viewer, StringComparison.OrdinalIgnoreCase) || item.Commit?.Oid is not { } oid) continue;
            if (bestOid is null || (item.CreatedAt ?? DateTimeOffset.MinValue) >= (bestDate ?? DateTimeOffset.MinValue))
            {
                bestOid = oid;
                bestDate = item.CreatedAt;
            }
        }
        foreach (var r in pr.LatestOpinionatedReviews.Items)
        {
            if (!string.Equals(r.Author?.Login, viewer, StringComparison.OrdinalIgnoreCase) || r.Commit?.Oid is not { Length: > 0 } oid) continue;
            if (bestOid is null || (r.SubmittedAt ?? DateTimeOffset.MinValue) > (bestDate ?? DateTimeOffset.MinValue))
            {
                bestOid = oid;
                bestDate = r.SubmittedAt;
            }
        }
        if (bestOid is null || bestOid == pr.HeadRefOid) return null;
        var oids = pr.AllCommits.Items.Select(c => c.Commit.Oid).ToList();
        var idx = oids.LastIndexOf(bestOid);
        return new ReviewedCommit(bestOid, bestDate, idx >= 0 ? oids.Count - 1 - idx : null);
    }
}
