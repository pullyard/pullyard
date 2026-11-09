using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Forges;
using PullYard.Core.Html;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class GitLabReviewTests
{
    private static readonly ItemRef Ref = new(new RepoRef("group", "sub/app"), 7);

    private const string Detail = """
    {"id":901,"iid":7,"project_id":42,"source_project_id":42,"target_project_id":42,"title":"Add login","description":"Adds **login**",
     "description_html":"<p>Adds <strong>login</strong> <img data-src=\"/group/sub/app/uploads/a.png\" src=\"data:image/gif;base64,R0lG\"> <a href=\"/group/sub/app/-/issues/3\">#3</a></p>",
     "state":"opened","draft":false,"web_url":"https://gitlab.example.com/group/sub/app/-/merge_requests/7",
     "created_at":"2026-10-01T10:00:00.000Z","updated_at":"2026-10-03T12:00:00.000Z",
     "author":{"id":1,"username":"max","name":"Max","avatar_url":"https://a/max.png"},
     "assignees":[{"id":1,"username":"max","avatar_url":null}],
     "reviewers":[{"id":2,"username":"sofia","avatar_url":null},{"id":3,"username":"lea","avatar_url":null}],
     "source_branch":"feature/login","target_branch":"main","sha":"head2",
     "diff_refs":{"base_sha":"base1","head_sha":"head2","start_sha":"start1"},
     "detailed_merge_status":"discussions_not_resolved","has_conflicts":false,"blocking_discussions_resolved":false,
     "labels":["backend"],"head_pipeline":{"id":55,"project_id":42,"status":"failed","web_url":"https://gitlab.example.com/p/55"},
     "changes_count":"3","user_notes_count":4,"squash":false,"merge_when_pipeline_succeeds":false,
     "user":{"can_merge":true},"references":{"full":"group/sub/app!7"}}
    """;

    private const string Discussions = """
    [
     {"id":"d3","individual_note":false,"notes":[
       {"id":31,"type":"DiffNote","body":"Old remark","author":{"username":"lea"},"created_at":"2026-10-02T09:00:00Z","system":false,"resolvable":true,"resolved":true,
        "position":{"base_sha":"base0","start_sha":"base0","head_sha":"head1","old_path":"a.swift","new_path":"a.swift","old_line":null,"new_line":4,"position_type":"text"}}]},
     {"id":"d1","individual_note":true,"notes":[
       {"id":11,"type":null,"body":"approved this merge request","author":{"username":"lea"},"created_at":"2026-10-01T11:00:00Z","system":true}]},
     {"id":"d2","individual_note":true,"notes":[
       {"id":21,"type":null,"body":"Looks **good**","author":{"username":"lea","avatar_url":"https://a/lea.png"},"created_at":"2026-10-01T12:00:00Z","system":false}]},
     {"id":"d4","individual_note":false,"notes":[
       {"id":41,"type":"DiffNote","body":"Rename this","author":{"username":"sofia"},"created_at":"2026-10-02T10:00:00Z","system":false,"resolvable":true,"resolved":false,
        "position":{"base_sha":"base1","start_sha":"start1","head_sha":"head2","old_path":"b.swift","new_path":"b.swift","old_line":9,"new_line":null,"position_type":"text"}},
       {"id":42,"type":"DiffNote","body":"Done","author":{"username":"max"},"created_at":"2026-10-02T11:00:00Z","system":false,"resolvable":true,"resolved":false}]},
     {"id":"d5","individual_note":false,"notes":[
       {"id":51,"type":"DiscussionNote","body":"General question","author":{"username":"lea"},"created_at":"2026-10-02T12:00:00Z","system":false,"resolvable":true,"resolved":false}]}
    ]
    """;

    private static GitAccount Account(string login = "sofia") =>
        new() { Id = "test", Provider = GitProvider.GitLab, Host = "gitlab.example.com", Login = login, CredentialKey = "test" };

    private static (GitLabPRBackend Backend, ForgeStub Stub) Backend(string login = "sofia")
    {
        var stub = new ForgeStub();
        stub.Routes["/api/v4/user"] = (HttpStatusCode.OK, """{"id":2,"username":"sofia","name":"Sofia"}""");
        stub.Routes["/merge_requests/7"] = (HttpStatusCode.OK, Detail);
        stub.Routes["/merge_requests/7/approvals"] = (HttpStatusCode.OK, """{"approved":false,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":3,"username":"lea","avatar_url":"https://a/lea.png"}}],"user_has_approved":false,"user_can_approve":true}""");
        stub.Routes["/merge_requests/7/discussions"] = (HttpStatusCode.OK, Discussions);
        stub.Routes["/merge_requests/7/commits"] = (HttpStatusCode.OK, """[{"id":"c2","short_id":"c2","title":"Second","author_name":"Max","committed_date":"2026-10-02T08:00:00Z"},{"id":"c1","short_id":"c1","title":"First","author_name":"Max","committed_date":"2026-10-01T08:00:00Z"}]""");
        stub.Routes["/pipelines/55/jobs"] = (HttpStatusCode.OK, """[{"id":1,"name":"build","stage":"build","status":"success","started_at":"2026-10-02T08:00:00Z","finished_at":"2026-10-02T08:01:30Z"},{"id":2,"name":"lint","stage":"test","status":"failed","allow_failure":true},{"id":3,"name":"unit","stage":"test","status":"failed"},{"id":4,"name":"deploy","stage":"deploy","status":"manual"},{"id":5,"name":"e2e","stage":"test","status":"running"}]""");
        stub.Routes["/projects/group%2Fsub%2Fapp"] = (HttpStatusCode.OK, """{"id":42,"path_with_namespace":"group/sub/app","merge_method":"merge","squash_option":"default_on"}""");
        stub.Routes["/merge_requests/7/notes"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/discussions/d4"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/merge_requests/7/discussions/d4/notes"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/approve"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/unapprove"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/merge"] = (HttpStatusCode.OK, "{}");
        stub.Routes["/merge_requests/7/cancel_merge_when_pipeline_succeeds"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/rebase"] = (HttpStatusCode.Accepted, "{}");
        var client = new GitLabClient(Account(login), GitCredential.Of("glpat-x"), client: stub.Client());
        return (new GitLabPRBackend(client), stub);
    }

    private static List<HttpRequestMessage> Requests(ForgeStub stub, string method, string suffix)
    {
        lock (stub.Requests) return stub.Requests.Where(r => r.Method.Method == method && r.RequestUri!.AbsolutePath.EndsWith(suffix, StringComparison.Ordinal)).ToList();
    }

    private static JsonObject Body(ForgeStub stub, HttpRequestMessage? request) =>
        stub.Body(request) is { Length: > 0 } text ? JsonNode.Parse(text) as JsonObject ?? new() : new();

    private static async Task<PullRequestDetail> Loaded(GitLabPRBackend backend) => (await backend.Load(Ref)).Repository!.PullRequest!;

    [Fact]
    public async Task LoadMapsMergeRequest()
    {
        var (backend, stub) = Backend();
        var load = await backend.Load(Ref);
        var repo = load.Repository!;
        var pr = repo.PullRequest!;

        Assert.Equal("sofia", load.Viewer);
        Assert.True(repo.CanWrite);
        Assert.True(repo.SquashMergeAllowed);
        Assert.False(repo.RebaseMergeAllowed);
        Assert.Equal("SQUASH", repo.ViewerDefaultMergeMethod);
        Assert.Equal(7, pr.Number);
        Assert.Equal("OPEN", pr.State);
        Assert.Equal("feature/login", pr.HeadRefName);
        Assert.Equal("main", pr.BaseRefName);
        Assert.Equal("head2", pr.HeadRefOid);
        Assert.Equal(3, pr.ChangedFiles);
        Assert.Equal("BLOCKED", pr.MergeStateStatus);
        Assert.Equal("All threads must be resolved", pr.MergeBlocker);
        Assert.Equal("REVIEW_REQUIRED", pr.ReviewDecision);
        Assert.False(pr.ViewerDidAuthor);
        Assert.True(pr.ViewerCanApprove);
        Assert.False(pr.ViewerApproved);
        Assert.Equal(new[] { "backend" }, pr.Labels.Items.Select(l => l.Name));
        Assert.Equal(new[] { "lea" }, pr.LatestOpinionatedReviews.Items.Select(r => r.Author?.Login));
        Assert.Equal(new[] { "sofia" }, pr.ReviewRequests.Items.Select(r => r.RequestedReviewer?.Login));
        Assert.Contains("src=\"https://gitlab.example.com/group/sub/app/uploads/a.png\"", pr.BodyHTML);
        Assert.Contains("href=\"https://gitlab.example.com/group/sub/app/-/issues/3\"", pr.BodyHTML);
        Assert.DoesNotContain("data:image", pr.BodyHTML);

        Assert.Equal(new[] { "c1", "c2" }, pr.AllCommits.Items.Select(c => c.Commit.Oid));

        var checks = pr.Checks.ToDictionary(c => c.Title, c => c.Outcome);
        Assert.Equal(CheckOutcome.Success, checks["build"]);
        Assert.Equal(CheckOutcome.Neutral, checks["lint"]);
        Assert.Equal(CheckOutcome.Failure, checks["unit"]);
        Assert.Equal(CheckOutcome.Skipped, checks["deploy"]);
        Assert.Equal(CheckOutcome.Pending, checks["e2e"]);
        Assert.Equal("build", pr.Checks[0].WorkflowName);
        Assert.Equal("1m 30s", pr.Checks[0].Duration);
        Assert.False(pr.Checks[0].IsActionsJob);
        Assert.Equal("FAILURE", pr.Rollup?.State);

        var threads = pr.ReviewThreads.Items.ToDictionary(t => t.Id);
        Assert.Equal(3, threads.Count);
        var current = threads["d4"];
        Assert.Equal("b.swift", current.Path);
        Assert.Equal(9, current.Line);
        Assert.Equal("LEFT", current.DiffSide);
        Assert.False(current.IsOutdated);
        Assert.False(current.IsResolved);
        Assert.True(current.ViewerCanResolve);
        Assert.Equal(new[] { "Rename this", "Done" }, current.Comments.Items.Select(c => c.Body));
        var old = threads["d3"];
        Assert.True(old.IsOutdated);
        Assert.True(old.IsResolved);
        Assert.Null(old.Line);
        Assert.Equal(4, old.OriginalLine);
        Assert.True(old.ViewerCanUnresolve);
        var general = threads["d5"];
        Assert.Equal("", general.Path);
        Assert.Null(general.Line);

        Assert.Equal(new[] { "SystemNote", "IssueComment", "PullRequestReview", "PullRequestReview", "PullRequestReview" }, pr.TimelineItems.Items.Select(i => i.Typename));
        var comment = pr.TimelineItems.Items.First(i => i.Typename == "IssueComment");
        Assert.Equal("<p>Looks <strong>good</strong></p>", comment.BodyHTML);

        var detailRequest = Requests(stub, "GET", "/merge_requests/7").First();
        Assert.Contains("/api/v4/projects/group%2Fsub%2Fapp/merge_requests/7?render_html=true", detailRequest.RequestUri!.AbsoluteUri);

        var html = ConversationHtml.Render(pr);
        Assert.Contains("started a thread", html);
        Assert.Contains("approved this merge request", html);
        Assert.DoesNotContain("post('file','')", html);
        Assert.Equal(load.Signature, await backend.Pulse(Ref));
    }

    [Fact]
    public async Task PulseTracksApprovals()
    {
        var (backend, stub) = Backend();
        var load = await backend.Load(Ref);
        Assert.Equal(load.Signature, await backend.Pulse(Ref));
        stub.Routes["/merge_requests/7/approvals"] = (HttpStatusCode.OK, """{"approved_by":[{"user":{"username":"lea"}},{"user":{"username":"sofia"}}],"user_has_approved":true}""");
        Assert.NotEqual(load.Signature, await backend.Pulse(Ref));
        Assert.DoesNotContain("render_html", Requests(stub, "GET", "/merge_requests/7").Last().RequestUri!.Query);
    }

    [Fact]
    public async Task FilesMapDiffsAndFallBackToChanges()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        stub.Routes["/merge_requests/7/diffs"] = (HttpStatusCode.OK, """
        [{"old_path":"a.swift","new_path":"a.swift","diff":"@@ -1,2 +1,3 @@\n line\n-old\n+new\n+more\n","new_file":false,"renamed_file":false,"deleted_file":false},
         {"old_path":"old.swift","new_path":"new.swift","diff":"","new_file":false,"renamed_file":true,"deleted_file":false},
         {"old_path":"big.json","new_path":"big.json","diff":"@@ -1 +1 @@\n-a\n+b\n","new_file":true,"renamed_file":false,"deleted_file":false,"too_large":true}]
        """);
        var files = await backend.Files(Ref, pr);
        Assert.Equal(new[] { "a.swift", "new.swift", "big.json" }, files.Select(f => f.Filename));
        Assert.Equal("modified", files[0].Status);
        Assert.Equal(2, files[0].Additions);
        Assert.Equal(1, files[0].Deletions);
        Assert.Equal(5, new DiffFile(files[0]).Lines.Count);
        Assert.Equal("renamed", files[1].Status);
        Assert.Equal("old.swift", files[1].PreviousFilename);
        Assert.Null(files[1].Patch);
        Assert.Equal("added", files[2].Status);
        Assert.Null(files[2].Patch);

        stub.Routes.Remove("/merge_requests/7/diffs");
        stub.Routes["/merge_requests/7/changes"] = (HttpStatusCode.OK, """{"changes":[{"old_path":"x","new_path":"x","diff":"@@ -0,0 +1 @@\n+x\n","new_file":true,"renamed_file":false,"deleted_file":true}]}""");
        var legacy = await backend.Files(Ref, pr);
        Assert.Equal(new[] { "added" }, legacy.Select(f => f.Status));
    }

    [Fact]
    public async Task SubmitReviewPostsPositionedThreadsThenApproves()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        var file = new DiffFile(new PRFile { Filename = "a.swift", Status = "renamed", Additions = 1, Deletions = 1, Patch = "@@ -10,3 +12,3 @@\n keep\n-old\n+new\n", PreviousFilename = "z.swift" });
        var context = new PendingComment { Path = "a.swift", Line = 12, Side = "RIGHT", Body = "On context" };
        var removed = new PendingComment { Path = "a.swift", Line = 11, Side = "LEFT", Body = "On removed" };
        lock (stub.Requests) stub.Requests.Clear();
        await backend.SubmitReview(Ref, pr, "APPROVE", " Summary ", new[] { context, removed }, new[] { file });

        var threads = Requests(stub, "POST", "/merge_requests/7/discussions").Select(r => Body(stub, r)).ToList();
        Assert.Equal(2, threads.Count);
        Assert.Equal("On context", threads[0].Str("body"));
        var first = threads[0].Obj("position")!;
        Assert.Equal("text", first.Str("position_type"));
        Assert.Equal("base1", first.Str("base_sha"));
        Assert.Equal("start1", first.Str("start_sha"));
        Assert.Equal("head2", first.Str("head_sha"));
        Assert.Equal("a.swift", first.Str("new_path"));
        Assert.Equal("z.swift", first.Str("old_path"));
        Assert.Equal(12, first.Int("new_line"));
        Assert.Equal(10, first.Int("old_line"));
        var second = threads[1].Obj("position")!;
        Assert.Equal(11, second.Int("old_line"));
        Assert.Null(second["new_line"]);

        Assert.Equal("Summary", Body(stub, Requests(stub, "POST", "/merge_requests/7/notes").First()).Str("body"));
        Assert.Equal("head2", Body(stub, Requests(stub, "POST", "/merge_requests/7/approve").First()).Str("sha"));
        Assert.Equal(new[] { "discussions", "discussions", "notes", "approve" }, stub.Requests.Select(r => r.RequestUri!.Segments[^1]));
    }

    [Fact]
    public async Task ThreadActionsMergeAndStateChanges()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        IPRBackend b = backend;
        lock (stub.Requests) stub.Requests.Clear();

        await b.Reply(Ref, "d4", "Fixed");
        Assert.Equal("Fixed", Body(stub, Requests(stub, "POST", "/merge_requests/7/discussions/d4/notes").First()).Str("body"));

        await b.SetResolved(Ref, "d4", true);
        Assert.True(Body(stub, Requests(stub, "PUT", "/merge_requests/7/discussions/d4").First()).Bool("resolved"));

        await b.Comment(Ref, pr, "Hello");
        Assert.Equal("Hello", Body(stub, Requests(stub, "POST", "/merge_requests/7/notes").First()).Str("body"));

        await b.RevokeApproval(Ref, pr);
        Assert.Single(Requests(stub, "POST", "/merge_requests/7/unapprove"));

        Assert.Null(await b.Merge(Ref, pr, "SQUASH", "Add login", "Details", true));
        var merge = Body(stub, Requests(stub, "PUT", "/merge_requests/7/merge").First());
        Assert.True(merge.Bool("squash"));
        Assert.True(merge.Bool("should_remove_source_branch"));
        Assert.Equal("head2", merge.Str("sha"));
        Assert.Equal("Add login\n\nDetails", merge.Str("squash_commit_message"));
        Assert.Null(merge["merge_commit_message"]);
        Assert.Null(merge["auto_merge"]);

        await b.EnableAutoMerge(Ref, pr, "MERGE");
        var auto = Body(stub, Requests(stub, "PUT", "/merge_requests/7/merge").Last());
        Assert.True(auto.Bool("auto_merge"));
        Assert.True(auto.Bool("merge_when_pipeline_succeeds"));
        Assert.False(auto.Bool("squash"));

        await b.Perform(PRAction.DisableAutoMerge, Ref, pr);
        Assert.Single(Requests(stub, "POST", "/merge_requests/7/cancel_merge_when_pipeline_succeeds"));
        await b.Perform(PRAction.UpdateBranch, Ref, pr);
        Assert.Single(Requests(stub, "PUT", "/merge_requests/7/rebase"));
        await b.Perform(PRAction.Close, Ref, pr);
        Assert.Equal("close", Body(stub, Requests(stub, "PUT", "/merge_requests/7").Last()).Str("state_event"));
        await b.Perform(PRAction.ConvertToDraft, Ref, pr);
        Assert.Equal("Draft: Add login", Body(stub, Requests(stub, "PUT", "/merge_requests/7").Last()).Str("title"));
        Assert.Equal("Add login", GitLabReviewMapper.Undrafted("Draft: Add login"));
        Assert.Equal("Add login", GitLabReviewMapper.Undrafted("[WIP] Add login"));
        await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => b.RequestReviewers(Ref, new[] { "lea" }));
    }

    [Fact]
    public async Task MergeErrorsAreReadable()
    {
        var (backend, stub) = Backend();
        var pr = await Loaded(backend);
        stub.Routes["/merge_requests/7/merge"] = (HttpStatusCode.MethodNotAllowed, """{"message":"405 Method Not Allowed"}""");
        stub.Routes["/merge_requests/7/discussions/d4"] = (HttpStatusCode.BadRequest, """{"message":{"base":["Discussion is not resolvable"]}}""");
        var merge = await Assert.ThrowsAsync<ApiException>(() => backend.Merge(Ref, pr, "MERGE", null, null, false));
        Assert.Equal("GitLab 405: 405 Method Not Allowed", merge.Message);
        var resolve = await Assert.ThrowsAsync<ApiException>(() => backend.SetResolved(Ref, "d4", true));
        Assert.Equal("GitLab 400: Discussion is not resolvable", resolve.Message);
        Assert.Equal("title is too long; is invalid", ForgeHttp.Message("""{"message":["title is too long","is invalid"]}"""u8.ToArray()));
        Assert.Equal("Discussion is locked; title is too long", ForgeHttp.Message("""{"message":{"title":["is too long"],"base":["Discussion is locked"]}}"""u8.ToArray()));
    }

    [Fact]
    public async Task CommitDetail()
    {
        var stub = new ForgeStub();
        stub.Routes["/repository/commits/abc"] = (HttpStatusCode.OK, """{"id":"abc","short_id":"abc","title":"Fix","message":"Fix\n\nBody","author_name":"Max","authored_date":"2026-10-01T08:00:00Z","web_url":"https://gitlab.example.com/g/p/-/commit/abc","stats":{"additions":1,"deletions":0}}""");
        stub.Routes["/repository/commits/abc/diff"] = (HttpStatusCode.OK, """[{"old_path":"a","new_path":"a","diff":"@@ -0,0 +1 @@\n+x\n","new_file":true,"renamed_file":false,"deleted_file":false}]""");
        var client = new GitLabClient(Account(), GitCredential.Of("t"), client: stub.Client());
        var c = await new GitLabPRBackend(client).Commit(new RepoRef("g", "p"), "abc");
        Assert.Equal("Fix\n\nBody", c.Commit.Message);
        Assert.Equal("Max", c.Commit.Author?.Name);
        Assert.Equal(1, c.Stats?.Additions);
        Assert.Equal("added", c.Files?.First().Status);
        Assert.Equal("https://gitlab.example.com/g/p/-/commit/abc", c.HtmlUrl);
    }

    [Theory]
    [InlineData("mergeable", null, true, "MERGEABLE", "CLEAN", null)]
    [InlineData("conflict", null, true, "CONFLICTING", "DIRTY", null)]
    [InlineData("need_rebase", null, true, "MERGEABLE", "BEHIND", null)]
    [InlineData("checking", null, true, "UNKNOWN", "UNKNOWN", null)]
    [InlineData("ci_still_running", null, true, "MERGEABLE", "BLOCKED", "Pipeline is still running")]
    [InlineData("ci_must_pass", null, false, "MERGEABLE", "BLOCKED", "A pipeline must run and succeed")]
    [InlineData("not_approved", null, true, "MERGEABLE", "BLOCKED", null)]
    [InlineData("some_new_check", null, true, "MERGEABLE", "BLOCKED", "Some New Check")]
    [InlineData(null, "can_be_merged", true, "MERGEABLE", "CLEAN", null)]
    [InlineData(null, "cannot_be_merged", true, "CONFLICTING", "DIRTY", null)]
    public void MergeStatusMapping(string? detailed, string? legacy, bool pipeline, string mergeable, string status, string? blocker)
    {
        var json = new JsonObject
        {
            ["id"] = 1, ["iid"] = 1, ["title"] = "t", ["state"] = "opened", ["web_url"] = "https://g/x/-/merge_requests/1",
            ["created_at"] = "2026-10-01T10:00:00Z", ["updated_at"] = "2026-10-01T10:00:00Z", ["source_branch"] = "a", ["target_branch"] = "b"
        };
        if (detailed is not null) json["detailed_merge_status"] = detailed;
        if (legacy is not null) json["merge_status"] = legacy;
        if (pipeline) json["head_pipeline"] = new JsonObject { ["id"] = 1, ["status"] = "running" };
        var mr = JsonSerializer.Deserialize<GitLabMR.Detail>(json.ToJsonString(), Json.Rest)!;
        Assert.Equal(new GitLabMergeStatus(mergeable, status, blocker), GitLabReviewMapper.MergeStatus(mr));
    }

    [Fact]
    public void MarkdownHtmlRendersBlocksAndAbsoluteLinks()
    {
        var html = MarkdownHtml.Render("# Title\n\nSee [docs](/help) and `code` ![shot](/uploads/x.png)\n\n- [x] done\n- todo\n\n```swift\nlet a = 1 < 2\n```", "https://gitlab.example.com/g/p");
        Assert.Contains("<h1>Title</h1>", html);
        Assert.Contains("<a href=\"https://gitlab.example.com/help\">docs</a>", html);
        Assert.Contains("<code>code</code>", html);
        Assert.Contains("<img src=\"https://gitlab.example.com/g/p/uploads/x.png\" alt=\"shot\">", html);
        Assert.Contains("<li><input type=\"checkbox\" checked disabled> done</li>", html);
        Assert.Contains("let a = 1 &lt; 2", html);
        Assert.Equal("&lt;script&gt;", MarkdownHtml.Inline("<script>"));
        Assert.Equal("[x](javascript:alert(1))", MarkdownHtml.Inline("[x](javascript:alert(1))"));
        Assert.Equal("snake_case_name", MarkdownHtml.Inline("snake_case_name"));
        Assert.Equal("<em>a</em> and <del>b</del>", MarkdownHtml.Inline("*a* and ~~b~~"));
    }

    [Fact]
    public void GitHubBackendKeepsFullFeatureSet()
    {
        var features = new GitHubPRBackend(new GitHubApi("t"), GitProvider.GitHubEnterprise).Features;
        Assert.Equal(GitProvider.GitHubEnterprise, features.Provider);
        Assert.True(features.ViewedFiles && features.Stack && features.Agent && features.RequestReviewers);
        Assert.False(features.RevokeApproval);
        Assert.False(PRFeatures.GitLab.ViewedFiles || PRFeatures.GitLab.Stack || PRFeatures.GitLab.Agent || PRFeatures.GitLab.RequestReviewers);
    }

    [Fact]
    public async Task GitLabAdvertisesReview()
    {
        var stub = new ForgeStub();
        stub.Routes["/api/v4/merge_requests"] = (HttpStatusCode.OK, "[]");
        var client = new GitLabClient(Account(), GitCredential.Of("t"), client: stub.Client());
        var caps = await client.Capabilities();
        Assert.Equal(CapabilityState.Supported, caps.PullRequestReview);
        Assert.Equal(CapabilityState.Supported, caps.MergeRequirements);
        Assert.IsType<GitLabPRBackend>(((IForgeClient)client).ReviewBackend());
    }
}
