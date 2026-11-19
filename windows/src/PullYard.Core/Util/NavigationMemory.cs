using PullYard.Core.Api;

namespace PullYard.Core.Util;

public static class NavigationMemory
{
    public static string? Encode(Route route, string? account)
    {
        var owner = account ?? "";
        return route.Kind switch
        {
            RouteKind.PullRequest when route.Item is { } r => $"{owner}|pr|{r.Repo.Full}|{r.Number}",
            RouteKind.Issue when route.Item is { } r => $"{owner}|issue|{r.Repo.Full}|{r.Number}",
            RouteKind.Repo when route.Repo is { } repo => $"{owner}|repo|{repo.Full}|0",
            _ => null
        };
    }

    public static Route? Decode(string? stored, string? account)
    {
        if (string.IsNullOrEmpty(stored)) return null;
        var parts = stored.Split('|');
        if (parts.Length != 4 || parts[0] != (account ?? "")) return null;
        if (RepoRef.Parse(parts[2]) is not { } repo) return null;
        switch (parts[1])
        {
            case "pr":
                return int.TryParse(parts[3], out var pr) ? Route.Pr(new ItemRef(repo, pr)) : null;
            case "issue":
                return int.TryParse(parts[3], out var issue) ? Route.Issue(new ItemRef(repo, issue)) : null;
            case "repo":
                return Route.ForRepo(repo);
            default:
                return null;
        }
    }

    public static string? NormalizeSection(string? stored, IEnumerable<string> known, string fallbackPrs, string fallbackIssues)
    {
        if (string.IsNullOrEmpty(stored)) return null;
        var all = known as ICollection<string> ?? known.ToList();
        if (all.Contains(stored)) return stored;
        if (stored.StartsWith("prs:", StringComparison.Ordinal)) return fallbackPrs;
        if (stored.StartsWith("issues:", StringComparison.Ordinal)) return fallbackIssues;
        return null;
    }
}

public sealed class RouteHistory
{
    private readonly List<Route> forward = new();

    public IReadOnlyList<Route> Forward => forward;

    public bool CanGoForward => forward.Count > 0;

    public void WentBack(Route left) => forward.Add(left);

    public Route? TakeForward()
    {
        if (forward.Count == 0) return null;
        var next = forward[^1];
        forward.RemoveAt(forward.Count - 1);
        return next;
    }

    public void Navigated() => forward.Clear();
}

public enum ListSort { Updated, Created, Comments }

public static class ListSorts
{
    public static readonly ListSort[] All = { ListSort.Updated, ListSort.Created, ListSort.Comments };

    public static string Query(this ListSort sort) => sort switch
    {
        ListSort.Created => "sort:created-desc",
        ListSort.Comments => "sort:comments-desc",
        _ => "sort:updated-desc"
    };

    public static string Key(this ListSort sort) => sort switch
    {
        ListSort.Created => "created",
        ListSort.Comments => "comments",
        _ => "updated"
    };

    public static ListSort Parse(string? key) => key switch
    {
        "created" => ListSort.Created,
        "comments" => ListSort.Comments,
        _ => ListSort.Updated
    };
}

public sealed class DropHover
{
    public static readonly TimeSpan IgnoreAfterDrop = TimeSpan.FromMilliseconds(600);

    private DateTimeOffset ignoredUntil = DateTimeOffset.MinValue;

    public bool Targeted { get; private set; }

    public void Set(bool on, DateTimeOffset? now = null)
    {
        if (on && (now ?? DateTimeOffset.Now) < ignoredUntil) return;
        Targeted = on;
    }

    public void FinishDrop(DateTimeOffset? now = null)
    {
        ignoredUntil = (now ?? DateTimeOffset.Now) + IgnoreAfterDrop;
        Targeted = false;
    }
}
