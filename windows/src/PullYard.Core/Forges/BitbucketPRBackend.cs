using System.Globalization;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Html;

namespace PullYard.Core.Forges;

public sealed record BitbucketPRSnapshot(
    string Repo,
    BitbucketPR.Detail Pr,
    List<BitbucketPR.Comment> Comments,
    List<BitbucketPR.CommitInfo> Commits,
    List<BitbucketPR.Status> Statuses,
    List<BitbucketPR.DiffStat> DiffStat,
    string Viewer);

public static class BitbucketReviewMapper
{
    public static readonly IReadOnlySet<string> ConflictStatuses = new HashSet<string>
    {
        "merge conflict", "local deleted", "remote deleted", "local and remote deleted", "rename conflict", "rename/delete conflict", "subrepo conflict"
    };

    public static string State(string raw) => raw switch
    {
        "MERGED" => "MERGED",
        "OPEN" => "OPEN",
        _ => "CLOSED"
    };

    public static PRRepository Repository(BitbucketPRSnapshot s) => new()
    {
        ViewerPermission = "WRITE",
        MergeCommitAllowed = true,
        SquashMergeAllowed = true,
        RebaseMergeAllowed = false,
        DeleteBranchOnMerge = s.Pr.CloseSourceBranch ?? false,
        AutoMergeAllowed = false,
        ViewerDefaultMergeMethod = "MERGE",
        PullRequest = Detail(s)
    };

    public static string? AuthorName(BitbucketPR.CommitAuthor? author)
    {
        if (author?.User?.DisplayName is { } name) return name;
        if (author?.Raw is not { } raw) return null;
        var cut = raw.IndexOf(" <", StringComparison.Ordinal);
        return cut >= 0 ? raw[..cut] : raw;
    }

    public static string Pulse(BitbucketPR.Detail pr)
    {
        var people = string.Join(",", (pr.Participants ?? new())
            .Select(p => (p.User?.Uuid ?? "") + ":" + (p.State ?? (p.Approved == true ? "approved" : "")))
            .OrderBy(x => x, StringComparer.Ordinal));
        return string.Join("|",
            pr.UpdatedOn.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            pr.State,
            pr.Draft ?? false,
            pr.Source?.Commit?.Hash ?? "",
            (pr.CommentCount ?? 0).ToString(CultureInfo.InvariantCulture),
            (pr.TaskCount ?? 0).ToString(CultureInfo.InvariantCulture),
            people);
    }

    public static List<CheckContext> Checks(IEnumerable<BitbucketPR.Status> statuses) => statuses.Select((s, index) =>
    {
        var (status, conclusion) = s.State switch
        {
            "INPROGRESS" => ("IN_PROGRESS", (string?)null),
            "SUCCESSFUL" => ("COMPLETED", "SUCCESS"),
            "FAILED" => ("COMPLETED", "FAILURE"),
            "STOPPED" => ("COMPLETED", "CANCELLED"),
            _ => ("QUEUED", null)
        };
        return new CheckContext
        {
            Typename = "BitbucketStatus",
            DatabaseId = index + 1,
            Name = s.Name ?? s.Key ?? "Build",
            Status = status,
            Conclusion = conclusion,
            DetailsUrl = s.Url,
            StartedAt = s.CreatedOn,
            CompletedAt = conclusion is null ? null : s.UpdatedOn,
            Description = s.Description
        };
    }).ToList();

    public static string? RollupState(IReadOnlyCollection<BitbucketPR.Status> statuses)
    {
        if (statuses.Count == 0) return null;
        if (statuses.Any(s => s.State == "FAILED")) return "FAILURE";
        if (statuses.Any(s => s.State == "INPROGRESS")) return "PENDING";
        if (statuses.Any(s => s.State == "STOPPED")) return "ERROR";
        return "SUCCESS";
    }

