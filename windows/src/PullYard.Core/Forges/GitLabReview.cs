using System.Net;
using System.Text.Json.Serialization;
using System.Text.Json.Nodes;
using PullYard.Core.Api;

namespace PullYard.Core.Forges;

public static class GitLabMR
{
    public sealed class User
    {
        public long? Id { get; set; }
        public string Username { get; set; } = "";
        public string? Name { get; set; }
        public string? AvatarUrl { get; set; }

        public Actor Actor => new() { Login = Username, AvatarUrl = AvatarUrl };
    }

    public sealed class DiffRefs
    {
        public string? BaseSha { get; set; }
        public string? HeadSha { get; set; }
        public string? StartSha { get; set; }
    }

    public sealed class Pipeline
    {
        public long Id { get; set; }
        public long? ProjectId { get; set; }
        public string Status { get; set; } = "";
        public string? WebUrl { get; set; }
    }

    public sealed class Permissions
    {
        public bool? CanMerge { get; set; }
    }

    public sealed class References
    {
        public string? Full { get; set; }
    }

    public sealed class Detail
    {
        public long Id { get; set; }
        public int Iid { get; set; }
        public long? ProjectId { get; set; }
        public long? SourceProjectId { get; set; }
        public long? TargetProjectId { get; set; }
        public string Title { get; set; } = "";
        public string? Description { get; set; }
        public string? DescriptionHtml { get; set; }
        public string State { get; set; } = "";
        public bool? Draft { get; set; }
        public bool? WorkInProgress { get; set; }
        public string WebUrl { get; set; } = "";
        public DateTimeOffset CreatedAt { get; set; }
        public DateTimeOffset UpdatedAt { get; set; }
        public User? Author { get; set; }
        public List<User>? Assignees { get; set; }
        public List<User>? Reviewers { get; set; }
        public string SourceBranch { get; set; } = "";
        public string TargetBranch { get; set; } = "";
        public string? Sha { get; set; }
        public DiffRefs? DiffRefs { get; set; }
        public string? DetailedMergeStatus { get; set; }
        public string? MergeStatus { get; set; }
        public bool? HasConflicts { get; set; }
        public bool? BlockingDiscussionsResolved { get; set; }
        public List<ForgeLabel>? Labels { get; set; }
        public Pipeline? HeadPipeline { get; set; }
        public string? ChangesCount { get; set; }
        public int? UserNotesCount { get; set; }
        public bool? ForceRemoveSourceBranch { get; set; }
        public bool? Squash { get; set; }
        public bool? SquashOnMerge { get; set; }
        public bool? MergeWhenPipelineSucceeds { get; set; }
        public Permissions? User { get; set; }
        public References? References { get; set; }

        public bool IsDraft => Draft ?? WorkInProgress ?? false;
    }

    public sealed class Approver
    {
        public User User { get; set; } = new();
    }

    public sealed class Approvals
    {
        public bool? Approved { get; set; }
        public int? ApprovalsRequired { get; set; }
        public int? ApprovalsLeft { get; set; }
        public List<Approver>? ApprovedBy { get; set; }
        public bool? UserHasApproved { get; set; }
        public bool? UserCanApprove { get; set; }
    }

    public sealed class Position
    {
        public string? BaseSha { get; set; }
        public string? StartSha { get; set; }
        public string? HeadSha { get; set; }
        public string? OldPath { get; set; }
        public string? NewPath { get; set; }
        public int? OldLine { get; set; }
        public int? NewLine { get; set; }
        public string? PositionType { get; set; }
    }

    public sealed class Note
    {
        public long Id { get; set; }
        public string? Type { get; set; }
        public string Body { get; set; } = "";
        public User? Author { get; set; }
        public DateTimeOffset CreatedAt { get; set; }
        public bool System { get; set; }
        public bool? Resolvable { get; set; }
        public bool? Resolved { get; set; }
        public Position? Position { get; set; }
    }

    public sealed class Discussion
    {
        public string Id { get; set; } = "";
        public bool IndividualNote { get; set; }
        public List<Note> Notes { get; set; } = new();
    }

