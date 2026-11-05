using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class CodeOwnersTests
{
    private const string Sample = """
    # comment
    *       @global-owner1 @global-owner2
    *.js    @js-owner #This is an inline comment.
    *.go docs@example.com
    *.txt @octo-org/octocats
    /build/logs/ @doctocat
    docs/*  docs@example.com
    apps/ @octocat
    /docs/ @doctocat
    /scripts/ @doctocat @octocat
    **/logs @octocat
    /apps/ @octocat
    /apps/github
    /lib/features/chat/   @chat-owner
    \#hash.md @hash-owner
    !negated @nobody
    [abc].md @nobody
    bad-owner notanowner
    """;

    private static CodeOwners Owners => new(Sample);

    [Fact]
    public void LastMatchWins()
    {
        Assert.Equal(new[] { "@global-owner1", "@global-owner2" }, Owners.OwnersFor("README.md"));
        Assert.Equal(new[] { "@js-owner" }, Owners.OwnersFor("src/app.js"));
        Assert.Equal(new[] { "docs@example.com" }, Owners.OwnersFor("main.go"));
        Assert.Equal(new[] { "@octo-org/octocats" }, Owners.OwnersFor("notes.txt"));
    }

    [Fact]
    public void DirectoryPatterns()
    {
        Assert.Equal(new[] { "@octocat" }, Owners.OwnersFor("build/logs/a/b.log"));
        Assert.Equal(new[] { "@doctocat", "@octocat" }, Owners.OwnersFor("scripts/deploy.sh"));
        Assert.Equal(new[] { "@octocat" }, Owners.OwnersFor("deeply/nested/logs/x.txt"));
        Assert.Equal(new[] { "@chat-owner" }, Owners.OwnersFor("lib/features/chat/view/chat_page.dart"));
        Assert.Equal(new[] { "@global-owner1", "@global-owner2" }, Owners.OwnersFor("other/lib/features/chat/x.dart"));
    }

    [Fact]
    public void RootDocsAndSingleLevelWildcard()
    {
        Assert.Equal(new[] { "@doctocat" }, Owners.OwnersFor("docs/getting-started.md"));
        var onlyStar = new CodeOwners("docs/* @docs-team");
        Assert.Equal(new[] { "@docs-team" }, onlyStar.OwnersFor("docs/getting-started.md"));
        Assert.Empty(onlyStar.OwnersFor("docs/build-app/troubleshooting.md"));
    }

    [Fact]
    public void RuleWithoutOwnersClearsOwnership()
    {
        Assert.Empty(Owners.OwnersFor("apps/github/main.swift"));
        Assert.Equal(new[] { "@octocat" }, Owners.OwnersFor("apps/other/main.swift"));
        Assert.NotNull(Owners.RuleFor("apps/github/main.swift"));
    }

    [Fact]
    public void EscapesAndUnsupportedSyntax()
    {
        Assert.Equal(new[] { "@hash-owner" }, Owners.OwnersFor("#hash.md"));
        Assert.Equal(3, Owners.InvalidLines.Count);
        Assert.Equal(new[] { "@global-owner1", "@global-owner2" }, Owners.OwnersFor("negated"));
    }

    [Fact]
    public void UnanchoredFileNameAndDoubleStar()
    {
        var o = new CodeOwners("Makefile @make\nsrc/**/test_*.py @py\n");
        Assert.Equal(new[] { "@make" }, o.OwnersFor("a/b/Makefile"));
        Assert.Equal(new[] { "@py" }, o.OwnersFor("src/test_x.py"));
        Assert.Equal(new[] { "@py" }, o.OwnersFor("src/a/b/test_x.py"));
        Assert.Empty(o.OwnersFor("lib/src/test_x.py"));
    }

    [Fact]
    public void SummaryGroupsAndStatuses()
    {
        const string json = """
        {"id":"PR_1","number":1,"title":"T","url":"u","state":"OPEN","isDraft":false,"merged":false,"mergeable":"MERGEABLE",
         "body":"","bodyHTML":"","createdAt":"2026-01-01T00:00:00Z","headRefName":"f","baseRefName":"main","headRefOid":"h",
         "additions":1,"deletions":1,"changedFiles":3,"viewerCanUpdate":true,"viewerDidAuthor":true,
         "labels":{"nodes":[]},"assignees":{"nodes":[]},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"Octocats","combinedSlug":"octo-org/octocats"}}]},
         "latestOpinionatedReviews":{"nodes":[{"state":"APPROVED","author":{"login":"JS-Owner","avatarUrl":""}}]},
         "lastCommit":{"nodes":[]},"allCommits":{"nodes":[]},"timelineItems":{"nodes":[]},"reviewThreads":{"nodes":[]}}
        """;
        var pr = JsonSerializer.Deserialize<PullRequestDetail>(json, Json.GraphQL)!;
        var o = new CodeOwners("*.js @js-owner\n*.txt @octo-org/octocats\n/scripts/ @doctocat\n");
        var s = OwnershipSummary.Build(o, new[] { "a.js", "b.txt", "scripts/run.sh", "README.md" }, pr);
        Assert.Equal(new[] { "README.md" }, s.Unowned);
        Assert.Equal(new[] { OwnerStatus.Approved, OwnerStatus.Requested, OwnerStatus.NotRequested }, s.Groups.Select(g => g.Owners.Single().Status));
        Assert.True(s.Groups[1].Owners[0].IsTeam);
        Assert.Equal(new[] { "doctocat" }, s.Suggestions(new HashSet<string>()).Select(e => e.Handle));
        Assert.Empty(s.Suggestions(new HashSet<string> { "doctocat" }));
    }

    [Fact]
    public void BaseTipOidComesFromBaseRefTarget()
    {
        var pr = JsonSerializer.Deserialize<PullRequestDetail>("""{"baseRef":{"target":{"oid":"abc"}}}""", Json.GraphQL)!;
        Assert.Equal("abc", pr.BaseTipOid);
        Assert.Contains("baseRef { target { oid } }", Q.PullRequestLegacy);
    }
}
