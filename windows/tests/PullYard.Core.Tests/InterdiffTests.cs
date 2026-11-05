using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class InterdiffTests
{
    private static PullRequestDetail Pr(JsonArray? timeline = null, JsonArray? latest = null, string[]? commits = null, string head = "c3")
    {
        var oids = commits ?? new[] { "c1", "c2", "c3" };
        var commitNodes = new JsonArray();
        foreach (var oid in oids)
            commitNodes.Add(new JsonObject { ["commit"] = new JsonObject { ["oid"] = oid, ["abbreviatedOid"] = oid, ["messageHeadline"] = "m", ["committedDate"] = "2026-01-01T00:00:00Z", ["url"] = "u" } });
        var json = new JsonObject
        {
            ["id"] = "PR_1", ["number"] = 1, ["title"] = "T", ["url"] = "u", ["state"] = "OPEN", ["isDraft"] = false, ["merged"] = false,
            ["mergeable"] = "MERGEABLE", ["body"] = "", ["bodyHTML"] = "", ["createdAt"] = "2026-01-01T00:00:00Z",
            ["headRefName"] = "f", ["baseRefName"] = "main", ["headRefOid"] = head, ["additions"] = 1, ["deletions"] = 1, ["changedFiles"] = 1,
            ["viewerCanUpdate"] = true, ["viewerDidAuthor"] = false,
            ["labels"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["assignees"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["reviewRequests"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["latestOpinionatedReviews"] = new JsonObject { ["nodes"] = latest ?? new JsonArray() },
            ["lastCommit"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["allCommits"] = new JsonObject { ["nodes"] = commitNodes },
            ["timelineItems"] = new JsonObject { ["nodes"] = timeline ?? new JsonArray() },
            ["reviewThreads"] = new JsonObject { ["nodes"] = new JsonArray() }
        };
        return JsonSerializer.Deserialize<PullRequestDetail>(json.ToJsonString(), Json.GraphQL)!;
    }

    private static JsonObject Review(string login, string oid, string date, string state = "COMMENTED") => new()
    {
        ["__typename"] = "PullRequestReview", ["state"] = state, ["createdAt"] = date,
        ["author"] = new JsonObject { ["login"] = login, ["avatarUrl"] = "" },
        ["commit"] = new JsonObject { ["oid"] = oid }
    };

    [Fact]
    public void PicksViewersLatestReviewIncludingComments()
    {
        var p = Pr(new JsonArray(
            Review("me", "c1", "2026-01-02T00:00:00Z", "APPROVED"),
            Review("other", "c2", "2026-01-04T00:00:00Z"),
            Review("Me", "c2", "2026-01-03T00:00:00Z")));
        var r = Interdiff.LastReviewed(p, "me");
        Assert.NotNull(r);
        Assert.Equal("c2", r!.Oid);
        Assert.Equal(1, r.CommitsSince);
        Assert.False(r.Rewritten);
    }

    [Fact]
    public void FallsBackToLatestOpinionatedReviews()
    {
        var latest = new JsonArray(new JsonObject
        {
            ["state"] = "APPROVED", ["submittedAt"] = "2026-01-02T00:00:00Z",
            ["commit"] = new JsonObject { ["oid"] = "c1" },
            ["author"] = new JsonObject { ["login"] = "me", ["avatarUrl"] = "" }
        });
        var r = Interdiff.LastReviewed(Pr(latest: latest), "me");
        Assert.NotNull(r);
        Assert.Equal("c1", r!.Oid);
        Assert.Equal(2, r.CommitsSince);
    }

    [Fact]
    public void NothingWhenReviewedHeadOrNeverReviewed()
    {
        Assert.Null(Interdiff.LastReviewed(Pr(new JsonArray(Review("me", "c3", "2026-01-02T00:00:00Z"))), "me"));
        Assert.Null(Interdiff.LastReviewed(Pr(new JsonArray(Review("other", "c1", "2026-01-02T00:00:00Z"))), "me"));
        Assert.Null(Interdiff.LastReviewed(Pr(new JsonArray(Review("me", "c1", "2026-01-02T00:00:00Z"))), ""));
    }

    [Fact]
    public void ForcePushedCommitIsRewritten()
    {
        var r = Interdiff.LastReviewed(Pr(new JsonArray(Review("me", "gone", "2026-01-02T00:00:00Z"))), "me");
        Assert.NotNull(r);
        Assert.True(r!.Rewritten);
        Assert.Null(r.CommitsSince);
    }

    [Fact]
    public void CompareResultDecodesSnakeCase()
    {
        const string json = """{"status":"diverged","ahead_by":2,"behind_by":3,"files":[{"filename":"a.swift","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1,2 @@\n a\n+b","previous_filename":null}]}""";
        var r = JsonSerializer.Deserialize<CompareResult>(json, Json.Rest)!;
        Assert.Equal(3, r.BehindBy);
        Assert.Equal(new[] { "a.swift" }, r.Files!.Select(f => f.Filename));
        Assert.Single(new DiffFile(r.Files![0]).Lines, l => l.Kind == DiffLineKind.Add);
    }

    [Fact]
    public void TimelineQueryCarriesReviewCommit()
    {
        Assert.Contains("... on PullRequestReview { id author { login avatarUrl } state body bodyHTML createdAt url commit { oid } }", Q.PullRequest);
    }
}
