using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PullYard.Core.Api;
using PullYard.Core.Html;

namespace PullYard.Core.Forges;

public sealed record GitLabMRSnapshot(
    string Project,
    GitLabMR.Detail Mr,
    GitLabMR.Approvals? Approvals,
    List<GitLabMR.Discussion> Discussions,
    List<GitLabMR.Commit> Commits,
    List<GitLabMR.Job> Jobs,
    GitLabMR.Project? Settings,
    string Viewer,
    GitLabMR.TrainCar? Train = null);

public sealed record GitLabMergeStatus(string Mergeable, string Status, string? Blocker);

public static class GitLabReviewMapper
{
    public static PRRepository Repository(GitLabMRSnapshot s)
    {
        var squash = s.Settings?.SquashOption ?? "default_off";
        var prefersSquash = squash is "always" or "default_on" || s.Mr.Squash == true || s.Mr.SquashOnMerge == true;
        return new PRRepository
        {
            ViewerPermission = s.Mr.User?.CanMerge == true ? "WRITE" : "READ",
            MergeCommitAllowed = squash != "always",
            SquashMergeAllowed = squash != "never",
            RebaseMergeAllowed = false,
            DeleteBranchOnMerge = false,
            AutoMergeAllowed = s.Mr.HeadPipeline is not null,
            ViewerDefaultMergeMethod = prefersSquash && squash != "never" ? "SQUASH" : "MERGE",
            PullRequest = Detail(s)
        };
    }

    public static string State(string raw) => raw switch
    {
        "merged" => "MERGED",
        "opened" or "locked" => "OPEN",
        _ => "CLOSED"
    };

    public static string RawMergeStatus(GitLabMR.Detail mr) => mr.DetailedMergeStatus ?? LegacyStatus(mr.MergeStatus);

    public static GitLabMergeStatus MergeStatus(GitLabMR.Detail mr)
    {
        static GitLabMergeStatus Blocked(string? text) => new("MERGEABLE", "BLOCKED", text);
        return RawMergeStatus(mr) switch
        {
            "mergeable" => new("MERGEABLE", "CLEAN", null),
            "conflict" or "broken_status" => new("CONFLICTING", "DIRTY", null),
            "need_rebase" => new("MERGEABLE", "BEHIND", null),
            "checking" or "unchecked" or "preparing" or "approvals_syncing" => new("UNKNOWN", "UNKNOWN", null),
            "draft_status" => new("MERGEABLE", "DRAFT", null),
            "not_open" => new("UNKNOWN", "UNKNOWN", null),
            "not_approved" or "requested_changes" => Blocked(null),
            "ci_must_pass" => Blocked(mr.HeadPipeline is null ? "A pipeline must run and succeed" : "Pipeline must succeed"),
            "ci_still_running" => Blocked("Pipeline is still running"),
            "discussions_not_resolved" => Blocked("All threads must be resolved"),
            "blocked_status" or "merge_request_blocked" => Blocked("Blocked by another merge request"),
            "external_status_checks" => Blocked("External status checks must pass"),
            "jira_association_missing" => Blocked("Title or description must reference a Jira issue"),
            "security_policy_violations" or "security_policy_pipeline_check" => Blocked("Blocked by a security policy"),
            "locked_paths" or "locked_lfs_files" => Blocked("Changed files are locked"),
            "title_regex" => Blocked("Title doesn't match the project's required pattern"),
            "commits_status" => Blocked("Commits don't pass the project's push rules"),
            "merge_time" => Blocked("Can't be merged before the scheduled time"),
            var other => Blocked(CultureInfo.InvariantCulture.TextInfo.ToTitleCase(other.Replace('_', ' ').ToLowerInvariant()))
        };
    }

    public static string LegacyStatus(string? status) => status switch
    {
        "can_be_merged" => "mergeable",
        "cannot_be_merged" => "conflict",
        _ => "checking"
    };

