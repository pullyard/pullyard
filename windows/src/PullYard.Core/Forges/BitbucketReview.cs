using System.Globalization;
using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PullYard.Core.Api;

namespace PullYard.Core.Forges;

public static class BitbucketPR
{
    public sealed class Link
    {
        public string? Href { get; set; }
    }

    public sealed class Links
    {
        public Link? Html { get; set; }
        public Link? Avatar { get; set; }
    }

    public sealed class User
    {
        public string? Uuid { get; set; }
        public string? DisplayName { get; set; }
        public string? Nickname { get; set; }
        public Links? Links { get; set; }

        public string Login => Nickname ?? DisplayName ?? Uuid ?? "unknown";
        public Actor Actor => new() { Login = Login, AvatarUrl = Links?.Avatar?.Href };
    }

    public sealed class Rendered
    {
        public string? Raw { get; set; }
        public string? Html { get; set; }
    }

    public sealed class Branch
    {
        public string Name { get; set; } = "";
    }

    public sealed class Commit
    {
        public string Hash { get; set; } = "";
    }

    public sealed class RepoName
    {
        public string? FullName { get; set; }
    }

    public sealed class Endpoint
    {
        public Branch? Branch { get; set; }
        public Commit? Commit { get; set; }
        public RepoName? Repository { get; set; }
    }

    public sealed class Participant
    {
        public User? User { get; set; }
        public string? Role { get; set; }
        public bool? Approved { get; set; }
        public string? State { get; set; }
        public DateTimeOffset? ParticipatedOn { get; set; }
    }

    public sealed class Detail
    {
        public int Id { get; set; }
        public string Title { get; set; } = "";
        public string State { get; set; } = "";
        public bool? Draft { get; set; }
        public Rendered? Summary { get; set; }
        public DateTimeOffset CreatedOn { get; set; }
        public DateTimeOffset UpdatedOn { get; set; }
        public User? Author { get; set; }
        public Endpoint? Source { get; set; }
        public Endpoint? Destination { get; set; }
        public bool? CloseSourceBranch { get; set; }
        public Links? Links { get; set; }
        public int? CommentCount { get; set; }
        public int? TaskCount { get; set; }
        public List<Participant>? Participants { get; set; }
        public List<User>? Reviewers { get; set; }
    }

    public sealed class Inline
    {
        public string? Path { get; set; }
        public int? From { get; set; }
        public int? To { get; set; }
        public bool? Outdated { get; set; }
    }

    public sealed class Parent
    {
        public int Id { get; set; }
    }

    public sealed class Resolution
    {
        public string? Type { get; set; }
        public User? User { get; set; }
    }

    public sealed class Comment
    {
        public int Id { get; set; }
        public Rendered? Content { get; set; }
        public User? User { get; set; }
        public DateTimeOffset CreatedOn { get; set; }
        public Inline? Inline { get; set; }
        public Parent? Parent { get; set; }
        public bool? Deleted { get; set; }
        public bool? Pending { get; set; }
        public Resolution? Resolution { get; set; }
    }

    public sealed class CommitAuthor
    {
        public string? Raw { get; set; }
        public User? User { get; set; }
    }

    public sealed class CommitInfo
    {
        public string Hash { get; set; } = "";
        public string? Message { get; set; }
        public DateTimeOffset? Date { get; set; }
        public CommitAuthor? Author { get; set; }
        public Links? Links { get; set; }
    }

    public sealed class Status
    {
        public string? Key { get; set; }
        public string? Name { get; set; }
        public string State { get; set; } = "";
        public string? Url { get; set; }
        public string? Description { get; set; }
        public DateTimeOffset? CreatedOn { get; set; }
        public DateTimeOffset? UpdatedOn { get; set; }
    }

    public sealed class DiffPath
    {
        public string Path { get; set; } = "";
    }