    public sealed class Stats
    {
        public int Additions { get; set; }
        public int Deletions { get; set; }
    }

    public sealed class Commit
    {
        public string Id { get; set; } = "";
        public string ShortId { get; set; } = "";
        public string Title { get; set; } = "";
        public string? Message { get; set; }
        public string? AuthorName { get; set; }
        public DateTimeOffset? AuthoredDate { get; set; }
        public DateTimeOffset? CommittedDate { get; set; }
        public string? WebUrl { get; set; }
        public Stats? Stats { get; set; }
    }

    public sealed class Job
    {
        public long Id { get; set; }
        public string Name { get; set; } = "";
        public string? Stage { get; set; }
        public string Status { get; set; } = "";
        public string? WebUrl { get; set; }
        public DateTimeOffset? StartedAt { get; set; }
        public DateTimeOffset? FinishedAt { get; set; }
        public bool? AllowFailure { get; set; }
    }

    public sealed class Diff
    {
        public string OldPath { get; set; } = "";
        public string NewPath { get; set; } = "";
        [JsonPropertyName("diff")]
        public string? Patch { get; set; }
        public bool NewFile { get; set; }
        public bool RenamedFile { get; set; }
        public bool DeletedFile { get; set; }
        public bool? TooLarge { get; set; }
        public bool? Collapsed { get; set; }
    }

    public sealed class Changes
    {
        [JsonPropertyName("changes")]
        public List<Diff> Items { get; set; } = new();
    }

    public sealed class Project
    {
        public long Id { get; set; }
        public string PathWithNamespace { get; set; } = "";
        public string? WebUrl { get; set; }
        public string? MergeMethod { get; set; }
        public string? SquashOption { get; set; }
        public bool? RemoveSourceBranchAfterMerge { get; set; }
        public bool? MergeTrainsEnabled { get; set; }
    }

    public sealed class TrainCar
    {
        public string Status { get; set; } = "";
        public Pipeline? Pipeline { get; set; }
    }
}

public sealed partial class GitLabClient
{
    public static string ProjectApiPath(string project) => "/projects/" + Uri.EscapeDataString(project);

    private static string MrPath(string project, int iid) => $"{ProjectApiPath(project)}/merge_requests/{iid}";

    private async Task<List<T>> Pages<T>(string path, int limit = 10, CancellationToken ct = default)
    {
        var all = new List<T>();
        for (var page = 1; page <= limit; page++)
        {
            var batch = await http.Get<List<T>>(path, new[] { ("per_page", "100"), ("page", page.ToString()) }, ct).ConfigureAwait(false);
            all.AddRange(batch);
            if (batch.Count < 100) break;
        }
        return all;
    }

    public Task<GitLabMR.Detail> MergeRequestDetail(string project, int iid, bool html = true, CancellationToken ct = default) =>
        http.Get<GitLabMR.Detail>(MrPath(project, iid), html ? new[] { ("render_html", "true") } : null, ct);

    public Task<GitLabMR.Approvals> Approvals(string project, int iid, CancellationToken ct = default) =>
        http.Get<GitLabMR.Approvals>(MrPath(project, iid) + "/approvals", ct: ct);

    public Task<List<GitLabMR.Discussion>> Discussions(string project, int iid, CancellationToken ct = default) =>
        Pages<GitLabMR.Discussion>(MrPath(project, iid) + "/discussions", ct: ct);

    public Task<List<GitLabMR.Commit>> Commits(string project, int iid, CancellationToken ct = default) =>
        Pages<GitLabMR.Commit>(MrPath(project, iid) + "/commits", 3, ct);

    public Task<List<GitLabMR.Job>> Jobs(string project, long pipeline, CancellationToken ct = default) =>
        Pages<GitLabMR.Job>($"{ProjectApiPath(project)}/pipelines/{pipeline}/jobs", 3, ct);

    public Task<string> JobTrace(string project, long job, CancellationToken ct = default) =>
        http.Text($"{ProjectApiPath(project)}/jobs/{job}/trace", ct: ct);

