using System.Net;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Forges;
using Xunit;

namespace PullYard.Core.Tests;

public class MergeQueueActionTests
{
    private static readonly ItemRef Ref = new(new RepoRef("group", "app"), 7);

    private static PullRequestDetail Pr(string head) => new() { Id = "PR_1", Number = 7, HeadRefOid = head, BaseRefName = "main", HeadRefName = "f" };

    private static List<HttpRequestMessage> Requests(ForgeStub stub, string method, string suffix)
    {
        lock (stub.Requests) return stub.Requests.Where(r => r.Method.Method == method && r.RequestUri!.AbsolutePath.EndsWith(suffix, StringComparison.Ordinal)).ToList();
    }

    private static JsonObject Body(ForgeStub stub, HttpRequestMessage request) => JsonNode.Parse(stub.Body(request)) as JsonObject ?? new();

    [Fact]
    public void MutationsAndFeatures()
    {
        Assert.Contains("enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $oid})", Q.Enqueue);
        Assert.Contains("$oid: GitObjectID", Q.Enqueue);
        Assert.Contains("dequeuePullRequest(input: {id: $id})", Q.Dequeue);
        Assert.True(PRFeatures.GitHub.MergeQueue);
        Assert.True(PRFeatures.GitLab.MergeQueue);
        Assert.False(PRFeatures.Bitbucket.MergeQueue);
        Assert.Equal("merge queue", PRFeatures.GitHub.QueueTitle);
        Assert.Equal("merge train", PRFeatures.GitLab.QueueTitle);
    }

    [Fact]
    public async Task GitHubEnqueueSendsHeadAndDequeueSendsId()
    {
        var stub = new ForgeStub();
        stub.Routes["/graphql"] = (HttpStatusCode.OK, """{"data":{}}""");
        var backend = new GitHubPRBackend(new GitHubApi("t", stub.Client()));
        await backend.Perform(PRAction.Enqueue, Ref, Pr("abc123"));
        var add = Body(stub, Requests(stub, "POST", "/graphql").Last());
        Assert.Equal(Q.Enqueue, add["query"]!.GetValue<string>());
        Assert.Equal("PR_1", add["variables"]!["id"]!.GetValue<string>());
        Assert.Equal("abc123", add["variables"]!["oid"]!.GetValue<string>());

        await backend.Perform(PRAction.Enqueue, Ref, Pr(""));
        Assert.Null(Body(stub, Requests(stub, "POST", "/graphql").Last())["variables"]!["oid"]);

        await backend.Perform(PRAction.Dequeue, Ref, Pr("abc123"));
        var remove = Body(stub, Requests(stub, "POST", "/graphql").Last());
        Assert.Equal(Q.Dequeue, remove["query"]!.GetValue<string>());
        Assert.Equal("PR_1", remove["variables"]!["id"]!.GetValue<string>());
    }

    [Fact]
    public async Task GitLabTrainActions()
    {
        var stub = new ForgeStub();
        stub.Routes["/merge_trains/merge_requests/7"] = (HttpStatusCode.Created, "{}");
        stub.Routes["/merge_requests/7/cancel_merge_when_pipeline_succeeds"] = (HttpStatusCode.Created, "{}");
        var account = new GitAccount { Id = "test", Provider = GitProvider.GitLab, Host = "gitlab.example.com", Login = "sofia", CredentialKey = "test" };
        var backend = new GitLabPRBackend(new GitLabClient(account, GitCredential.Of("glpat-x"), client: stub.Client()));

        await backend.Perform(PRAction.Enqueue, Ref, Pr("abc123"));
        var add = Assert.Single(Requests(stub, "POST", "/merge_trains/merge_requests/7"));
        Assert.EndsWith("/projects/group%2Fapp/merge_trains/merge_requests/7", add.RequestUri!.AbsolutePath);
        var json = Body(stub, add);
        Assert.Equal("abc123", json["sha"]!.GetValue<string>());
        Assert.True(json["when_pipeline_succeeds"]!.GetValue<bool>());

        await backend.Perform(PRAction.Enqueue, Ref, Pr(""));
        Assert.False(Body(stub, Requests(stub, "POST", "/merge_trains/merge_requests/7").Last()).ContainsKey("sha"));

        await backend.Perform(PRAction.Dequeue, Ref, Pr("abc123"));
        Assert.Single(Requests(stub, "POST", "/merge_requests/7/cancel_merge_when_pipeline_succeeds"));
    }

    [Fact]
    public async Task BitbucketRejectsQueueActions()
    {
        var stub = new ForgeStub();
        var account = new GitAccount { Id = "test", Provider = GitProvider.Bitbucket, Host = "bitbucket.org", Login = "sofia", Email = "s@example.com", UserId = "{u}", CredentialKey = "test" };
        var backend = new BitbucketPRBackend(new BitbucketClient(account, GitCredential.Of("tok"), stub.Client()));
        var error = await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => backend.Perform(PRAction.Enqueue, Ref, Pr("h")));
        Assert.Equal("Not available for Bitbucket yet", error.Message);
        await Assert.ThrowsAsync<PRBackendUnsupportedException>(() => backend.Perform(PRAction.Dequeue, Ref, Pr("h")));
        Assert.Empty(stub.Requests);
    }
}
