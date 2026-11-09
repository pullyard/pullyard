using PullYard.Core.Auth;

namespace PullYard.Core.Api;

public enum PRAction { Close, Reopen, ReadyForReview, ConvertToDraft, UpdateBranch, DisableAutoMerge }

public sealed record PRLoad(string Viewer, PRRepository? Repository, string? Signature);

public sealed record PRFeatures
{
    public GitProvider Provider { get; init; }
    public bool Stack { get; init; }
    public bool LocalConflicts { get; init; }
    public bool ViewedFiles { get; init; }
    public bool RequestReviewers { get; init; }
    public bool Editing { get; init; }
    public bool DraftToggle { get; init; }
    public bool UpdateBranch { get; init; }
    public bool RerunChecks { get; init; }
    public bool JobLogs { get; init; }
    public bool RequestChanges { get; init; }
    public bool RevokeApproval { get; init; }
    public bool Agent { get; init; }
    public bool Blame { get; init; }
    public bool DeleteBranch { get; init; }
    public bool CodeOwners { get; init; }

    public static PRFeatures GitHub { get; } = new()
    {
        Provider = GitProvider.GitHub, Stack = true, LocalConflicts = true, ViewedFiles = true, RequestReviewers = true, Editing = true, DraftToggle = true,
        UpdateBranch = true, RerunChecks = true, JobLogs = true, RequestChanges = true, Agent = true, Blame = true, DeleteBranch = true, CodeOwners = true
    };

    public static PRFeatures GitLab { get; } = new() { Provider = GitProvider.GitLab, Editing = true, DraftToggle = true, UpdateBranch = true, RevokeApproval = true };

    public bool IsGitLab => Provider == GitProvider.GitLab;
    public bool IsGitHub => Provider.IsGitHub();
}

public sealed class PRBackendUnsupportedException : Exception
{
    public PRBackendUnsupportedException(GitProvider provider) : base($"Not available for {provider.Title()} yet")
    {
    }
}

public interface IPRBackend
{
    PRFeatures Features { get; }
    GitHubApi? GitHub => null;
    Task<PRLoad> Load(ItemRef r, CancellationToken ct = default);
    Task<string?> Pulse(ItemRef r, CancellationToken ct = default);
    Task<List<PRFile>> Files(ItemRef r, PullRequestDetail pr, CancellationToken ct = default);
    Task Comment(ItemRef r, PullRequestDetail pr, string body);
    Task SubmitReview(ItemRef r, PullRequestDetail pr, string @event, string body, IReadOnlyList<PendingComment> comments, IReadOnlyList<DiffFile> files);
    Task Reply(ItemRef r, string thread, string body);
    Task SetResolved(ItemRef r, string thread, bool resolved);
    Task<string?> Merge(ItemRef r, PullRequestDetail pr, string method, string? title, string? body, bool deleteBranch);
    Task EnableAutoMerge(ItemRef r, PullRequestDetail pr, string method);
    Task Perform(PRAction action, ItemRef r, PullRequestDetail pr);
    Task Edit(ItemRef r, PullRequestDetail pr, string title, string body);
    Task<CommitDetailRest> Commit(RepoRef repo, string sha);
    Task RevokeApproval(ItemRef r, PullRequestDetail pr) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));
    Task RequestReviewers(ItemRef r, IReadOnlyList<string> logins) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));
    Task DeleteBranch(ItemRef r, PullRequestDetail pr) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));
    Task SetViewed(ItemRef r, PullRequestDetail pr, string path, bool viewed) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));
    Task RerunFailed(ItemRef r, IReadOnlyCollection<long> runs) => Task.FromException(new PRBackendUnsupportedException(Features.Provider));
}

public sealed class GitHubPRBackend : IPRBackend
{
    private readonly GitHubApi api;

    public GitHubPRBackend(GitHubApi api, GitProvider provider = GitProvider.GitHub)
    {
        this.api = api;
        Features = PRFeatures.GitHub with { Provider = provider };
    }

    public PRFeatures Features { get; }
    public GitHubApi? GitHub => api;

