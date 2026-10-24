using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public sealed record SessionNode(ClaudeSessionInfo Session, IReadOnlyList<ClaudeSessionInfo> Children)
{
    public string Id => Session.Id;
}

public static class SessionTree
{
    public static List<SessionNode> Build(IEnumerable<ClaudeSessionInfo> sessions)
    {
        var list = sessions.ToList();
        var ids = new HashSet<string>(list.Select(s => s.Id));
        var children = new Dictionary<string, List<ClaudeSessionInfo>>();
        var roots = new List<ClaudeSessionInfo>();
        foreach (var s in list)
        {
            if (s.ParentId is { } p && p != s.Id && ids.Contains(p))
            {
                if (!children.TryGetValue(p, out var c)) children[p] = c = new();
                c.Add(s);
            }
            else
            {
                roots.Add(s);
            }
        }
        return roots
            .Select(r => new SessionNode(r, children.TryGetValue(r.Id, out var c) ? c.OrderByDescending(x => x.Modified).ToList() : new List<ClaudeSessionInfo>()))
            .OrderByDescending(n => n.Children.Count > 0 && n.Children[0].Modified > n.Session.Modified ? n.Children[0].Modified : n.Session.Modified)
            .ToList();
    }
}

public enum SessionIndicator { None, Working, Done, Waiting }

public static class SessionIndicators
{
    public static readonly TimeSpan RecentWrite = TimeSpan.FromSeconds(15);

    public static SessionIndicator ForTab(ClaudeTabState state, bool unread) => state switch
    {
        ClaudeTabState.Waiting => SessionIndicator.Waiting,
        ClaudeTabState.Working => SessionIndicator.Working,
        _ => unread ? SessionIndicator.Done : SessionIndicator.None
    };

    public static SessionIndicator ForClosed(ClaudeSessionInfo session, SessionSeen seen, DateTimeOffset now)
    {
        if (now - session.Modified < RecentWrite) return SessionIndicator.Working;
        return seen.IsUnread(session.Id, session.Modified) ? SessionIndicator.Done : SessionIndicator.None;
    }
}

public sealed class SessionSeen
{
    private static SessionSeen? shared;
    public static SessionSeen Shared => shared ??= new SessionSeen(Settings.Shared, () => DateTimeOffset.Now);

    private readonly Settings settings;
    private readonly Func<DateTimeOffset> now;
    private readonly Dictionary<string, DateTimeOffset> seen;
    private readonly object gate = new();

    public DateTimeOffset Baseline { get; }

    public SessionSeen(Settings settings, Func<DateTimeOffset> now)
    {
        this.settings = settings;
        this.now = now;
        if (settings.GetDate(Keys.AgentsSeenBaseline) is { } b)
        {
            Baseline = b;
        }
        else
        {
            Baseline = now();
            settings.Set(Keys.AgentsSeenBaseline, Baseline);
        }
        seen = new Dictionary<string, DateTimeOffset>();
        foreach (var (k, v) in settings.GetObject<Dictionary<string, string>>(Keys.AgentsSeen) ?? new())
            if (DateTimeOffset.TryParse(v, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var d)) seen[k] = d;
    }

    public bool IsUnread(string id, DateTimeOffset modified)
    {
        lock (gate)
        {
            if (modified <= Baseline) return false;
            return !seen.TryGetValue(id, out var last) || modified > last.AddSeconds(2);
        }
    }

    public void Mark(string? id)
    {
        if (string.IsNullOrEmpty(id)) return;
        Dictionary<string, string> snapshot;
        lock (gate)
        {
            var t = now();
            if (seen.TryGetValue(id, out var last) && t - last < TimeSpan.FromSeconds(1)) return;
            seen[id] = t;
            if (seen.Count > 600)
                foreach (var k in seen.OrderBy(kv => kv.Value).Take(seen.Count - 500).Select(kv => kv.Key).ToList()) seen.Remove(k);
            snapshot = seen.ToDictionary(kv => kv.Key, kv => kv.Value.ToString("o"));
        }
        settings.Set(Keys.AgentsSeen, snapshot);
    }
}

public sealed class AgentSessionPrefs
{
    private static AgentSessionPrefs? shared;
    public static AgentSessionPrefs Shared => shared ??= new AgentSessionPrefs(Settings.Shared);

    private readonly Settings settings;
    private readonly List<string> pinned;
    private readonly Dictionary<string, string> titles;
    private readonly HashSet<string> archived;

    public event Action? Changed;

    public AgentSessionPrefs(Settings settings)
    {
        this.settings = settings;
        pinned = settings.GetObject<List<string>>(Keys.AgentsPinned) ?? new();
        titles = settings.GetObject<Dictionary<string, string>>(Keys.AgentsTitles) ?? new();
        archived = new HashSet<string>(settings.GetObject<List<string>>(Keys.AgentsArchived) ?? new());
    }

    public IReadOnlyList<string> Pinned => pinned;

    public bool IsPinned(string id) => pinned.Contains(id);

    public void TogglePin(string id)
    {
        if (!pinned.Remove(id)) pinned.Insert(0, id);
        settings.Set(Keys.AgentsPinned, pinned);
        Changed?.Invoke();
    }

    public string Title(ClaudeSessionInfo s) => titles.TryGetValue(s.Id, out var t) ? t : s.Title;

    public bool HasCustomTitle(string id) => titles.ContainsKey(id);

    public ClaudeSessionInfo Apply(ClaudeSessionInfo s) => titles.TryGetValue(s.Id, out var t) ? s.With(title: t) : s;

    public void Rename(string id, string title)
    {
        var t = title.Trim();
        if (t.Length == 0) titles.Remove(id);
        else titles[id] = t;
        settings.Set(Keys.AgentsTitles, titles);
        Changed?.Invoke();
    }

    public bool IsArchived(ClaudeSessionInfo s) => archived.Contains(s.Id) || s.Archived;

    public void SetArchived(string id, bool value)
    {
        if (value)
        {
            archived.Add(id);
            pinned.Remove(id);
        }
        else
        {
            archived.Remove(id);
        }
        settings.Set(Keys.AgentsArchived, archived.ToList());
        settings.Set(Keys.AgentsPinned, pinned);
        Changed?.Invoke();
    }
}
