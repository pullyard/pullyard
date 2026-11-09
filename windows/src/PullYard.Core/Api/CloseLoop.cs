namespace PullYard.Core.Api;

public sealed record ReviewFixLaunch(IReadOnlyList<string> ThreadIds, string HeadOid, DateTimeOffset At);

public sealed record CloseLoopPending(IReadOnlyList<string> Threads, int NewCommits);

public static class CloseLoop
{
    public static CloseLoopPending? Pending(ReviewFixLaunch? launch, PullRequestDetail pr)
    {
        if (launch is null || !pr.IsOpen || string.IsNullOrEmpty(pr.HeadRefOid) || pr.HeadRefOid == launch.HeadOid) return null;
        var open = pr.ReviewThreads.Items.Where(t => !t.IsResolved).Select(t => t.Id).ToHashSet();
        var threads = launch.ThreadIds.Where(open.Contains).ToList();
        if (threads.Count == 0) return null;
        var oids = pr.AllCommits.Items.Select(c => c.Commit.Oid).ToList();
        var idx = oids.IndexOf(launch.HeadOid);
        var newCommits = idx >= 0 ? oids.Count - idx - 1 : 1;
        return new CloseLoopPending(threads, Math.Max(newCommits, 1));
    }

    public static string DefaultReply(string head) =>
        string.IsNullOrEmpty(head) ? "Fixed." : $"Fixed in {(head.Length > 7 ? head[..7] : head)}.";

    public static List<ReviewThread> Replyable(PullRequestDetail pr) =>
        pr.ReviewThreads.Items.Where(t => !t.IsResolved && t.ViewerCanReply).ToList();

    public static async Task<Dictionary<string, string>> Run(IPRBackend backend, ItemRef r, IEnumerable<ReviewThread> threads, string body, bool resolve)
    {
        var failures = new Dictionary<string, string>();
        foreach (var t in threads)
        {
            try
            {
                await backend.Reply(r, t.Id, body).ConfigureAwait(false);
                if (resolve && t.ViewerCanResolve) await backend.SetResolved(r, t.Id, true).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                failures[t.Id] = e.Message;
            }
        }
        return failures;
    }
}