    public async Task<PRLoad> Load(ItemRef r, CancellationToken ct = default)
    {
        var response = await api.PullRequest(r, ct).ConfigureAwait(false);
        var signature = response.Repository?.PullRequest is { } pr ? PullRequestSignature.Of(pr) : null;
        return new PRLoad(response.Viewer.Login, response.Repository, signature);
    }

    public async Task<string?> Pulse(ItemRef r, CancellationToken ct = default) =>
        await api.PullRequestPulse(r, ct).ConfigureAwait(false) is { } pulse ? PullRequestSignature.Of(pulse) : null;

    public Task<List<PRFile>> Files(ItemRef r, PullRequestDetail pr, CancellationToken ct = default) => api.PullRequestFiles(r, ct);

    public Task Comment(ItemRef r, PullRequestDetail pr, string body) => api.AddComment(pr.Id, body);

    public Task SubmitReview(ItemRef r, PullRequestDetail pr, string @event, string body, IReadOnlyList<PendingComment> comments, IReadOnlyList<DiffFile> files) =>
        api.AddReview(pr.Id, @event, body.Length == 0 && comments.Count > 0 ? null : body, comments);

    public Task Reply(ItemRef r, string thread, string body) => api.Mutate(Q.ReplyThread, Vars(("id", thread), ("b", body)));

    public Task SetResolved(ItemRef r, string thread, bool resolved) => api.Mutate(resolved ? Q.ResolveThread : Q.UnresolveThread, Vars(("id", thread)));

    public async Task<string?> Merge(ItemRef r, PullRequestDetail pr, string method, string? title, string? body, bool deleteBranch)
    {
        await api.Mutate(Q.Merge, Vars(("id", pr.Id), ("m", method), ("t", title), ("b", body))).ConfigureAwait(false);
        if (!deleteBranch || pr.HeadRepository?.NameWithOwner is not { } head) return null;
        try
        {
            await api.DeleteBranch(head, pr.HeadRefName).ConfigureAwait(false);
            return null;
        }
        catch (Exception e)
        {
            return e.Message;
        }
    }

    public Task EnableAutoMerge(ItemRef r, PullRequestDetail pr, string method) => api.Mutate(Q.EnableAutoMerge, Vars(("id", pr.Id), ("m", method)));

    public Task Perform(PRAction action, ItemRef r, PullRequestDetail pr)
    {
        var mutation = action switch
        {
            PRAction.Close => Q.ClosePR,
            PRAction.Reopen => Q.ReopenPR,
            PRAction.ReadyForReview => Q.ReadyForReview,
            PRAction.ConvertToDraft => Q.ConvertToDraft,
            PRAction.UpdateBranch => Q.UpdateBranch,
            _ => Q.DisableAutoMerge
        };
        return api.Mutate(mutation, Vars(("id", pr.Id)));
    }

    public Task Edit(ItemRef r, PullRequestDetail pr, string title, string body) => api.Mutate(Q.EditPR, Vars(("id", pr.Id), ("t", title), ("b", body)));

    public Task<CommitDetailRest> Commit(RepoRef repo, string sha) => api.Commit(repo, sha);

    public Task RequestReviewers(ItemRef r, IReadOnlyList<string> logins) => api.RequestReviewers(r, logins);

    public Task DeleteBranch(ItemRef r, PullRequestDetail pr) =>
        pr.HeadRepository?.NameWithOwner is { } head ? api.DeleteBranch(head, pr.HeadRefName) : Task.CompletedTask;

    public Task SetViewed(ItemRef r, PullRequestDetail pr, string path, bool viewed) =>
        api.Mutate(viewed ? Q.MarkViewed : Q.UnmarkViewed, Vars(("id", pr.Id), ("p", path)));

    public async Task RerunFailed(ItemRef r, IReadOnlyCollection<long> runs)
    {
        foreach (var id in runs) await api.RerunFailedJobs(r.Repo, id).ConfigureAwait(false);
    }

    private static Dictionary<string, object?> Vars(params (string, object?)[] pairs) => pairs.ToDictionary(p => p.Item1, p => p.Item2);
}
