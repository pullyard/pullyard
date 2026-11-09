using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class ReviewLoadTests
{
    [Fact]
    public void ValidAcceptsLoginsAndTeams()
    {
        Assert.True(ReviewLoad.Valid("alice"));
        Assert.True(ReviewLoad.Valid("my-org/core_team.v2"));
        Assert.False(ReviewLoad.Valid(""));
        Assert.False(ReviewLoad.Valid("a\" b"));
        Assert.False(ReviewLoad.Valid("bob) { x }"));
        Assert.False(ReviewLoad.Valid(new string('a', 101)));
        Assert.True(ReviewLoad.Valid(new string('a', 100)));
    }

    [Fact]
    public void QueryUsesAliasesAndTeamQualifier()
    {
        var (query, aliases) = ReviewLoad.Query(new[] { "alice", "bad name", "org/team" });
        Assert.Equal(2, aliases.Count);
        Assert.Equal("alice", aliases["r0"]);
        Assert.Equal("org/team", aliases["r1"]);
        Assert.Contains("r0: search(query: \"is:pr is:open archived:false review-requested:alice\", type: ISSUE, first: 0) { issueCount }", query);
        Assert.Contains("r1: search(query: \"is:pr is:open archived:false team-review-requested:org/team\", type: ISSUE, first: 0) { issueCount }", query);
        Assert.StartsWith("query { ", query);
        Assert.DoesNotContain("bad", query);
    }

    [Fact]
    public void QueryCapsAtTwenty()
    {
        var (query, aliases) = ReviewLoad.Query(Enumerable.Range(0, 30).Select(i => $"u{i}"));
        Assert.Equal(ReviewLoad.MaxPerQuery, aliases.Count);
        Assert.Contains("r19:", query);
        Assert.DoesNotContain("r20:", query);
    }

    [Fact]
    public void ParseKeysByLowercasedHandle()
    {
        var data = JsonSerializer.Deserialize<Dictionary<string, ReviewLoad.Hit?>>("{\"r0\":{\"issueCount\":3},\"r1\":null}", Json.GraphQL)!;
        var counts = ReviewLoad.Parse(data, new Dictionary<string, string> { ["r0"] = "Alice", ["r1"] = "bob", ["r2"] = "carol" });
        Assert.Equal(new Dictionary<string, int> { ["alice"] = 3 }, counts);
    }

    [Fact]
    public void LabelAndBusy()
    {
        Assert.Equal("1 open review", ReviewLoad.Label(1));
        Assert.Equal("0 open reviews", ReviewLoad.Label(0));
        Assert.Equal("12 open reviews", ReviewLoad.Label(12));
        Assert.False(ReviewLoad.Busy(9));
        Assert.True(ReviewLoad.Busy(10));
    }

    [Fact]
    public async Task StoreBatchesCachesAndIgnoresFailures()
    {
        var clock = DateTimeOffset.UtcNow;
        var store = new ReviewLoadStore(() => clock);
        var queries = new List<string>();
        Task<Dictionary<string, ReviewLoad.Hit?>> Fetch(string q)
        {
            queries.Add(q);
            if (queries.Count == 2) throw new ApiException("boom");
            var n = q.Split("search(").Length - 1;
            return Task.FromResult(Enumerable.Range(0, n).ToDictionary(i => $"r{i}", i => (ReviewLoad.Hit?)new ReviewLoad.Hit { IssueCount = i }));
        }
        var handles = Enumerable.Range(0, 25).Select(i => $"User{i}").Append("bad name").ToList();
        var first = await store.Load(handles, Fetch);
        Assert.Equal(2, queries.Count);
        Assert.Equal(20, first.Count);
        Assert.Equal(5, first["user5"]);
        Assert.Equal(5, store.Cached("USER5"));

        await store.Load(handles.Take(20), Fetch);
        Assert.Equal(2, queries.Count);

        clock += TimeSpan.FromMinutes(11);
        Assert.Null(store.Cached("user5"));
        await store.Load(new[] { "user5" }, Fetch);
        Assert.Equal(3, queries.Count);
    }
}
