using System.Text.Json.Nodes;
using PullYard.Core.Api;
using Xunit;

namespace PullYard.Core.Tests;

public class OverviewCountsTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 25, 9, 0, 0, TimeSpan.Zero);

    [Fact]
    public void QueryAliasesEverySearchInOneRequest()
    {
        var query = OverviewCounts.Query;
        Assert.StartsWith("query OverviewCounts(", query);
        foreach (var tile in OverviewCounts.Tiles)
        {
            var alias = OverviewCounts.Alias(tile);
            Assert.Contains($"${alias}: String!", query);
            Assert.Contains($"{alias}: search(type: ISSUE, first: 0, query: ${alias}) {{ issueCount }}", query);
        }
        Assert.Equal(OverviewCounts.Tiles.Count, OverviewCounts.Tiles.Select(OverviewCounts.Alias).Distinct().Count());
        Assert.DoesNotContain("nodes", query);
    }

    [Fact]
    public void VariablesCarryOpenPullRequestSearches()
    {
        var vars = OverviewCounts.Variables();
        Assert.Equal(OverviewCounts.Tiles.Count, vars.Count);
        Assert.Equal("review-requested:@me is:pr is:open archived:false", vars["rr"]);
        Assert.Equal("author:@me is:pr is:open archived:false", vars["mine"]);
        Assert.Equal("author:@me review:approved status:success is:pr is:open archived:false", vars["ready"]);
        Assert.Equal("author:@me status:failure is:pr is:open archived:false", vars["failing"]);
        Assert.Equal("author:@me review:changes_requested is:pr is:open archived:false", vars["changes"]);
        Assert.Equal("assignee:@me is:pr is:open archived:false", vars["assigned"]);
        Assert.Equal("mentions:@me is:pr is:open archived:false", vars["mentioned"]);
        Assert.Equal("reviewed-by:@me -author:@me is:pr is:open archived:false", vars["reviewed"]);
    }

    [Fact]
    public void ListQueryLeavesStateAndKindToTheList()
    {
        Assert.Equal("author:@me status:failure", OverviewCounts.ListQuery(OverviewTile.Failing));
        Assert.Equal("assignee:@me", OverviewCounts.ListQuery(OverviewTile.Assigned));
        Assert.Null(OverviewCounts.Refine(OverviewTile.Mine));
    }

    [Fact]
    public void ParsesAliasedCounts()
    {
        const string json = """
        {"rr":{"issueCount":3},"mine":{"issueCount":7},"ready":{"issueCount":2},"failing":{"issueCount":1},
         "changes":{"issueCount":0},"assigned":{"issueCount":4},"mentioned":{"issueCount":12},"reviewed":{"issueCount":30}}
        """;
        var counts = OverviewCounts.Parse(json, Now);
        Assert.True(counts.IsComplete);
        Assert.Equal(3, counts.Waiting);
        Assert.Equal(7, counts[OverviewTile.Mine]);
        Assert.Equal(2, counts[OverviewTile.ReadyToMerge]);
        Assert.Equal(1, counts[OverviewTile.Failing]);
        Assert.Equal(0, counts[OverviewTile.ChangesRequested]);
        Assert.Equal(4, counts[OverviewTile.Assigned]);
        Assert.Equal(12, counts[OverviewTile.Mentioned]);
        Assert.Equal(30, counts[OverviewTile.Reviewed]);
        Assert.Equal(Now, counts.LoadedAt);
    }

    [Fact]
    public void ParsesFullResponseEnvelope()
    {
        var counts = OverviewCounts.Parse("""{"data":{"mine":{"issueCount":5}},"errors":[{"message":"x"}]}""", Now);
        Assert.Equal(5, counts[OverviewTile.Mine]);
        Assert.Equal(1, counts.Known);
    }

    [Fact]
    public void SkipsNullMissingAndMalformedSearches()
    {
        var counts = OverviewCounts.Parse("""{"rr":null,"mine":{"issueCount":"9"},"ready":{},"failing":{"issueCount":-1},"changes":[1]}""", Now);
        Assert.Null(counts.Waiting);
        Assert.Null(counts[OverviewTile.Mine]);
        Assert.Null(counts[OverviewTile.ReadyToMerge]);
        Assert.Null(counts[OverviewTile.Failing]);
        Assert.Null(counts[OverviewTile.ChangesRequested]);
        Assert.False(counts.IsComplete);
        Assert.Equal(0, counts.Known);
        Assert.Equal(0, OverviewCounts.Parse((JsonNode?)null, Now).Known);
    }

    [Fact]
    public void PartialResultKeepsPreviousCounts()
    {
        var previous = OverviewCounts.Parse("""{"rr":{"issueCount":1},"failing":{"issueCount":4}}""", Now.AddMinutes(-5));
        var partial = OverviewCounts.Parse("""{"rr":{"issueCount":2},"failing":null}""", Now);
        var merged = partial.Over(previous);
        Assert.Equal(2, merged.Waiting);
        Assert.Equal(4, merged[OverviewTile.Failing]);
        Assert.Equal(Now, merged.LoadedAt);
        Assert.Same(partial, partial.Over(null));
    }

    [Fact]
    public void CompleteResultReplacesPreviousCounts()
    {
        var previous = OverviewCounts.Parse("""{"rr":{"issueCount":9}}""", Now.AddMinutes(-5));
        var complete = new OverviewCounts(OverviewCounts.Tiles.ToDictionary(t => t, _ => 0), Now);
        Assert.Same(complete, complete.Over(previous));
        Assert.Equal(0, complete.Waiting);
    }
}