    public sealed class DiffStat
    {
        public string Status { get; set; } = "";
        public int? LinesAdded { get; set; }
        public int? LinesRemoved { get; set; }
        public DiffPath? Old { get; set; }
        public DiffPath? New { get; set; }

        public string Path => New?.Path ?? Old?.Path ?? "";
    }

    public sealed class PipelineResult
    {
        public string? Name { get; set; }
    }

    public sealed class Outcome
    {
        public string? Name { get; set; }
        public PipelineResult? Result { get; set; }
    }

    public sealed class Pipeline
    {
        public string Uuid { get; set; } = "";
        public int? BuildNumber { get; set; }
        public Outcome? State { get; set; }
    }

    public sealed class Step
    {
        public string Uuid { get; set; } = "";
        public string? Name { get; set; }
        public Outcome? State { get; set; }
    }

    public sealed class Page<T>
    {
        public List<T>? Values { get; set; }
        public string? Next { get; set; }
    }
}

public sealed partial class BitbucketClient
{
    public static string RepoPath(string repo) => "/repositories/" + string.Join("/", repo.Split('/').Select(Uri.EscapeDataString));

    public static string PullPath(string repo, int id) => $"{RepoPath(repo)}/pullrequests/{id}";

    private async Task<List<T>> Pages<T>(string path, int limit = 10, CancellationToken ct = default)
    {
        var all = new List<T>();
        var page = await http.Get<BitbucketPR.Page<T>>(path, new[] { ("pagelen", "100") }, ct).ConfigureAwait(false);
        all.AddRange(page.Values ?? new());
        for (var count = 1; page.Next is { } next && count < limit; count++)
        {
            page = await http.Get<BitbucketPR.Page<T>>(next, ct: ct).ConfigureAwait(false);
            all.AddRange(page.Values ?? new());
        }
        return all;
    }

    public Task<BitbucketPR.Detail> PullRequestDetail(string repo, int id, CancellationToken ct = default) =>
        http.Get<BitbucketPR.Detail>(PullPath(repo, id), ct: ct);

    public Task<List<BitbucketPR.Comment>> Comments(string repo, int id, CancellationToken ct = default) =>
        Pages<BitbucketPR.Comment>(PullPath(repo, id) + "/comments", 20, ct);

    public Task<List<BitbucketPR.CommitInfo>> PullCommits(string repo, int id, CancellationToken ct = default) =>
        Pages<BitbucketPR.CommitInfo>(PullPath(repo, id) + "/commits", 3, ct);

    public Task<List<BitbucketPR.Status>> Statuses(string repo, int id, CancellationToken ct = default) =>
        Pages<BitbucketPR.Status>(PullPath(repo, id) + "/statuses", 3, ct);

    public Task<List<BitbucketPR.DiffStat>> DiffStat(string repo, int id, CancellationToken ct = default) =>
        Pages<BitbucketPR.DiffStat>(PullPath(repo, id) + "/diffstat", 30, ct);

    public Task<string> Diff(string repo, int id, CancellationToken ct = default) => http.Text(PullPath(repo, id) + "/diff", ct: ct);

    public Task AddComment(string repo, int id, string body, JsonObject? inline = null, int? parent = null)
    {
        var json = new JsonObject { ["content"] = new JsonObject { ["raw"] = body } };
        if (inline is not null) json["inline"] = inline;
        if (parent is { } p) json["parent"] = new JsonObject { ["id"] = p };
        return http.Post(PullPath(repo, id) + "/comments", json);
    }

    public Task SetResolved(string repo, int id, int comment, bool resolved) =>
        http.Post($"{PullPath(repo, id)}/comments/{comment}/resolve", method: resolved ? "POST" : "DELETE");

    public Task Approve(string repo, int id, bool on) => http.Post(PullPath(repo, id) + "/approve", method: on ? "POST" : "DELETE");

    public Task RequestChanges(string repo, int id, bool on) => http.Post(PullPath(repo, id) + "/request-changes", method: on ? "POST" : "DELETE");

