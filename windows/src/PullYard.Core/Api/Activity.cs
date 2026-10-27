using PullYard.Core.Util;

namespace PullYard.Core.Api;

public enum NotifyKind { ReviewRequest, CiFailed, ReviewDecision, AgentInput, AgentFinished }

public static class NotifyKinds
{
    public static IReadOnlyList<NotifyKind> All { get; } = Enum.GetValues<NotifyKind>();

    public static string Key(this NotifyKind kind) => "notify." + kind switch
    {
        NotifyKind.ReviewRequest => "reviewRequest",
        NotifyKind.CiFailed => "ciFailed",
        NotifyKind.ReviewDecision => "reviewDecision",
        NotifyKind.AgentInput => "agentInput",
        _ => "agentFinished"
    };

    public static bool IsAgent(this NotifyKind kind) => kind is NotifyKind.AgentInput or NotifyKind.AgentFinished;

    public static bool Enabled(this NotifyKind kind, Settings settings)
    {
        if (settings.Contains(kind.Key())) return settings.GetBool(kind.Key(), true);
        if (kind.IsAgent() && settings.Contains(Keys.AgentsNotify)) return settings.GetBool(Keys.AgentsNotify, true);
        return true;
    }

    public static void SetEnabled(this NotifyKind kind, Settings settings, bool on) => settings.Set(kind.Key(), on);
}

public sealed record ActivityItem(string Id, ItemRef Ref, string Title, DateTimeOffset UpdatedAt, string? CiState, string? ReviewDecision)
{
    public static ActivityItem From(SearchItem item) => new(item.Id, item.Ref, item.Title, item.UpdatedAt, item.CiState, item.ReviewDecision);
}

public enum ActivityEventType { ReviewRequested, CiFailed, Approved, ChangesRequested }

public sealed record ActivityEvent(ActivityEventType Type, ActivityItem Item)
{
    public NotifyKind Kind => Type switch
    {
        ActivityEventType.ReviewRequested => NotifyKind.ReviewRequest,
        ActivityEventType.CiFailed => NotifyKind.CiFailed,
        _ => NotifyKind.ReviewDecision
    };

    public string Key
    {
        get
        {
            var tag = Type switch
            {
                ActivityEventType.ReviewRequested => "rr",
                ActivityEventType.CiFailed => "ci",
                ActivityEventType.Approved => "approved",
                _ => "changes"
            };
            return $"{tag}|{Item.Id}|{Item.UpdatedAt.ToUnixTimeSeconds()}";
        }
    }
}

public sealed class ActivityTracker
{
    private static readonly HashSet<string> Failing = new() { "FAILURE", "ERROR" };

    private bool reviewsPrimed;
    private bool minePrimed;
    private HashSet<string> reviewIds = new();
    private int reviewTotal;
    private HashSet<string> mineIds = new();
    private Dictionary<string, string> ci = new();
    private Dictionary<string, string> decisions = new();

    public static bool IsFailing(string? state) => state is not null && Failing.Contains(state);

    public List<ActivityEvent> Update(IReadOnlyList<ActivityItem>? reviews, int total, IReadOnlyList<ActivityItem>? mine)
    {
        var events = new List<ActivityEvent>();
        if (reviews is not null)
        {
            if (reviewsPrimed)
            {
                var fresh = reviews.Where(r => !reviewIds.Contains(r.Id));
                if (total > reviews.Count) fresh = fresh.Take(Math.Max(0, total - reviewTotal));
                events.AddRange(fresh.Select(r => new ActivityEvent(ActivityEventType.ReviewRequested, r)));
            }
            reviewIds = reviews.Select(r => r.Id).ToHashSet();
            reviewTotal = total;
            reviewsPrimed = true;
        }
        if (mine is not null)
        {
            if (minePrimed)
            {
                foreach (var item in mine.Where(i => mineIds.Contains(i.Id)))
                {
                    if (IsFailing(item.CiState) && !IsFailing(ci.GetValueOrDefault(item.Id))) events.Add(new ActivityEvent(ActivityEventType.CiFailed, item));
                    if (item.ReviewDecision != decisions.GetValueOrDefault(item.Id))
                    {
                        switch (item.ReviewDecision)
                        {
                            case "APPROVED":
                                events.Add(new ActivityEvent(ActivityEventType.Approved, item));
                                break;
                            case "CHANGES_REQUESTED":
                                events.Add(new ActivityEvent(ActivityEventType.ChangesRequested, item));
                                break;
                        }
                    }
                }
            }
            mineIds = mine.Select(i => i.Id).ToHashSet();
            ci = new Dictionary<string, string>();
            decisions = new Dictionary<string, string>();
            foreach (var item in mine)
            {
                if (item.CiState is { } state) ci.TryAdd(item.Id, state);
                if (item.ReviewDecision is { } decision) decisions.TryAdd(item.Id, decision);
            }
            minePrimed = true;
        }
        return events;
    }
}

public sealed class RecentEvents
{
    private readonly List<string> keys;

    public RecentEvents(IEnumerable<string>? keys = null, int limit = 300)
    {
        Limit = limit;
        var all = (keys ?? Enumerable.Empty<string>()).ToList();
        this.keys = all.Skip(Math.Max(0, all.Count - limit)).ToList();
    }

    public int Limit { get; }

    public IReadOnlyList<string> Keys => keys;

    public bool Contains(string key) => keys.Contains(key);

    public bool Insert(string key)
    {
        if (keys.Contains(key)) return false;
        keys.Add(key);
        if (keys.Count > Limit) keys.RemoveRange(0, keys.Count - Limit);
        return true;
    }
}

public sealed record ActivityTarget(string Url, string Repo, int Number, string? Account)
{
    public const string Prefix = "activity:";

    public string Encode() => Prefix + string.Join("|", Uri.EscapeDataString(Repo), Number.ToString(System.Globalization.CultureInfo.InvariantCulture), Uri.EscapeDataString(Account ?? ""), Uri.EscapeDataString(Url));

    public static ActivityTarget? Decode(string? action)
    {
        if (action is null || !action.StartsWith(Prefix, StringComparison.Ordinal)) return null;
        var parts = action[Prefix.Length..].Split('|');
        if (parts.Length != 4 || !int.TryParse(parts[1], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var number)) return null;
        var repo = Uri.UnescapeDataString(parts[0]);
        var url = Uri.UnescapeDataString(parts[3]);
        if (repo.Length == 0 || url.Length == 0) return null;
        var account = Uri.UnescapeDataString(parts[2]);
        return new ActivityTarget(url, repo, number, account.Length == 0 ? null : account);
    }
}

public static class TaskbarCount
{
    public const string EnabledKey = "taskbar.badge";
    public const string AgentsKey = "taskbar.badge.agents";

    public static int Count(int reviews, int agents, bool enabled, bool includesAgents)
    {
        if (!enabled) return 0;
        return Math.Max(0, reviews) + (includesAgents ? Math.Max(0, agents) : 0);
    }
}