    public Task<GitLabMR.TrainCar> TrainCar(string project, int iid, CancellationToken ct = default) =>
        http.Get<GitLabMR.TrainCar>($"{ProjectApiPath(project)}/merge_trains/merge_requests/{iid}", ct: ct);

    public Task<GitLabMR.Project> Project(string project, CancellationToken ct = default) =>
        http.Get<GitLabMR.Project>(ProjectApiPath(project), ct: ct);

    public async Task<List<GitLabMR.Diff>> Diffs(string project, int iid, CancellationToken ct = default)
    {
        try
        {
            return await Pages<GitLabMR.Diff>(MrPath(project, iid) + "/diffs", 30, ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.Status == (int)HttpStatusCode.NotFound)
        {
            var changes = await http.Get<GitLabMR.Changes>(MrPath(project, iid) + "/changes", ct: ct).ConfigureAwait(false);
            return changes.Items;
        }
    }

    public Task AddNote(string project, int iid, string body) =>
        http.Post(MrPath(project, iid) + "/notes", new JsonObject { ["body"] = body });

    public Task AddDiscussion(string project, int iid, string body, JsonObject? position)
    {
        var json = new JsonObject { ["body"] = body };
        if (position is not null) json["position"] = position;
        return http.Post(MrPath(project, iid) + "/discussions", json);
    }

    public Task Reply(string project, int iid, string discussion, string body) =>
        http.Post($"{MrPath(project, iid)}/discussions/{Uri.EscapeDataString(discussion)}/notes", new JsonObject { ["body"] = body });

    public Task Resolve(string project, int iid, string discussion, bool resolved) =>
        http.Post($"{MrPath(project, iid)}/discussions/{Uri.EscapeDataString(discussion)}", new JsonObject { ["resolved"] = resolved }, "PUT");

    public Task Approve(string project, int iid, string? sha)
    {
        var json = new JsonObject();
        if (sha is not null) json["sha"] = sha;
        return http.Post(MrPath(project, iid) + "/approve", json);
    }

    public Task Unapprove(string project, int iid) => http.Post(MrPath(project, iid) + "/unapprove");

    public Task Merge(string project, int iid, bool squash, bool removeBranch, string? message, string? sha, bool auto)
    {
        var json = new JsonObject { ["squash"] = squash, ["should_remove_source_branch"] = removeBranch };
        if (sha is not null) json["sha"] = sha;
        if (message is not null) json[squash ? "squash_commit_message" : "merge_commit_message"] = message;
        if (auto)
        {
            json["auto_merge"] = true;
            json["merge_when_pipeline_succeeds"] = true;
        }
        return http.Post(MrPath(project, iid) + "/merge", json, "PUT");
    }

    public Task CancelAutoMerge(string project, int iid) => http.Post(MrPath(project, iid) + "/cancel_merge_when_pipeline_succeeds");

    public Task Rebase(string project, int iid) => http.Post(MrPath(project, iid) + "/rebase", method: "PUT");

    public Task Update(string project, int iid, JsonObject fields) => http.Post(MrPath(project, iid), fields, "PUT");

    public async Task<CommitDetailRest> Commit(string project, string sha, CancellationToken ct = default)
    {
        var path = $"{ProjectApiPath(project)}/repository/commits/{Uri.EscapeDataString(sha)}";
        var detailTask = http.Get<GitLabMR.Commit>(path, ct: ct);
        var diffTask = Pages<GitLabMR.Diff>(path + "/diff", 10, ct);
        var c = await detailTask.ConfigureAwait(false);
        var files = await diffTask.ConfigureAwait(false);
        return new CommitDetailRest
        {
            Sha = c.Id,
            HtmlUrl = c.WebUrl ?? $"https://{Host}/{project}/-/commit/{c.Id}",
            Commit = new CommitDetailRest.Inner
            {
                Message = c.Message ?? c.Title,
                Author = new CommitDetailRest.Person { Name = c.AuthorName, Date = c.AuthoredDate ?? c.CommittedDate }
            },
            Stats = c.Stats is { } s ? new CommitDetailRest.StatsInfo { Additions = s.Additions, Deletions = s.Deletions } : null,
            Files = files.Select(GitLabReviewMapper.File).ToList()
        };
    }
}