    public Task Merge(string repo, int id, string strategy, string? message, bool closeBranch)
    {
        var json = new JsonObject { ["type"] = "pullrequest", ["merge_strategy"] = strategy };
        if (closeBranch) json["close_source_branch"] = true;
        if (message is not null) json["message"] = message;
        return http.Post(PullPath(repo, id) + "/merge", json);
    }

    public Task Decline(string repo, int id) => http.Post(PullPath(repo, id) + "/decline");

    public Task UpdatePull(string repo, int id, JsonObject fields) => http.Post(PullPath(repo, id), fields, "PUT");

    public async Task<CommitDetailRest> Commit(string repo, string sha, CancellationToken ct = default)
    {
        var escaped = Uri.EscapeDataString(sha);
        var detailTask = http.Get<BitbucketPR.CommitInfo>($"{RepoPath(repo)}/commit/{escaped}", ct: ct);
        var statsTask = Pages<BitbucketPR.DiffStat>($"{RepoPath(repo)}/diffstat/{escaped}", 10, ct);
        var textTask = BitbucketPRBackend.Optional(http.Text($"{RepoPath(repo)}/diff/{escaped}", ct: ct));
        var c = await detailTask.ConfigureAwait(false);
        var files = BitbucketReviewMapper.Files(await statsTask.ConfigureAwait(false), await textTask.ConfigureAwait(false) ?? "");
        return new CommitDetailRest
        {
            Sha = c.Hash,
            HtmlUrl = c.Links?.Html?.Href ?? $"https://bitbucket.org/{repo}/commits/{c.Hash}",
            Commit = new CommitDetailRest.Inner
            {
                Message = c.Message ?? "",
                Author = new CommitDetailRest.Person { Name = BitbucketReviewMapper.AuthorName(c.Author), Date = c.Date }
            },
            Stats = new CommitDetailRest.StatsInfo { Additions = files.Sum(f => f.Additions), Deletions = files.Sum(f => f.Deletions) },
            Files = files
        };
    }

    private static readonly Regex BuildLink = new(@"(?:pipelines/results/|#!/results/)(\d+)", RegexOptions.Compiled);

    public static int? BuildNumber(string? link) =>
        link is not null && BuildLink.Match(link) is { Success: true } m && int.TryParse(m.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : null;

    public async Task<BitbucketPR.Pipeline> Pipeline(string repo, int build, CancellationToken ct = default)
    {
        try
        {
            return await http.Get<BitbucketPR.Pipeline>($"{RepoPath(repo)}/pipelines/{build}", ct: ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.Status is 404 or 400)
        {
            var page = await http.Get<BitbucketPR.Page<BitbucketPR.Pipeline>>($"{RepoPath(repo)}/pipelines/", new[] { ("sort", "-created_on"), ("pagelen", "100") }, ct).ConfigureAwait(false);
            if (page.Values?.FirstOrDefault(p => p.BuildNumber == build) is { } hit) return hit;
            throw;
        }
    }

    public async Task<string?> SourceFile(string repo, string commit, string path, CancellationToken ct = default)
    {
        var encoded = string.Join("/", path.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString));
        try
        {
            return await http.Text($"{RepoPath(repo)}/src/{Uri.EscapeDataString(commit)}/{encoded}", ct: ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.Status == (int)HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public Task<List<BitbucketPR.Step>> PipelineSteps(string repo, string pipeline, CancellationToken ct = default) =>
        Pages<BitbucketPR.Step>($"{RepoPath(repo)}/pipelines/{Uri.EscapeDataString(pipeline)}/steps/", 3, ct);

    public Task<string> StepLog(string repo, string pipeline, string step, CancellationToken ct = default) =>
        http.Download($"{RepoPath(repo)}/pipelines/{Uri.EscapeDataString(pipeline)}/steps/{Uri.EscapeDataString(step)}/log", ct: ct);

    public IPRBackend? ReviewBackend() => new BitbucketPRBackend(this);
}
