using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Api;

public enum OverviewTile { ReviewRequested, Mine, ReadyToMerge, Failing, ChangesRequested, Assigned, Mentioned, Reviewed }

public sealed class OverviewCounts
{
    public static IReadOnlyList<OverviewTile> Tiles { get; } = Enum.GetValues<OverviewTile>();

    private readonly Dictionary<OverviewTile, int> values;

    public OverviewCounts(IReadOnlyDictionary<OverviewTile, int> values, DateTimeOffset loadedAt)
    {
        this.values = new Dictionary<OverviewTile, int>(values);
        LoadedAt = loadedAt;
    }

    public DateTimeOffset LoadedAt { get; }

    public int? this[OverviewTile tile] => values.TryGetValue(tile, out var n) ? n : null;

    public int? Waiting => this[OverviewTile.ReviewRequested];

    public int Known => values.Count;

    public bool IsComplete => Tiles.All(values.ContainsKey);

    public OverviewCounts Over(OverviewCounts? previous)
    {
        if (previous is null || IsComplete) return this;
        var merged = new Dictionary<OverviewTile, int>(previous.values);
        foreach (var (tile, n) in values) merged[tile] = n;
        return new OverviewCounts(merged, LoadedAt);
    }

    public static string Alias(OverviewTile tile) => tile switch
    {
        OverviewTile.ReviewRequested => "rr",
        OverviewTile.Mine => "mine",
        OverviewTile.ReadyToMerge => "ready",
        OverviewTile.Failing => "failing",
        OverviewTile.ChangesRequested => "changes",
        OverviewTile.Assigned => "assigned",
        OverviewTile.Mentioned => "mentioned",
        _ => "reviewed"
    };

    public static string Filter(OverviewTile tile) => tile switch
    {
        OverviewTile.ReviewRequested => Demo.Query("review-requested:@me"),
        OverviewTile.Mine or OverviewTile.ReadyToMerge or OverviewTile.Failing or OverviewTile.ChangesRequested => Demo.Query("author:@me"),
        OverviewTile.Assigned => Demo.Query("assignee:@me"),
        OverviewTile.Mentioned => Demo.Query("mentions:@me"),
        _ => Demo.Query("reviewed-by:@me -author:@me")
    };

    public static string? Refine(OverviewTile tile) => tile switch
    {
        OverviewTile.ReadyToMerge => "review:approved status:success",
        OverviewTile.Failing => "status:failure",
        OverviewTile.ChangesRequested => "review:changes_requested",
        _ => null
    };

    public static string ListQuery(OverviewTile tile) => Refine(tile) is { } refine ? $"{Filter(tile)} {refine}" : Filter(tile);

    public static string SearchQuery(OverviewTile tile) => $"{ListQuery(tile)} is:pr is:open archived:false";

    public static string Query
    {
        get
        {
            var parameters = string.Join(", ", Tiles.Select(t => $"${Alias(t)}: String!"));
            var fields = string.Join(" ", Tiles.Select(t => $"{Alias(t)}: search(type: ISSUE, first: 0, query: ${Alias(t)}) {{ issueCount }}"));
            return $"query OverviewCounts({parameters}) {{ {fields} }}";
        }
    }

    public static Dictionary<string, object?> Variables() => Tiles.ToDictionary(Alias, t => (object?)SearchQuery(t));

    public static OverviewCounts Parse(JsonNode? data, DateTimeOffset loadedAt)
    {
        var root = data.Obj("data") ?? data;
        var found = new Dictionary<OverviewTile, int>();
        foreach (var tile in Tiles)
            if (root.Obj(Alias(tile)).Int("issueCount") is { } n && n >= 0) found[tile] = n;
        return new OverviewCounts(found, loadedAt);
    }

    public static OverviewCounts Parse(string json, DateTimeOffset loadedAt) => Parse(JsonNode.Parse(json), loadedAt);

    public static async Task<OverviewCounts> Load(GitHubApi api, CancellationToken ct = default)
    {
        var data = await api.GraphQL<JsonObject>(Query, Variables(), ct: ct).ConfigureAwait(false);
        return Parse(data, DateTimeOffset.Now);
    }
}