    public static (List<TimelineItem> Timeline, List<ReviewThread> Threads) Conversation(IEnumerable<BitbucketPR.Comment> comments, string baseUrl, IReadOnlySet<string> headPaths)
    {
        var visible = comments.Where(c => c.Deleted != true && c.Pending != true).ToList();
        var ids = visible.Select(c => c.Id).ToHashSet();
        var children = new Dictionary<int, List<BitbucketPR.Comment>>();
        var roots = new List<BitbucketPR.Comment>();
        foreach (var c in visible)
        {
            if (c.Parent?.Id is { } parent && ids.Contains(parent))
            {
                if (!children.TryGetValue(parent, out var list)) children[parent] = list = new();
                list.Add(c);
            }
            else roots.Add(c);
        }
        IEnumerable<BitbucketPR.Comment> Descendants(int id) =>
            (children.TryGetValue(id, out var direct) ? direct : new()).OrderBy(c => c.CreatedOn).SelectMany(c => new[] { c }.Concat(Descendants(c.Id)));

        var timeline = new List<TimelineItem>();
        var threads = new List<ReviewThread>();
        foreach (var root in roots.OrderBy(c => c.CreatedOn))
        {
            var replies = Descendants(root.Id).ToList();
            if (root.Inline is null && replies.Count == 0)
            {
                timeline.Add(Item("IssueComment", $"bb-c-{root.Id}", root.User?.Actor, root.Content?.Raw, Html(root, baseUrl), root.CreatedOn));
                continue;
            }
            var review = $"bb-t-{root.Id}";
            var inline = root.Inline;
            var line = inline?.To ?? inline?.From;
            var outdated = inline?.Outdated == true || (inline?.Path is { } path && headPaths.Count > 0 && !headPaths.Contains(path));
            var resolved = root.Resolution is not null;
            threads.Add(new ReviewThread
            {
                Id = root.Id.ToString(CultureInfo.InvariantCulture),
                IsResolved = resolved,
                IsOutdated = outdated,
                Path = inline?.Path ?? "",
                Line = outdated ? null : line,
                OriginalLine = line,
                DiffSide = inline?.To is null && inline?.From is not null ? "LEFT" : "RIGHT",
                ViewerCanResolve = !resolved,
                ViewerCanUnresolve = resolved,
                ViewerCanReply = true,
                Comments = new Nodes<ThreadComment>
                {
                    Items = new[] { root }.Concat(replies).Select(c => new ThreadComment
                    {
                        Id = c.Id.ToString(CultureInfo.InvariantCulture),
                        Author = c.User?.Actor,
                        Body = c.Content?.Raw ?? "",
                        BodyHTML = Html(c, baseUrl),
                        CreatedAt = c.CreatedOn,
                        PullRequestReview = new IdOnly { Id = review }
                    }).ToList()
                }
            });
            timeline.Add(Item("PullRequestReview", review, root.User?.Actor, null, null, root.CreatedOn, "DISCUSSION"));
        }
        return (timeline, threads);
    }

    private static string Html(BitbucketPR.Comment c, string baseUrl) =>
        c.Content?.Html is { Length: > 0 } h ? MarkdownHtml.AbsolutizeHtml(h, baseUrl) : MarkdownHtml.Render(c.Content?.Raw ?? "", baseUrl);

    private static TimelineItem Item(string type, string id, Actor? author, string? body, string? html, DateTimeOffset date, string? state = null) =>
        new() { Typename = type, Id = id, Author = author, Body = body, BodyHTML = html, CreatedAt = date, State = state };

    public static string? ReviewDecision(BitbucketPR.Detail pr)
    {
        var people = pr.Participants ?? new();
        if (people.Any(p => p.State == "changes_requested")) return "CHANGES_REQUESTED";
        if (people.Any(p => p.Approved == true)) return "APPROVED";
        return null;
    }

