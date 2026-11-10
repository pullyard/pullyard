using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PullYard.Core.Git;
using PullYard.Core.Jira;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public static partial class AgentShip
{
    private static readonly string[] DefaultBranches = { "main", "master", "develop" };

    public static string OpenPRPrompt(string branch, string? defaultBranch, bool hasChanges, int ahead, GitRemote? remote = null)
    {
        var onDefault = defaultBranch is not null ? defaultBranch == branch : DefaultBranches.Contains(branch);
        var steps = new List<string>();
        if (onDefault)
            steps.Add($"We are on the default branch `{branch}`. Create a new branch with a short descriptive name for this work first.");
        if (hasChanges)
            steps.Add("Commit the current changes with a clear, conventional commit message. Do not commit secrets, build output or unrelated files.");
        else if (ahead == 0 && !onDefault)
            steps.Add("There are no local changes or unpushed commits. If there is nothing to open a pull request for, say so and stop.");
        steps.Add("Push the branch to origin and set the upstream.");
        if (!onDefault && JiraFollowUp.ShipStep(branch) is { } jira) steps.Add(jira);
        var target = defaultBranch ?? "the default branch";
        switch (remote?.Kind ?? GitRemoteKind.GitHub)
        {
            case GitRemoteKind.GitHub:
                steps.Add("Open a pull request with `gh pr create`. Write a concise title and a description with a short summary, the list of changes and how it was tested.");
                steps.Add("Reply with the pull request URL on its own line.");
                break;
            case GitRemoteKind.GitLab:
                steps.Add($"Open a merge request into {target}. If `glab` is installed and signed in, use `glab mr create` with a concise title and a description (short summary, list of changes, how it was tested). Otherwise create it while pushing: `git push -u origin HEAD -o merge_request.create -o merge_request.target=<target branch> -o merge_request.title=\"<title>\"`, then show the description you would add.");
                steps.Add("Reply with the merge request URL on its own line.");
                break;
            case GitRemoteKind.Bitbucket:
                steps.Add("Bitbucket has no command-line tool for pull requests here, so do not try to create it. Write a concise title and a description (short summary, list of changes, how it was tested) for me to paste.");
                steps.Add($"Reply with the create link {remote?.NewRequestUrl(branch) ?? "Bitbucket printed after the push"} on its own line.");
                break;
            default:
                steps.Add("If the push output contains a link to create a pull request, reply with it on its own line, together with a concise title and description. Otherwise just confirm the push.");
                break;
        }
        var noun = remote?.Noun ?? "pull request";
        return $"Open a {noun} for this work:\n" + string.Join("\n", steps.Select((s, i) => $"{i + 1}. {s}"));
    }

    public static string CommitPrompt(int pr) =>
        $"Commit the current changes with a clear message and push them so pull request #{pr} is updated. Reply with a one-line summary.";

    public static readonly string[] CreateCommands = { "gh pr create", "glab mr create", "merge_request.create" };

    [GeneratedRegex(@"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull/\d+")]
    private static partial Regex PullUrl();

    [GeneratedRegex(@"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-/]+/-/merge_requests/\d+")]
    private static partial Regex MergeRequestUrl();

    [GeneratedRegex(@"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull-requests/\d+")]
    private static partial Regex BitbucketPullUrl();

    public static string? PullRequestUrl(string? text)
    {
        if (text is null) return null;
        return new[] { PullUrl().Match(text), MergeRequestUrl().Match(text), BitbucketPullUrl().Match(text) }
            .Where(m => m.Success)
            .OrderBy(m => m.Index)
            .FirstOrDefault()?.Value;
    }

    public static bool CreatesPullRequest(ToolItem tool) => tool.Name == "Bash" && tool.Input.Str("command") is { } command && CreateCommands.Any(command.Contains);

    public static string? CreatedPullRequest(ToolItem tool)
    {
        if (!CreatesPullRequest(tool) || tool.Status == ToolStatus.Error) return null;
        return PullRequestUrl(tool.ResultText) ?? PullRequestUrl(tool.Structured.Str("stdout"));
    }

    public static (int Number, string Repo)? ParsePullRequestUrl(string url) =>
        Describe(url) is { } r && int.TryParse(r.Number, out var n) ? (n, r.Repo) : null;

    public static CreatedRequest? Describe(string url)
    {
        var number = url.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return number.Length > 0 ? new CreatedRequest("", number, false) : null;
        var parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.IndexOf(parts, "-");
        if (i >= 0 && parts.Length > i + 1 && parts[i + 1] == "merge_requests")
            return new CreatedRequest(string.Join("/", parts[..i]), number, true);
        return new CreatedRequest(parts.Length >= 2 ? $"{parts[0]}/{parts[1]}" : "", number, false);
    }
}

