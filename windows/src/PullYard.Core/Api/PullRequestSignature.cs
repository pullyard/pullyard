namespace PullYard.Core.Api;

public static class PullRequestSignature
{
    public static string Of(PullRequestDetail pr)
    {
        var commit = pr.LastCommit.Items.FirstOrDefault()?.Commit;
        var checks = (commit?.StatusCheckRollup?.Contexts?.Items ?? new())
            .Select(c => $"{c.Typename}:{c.DatabaseId}:{c.Name}:{c.Context}:{c.Status}:{c.Conclusion}:{c.State}:{c.CompletedAt?.ToUniversalTime():O}")
            .OrderBy(s => s, StringComparer.Ordinal);
        var threads = pr.ReviewThreads.Items;
        var edits = (pr.EditedComments?.Items ?? new())
            .Concat(pr.EditedReviews?.Items ?? new())
            .Concat(threads.SelectMany(t => t.EditedComments?.Items ?? new()))
            .Select(e => e.LastEditedAt)
            .Where(d => d is not null)
            .DefaultIfEmpty()
            .Max();
        return string.Join("|",
            pr.UpdatedAt?.ToUniversalTime().ToString("O"),
            pr.HeadRefOid,
            commit?.Oid,
            pr.State,
            pr.IsDraft,
            pr.Mergeable,
            pr.MergeStateStatus,
            pr.ReviewDecision,
            pr.Comments?.TotalCount,
            pr.Reviews?.TotalCount,
            pr.TimelineItems.TotalCount,
            pr.AllCommits.TotalCount,
            $"{threads.Count}/{threads.Count(t => t.IsResolved)}",
            edits?.ToUniversalTime().ToString("O"),
            commit?.StatusCheckRollup?.State,
            string.Join(",", checks));
    }

    public static string Threads(IEnumerable<ReviewThread> threads)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var t in threads)
        {
            sb.Append(t.Id).Append('|').Append(t.IsResolved).Append('|').Append(t.IsOutdated).Append('|').Append(t.Path).Append('|').Append(t.DiffSide).Append('|').Append(t.Line).Append('\n');
            foreach (var c in t.Comments.Items) sb.Append(c.Id).Append('|').Append(c.Body).Append('\n');
        }
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(sb.ToString())));
    }

    public static int Hidden(int? total, int loaded) => total is { } t ? Math.Max(t - loaded, 0) : 0;
}