    public static PullRequestDetail Detail(BitbucketPRSnapshot s)
    {
        var pr = s.Pr;
        var repoName = pr.Destination?.Repository?.FullName ?? s.Repo;
        var baseUrl = $"https://bitbucket.org/{repoName}";
        var state = State(pr.State);
        var participants = pr.Participants ?? new();
        var conflicted = s.DiffStat.Any(d => ConflictStatuses.Contains(d.Status));
        var failed = s.Statuses.Any(x => x.State == "FAILED");
        var changesRequested = participants.Any(p => p.State == "changes_requested");
        var openTasks = pr.TaskCount ?? 0;
        var mergeState = pr.Draft == true ? "DRAFT"
            : conflicted ? "DIRTY"
            : failed || changesRequested || openTasks > 0 ? "UNSTABLE"
            : "CLEAN";
        var headSha = pr.Source?.Commit?.Hash ?? "";
        var paths = s.DiffStat.Select(d => d.Path).ToHashSet();
        var (timeline, threads) = Conversation(s.Comments, baseUrl, paths);
        var commits = Enumerable.Reverse(s.Commits).Select(c => new CommitInfoNode
        {
            Commit = new CommitInfo
            {
                Oid = c.Hash,
                AbbreviatedOid = c.Hash.Length > 7 ? c.Hash[..7] : c.Hash,
                MessageHeadline = (c.Message ?? "").Split('\n')[0],
                CommittedDate = c.Date ?? pr.CreatedOn,
                Url = c.Links?.Html?.Href ?? $"{baseUrl}/commits/{c.Hash}",
                Author = new GitActor { Name = AuthorName(c.Author), AvatarUrl = c.Author?.User?.Links?.Avatar?.Href }
            }
        }).ToList();
        var contexts = Checks(s.Statuses);
        var rollup = RollupState(s.Statuses) is { } rs ? new StatusRollup { State = rs, Contexts = new Nodes<CheckContext> { Items = contexts, TotalCount = contexts.Count } } : null;
        var me = s.Viewer.ToLowerInvariant();
        var mine = participants.FirstOrDefault(p => p.User?.Uuid?.ToLowerInvariant() == me);
        var isAuthor = me.Length > 0 && pr.Author?.Uuid?.ToLowerInvariant() == me;
        var reviews = participants.Where(p => p.User is not null).Select(p =>
        {
            if (p.Approved == true || p.State == "approved") return new LatestReview { State = "APPROVED", SubmittedAt = p.ParticipatedOn, Author = p.User!.Actor };
            if (p.State == "changes_requested") return new LatestReview { State = "CHANGES_REQUESTED", SubmittedAt = p.ParticipatedOn, Author = p.User!.Actor };
            return null;
        }).OfType<LatestReview>().ToList();
        var decided = reviews.Select(r => r.Author?.Login).OfType<string>().ToHashSet();
        var pending = (pr.Reviewers ?? new()).Where(r => !decided.Contains(r.Login)).ToList();
        string? blocker = conflicted ? null
            : changesRequested ? "Changes requested"
            : failed ? "A build failed"
            : openTasks > 0 ? (openTasks == 1 ? "1 open task" : $"{openTasks} open tasks")
            : null;
        var summaryHtml = pr.Summary?.Html is { Length: > 0 } h ? MarkdownHtml.AbsolutizeHtml(h, baseUrl) : null;
        return new PullRequestDetail
        {
            Id = $"bitbucket-pr-{repoName}-{pr.Id}",
            Number = pr.Id,
            Title = pr.Title,
            Url = pr.Links?.Html?.Href ?? $"{baseUrl}/pull-requests/{pr.Id}",
            State = state,
            IsDraft = pr.Draft ?? false,
            Merged = state == "MERGED",
            Mergeable = conflicted ? "CONFLICTING" : "MERGEABLE",
            MergeStateStatus = mergeState,
            Body = pr.Summary?.Raw ?? "",
            BodyHTML = summaryHtml ?? MarkdownHtml.Render(pr.Summary?.Raw ?? "", baseUrl),
            CreatedAt = pr.CreatedOn,
            UpdatedAt = pr.UpdatedOn,
            Author = pr.Author?.Actor,
            HeadRefName = pr.Source?.Branch?.Name ?? "",
            BaseRefName = pr.Destination?.Branch?.Name ?? "",
            HeadRefOid = headSha,
            BaseRef = pr.Destination?.Commit is { } b ? new RefTip { Target = new ReviewCommit { Oid = b.Hash } } : null,
            HeadRepository = pr.Source?.Repository?.FullName is { } head ? new RepoName { NameWithOwner = head } : null,
            HeadRef = state == "OPEN" && pr.Source?.Branch is { } branch ? new BranchName { Name = branch.Name } : null,
            Additions = s.DiffStat.Sum(d => d.LinesAdded ?? 0),
            Deletions = s.DiffStat.Sum(d => d.LinesRemoved ?? 0),
            ChangedFiles = s.DiffStat.Count,
            ReviewDecision = ReviewDecision(pr),
            ViewerCanUpdate = true,
            ViewerDidAuthor = isAuthor,
            ReviewRequests = new Nodes<ReviewRequest>
            {
                Items = pending.Select(r => new ReviewRequest { RequestedReviewer = new Reviewer { Typename = "User", Login = r.Login, AvatarUrl = r.Links?.Avatar?.Href, Name = r.DisplayName } }).ToList()
            },
            LatestOpinionatedReviews = new Nodes<LatestReview> { Items = reviews },
            LastCommit = new Nodes<LastCommitNode>
            {
                Items = new() { new LastCommitNode { Commit = new LastCommit { Oid = headSha, CommittedDate = commits.LastOrDefault()?.Commit.CommittedDate, StatusCheckRollup = rollup } } }
            },
            AllCommits = new Nodes<CommitInfoNode> { Items = commits, TotalCount = commits.Count },
            TimelineItems = new Nodes<TimelineItem> { Items = timeline },
            ReviewThreads = new Nodes<ReviewThread> { Items = threads },
            ViewerCanApprove = !isAuthor,
            ViewerApproved = mine?.Approved == true,
            MergeBlocker = blocker,
            ForgeMerge = new ForgeMergeInfo { Status = pr.Draft == true ? "draft" : conflicted ? "conflict" : "open", OpenTasks = openTasks, Provider = "bitbucket" }
        };
    }

