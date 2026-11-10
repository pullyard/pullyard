using System.Net;
using System.Text;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Forges;
using Xunit;

namespace PullYard.Core.Tests;

public class JobLogTests
{
    private static CheckContext Check(string typename, long? id, string? conclusion = "FAILURE", string? link = null) => new()
    {
        Typename = typename,
        DatabaseId = id,
        Name = "unit",
        Status = conclusion is null ? "IN_PROGRESS" : "COMPLETED",
        Conclusion = conclusion,
        DetailsUrl = link
    };

    [Fact]
    public void GitLabTraceCleanup()
    {
        var raw = "section_start:1700000000:prepare_script\r\u001B[0K\u001B[0K\u001B[36;1mPreparing\u001B[0;m\nprogress 10%\rprogress 100%\n\u001B[31mERROR: tests failed\u001B[0m\nsection_end:1700000001:prepare_script\r\u001B[0K";
        Assert.Equal("Preparing\nprogress 100%\nERROR: tests failed\n", GitLabReviewMapper.CleanTrace(raw));
    }

    [Fact]
    public async Task GitLabJobLog()
    {
        var stub = new ForgeStub();
        stub.Routes["/jobs/3/trace"] = (HttpStatusCode.OK, "line one\nERROR boom");
        var account = new GitAccount { Id = "t", Provider = GitProvider.GitLab, Host = "gitlab.example.com", Login = "s", CredentialKey = "t" };
        var backend = new GitLabPRBackend(new GitLabClient(account, GitCredential.Of("x"), client: stub.Client()));
        var r = new ItemRef(new RepoRef("group", "app"), 1);
        Assert.True(backend.CanShowLog(Check("GitLabJob", 3)));
        Assert.False(backend.CanShowLog(Check("GitLabJob", 3, conclusion: null)));
        Assert.False(backend.CanShowLog(Check("GitLabJob", 3, conclusion: "SKIPPED")));
        Assert.False(backend.CanShowLog(Check("CheckRun", 3)));
        var log = await backend.JobLog(r, Check("GitLabJob", 3));
        Assert.Equal("line one\nERROR boom", log);
        Assert.Equal("text/plain", stub.Requests[^1].Headers.Accept.ToString());
        Assert.Contains("/projects/group%2Fapp/jobs/3/trace", stub.Requests[^1].RequestUri!.AbsoluteUri);
    }

    [Fact]
    public void BitbucketBuildNumber()
    {
        Assert.Equal(42, BitbucketClient.BuildNumber("https://bitbucket.org/acme/api/pipelines/results/42"));
        Assert.Equal(7, BitbucketClient.BuildNumber("https://bitbucket.org/acme/api/addon/pipelines/home#!/results/7"));
        Assert.Null(BitbucketClient.BuildNumber("https://ci.example.com/build/9"));
        Assert.Null(BitbucketClient.BuildNumber(null));
    }

    private static GitAccount BitbucketAccount() =>
        new() { Id = "t", Provider = GitProvider.Bitbucket, Host = "bitbucket.org", Login = "s", Email = "s@x", UserId = "{u}", CredentialKey = "t" };

    [Fact]
    public async Task BitbucketPipelineLog()
    {
        var stub = new ForgeStub();
        stub.QueryRoutes.Add(("/steps/{s-1}/log", HttpStatusCode.OK, "compiled\n"));
        stub.QueryRoutes.Add(("/steps/{s-2}/log", HttpStatusCode.OK, "\u001B[31mFAIL\u001B[0m test_a\n"));
        stub.QueryRoutes.Add(("/steps/", HttpStatusCode.OK, """{"values":[{"uuid":"{s-1}","name":"Build","state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},{"uuid":"{s-2}","name":"Test","state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}"""));
        stub.Routes["/pipelines/42"] = (HttpStatusCode.OK, """{"uuid":"{p-1}","build_number":42,"state":{"name":"COMPLETED","result":{"name":"FAILED"}}}""");
        var backend = new BitbucketPRBackend(new BitbucketClient(BitbucketAccount(), GitCredential.Of("t"), stub.Client()));
        var r = new ItemRef(new RepoRef("acme", "api"), 5);
        var build = Check("BitbucketStatus", 1, link: "https://bitbucket.org/acme/api/pipelines/results/42");
        Assert.True(backend.CanShowLog(build));
        Assert.False(backend.CanShowLog(Check("BitbucketStatus", 1, link: "https://ci.example.com/9")));
        Assert.False(backend.CanShowLog(Check("BitbucketStatus", 1, conclusion: null, link: "https://bitbucket.org/acme/api/pipelines/results/42")));
        var log = await backend.JobLog(r, build);
        Assert.Equal("=== Build (successful) ===\ncompiled\n\n=== Test (failed) ===\nFAIL test_a", log);
    }

