using System.Net;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Forges;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class BitbucketReviewTests
{
    private static readonly ItemRef Ref = new(new RepoRef("acme", "api"), 5);

    private const string Detail = """
    {"id":5,"title":"Add billing","state":"OPEN","draft":false,
     "summary":{"raw":"Adds **billing**","html":"<p>Adds <strong>billing</strong> <a href=\"/acme/api/issues/2\">#2</a></p>"},
     "created_on":"2026-10-01T10:00:00.000000+00:00","updated_on":"2026-10-03T12:00:00.123456+00:00",
     "author":{"uuid":"{u-max}","display_name":"Max","nickname":"max","links":{"avatar":{"href":"https://a/max.png"}}},
     "source":{"branch":{"name":"feature/billing"},"commit":{"hash":"head2"},"repository":{"full_name":"acme/api"}},
     "destination":{"branch":{"name":"main"},"commit":{"hash":"base1"},"repository":{"full_name":"acme/api"}},
     "close_source_branch":true,"links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/5"}},
     "comment_count":4,"task_count":1,
     "participants":[
       {"user":{"uuid":"{u-lea}","nickname":"lea"},"role":"REVIEWER","approved":true,"state":"approved","participated_on":"2026-10-02T10:00:00+00:00"},
       {"user":{"uuid":"{u-ivo}","nickname":"ivo"},"role":"REVIEWER","approved":false,"state":"changes_requested"},
       {"user":{"uuid":"{u-sofia}","nickname":"sofia"},"role":"REVIEWER","approved":false,"state":null}],
     "reviewers":[{"uuid":"{u-lea}","nickname":"lea"},{"uuid":"{u-ivo}","nickname":"ivo"},{"uuid":"{u-sofia}","nickname":"sofia"}]}
    """;

    private const string Comments = """
    {"values":[
      {"id":10,"content":{"raw":"Looks good","html":"<p>Looks good</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T11:00:00+00:00"},
      {"id":20,"content":{"raw":"Rename this","html":"<p>Rename this</p>"},"user":{"nickname":"ivo"},"created_on":"2026-10-02T09:00:00+00:00","inline":{"path":"b.swift","from":null,"to":9}},
      {"id":21,"content":{"raw":"Done","html":"<p>Done</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T10:00:00+00:00","parent":{"id":20}},
      {"id":22,"content":{"raw":"Thanks","html":""},"user":{"nickname":"ivo"},"created_on":"2026-10-02T11:00:00+00:00","parent":{"id":21}},
      {"id":30,"content":{"raw":"Old","html":"<p>Old</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:00:00+00:00","inline":{"path":"a.swift","from":4,"to":null,"outdated":true},"resolution":{"type":"resolved"}},
      {"id":40,"content":{"raw":"Gone","html":""},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:30:00+00:00","deleted":true},
      {"id":50,"content":{"raw":"Question?","html":"<p>Question?</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-02T12:00:00+00:00"},
      {"id":51,"content":{"raw":"Answer","html":"<p>Answer</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T13:00:00+00:00","parent":{"id":50}}
    ],"next":null}
    """;

    private const string Diff = """
    diff --git a/a.swift b/a.swift
    index 1..2 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,2 @@
    -let a = 1
    +let a = 2
     let b = 3
    diff --git a/b.swift b/b.swift
    new file mode 100644
    --- /dev/null
    +++ b/b.swift
    @@ -0,0 +1 @@
    +print(1)
    """;

    private static GitAccount Account() =>
        new() { Id = "test", Provider = GitProvider.Bitbucket, Host = "bitbucket.org", Login = "sofia", Email = "s@example.com", UserId = "{u-sofia}", CredentialKey = "test" };

    private static (BitbucketPRBackend Backend, ForgeStub Stub) Backend()
    {
        var stub = new ForgeStub();
        stub.Routes["/pullrequests/5"] = (HttpStatusCode.OK, Detail);
        stub.Routes["/pullrequests/5/comments"] = (HttpStatusCode.OK, Comments);
        stub.Routes["/pullrequests/5/commits"] = (HttpStatusCode.OK, """{"values":[{"hash":"head2abcdef","message":"Second\n\nbody","date":"2026-10-02T08:00:00+00:00","author":{"raw":"Max <max@x>"}},{"hash":"c1","message":"First","date":"2026-10-01T08:00:00+00:00","author":{"raw":"Max <max@x>","user":{"display_name":"Max M"}}}]}""");
        stub.Routes["/pullrequests/5/statuses"] = (HttpStatusCode.OK, """{"values":[{"key":"ci","name":"CI","state":"FAILED","url":"https://ci/1"},{"key":"lint","state":"SUCCESSFUL"},{"key":"e2e","name":"E2E","state":"INPROGRESS"}]}""");
        stub.Routes["/pullrequests/5/diffstat"] = (HttpStatusCode.OK, """{"values":[{"status":"modified","lines_added":1,"lines_removed":1,"old":{"path":"a.swift"},"new":{"path":"a.swift"}},{"status":"added","lines_added":1,"lines_removed":0,"old":null,"new":{"path":"b.swift"}}]}""");
        stub.Routes["/pullrequests/5/diff"] = (HttpStatusCode.OK, Diff);
        stub.Routes["/pullrequests/5/approve"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/pullrequests/5/request-changes"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/pullrequests/5/merge"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/pullrequests/5/decline"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/comments/20/resolve"] = (HttpStatusCode.OK, "{}");
        var client = new BitbucketClient(Account(), GitCredential.Of("tok"), stub.Client());
        return (new BitbucketPRBackend(client), stub);
    }

    private static List<HttpRequestMessage> Requests(ForgeStub stub, string method, string suffix)
    {
        lock (stub.Requests) return stub.Requests.Where(r => r.Method.Method == method && r.RequestUri!.AbsolutePath.EndsWith(suffix, StringComparison.Ordinal)).ToList();
    }

    private static JsonObject Body(ForgeStub stub, HttpRequestMessage? request) =>
        stub.Body(request) is { Length: > 0 } text ? JsonNode.Parse(text) as JsonObject ?? new() : new();

    private static async Task<PullRequestDetail> Loaded(BitbucketPRBackend backend) => (await backend.Load(Ref)).Repository!.PullRequest!;

    [Fact]
    public async Task LoadMapsPullRequest()
    {
        var (backend, stub) = Backend();
        var load = await backend.Load(Ref);
        var repo = load.Repository!;
        var pr = repo.PullRequest!;

        Assert.Equal("{u-sofia}", load.Viewer);
        Assert.Equal("OPEN", pr.State);
        Assert.Equal("MERGEABLE", pr.Mergeable);
        Assert.Equal("UNSTABLE", pr.MergeStateStatus);
        Assert.Equal("Changes requested", pr.MergeBlocker);
        Assert.Equal("CHANGES_REQUESTED", pr.ReviewDecision);
        Assert.Equal("feature/billing", pr.HeadRefName);
        Assert.Equal("head2", pr.HeadRefOid);
        Assert.Equal(2, pr.Additions);
        Assert.Equal(1, pr.Deletions);
        Assert.Equal(2, pr.ChangedFiles);
        Assert.Contains("href=\"https://bitbucket.org/acme/api/issues/2\"", pr.BodyHTML);
        Assert.Equal(new[] { "ivo:CHANGES_REQUESTED", "lea:APPROVED" }, pr.LatestOpinionatedReviews.Items.Select(r => $"{r.Author?.Login}:{r.State}").OrderBy(x => x, StringComparer.Ordinal));
        Assert.Equal(new[] { "sofia" }, pr.ReviewRequests.Items.Select(r => r.RequestedReviewer?.Display));
        Assert.False(pr.ViewerApproved);
        Assert.True(pr.ViewerCanApprove);
        Assert.True(repo.DeleteBranchOnMerge);
        Assert.False(repo.AutoMergeAllowed);
        Assert.Equal(new[] { "First", "Second" }, pr.AllCommits.Items.Select(c => c.Commit.MessageHeadline));
        Assert.Equal("Max M", pr.AllCommits.Items[0].Commit.Author?.Name);
        Assert.Equal("head2ab", pr.AllCommits.Items[^1].Commit.AbbreviatedOid);

        Assert.Equal(new[] { "CI", "lint", "E2E" }, pr.Checks.Select(c => c.Title));
        Assert.Equal(new[] { CheckOutcome.Failure, CheckOutcome.Success, CheckOutcome.Pending }, pr.Checks.Select(c => c.Outcome));
        Assert.Equal("FAILURE", pr.Rollup?.State);

        var threads = pr.ReviewThreads.Items;
        Assert.Equal(new[] { "30", "20", "50" }, threads.Select(t => t.Id));
        var inline = threads.First(t => t.Id == "20");
        Assert.Equal("b.swift", inline.Path);
        Assert.Equal(9, inline.Line);
        Assert.Equal("RIGHT", inline.DiffSide);
        Assert.False(inline.IsResolved);
        Assert.True(inline.ViewerCanResolve);
        Assert.Equal(new[] { "Rename this", "Done", "Thanks" }, inline.Comments.Items.Select(c => c.Body));
        var old = threads.First(t => t.Id == "30");
        Assert.True(old.IsResolved);
        Assert.True(old.IsOutdated);
        Assert.Null(old.Line);
        Assert.Equal("LEFT", old.DiffSide);
        Assert.True(old.ViewerCanUnresolve);
        var general = threads.First(t => t.Id == "50");
        Assert.Equal("", general.Path);
        Assert.Equal(2, general.Comments.Items.Count);
        Assert.Equal(new[] { "bb-c-10" }, pr.TimelineItems.Items.Where(i => i.Typename == "IssueComment").Select(i => i.Id));
        Assert.DoesNotContain(pr.TimelineItems.Items, i => i.Id == "bb-c-40");

        Assert.Contains("/2.0/repositories/acme/api/pullrequests/5/comments?pagelen=100", Requests(stub, "GET", "/pullrequests/5/comments").First().RequestUri!.AbsoluteUri);
        Assert.Equal(load.Signature, await backend.Pulse(Ref));
    }

    [Fact]
    public async Task RequirementsAreAdvisoryExceptConflicts()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        var reqs = MergeReadiness.Requirements(pr, RulesStatus.Loading);
        Assert.Equal(RequirementState.Satisfied, reqs.First(r => r.Kind == RequirementKind.Conflicts).State);
        Assert.Equal(RequirementState.Advisory, reqs.First(r => r.Kind == RequirementKind.ChangesRequested).State);
        Assert.Equal("Approved", reqs.First(r => r.Kind == RequirementKind.Approvals).Title);
        Assert.Equal("1 build failed", reqs.First(r => r.Kind == RequirementKind.Checks).Title);
        Assert.Equal("1 open task", reqs.First(r => r.Kind == RequirementKind.Conversations).Title);
        Assert.Equal(RequirementKind.OtherRules, reqs[^1].Kind);
        Assert.DoesNotContain(reqs, r => r.State == RequirementState.Missing);

        stub.Routes["/pullrequests/5"] = (HttpStatusCode.OK, Detail.Replace("\"task_count\":1", "\"task_count\":0"));
        stub.Routes["/pullrequests/5/diffstat"] = (HttpStatusCode.OK, """{"values":[{"status":"merge conflict","old":{"path":"a.swift"},"new":{"path":"a.swift"}}]}""");
        var bad = await Loaded(backend);
        Assert.Equal("DIRTY", bad.MergeStateStatus);
        Assert.Equal(RequirementState.Missing, MergeReadiness.Requirements(bad, RulesStatus.Loading).First(r => r.Kind == RequirementKind.Conflicts).State);
    }

    [Fact]
    public async Task FilesSplitUnifiedDiff()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        var files = await backend.Files(Ref, pr);
        Assert.Equal(new[] { "a.swift", "b.swift" }, files.Select(f => f.Filename));
        Assert.Equal(new[] { "modified", "added" }, files.Select(f => f.Status));
        Assert.Equal("@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n let b = 3", files[0].Patch);
        Assert.Equal("@@ -0,0 +1 @@\n+print(1)", files[1].Patch);
        Assert.Empty(BitbucketReviewMapper.SplitDiff(""));
        Assert.Contains("text/plain", Requests(stub, "GET", "/pullrequests/5/diff").Last().Headers.Accept.ToString());
    }

    [Fact]
    public async Task SubmitReviewPostsInlineCommentsThenDecision()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        var right = new PendingComment { Path = "a.swift", Line = 1, Side = "RIGHT", Body = "nit" };
        var left = new PendingComment { Path = "a.swift", Line = 1, Side = "LEFT", Body = "was this needed?" };
        lock (stub.Requests) stub.Requests.Clear();
        await backend.SubmitReview(Ref, pr, "REQUEST_CHANGES", "Please fix", new[] { right, left }, Array.Empty<DiffFile>());
        var posts = Requests(stub, "POST", "/pullrequests/5/comments").Select(r => Body(stub, r)).ToList();
        Assert.Equal(3, posts.Count);
        Assert.Equal("""{"path":"a.swift","to":1}""", posts[0]["inline"]!.ToJsonString());
        Assert.Equal("""{"path":"a.swift","from":1}""", posts[1]["inline"]!.ToJsonString());
        Assert.Equal("Please fix", posts[2].Obj("content").Str("raw"));
        Assert.Single(Requests(stub, "POST", "/request-changes"));
        Assert.Empty(Requests(stub, "POST", "/approve"));

        await backend.SubmitReview(Ref, pr, "APPROVE", "", Array.Empty<PendingComment>(), Array.Empty<DiffFile>());
        Assert.Single(Requests(stub, "POST", "/approve"));
        await backend.RevokeApproval(Ref, pr);
        Assert.Single(Requests(stub, "DELETE", "/approve"));
    }

    [Fact]
    public async Task ThreadActionsMergeAndState()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        IPRBackend b = backend;
        lock (stub.Requests) stub.Requests.Clear();

        await b.Reply(Ref, "20", "ok");
        Assert.Equal(20, Body(stub, Requests(stub, "POST", "/pullrequests/5/comments").First()).Obj("parent").Int("id"));
        await b.SetResolved(Ref, "20", true);
        await b.SetResolved(Ref, "20", false);
        Assert.Single(Requests(stub, "POST", "/comments/20/resolve"));
        Assert.Single(Requests(stub, "DELETE", "/comments/20/resolve"));
        await Assert.ThrowsAsync<ApiException>(() => b.Reply(Ref, "x", "ok"));

        Assert.Null(await b.Merge(Ref, pr, "SQUASH", "Billing", null, true));
        var merge = Body(stub, Requests(stub, "POST", "/pullrequests/5/merge").First());
        Assert.Equal("squash", merge.Str("merge_strategy"));
        Assert.True(merge.Bool("close_source_branch"));
        Assert.Equal("Billing", merge.Str("message"));
        await b.Merge(Ref, pr, "MERGE", null, null, false);
        var plain = Body(stub, Requests(stub, "POST", "/pullrequests/5/merge").Last());
        Assert.Equal("merge_commit", plain.Str("merge_strategy"));
        Assert.Null(plain["close_source_branch"]);
        Assert.Null(plain["message"]);

        await b.Perform(PRAction.ConvertToDraft, Ref, pr);
        Assert.True(Body(stub, Requests(stub, "PUT", "/pullrequests/5").Last()).Bool("draft"));
        await b.Edit(Ref, pr, "T", "B");
        Assert.Equal("B", Body(stub, Requests(stub, "PUT", "/pullrequests/5").Last()).Str("description"));
        await b.Perform(PRAction.Close, Ref, pr);
        Assert.Single(Requests(stub, "POST", "/decline"));
        var reopen = await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => b.Perform(PRAction.Reopen, Ref, pr));
        Assert.Equal("Not available for Bitbucket yet", reopen.Message);
        await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => b.EnableAutoMerge(Ref, pr, "MERGE"));
        await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => b.Perform(PRAction.UpdateBranch, Ref, pr));
    }

    [Fact]
    public async Task CommitDetail()
    {
        var stub = new ForgeStub();
        stub.Routes["/repositories/acme/api/commit/abc"] = (HttpStatusCode.OK, """{"hash":"abc","message":"Fix\n\nBody","date":"2026-10-01T08:00:00+00:00","author":{"raw":"Max <max@x>"},"links":{"html":{"href":"https://bitbucket.org/acme/api/commits/abc"}}}""");
        stub.Routes["/repositories/acme/api/diffstat/abc"] = (HttpStatusCode.OK, """{"values":[{"status":"added","lines_added":1,"lines_removed":0,"new":{"path":"a"}}]}""");
        stub.Routes["/repositories/acme/api/diff/abc"] = (HttpStatusCode.OK, "diff --git a/a b/a\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+x\n");
        var client = new BitbucketClient(Account(), GitCredential.Of("t"), stub.Client());
        var c = await new BitbucketPRBackend(client).Commit(new RepoRef("acme", "api"), "abc");
        Assert.Equal("Fix\n\nBody", c.Commit.Message);
        Assert.Equal("Max", c.Commit.Author?.Name);
        Assert.Equal(1, c.Stats?.Additions);
        Assert.Equal("added", c.Files?.First().Status);
        Assert.Equal("@@ -0,0 +1 @@\n+x", c.Files?.First().Patch);
        Assert.Equal("https://bitbucket.org/acme/api/commits/abc", c.HtmlUrl);
    }

    [Fact]
    public async Task FeaturesAndCapabilities()
    {
        var f = PRFeatures.Bitbucket;
        Assert.True(f.RequestChanges);
        Assert.True(f.RevokeApproval);
        Assert.False(f.Reopen);
        Assert.False(f.ViewedFiles);
        Assert.False(f.UpdateBranch);
        Assert.True(PRFeatures.GitLab.Reopen && PRFeatures.GitHub.Reopen);
        var client = new BitbucketClient(Account(), GitCredential.Of("t"), new ForgeStub().Client());
        var caps = await client.Capabilities();
        Assert.Equal(CapabilityState.Supported, caps.PullRequestReview);
        Assert.Equal(CapabilityState.Unavailable, caps.MergeRequirements);
        Assert.IsType<BitbucketPRBackend>(((IForgeClient)client).ReviewBackend());
    }

    [Fact]
    public void SplitDiffHandlesWindowsLineEndings()
    {
        var diff = "diff --git a/a.swift b/a.swift\r\n--- a/a.swift\r\n+++ b/a.swift\r\n@@ -1 +1 @@\r\n-let a = 1\r\n+let a = 2\r\n";
        var patches = BitbucketReviewMapper.SplitDiff(diff);
        Assert.Equal("@@ -1 +1 @@\n-let a = 1\n+let a = 2", patches["a.swift"]);
    }
}