    public static List<PRFile> Files(IEnumerable<BitbucketPR.DiffStat> stats, string diff)
    {
        var patches = SplitDiff(diff);
        return stats.Select(s =>
        {
            var status = s.Status switch
            {
                "added" => "added",
                "removed" => "removed",
                "renamed" => "renamed",
                _ => "modified"
            };
            var patch = patches.GetValueOrDefault(s.Path) ?? (s.Old is { } old ? patches.GetValueOrDefault(old.Path) : null);
            return new PRFile
            {
                Filename = s.Path,
                Status = status,
                Additions = s.LinesAdded ?? 0,
                Deletions = s.LinesRemoved ?? 0,
                Patch = patch,
                PreviousFilename = s.Status == "renamed" ? s.Old?.Path : null
            };
        }).ToList();
    }

    public static Dictionary<string, string> SplitDiff(string diff)
    {
        var output = new Dictionary<string, string>();
        string? path = null;
        string? oldPath = null;
        var hunk = new List<string>();
        void Flush()
        {
            if ((path ?? oldPath) is { } key && hunk.Count > 0) output[key] = string.Join("\n", hunk).Trim('\r', '\n');
            hunk.Clear();
        }
        foreach (var line in diff.Replace("\r\n", "\n").Split('\n'))
        {
            if (line.StartsWith("diff --git ", StringComparison.Ordinal))
            {
                Flush();
                path = null;
                oldPath = null;
                var cut = line.LastIndexOf(" b/", StringComparison.Ordinal);
                if (cut >= 0) path = line[(cut + 3)..];
                continue;
            }
            if (hunk.Count == 0)
            {
                if (line.StartsWith("+++ ", StringComparison.Ordinal))
                {
                    var p = line[4..];
                    if (p != "/dev/null") path = p.StartsWith("b/", StringComparison.Ordinal) ? p[2..] : p;
                    continue;
                }
                if (line.StartsWith("--- ", StringComparison.Ordinal))
                {
                    var p = line[4..];
                    if (p != "/dev/null") oldPath = p.StartsWith("a/", StringComparison.Ordinal) ? p[2..] : p;
                    continue;
                }
                if (!line.StartsWith("@@", StringComparison.Ordinal)) continue;
            }
            hunk.Add(line);
        }
        Flush();
        return output;
    }