public sealed record CreatedRequest(string Repo, string Number, bool MergeRequest)
{
    public string Title => MergeRequest ? $"Merge request !{Number} is open" : $"Pull request #{Number} is open";
}

public enum WelcomeSuggestionKind { ReviewChanges, OpenPR, AddressReview, ExplainStructure, FindBugs, WriteTests }

public sealed record WelcomeSuggestion(WelcomeSuggestionKind Kind, string Prompt, int? PullRequest = null);

public static class AgentWelcome
{
    public static List<WelcomeSuggestion> Suggestions(int changed, string? branch, bool hasRepo, int ahead, int? prNumber, string? prUrl) =>
        Build(changed, branch, hasRepo, null, ahead, prNumber, prUrl);

    public static List<WelcomeSuggestion> Suggestions(int changed, string? branch, GitRemote? remote, int ahead, int? prNumber, string? prUrl) =>
        Build(changed, branch, remote is not null, remote, ahead, prNumber, prUrl);

    private static List<WelcomeSuggestion> Build(int changed, string? branch, bool canOpen, GitRemote? remote, int ahead, int? prNumber, string? prUrl)
    {
        var list = new List<WelcomeSuggestion>();
        if (changed > 0)
        {
            list.Add(new(WelcomeSuggestionKind.ReviewChanges, "Review my uncommitted changes (git diff HEAD). Point out bugs, risky parts and missing tests."));
            if (branch is { Length: > 0 } b && b != "HEAD" && canOpen && prNumber is null)
                list.Add(new(WelcomeSuggestionKind.OpenPR, AgentShip.OpenPRPrompt(b, null, true, ahead, remote)));
        }
        if (prNumber is { } n)
        {
            var link = prUrl is { Length: > 0 } u ? $" ({u})" : "";
            list.Add(new(WelcomeSuggestionKind.AddressReview, $"Read the review comments on pull request #{n}{link} with gh, fix what is valid and reply to what is not.", n));
        }
        list.Add(new(WelcomeSuggestionKind.ExplainStructure, "Explain the project structure: main modules, how they connect, and where to start reading."));
        list.Add(new(WelcomeSuggestionKind.FindBugs, "Look at the last few commits and find likely bugs or regressions."));
        list.Add(new(WelcomeSuggestionKind.WriteTests, "Write tests for the code changed on this branch, following the existing test style."));
        return list.Take(4).ToList();
    }
}

public sealed record TodoEntry(string Title, string Active, string Status);

public sealed record TodoProgress(int Done, int Total, string? Current, IReadOnlyList<TodoEntry> Todos)
{
    public bool Finished => Done >= Total;

    public static TodoProgress? Latest(IReadOnlyList<ChatItem> items)
    {
        for (var i = items.Count - 1; i >= 0; i--)
        {
            if (items[i] is ToolItem { Name: "TodoWrite", ParentToolUseId: null } t && t.Input.Arr("todos") is { } arr)
                return From(arr);
        }
        return null;
    }

    public static TodoProgress? From(JsonArray todos)
    {
        var list = todos.Objects()
            .Select(t =>
            {
                var title = t.Str("content") ?? t.Str("subject") ?? "";
                return new TodoEntry(title, t.Str("activeForm") is { Length: > 0 } a ? a : title, t.Str("status") ?? "pending");
            })
            .ToList();
        if (list.Count == 0) return null;
        var done = list.Count(t => t.Status == "completed");
        var current = list.FirstOrDefault(t => t.Status == "in_progress") ?? list.FirstOrDefault(t => t.Status != "completed");
        return new TodoProgress(done, list.Count, current?.Active, list);
    }

    public JsonObject ToJson() => new()
    {
        ["done"] = Done,
        ["total"] = Total,
        ["current"] = Current,
        ["todos"] = new JsonArray(Todos.Select(t => (JsonNode)new JsonObject { ["title"] = t.Title, ["status"] = t.Status }).ToArray())
    };
}