    public static string? ReviewDecision(GitLabMR.Detail mr, GitLabMR.Approvals? approvals)
    {
        if (mr.DetailedMergeStatus == "requested_changes") return "CHANGES_REQUESTED";
        if (approvals is null) return null;
        if ((approvals.ApprovalsLeft ?? 0) > 0) return "REVIEW_REQUIRED";
        if ((approvals.ApprovedBy ?? new()).Count > 0) return "APPROVED";
        return null;
    }

    public static string Pulse(GitLabMR.Detail mr, GitLabMR.Approvals? approvals)
    {
        var approvers = string.Join(",", (approvals?.ApprovedBy ?? new()).Select(a => a.User.Username).OrderBy(u => u, StringComparer.Ordinal));
        var pipeline = mr.HeadPipeline is { } p ? $"{p.Id}:{p.Status}" : "";
        return string.Join("|",
            mr.UpdatedAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            mr.Sha ?? "",
            mr.State,
            pipeline,
            mr.DetailedMergeStatus ?? mr.MergeStatus ?? "",
            (mr.UserNotesCount ?? 0).ToString(CultureInfo.InvariantCulture),
            mr.BlockingDiscussionsResolved ?? true,
            approvers);
    }

    public static List<CheckContext> Checks(IEnumerable<GitLabMR.Job> jobs) => jobs.Select(job =>
    {
        var status = job.Status switch
        {
            "running" => "IN_PROGRESS",
            "created" or "pending" or "waiting_for_resource" or "preparing" or "scheduled" or "waiting_for_callback" => "QUEUED",
            _ => "COMPLETED"
        };
        string? conclusion = null;
        string? note = null;
        switch (job.Status)
        {
            case "success":
                conclusion = "SUCCESS";
                break;
            case "failed":
                conclusion = job.AllowFailure == true ? "NEUTRAL" : "FAILURE";
                if (job.AllowFailure == true) note = "Allowed to fail";
                break;
            case "canceled" or "canceling":
                conclusion = "CANCELLED";
                break;
            case "skipped":
                conclusion = "SKIPPED";
                break;
            case "manual":
                conclusion = "SKIPPED";
                note = "Manual";
                break;
        }
        return new CheckContext
        {
            Typename = "GitLabJob",
            DatabaseId = job.Id,
            Name = job.Name,
            Status = status,
            Conclusion = conclusion,
            DetailsUrl = job.WebUrl,
            StartedAt = job.StartedAt,
            CompletedAt = job.FinishedAt,
            CheckSuite = job.Stage is { } stage ? new CheckSuite { WorkflowRun = new WorkflowRun { Workflow = new WorkflowInfo { Name = stage } } } : null,
            Description = note
        };
    }).ToList();

    private static readonly Regex TraceSection = new(@"section_(?:start|end):\d+:[A-Za-z0-9_.\-\[\]=,]+\r?(?:\x1B\[0K)?", RegexOptions.Compiled);

    public static string CleanTrace(string raw)
    {
        var lines = TraceSection.Replace(raw, "").Split('\n').Select(line =>
        {
            var body = line.EndsWith('\r') ? line[..^1] : line;
            var cut = body.LastIndexOf('\r');
            return cut < 0 ? body : body[(cut + 1)..];
        });
        return CiLog.Clean(string.Join("\n", lines));
    }

    public static string? RollupState(GitLabMR.Pipeline? pipeline) => pipeline?.Status switch
    {
        null => null,
        "success" => "SUCCESS",
        "failed" => "FAILURE",
        "canceled" or "skipped" => "ERROR",
        _ => "PENDING"
    };

    public static string ProjectUrl(string webUrl)
    {
        var cut = webUrl.IndexOf("/-/", StringComparison.Ordinal);
        return cut >= 0 ? webUrl[..cut] : webUrl;
    }