    public static JsonObject Inline(PendingComment comment) => comment.Side == "LEFT"
        ? new JsonObject { ["path"] = comment.Path, ["from"] = comment.Line }
        : new JsonObject { ["path"] = comment.Path, ["to"] = comment.Line };
}

public sealed class BitbucketPRBackend : IPRBackend
{
    private readonly BitbucketClient client;

    public BitbucketPRBackend(BitbucketClient client)
    {
        this.client = client;
    }

    public PRFeatures Features => PRFeatures.Bitbucket;

    internal static async Task<T?> Optional<T>(Task<T> task) where T : class
    {
        try
        {
            return await task.ConfigureAwait(false);
        }
        catch (Exception e) when (e is ApiException or HttpRequestException)
        {
            return null;
        }
    }

    public async Task<PRLoad> Load(ItemRef r, CancellationToken ct = default)
    {
        var repo = r.Repo.Full;
        var prTask = client.PullRequestDetail(repo, r.Number, ct);
        var commentsTask = client.Comments(repo, r.Number, ct);
        var commitsTask = Optional(client.PullCommits(repo, r.Number, ct));
        var statusesTask = Optional(client.Statuses(repo, r.Number, ct));
        var diffstatTask = Optional(client.DiffStat(repo, r.Number, ct));
        var viewerTask = Optional(client.UserId(ct));
        var snapshot = new BitbucketPRSnapshot(
            repo,
            await prTask.ConfigureAwait(false),
            await commentsTask.ConfigureAwait(false),
            await commitsTask.ConfigureAwait(false) ?? new(),
            await statusesTask.ConfigureAwait(false) ?? new(),
            await diffstatTask.ConfigureAwait(false) ?? new(),
            await viewerTask.ConfigureAwait(false) ?? "");
        return new PRLoad(snapshot.Viewer, BitbucketReviewMapper.Repository(snapshot), BitbucketReviewMapper.Pulse(snapshot.Pr));
    }

    public async Task<string?> Pulse(ItemRef r, CancellationToken ct = default) =>
        BitbucketReviewMapper.Pulse(await client.PullRequestDetail(r.Repo.Full, r.Number, ct).ConfigureAwait(false));

    public async Task<List<PRFile>> Files(ItemRef r, PullRequestDetail pr, CancellationToken ct = default)
    {
        var statsTask = client.DiffStat(r.Repo.Full, r.Number, ct);
        var textTask = Optional(client.Diff(r.Repo.Full, r.Number, ct));
        return BitbucketReviewMapper.Files(await statsTask.ConfigureAwait(false), await textTask.ConfigureAwait(false) ?? "");
    }

    public Task Comment(ItemRef r, PullRequestDetail pr, string body) => client.AddComment(r.Repo.Full, r.Number, body);

    public async Task SubmitReview(ItemRef r, PullRequestDetail pr, string @event, string body, IReadOnlyList<PendingComment> comments, IReadOnlyList<DiffFile> files)
    {
        var repo = r.Repo.Full;
        foreach (var c in comments)
            await client.AddComment(repo, r.Number, c.Body, BitbucketReviewMapper.Inline(c)).ConfigureAwait(false);
        var text = body.Trim();
        if (text.Length > 0) await client.AddComment(repo, r.Number, text).ConfigureAwait(false);
        if (@event == "APPROVE") await client.Approve(repo, r.Number, true).ConfigureAwait(false);
        else if (@event == "REQUEST_CHANGES") await client.RequestChanges(repo, r.Number, true).ConfigureAwait(false);
    }

