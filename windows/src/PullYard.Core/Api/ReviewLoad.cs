namespace PullYard.Core.Api;

public static class ReviewLoad
{
    public static readonly TimeSpan Ttl = TimeSpan.FromMinutes(10);
    public const int MaxPerQuery = 20;

    public sealed class Hit
    {
        public int IssueCount { get; set; }
    }

    public static bool Valid(string handle) =>
        handle.Length > 0 && handle.Length <= 100 && handle.All(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '/' or '.');

    public static (string Query, Dictionary<string, string> Aliases) Query(IEnumerable<string> handles)
    {
        var aliases = new Dictionary<string, string>();
        var parts = new List<string>();
        var i = 0;
        foreach (var h in handles.Where(Valid).Take(MaxPerQuery))
        {
            var alias = $"r{i++}";
            aliases[alias] = h;
            var qualifier = h.Contains('/') ? $"team-review-requested:{h}" : $"review-requested:{h}";
            parts.Add($"{alias}: search(query: \"is:pr is:open archived:false {qualifier}\", type: ISSUE, first: 0) {{ issueCount }}");
        }
        return ("query { " + string.Join(" ", parts) + " }", aliases);
    }

    public static Dictionary<string, int> Parse(IReadOnlyDictionary<string, Hit?> data, IReadOnlyDictionary<string, string> aliases)
    {
        var result = new Dictionary<string, int>();
        foreach (var (alias, handle) in aliases)
            if (data.TryGetValue(alias, out var hit) && hit is not null) result[handle.ToLowerInvariant()] = hit.IssueCount;
        return result;
    }

    public static string Label(int count) => count == 1 ? "1 open review" : $"{count} open reviews";

    public static bool Busy(int count) => count >= 10;
}

public sealed class ReviewLoadStore
{
    public static ReviewLoadStore Shared { get; } = new();

    private readonly Dictionary<string, (int Count, DateTimeOffset At)> cache = new();
    private readonly object gate = new();
    private readonly Func<DateTimeOffset> now;

    public ReviewLoadStore(Func<DateTimeOffset>? now = null) => this.now = now ?? (() => DateTimeOffset.UtcNow);

    public int? Cached(string handle)
    {
        lock (gate)
            return cache.TryGetValue(handle.ToLowerInvariant(), out var hit) && now() - hit.At < ReviewLoad.Ttl ? hit.Count : null;
    }

    public Task<Dictionary<string, int>> Load(IEnumerable<string> handles, GitHubApi api, CancellationToken ct = default) =>
        Load(handles, q => api.GraphQL<Dictionary<string, ReviewLoad.Hit?>>(q, ct: ct));

    public async Task<Dictionary<string, int>> Load(IEnumerable<string> handles, Func<string, Task<Dictionary<string, ReviewLoad.Hit?>>> fetch)
    {
        var result = new Dictionary<string, int>();
        var missing = new List<string>();
        var seen = new HashSet<string>();
        foreach (var h in handles)
        {
            if (!seen.Add(h.ToLowerInvariant())) continue;
            if (Cached(h) is { } n) result[h.ToLowerInvariant()] = n;
            else if (ReviewLoad.Valid(h)) missing.Add(h);
        }
        foreach (var chunk in missing.Chunk(ReviewLoad.MaxPerQuery))
        {
            var (query, aliases) = ReviewLoad.Query(chunk);
            Dictionary<string, ReviewLoad.Hit?> data;
            try
            {
                data = await fetch(query).ConfigureAwait(false);
            }
            catch
            {
                continue;
            }
            foreach (var (handle, n) in ReviewLoad.Parse(data, aliases))
            {
                lock (gate) cache[handle] = (n, now());
                result[handle] = n;
            }
        }
        return result;
    }
}