    [Fact]
    public async Task BitbucketPipelineFallsBackToListing()
    {
        var stub = new ForgeStub();
        stub.QueryRoutes.Add(("sort=-created_on", HttpStatusCode.OK, """{"values":[{"uuid":"{p-9}","build_number":41},{"uuid":"{p-1}","build_number":42}]}"""));
        stub.Routes["/pipelines/42"] = (HttpStatusCode.NotFound, """{"error":{"message":"not found"}}""");
        var client = new BitbucketClient(BitbucketAccount(), GitCredential.Of("t"), stub.Client());
        var pipeline = await client.Pipeline("acme/api", 42);
        Assert.Equal("{p-1}", pipeline.Uuid);
    }

    [Fact]
    public async Task BitbucketStepFailureIsReported()
    {
        var stub = new ForgeStub();
        stub.QueryRoutes.Add(("/steps/{s-1}/log", HttpStatusCode.InternalServerError, """{"error":{"message":"boom"}}"""));
        stub.QueryRoutes.Add(("/steps/", HttpStatusCode.OK, """{"values":[{"uuid":"{s-1}","name":"Build","state":{"name":"IN_PROGRESS"}}]}"""));
        stub.Routes["/pipelines/42"] = (HttpStatusCode.OK, """{"uuid":"{p-1}","build_number":42}""");
        var backend = new BitbucketPRBackend(new BitbucketClient(BitbucketAccount(), GitCredential.Of("t"), stub.Client()));
        var log = await backend.JobLog(new ItemRef(new RepoRef("acme", "api"), 5), Check("BitbucketStatus", 1, link: "https://bitbucket.org/acme/api/pipelines/results/42"));
        Assert.Equal("=== Build (in_progress) ===\nLog unavailable: Bitbucket 500: boom", log);
    }

    private sealed class RedirectStub : HttpMessageHandler
    {
        public List<(Uri Url, string? Authorization)> Requests { get; } = new();
        public Func<Uri, HttpResponseMessage> Reply { get; init; } = _ => new HttpResponseMessage(HttpStatusCode.NotFound);

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add((request.RequestUri!, request.Headers.TryGetValues("Authorization", out var v) ? v.First() : null));
            return Task.FromResult(Reply(request.RequestUri!));
        }
    }

    private static HttpResponseMessage Redirect(string location)
    {
        var response = new HttpResponseMessage(HttpStatusCode.Found);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    }

    private static HttpResponseMessage Ok(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "text/plain") };

    [Fact]
    public async Task DownloadFollowsSameHostWithCredentialsAndStorageWithout()
    {
        var stub = new RedirectStub
        {
            Reply = u => u.AbsolutePath switch
            {
                "/2.0/log" => Redirect("/2.0/moved"),
                "/2.0/moved" => Redirect("https://storage.example.com/blob?sig=1"),
                _ => Ok("text")
            }
        };
        var http = new ForgeHttp("https://api.bitbucket.org/2.0", "Bitbucket", "Bearer secret", new HttpClient(stub));
        Assert.Equal("text", await http.Download("/log"));
        Assert.Equal(3, stub.Requests.Count);
        Assert.Equal("Bearer secret", stub.Requests[1].Authorization);
        Assert.Equal("storage.example.com", stub.Requests[2].Url.Host);
        Assert.Null(stub.Requests[2].Authorization);
    }

    [Fact]
    public async Task DownloadRefusesInsecureCrossHostRedirect()
    {
        var stub = new RedirectStub { Reply = u => u.Host == "api.bitbucket.org" ? Redirect("http://storage.example.com/blob") : Ok("leak") };
        var http = new ForgeHttp("https://api.bitbucket.org/2.0", "Bitbucket", "Bearer secret", new HttpClient(stub));
        await Assert.ThrowsAsync<ApiException>(() => http.Download("/log"));
        Assert.Single(stub.Requests);
    }

    [Fact]
    public void GitHubOnlyShowsActionsJobs()
    {
        var backend = new GitHubPRBackend(new GitHubApi("x"));
        var job = Check("CheckRun", 5);
        job.CheckSuite = new CheckSuite { WorkflowRun = new WorkflowRun { DatabaseId = 9, Workflow = new WorkflowInfo { Name = "CI" } } };
        Assert.True(backend.CanShowLog(job));
        Assert.False(backend.CanShowLog(Check("StatusContext", null)));
    }

    [Fact]
    public void FeaturesEnableJobLogs()
    {
        Assert.True(PRFeatures.GitLab.JobLogs);
        Assert.True(PRFeatures.Bitbucket.JobLogs);
    }
}