    private static int CommentId(string thread) =>
        int.TryParse(thread, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : throw new ApiException("Unknown comment thread");

    public Task Reply(ItemRef r, string thread, string body) => client.AddComment(r.Repo.Full, r.Number, body, parent: CommentId(thread));

    public Task SetResolved(ItemRef r, string thread, bool resolved) => client.SetResolved(r.Repo.Full, r.Number, CommentId(thread), resolved);

    public async Task<string?> Merge(ItemRef r, PullRequestDetail pr, string method, string? title, string? body, bool deleteBranch)
    {
        string? message = title is null && body is null ? null : string.Join("\n\n", new[] { title ?? pr.Title, body }.OfType<string>());
        await client.Merge(r.Repo.Full, r.Number, method == "SQUASH" ? "squash" : "merge_commit", message, deleteBranch).ConfigureAwait(false);
        return null;
    }

    public Task EnableAutoMerge(ItemRef r, PullRequestDetail pr, string method) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));

    public Task Perform(PRAction action, ItemRef r, PullRequestDetail pr)
    {
        var repo = r.Repo.Full;
        return action switch
        {
            PRAction.Close => client.Decline(repo, r.Number),
            PRAction.ReadyForReview => client.UpdatePull(repo, r.Number, new JsonObject { ["draft"] = false }),
            PRAction.ConvertToDraft => client.UpdatePull(repo, r.Number, new JsonObject { ["draft"] = true }),
            _ => Task.FromException(new PRBackendUnsupportedException(Features.Provider))
        };
    }

    public Task Edit(ItemRef r, PullRequestDetail pr, string title, string body) =>
        client.UpdatePull(r.Repo.Full, r.Number, new JsonObject { ["title"] = title, ["description"] = body });

    public Task<CommitDetailRest> Commit(RepoRef repo, string sha) => client.Commit(repo.Full, sha);

    public Task RevokeApproval(ItemRef r, PullRequestDetail pr) => client.Approve(r.Repo.Full, r.Number, false);

    public async Task<CodeOwners?> CodeOwners(ItemRef r, string @base, CancellationToken ct = default)
    {
        foreach (var path in Api.CodeOwners.BitbucketPaths)
        {
            if (await client.SourceFile(r.Repo.Full, @base, path, ct).ConfigureAwait(false) is { } text)
                return new CodeOwners(text, path);
        }
        return null;
    }

    public bool CanShowLog(CheckContext check) => check.Outcome != CheckOutcome.Pending && BitbucketClient.BuildNumber(check.Link) is not null;

    public async Task<string> JobLog(ItemRef r, CheckContext check, CancellationToken ct = default)
    {
        if (BitbucketClient.BuildNumber(check.Link) is not { } build)
            throw new ApiException("Only Bitbucket Pipelines builds have a log here. Open this build in the browser.");
        var repo = r.Repo.Full;
        var pipeline = await client.Pipeline(repo, build, ct).ConfigureAwait(false);
        var steps = await client.PipelineSteps(repo, pipeline.Uuid, ct).ConfigureAwait(false);
        if (steps.Count == 0) return $"Pipeline #{build} has no steps.";
        var parts = new List<string>();
        foreach (var step in steps)
        {
            var result = step.State?.Result?.Name ?? step.State?.Name ?? "";
            var header = $"=== {step.Name ?? "Step"}" + (result.Length == 0 ? "" : $" ({result.ToLowerInvariant()})") + " ===";
            string text;
            try
            {
                text = CiLog.Clean(await client.StepLog(repo, pipeline.Uuid, step.Uuid, ct).ConfigureAwait(false));
            }
            catch (Exception e) when (!ct.IsCancellationRequested)
            {
                text = "Log unavailable: " + e.Message;
            }
            parts.Add(header + "\n" + text.Trim('\n', '\r'));
        }
        return string.Join("\n\n", parts);
    }
}