    public static PullRequestDetail Detail(GitLabMRSnapshot s)
    {
        var mr = s.Mr;
        var baseUrl = ProjectUrl(mr.WebUrl);
        var merge = MergeStatus(mr);
        var me = s.Viewer.ToLowerInvariant();
        var isAuthor = me.Length > 0 && mr.Author?.Username.ToLowerInvariant() == me;
        var canMerge = mr.User?.CanMerge == true;
        var headSha = mr.DiffRefs?.HeadSha ?? mr.Sha;
        var (timeline, threads) = Conversation(s.Discussions, headSha, baseUrl, me, canMerge || isAuthor);
        var commits = Enumerable.Reverse(s.Commits).Select(c => new CommitInfoNode
        {
            Commit = new CommitInfo
            {
                Oid = c.Id,
                AbbreviatedOid = c.ShortId,
                MessageHeadline = c.Title,
                CommittedDate = c.CommittedDate ?? c.AuthoredDate ?? mr.CreatedAt,
                Url = c.WebUrl ?? $"{baseUrl}/-/commit/{c.Id}",
                Author = new GitActor { Name = c.AuthorName }
            }
        }).ToList();
        var contexts = Checks(s.Jobs);
        var rollup = RollupState(mr.HeadPipeline) is { } rs ? new StatusRollup { State = rs, Contexts = new Nodes<CheckContext> { Items = contexts, TotalCount = contexts.Count } } : null;
        var approvers = (s.Approvals?.ApprovedBy ?? new()).Select(a => a.User).ToList();
        var approved = approvers.Select(a => a.Username).ToHashSet();
        var pending = (mr.Reviewers ?? new()).Where(r => !approved.Contains(r.Username)).ToList();
        var changed = int.TryParse(new string((mr.ChangesCount ?? "").TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0;
        var samePlace = mr.SourceProjectId is null || mr.SourceProjectId == mr.TargetProjectId;
        var state = State(mr.State);
        return new PullRequestDetail
        {
            Id = $"gitlab-mr-{mr.Id}",
            Number = mr.Iid,
            Title = mr.Title,
            Url = mr.WebUrl,
            State = state,
            IsDraft = mr.IsDraft,
            Merged = state == "MERGED",
            Mergeable = merge.Mergeable,
            MergeStateStatus = merge.Status,
            Body = mr.Description ?? "",
            BodyHTML = mr.DescriptionHtml is { } h ? MarkdownHtml.AbsolutizeHtml(h, baseUrl) : MarkdownHtml.Render(mr.Description ?? "", baseUrl),
            CreatedAt = mr.CreatedAt,
            UpdatedAt = mr.UpdatedAt,
            Author = mr.Author?.Actor,
            HeadRefName = mr.SourceBranch,
            BaseRefName = mr.TargetBranch,
            HeadRefOid = headSha ?? "",
            BaseRef = mr.DiffRefs?.BaseSha is { } b ? new RefTip { Target = new ReviewCommit { Oid = b } } : null,
            HeadRepository = samePlace ? new RepoName { NameWithOwner = s.Project } : null,
            HeadRef = state == "OPEN" ? new BranchName { Name = mr.SourceBranch } : null,
            ChangedFiles = changed,
            ReviewDecision = ReviewDecision(mr, s.Approvals),
            ViewerCanUpdate = canMerge || isAuthor,
            ViewerDidAuthor = isAuthor,
            AutoMergeRequest = mr.MergeWhenPipelineSucceeds == true ? new AutoMergeRequest() : null,
            Labels = new Nodes<LabelInfo> { Items = (mr.Labels ?? new()).Select(l => l.Info).ToList() },
            Assignees = new Nodes<Actor> { Items = (mr.Assignees ?? new()).Select(a => a.Actor).ToList() },
            ReviewRequests = new Nodes<ReviewRequest>
            {
                Items = pending.Select(r => new ReviewRequest { RequestedReviewer = new Reviewer { Typename = "User", Login = r.Username, AvatarUrl = r.AvatarUrl, Name = r.Name } }).ToList()
            },
            LatestOpinionatedReviews = new Nodes<LatestReview> { Items = approvers.Select(a => new LatestReview { State = "APPROVED", Author = a.Actor }).ToList() },
            LastCommit = new Nodes<LastCommitNode>
            {
                Items = new() { new LastCommitNode { Commit = new LastCommit { Oid = headSha ?? "", CommittedDate = commits.LastOrDefault()?.Commit.CommittedDate, StatusCheckRollup = rollup } } }
            },
            AllCommits = new Nodes<CommitInfoNode> { Items = commits, TotalCount = commits.Count },
            TimelineItems = new Nodes<TimelineItem> { Items = timeline },
            ReviewThreads = new Nodes<ReviewThread> { Items = threads },
            ViewerCanApprove = s.Approvals?.UserCanApprove,
            ViewerApproved = s.Approvals?.UserHasApproved,
            MergeBlocker = merge.Blocker,
            ForgeMerge = new ForgeMergeInfo { Status = RawMergeStatus(mr), ApprovalsRequired = s.Approvals?.ApprovalsRequired, ApprovalsLeft = s.Approvals?.ApprovalsLeft },
            IsMergeQueueEnabled = s.Settings?.MergeTrainsEnabled,
            MergeQueueEntry = TrainEntry(s.Train)
        };
    }

    private static readonly HashSet<string> TrainRunning = new() { "created", "pending", "running", "waiting_for_resource", "preparing" };

    public static MergeQueueEntry? TrainEntry(GitLabMR.TrainCar? car)
    {
        if (car is null) return null;
        var running = TrainRunning.Contains(car.Pipeline?.Status ?? "");
        return car.Status switch
        {
            "merging" => new MergeQueueEntry { State = "MERGEABLE" },
            "stale" => new MergeQueueEntry { State = "AWAITING_CHECKS" },
            "idle" or "fresh" => new MergeQueueEntry { State = running ? "AWAITING_CHECKS" : "QUEUED" },
            _ => null
        };
    }

    public static (List<TimelineItem> Timeline, List<ReviewThread> Threads) Conversation(IEnumerable<GitLabMR.Discussion> discussions, string? headSha, string baseUrl, string viewer, bool moderator)
    {
        var timeline = new List<TimelineItem>();
        var threads = new List<ReviewThread>();
        foreach (var d in discussions.OrderBy(d => d.Notes.FirstOrDefault()?.CreatedAt ?? DateTimeOffset.MinValue))
        {
            if (d.Notes.FirstOrDefault() is not { } first) continue;
            if (first.System)
            {
                foreach (var note in d.Notes)
                    timeline.Add(Item("SystemNote", $"gl-n-{note.Id}", null, note.Author?.Actor, note.Body, null, note.CreatedAt));
                continue;
            }
            var notes = d.Notes.Where(x => !x.System).ToList();
            if (d.IndividualNote && first.Position is null)
            {
                timeline.Add(Item("IssueComment", $"gl-n-{first.Id}", first.Author?.Actor, null, first.Body, MarkdownHtml.Render(first.Body, baseUrl), first.CreatedAt));
                continue;
            }
            var review = $"gl-d-{d.Id}";
            var resolvableNotes = notes.Where(x => x.Resolvable == true).ToList();
            var resolvable = resolvableNotes.Count > 0;
            var resolved = resolvable && resolvableNotes.All(x => x.Resolved == true);
            var starter = first.Author?.Username.ToLowerInvariant() == viewer;
            var canResolve = resolvable && (moderator || starter);
            var position = first.Position;
            var outdated = position is not null && headSha is not null && position.HeadSha is not null && position.HeadSha != headSha;
            var line = position?.NewLine ?? position?.OldLine;
            threads.Add(new ReviewThread
            {
                Id = d.Id,
                IsResolved = resolved,
                IsOutdated = outdated,
                Path = position is null ? "" : position.NewPath ?? position.OldPath ?? "",
                Line = outdated ? null : line,
                OriginalLine = line,
                DiffSide = position?.NewLine is null && position?.OldLine is not null ? "LEFT" : "RIGHT",
                ViewerCanResolve = canResolve && !resolved,
                ViewerCanUnresolve = canResolve && resolved,
                ViewerCanReply = true,
                Comments = new Nodes<ThreadComment>
                {
                    Items = notes.Select(x => new ThreadComment
                    {
                        Id = x.Id.ToString(CultureInfo.InvariantCulture),
                        Author = x.Author?.Actor,
                        Body = x.Body,
                        BodyHTML = MarkdownHtml.Render(x.Body, baseUrl),
                        CreatedAt = x.CreatedAt,
                        PullRequestReview = new IdOnly { Id = review }
                    }).ToList()
                }
            });
            timeline.Add(Item("PullRequestReview", review, first.Author?.Actor, null, null, null, first.CreatedAt, "DISCUSSION"));
        }
        return (timeline, threads);
    }

    private static TimelineItem Item(string type, string id, Actor? author, Actor? actor, string? body, string? html, DateTimeOffset date, string? state = null) =>
        new() { Typename = type, Id = id, Author = author, Actor = actor, Body = body, BodyHTML = html, CreatedAt = date, State = state };

    public static PRFile File(GitLabMR.Diff d)
    {
        var patch = string.IsNullOrEmpty(d.Patch) || d.TooLarge == true ? null : d.Patch;
        int additions = 0, deletions = 0;
        if (patch is not null)
        {
            foreach (var line in patch.Split('\n'))
            {
                if (line.StartsWith('+')) additions++;
                else if (line.StartsWith('-')) deletions++;
            }
        }
        var status = d.NewFile ? "added" : d.DeletedFile ? "removed" : d.RenamedFile ? "renamed" : "modified";
        return new PRFile { Filename = d.NewPath, Status = status, Additions = additions, Deletions = deletions, Patch = patch, PreviousFilename = d.RenamedFile ? d.OldPath : null };
    }

    public static JsonObject? Position(PendingComment comment, IReadOnlyList<DiffFile> files, GitLabMR.DiffRefs? refs)
    {
        if (refs?.BaseSha is not { } baseSha || refs.HeadSha is not { } headSha) return null;
        var file = files.FirstOrDefault(f => f.Id == comment.Path);
        var p = new JsonObject
        {
            ["position_type"] = "text",
            ["base_sha"] = baseSha,
            ["start_sha"] = refs.StartSha ?? baseSha,
            ["head_sha"] = headSha,
            ["new_path"] = comment.Path,
            ["old_path"] = file?.PreviousFilename ?? comment.Path
        };
        var left = comment.Side == "LEFT";
        var line = file?.Lines.FirstOrDefault(l => left
            ? l.OldLine == comment.Line && l.Kind != DiffLineKind.Add
            : l.NewLine == comment.Line && l.Kind != DiffLineKind.Del);
        if (left) p["old_line"] = comment.Line;
        else p["new_line"] = comment.Line;
        if (line?.Kind == DiffLineKind.Context)
        {
            if (line.OldLine is { } o) p["old_line"] = o;
            if (line.NewLine is { } nl) p["new_line"] = nl;
        }
        return p;
    }

    public static string Undrafted(string title) =>
        Regex.Replace(title, @"^\s*(\[draft\]|\(draft\)|draft:|draft\s*-|wip:|\[wip\])\s*", "", RegexOptions.IgnoreCase);
}

public sealed class GitLabPRBackend : IPRBackend
{
    private readonly GitLabClient client;
    private readonly Dictionary<string, GitLabMR.Project?> settings = new();
    private readonly Dictionary<ItemRef, GitLabMR.DiffRefs?> refs = new();
    private readonly Dictionary<ItemRef, string> jobProjects = new();

    public GitLabPRBackend(GitLabClient client)
    {
        this.client = client;
    }

    public PRFeatures Features => PRFeatures.GitLab;

    private async Task<GitLabMR.Project?> ProjectSettings(string project, CancellationToken ct)
    {
        lock (settings)
            if (settings.TryGetValue(project, out var hit)) return hit;
        GitLabMR.Project? fresh;
        try
        {
            fresh = await client.Project(project, ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is ApiException or HttpRequestException)
        {
            fresh = null;
        }
        lock (settings) settings[project] = fresh;
        return fresh;
    }

    private static async Task<T?> Optional<T>(Task<T> task) where T : class
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
        var project = r.Repo.Full;
        var mrTask = client.MergeRequestDetail(project, r.Number, ct: ct);
        var approvalsTask = Optional(client.Approvals(project, r.Number, ct));
        var discussionsTask = client.Discussions(project, r.Number, ct);
        var commitsTask = client.Commits(project, r.Number, ct);
        var settingsTask = ProjectSettings(project, ct);
        var viewerTask = Optional(client.Username(ct));
        var mr = await mrTask.ConfigureAwait(false);
        var jobs = new List<GitLabMR.Job>();
        if (mr.HeadPipeline is { } pipeline)
        {
            var owner = pipeline.ProjectId?.ToString(CultureInfo.InvariantCulture) ?? project;
            lock (jobProjects) jobProjects[r] = owner;
            jobs = await Optional(client.Jobs(owner, pipeline.Id, ct)).ConfigureAwait(false) ?? new();
        }
        var approvals = await approvalsTask.ConfigureAwait(false);
        var projectSettings = await settingsTask.ConfigureAwait(false);
        var train = projectSettings?.MergeTrainsEnabled == true && mr.State == "opened"
            ? await Optional(client.TrainCar(project, r.Number, ct)).ConfigureAwait(false)
            : null;
        var snapshot = new GitLabMRSnapshot(
            project,
            mr,
            approvals,
            await discussionsTask.ConfigureAwait(false),
            await commitsTask.ConfigureAwait(false),
            jobs,
            projectSettings,
            await viewerTask.ConfigureAwait(false) ?? "",
            train);
        lock (refs) refs[r] = mr.DiffRefs;
        return new PRLoad(snapshot.Viewer, GitLabReviewMapper.Repository(snapshot), GitLabReviewMapper.Pulse(mr, approvals));
    }

    public async Task<string?> Pulse(ItemRef r, CancellationToken ct = default)
    {
        var mrTask = client.MergeRequestDetail(r.Repo.Full, r.Number, html: false, ct: ct);
        var approvalsTask = Optional(client.Approvals(r.Repo.Full, r.Number, ct));
        return GitLabReviewMapper.Pulse(await mrTask.ConfigureAwait(false), await approvalsTask.ConfigureAwait(false));
    }

    public async Task<List<PRFile>> Files(ItemRef r, PullRequestDetail pr, CancellationToken ct = default) =>
        (await client.Diffs(r.Repo.Full, r.Number, ct).ConfigureAwait(false)).Select(GitLabReviewMapper.File).ToList();

    public Task Comment(ItemRef r, PullRequestDetail pr, string body) => client.AddNote(r.Repo.Full, r.Number, body);

    public async Task SubmitReview(ItemRef r, PullRequestDetail pr, string @event, string body, IReadOnlyList<PendingComment> comments, IReadOnlyList<DiffFile> files)
    {
        var project = r.Repo.Full;
        GitLabMR.DiffRefs? diffRefs;
        lock (refs) refs.TryGetValue(r, out diffRefs);
        foreach (var c in comments)
        {
            var position = GitLabReviewMapper.Position(c, files, diffRefs) ?? throw new ApiException("Reload the merge request and try again: its diff version is unknown");
            await client.AddDiscussion(project, r.Number, c.Body, position).ConfigureAwait(false);
        }
        var text = body.Trim();
        if (text.Length > 0) await client.AddNote(project, r.Number, text).ConfigureAwait(false);
        if (@event == "APPROVE") await client.Approve(project, r.Number, pr.HeadRefOid.Length == 0 ? null : pr.HeadRefOid).ConfigureAwait(false);
    }

    public Task Reply(ItemRef r, string thread, string body) => client.Reply(r.Repo.Full, r.Number, thread, body);

    public Task SetResolved(ItemRef r, string thread, bool resolved) => client.Resolve(r.Repo.Full, r.Number, thread, resolved);

    public async Task<string?> Merge(ItemRef r, PullRequestDetail pr, string method, string? title, string? body, bool deleteBranch)
    {
        await client.Merge(r.Repo.Full, r.Number, method == "SQUASH", deleteBranch, Message(title, body, pr), Sha(pr), auto: false).ConfigureAwait(false);
        return null;
    }

    public Task EnableAutoMerge(ItemRef r, PullRequestDetail pr, string method) =>
        client.Merge(r.Repo.Full, r.Number, method == "SQUASH", false, null, Sha(pr), auto: true);

    private static string? Sha(PullRequestDetail pr) => pr.HeadRefOid.Length == 0 ? null : pr.HeadRefOid;

    private static string? Message(string? title, string? body, PullRequestDetail pr)
    {
        if (title is null && body is null) return null;
        return string.Join("\n\n", new[] { title ?? pr.Title, body }.OfType<string>());
    }

    public Task Perform(PRAction action, ItemRef r, PullRequestDetail pr)
    {
        var project = r.Repo.Full;
        return action switch
        {
            PRAction.Close => client.Update(project, r.Number, new JsonObject { ["state_event"] = "close" }),
            PRAction.Reopen => client.Update(project, r.Number, new JsonObject { ["state_event"] = "reopen" }),
            PRAction.ReadyForReview => client.Update(project, r.Number, new JsonObject { ["title"] = GitLabReviewMapper.Undrafted(pr.Title) }),
            PRAction.ConvertToDraft => client.Update(project, r.Number, new JsonObject { ["title"] = "Draft: " + GitLabReviewMapper.Undrafted(pr.Title) }),
            PRAction.UpdateBranch => client.Rebase(project, r.Number),
            _ => client.CancelAutoMerge(project, r.Number)
        };
    }

    public Task Edit(ItemRef r, PullRequestDetail pr, string title, string body) =>
        client.Update(r.Repo.Full, r.Number, new JsonObject { ["title"] = title, ["description"] = body });

    public Task<CommitDetailRest> Commit(RepoRef repo, string sha) => client.Commit(repo.Full, sha);

    public Task RevokeApproval(ItemRef r, PullRequestDetail pr) => client.Unapprove(r.Repo.Full, r.Number);

    public async Task<CodeOwners?> CodeOwners(ItemRef r, string @base, CancellationToken ct = default)
    {
        foreach (var path in Api.CodeOwners.GitLabPaths)
        {
            if (await client.RawFile(r.Repo.Full, path, @base, ct).ConfigureAwait(false) is { } text)
                return new CodeOwners(text, path, CodeOwnersFlavor.GitLab);
        }
        return null;
    }

    public bool CanShowLog(CheckContext check) =>
        check.Typename == "GitLabJob" && check.DatabaseId is not null && check.Outcome is not CheckOutcome.Pending and not CheckOutcome.Skipped;

    public async Task<string> JobLog(ItemRef r, CheckContext check, CancellationToken ct = default)
    {
        if (check.DatabaseId is not { } id) throw new ApiException("This job has no log");
        string? project;
        lock (jobProjects) jobProjects.TryGetValue(r, out project);
        var raw = await client.JobTrace(project ?? r.Repo.Full, id, ct).ConfigureAwait(false);
        return GitLabReviewMapper.CleanTrace(raw);
    }
}
