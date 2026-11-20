using PullYard.Core.Api;
using Xunit;

namespace PullYard.Core.Tests;

public class CloseLoopTests
{
    private sealed class RecordingBackend : IPRBackend
    {
        public PRFeatures Features => PRFeatures.GitHub;
        public List<string> Calls { get; } = new();
        public HashSet<string> FailReply { get; set; } = new();

        public Task<PRLoad> Load(ItemRef r, CancellationToken ct = default) => throw new InvalidOperationException("offline");
        public Task<string?> Pulse(ItemRef r, CancellationToken ct = default) => Task.FromResult<string?>(null);
        public Task<List<PRFile>> Files(ItemRef r, PullRequestDetail pr, CancellationToken ct = default) => Task.FromResult(new List<PRFile>());
        public Task Comment(ItemRef r, PullRequestDetail pr, string body) => Task.CompletedTask;
        public Task SubmitReview(ItemRef r, PullRequestDetail pr, string @event, string body, IReadOnlyList<PendingComment> comments, IReadOnlyList<DiffFile> files) => Task.CompletedTask;

        public async Task Reply(ItemRef r, string thread, string body)
        {
            await Task.Yield();
            if (FailReply.Contains(thread)) throw new InvalidOperationException("Thread is locked");
            Calls.Add($"reply {thread}: {body}");
        }

        public Task SetResolved(ItemRef r, string thread, bool resolved)
        {
            Calls.Add($"resolve {thread} {resolved.ToString().ToLowerInvariant()}");
            return Task.CompletedTask;
        }

        public Task<string?> Merge(ItemRef r, PullRequestDetail pr, string method, string? title, string? body, bool deleteBranch) => Task.FromResult<string?>(null);
        public Task EnableAutoMerge(ItemRef r, PullRequestDetail pr, string method) => Task.CompletedTask;
        public Task Perform(PRAction action, ItemRef r, PullRequestDetail pr) => Task.CompletedTask;
        public Task Edit(ItemRef r, PullRequestDetail pr, string title, string body) => Task.CompletedTask;
        public Task<CommitDetailRest> Commit(RepoRef repo, string sha) => Task.FromResult(new CommitDetailRest());
    }

    private static ReviewThread Thread(string id, bool resolved = false, bool canResolve = true) => new()
    {
        Id = id,
        IsResolved = resolved,
        Path = "a.cs",
        Line = 3,
        ViewerCanResolve = canResolve,
        ViewerCanReply = true
    };

    private static PullRequestDetail Pr(string head, string[] commits, ReviewThread[] threads, string state = "OPEN") => new()
    {
        Id = "PR_1",
        Number = 7,
        State = state,
        HeadRefOid = head,
        AllCommits = new Nodes<CommitInfoNode> { Items = commits.Select(c => new CommitInfoNode { Commit = new CommitInfo { Oid = c } }).ToList(), TotalCount = commits.Length },
        ReviewThreads = new Nodes<ReviewThread> { Items = threads.ToList() }
    };

    [Fact]
    public void PendingNeedsNewCommitsAndOpenThreads()
    {
        var launch = new ReviewFixLaunch(new[] { "t1", "t2", "t3" }, "c1", DateTimeOffset.Now);
        Assert.Null(CloseLoop.Pending(launch, Pr("c1", new[] { "c0", "c1" }, new[] { Thread("t1") })));

        var pushed = Pr("c3", new[] { "c0", "c1", "c2", "c3" }, new[] { Thread("t1"), Thread("t2", resolved: true), Thread("t9") });
        var pending = CloseLoop.Pending(launch, pushed);
        Assert.NotNull(pending);
        Assert.Equal(new[] { "t1" }, pending!.Threads);
        Assert.Equal(2, pending.NewCommits);

        Assert.Equal(1, CloseLoop.Pending(launch, Pr("x9", new[] { "x8", "x9" }, new[] { Thread("t3") }))?.NewCommits);
        Assert.Null(CloseLoop.Pending(launch, Pr("c3", new[] { "c1", "c3" }, new[] { Thread("t1", resolved: true) })));
        Assert.Null(CloseLoop.Pending(launch, Pr("c3", new[] { "c1", "c3" }, new[] { Thread("t1") }, state: "MERGED")));
        Assert.Null(CloseLoop.Pending(null, pushed));
    }

    [Fact]
    public void DefaultReply()
    {
        Assert.Equal("Fixed in abcdef1.", CloseLoop.DefaultReply("abcdef123456"));
        Assert.Equal("Fixed.", CloseLoop.DefaultReply(""));
    }

    [Fact]
    public void ReplyableSkipsResolvedAndReadOnlyThreads()
    {
        var readOnly = Thread("t3");
        readOnly.ViewerCanReply = false;
        var pr = Pr("c1", new[] { "c1" }, new[] { Thread("t1"), Thread("t2", resolved: true), readOnly });
        Assert.Equal(new[] { "t1" }, CloseLoop.Replyable(pr).Select(t => t.Id));
    }

    [Fact]
    public async Task RunRepliesResolvesAndReportsFailures()
    {
        var backend = new RecordingBackend { FailReply = new() { "t2" } };
        var r = new ItemRef(new RepoRef("o", "r"), 7);
        var pr = Pr("c3", new[] { "c3" }, new[] { Thread("t1"), Thread("t2"), Thread("t3", canResolve: false) });
        var failures = await CloseLoop.Run(backend, r, pr.ReviewThreads.Items, "Fixed in c3.", resolve: true);
        Assert.Equal(new Dictionary<string, string> { ["t2"] = "Thread is locked" }, failures);
        Assert.Equal(new[] { "reply t1: Fixed in c3.", "resolve t1 true", "reply t3: Fixed in c3." }, backend.Calls);

        backend.Calls.Clear();
        await CloseLoop.Run(backend, r, new[] { pr.ReviewThreads.Items[0] }, "Thanks", resolve: false);
        Assert.Equal(new[] { "reply t1: Thanks" }, backend.Calls);
    }
}
