using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Jira;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class JiraTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "pullyard-jira-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    private sealed class MemoryVault : ICredentialVault
    {
        public Dictionary<string, string> Values { get; } = new();
        public string? Load(string key) => Values.TryGetValue(key, out var v) ? v : null;
        public void Save(string key, string value) => Values[key] = value;
        public bool Delete(string key) => Values.Remove(key) || true;
    }

    [Fact]
    public void ExtractsKeysInOrderWithoutDuplicates()
    {
        Assert.Equal(new[] { "ABC-12", "PAY_2-7" }, JiraKeys.Extract("Fix ABC-12 and PAY_2-7, see ABC-12"));
    }

    [Theory]
    [InlineData("UTF-8 handling")]
    [InlineData("SHA-256 and ISO-8601")]
    [InlineData("abc-12")]
    [InlineData("ABC-0")]
    [InlineData("A-12")]
    [InlineData("XABC-12x")]
    [InlineData("ABCDEFGHIJK-1")]
    [InlineData("ABC-12345678")]
    public void IgnoresNonKeys(string text)
    {
        Assert.Empty(JiraKeys.Extract(text));
    }

    [Fact]
    public void DetectsFromTitleBranchAndBody()
    {
        Assert.Equal(new[] { "ONE-1", "TWO-2", "THREE-3" }, JiraKeys.Detected("ONE-1: thing", "feature/two-2-login", "Closes THREE-3 and ONE-1"));
        Assert.Empty(JiraKeys.Detected("plain", "feature/utf-8", ""));
        Assert.Equal(new[] { "MAN-9", "ONE-1" }, JiraKeys.ForPullRequest(new[] { "MAN-9", "ONE-1" }, "ONE-1", "", ""));
        Assert.Equal("ABC-7", JiraKeys.Normalize(" abc-7 "));
        Assert.Null(JiraKeys.Normalize("nope"));
    }

    [Fact]
    public void AuthorizationUsesBasicOrBearer()
    {
        Assert.Equal("Bearer tok", JiraAuth.Authorization("", "tok"));
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("me@x.com:tok")), JiraAuth.Authorization("me@x.com", "tok"));
    }

    [Theory]
    [InlineData("acme.atlassian.net", "https://acme.atlassian.net")]
    [InlineData(" https://acme.atlassian.net/ ", "https://acme.atlassian.net")]
    [InlineData("jira.example.com/jira//", "https://jira.example.com/jira")]
    public void NormalizesSite(string site, string expected)
    {
        Assert.Equal(expected, JiraAuth.BaseString(JiraAuth.BaseUrl(site)!));
    }

    [Theory]
    [InlineData("")]
    [InlineData("http://acme.atlassian.net")]
    public void RejectsBadSites(string site)
    {
        Assert.Null(JiraAuth.BaseUrl(site));
    }

    private const string IssueJson = """
    {
      "key": "ABC-12",
      "fields": {
        "summary": "Login fails",
        "status": { "name": "In Progress", "statusCategory": { "key": "indeterminate" } },
        "issuetype": { "name": "Bug" },
        "priority": { "name": "High" },
        "assignee": { "displayName": "Ann", "avatarUrls": { "48x48": "https://a/48.png" } },
        "reporter": { "displayName": "Bob" },
        "description": "raw *wiki*",
        "updated": "2024-03-05T10:11:12.000+0100"
      },
      "renderedFields": { "description": "<p>Steps:</p><ul><li>Open &amp; tap</li><li>See &lt;error&gt;</li></ul><br/>Done" }
    }
    """;

    [Fact]
    public void ParsesIssue()
    {
        var issue = JiraClient.ParseIssue((JsonObject)JsonNode.Parse(IssueJson)!, new Uri("https://acme.atlassian.net"));
        Assert.Equal("ABC-12", issue.Key);
        Assert.Equal("Login fails", issue.Summary);
        Assert.Equal("In Progress", issue.Status);
        Assert.Equal("indeterminate", issue.StatusCategory);
        Assert.Equal("Bug", issue.Type);
        Assert.Equal("High", issue.Priority);
        Assert.Equal("Ann", issue.Assignee);
        Assert.Equal("https://a/48.png", issue.AssigneeAvatar);
        Assert.Equal("Bob", issue.Reporter);
        Assert.Equal("Steps:\n\n• Open & tap\n• See <error>\n\nDone", issue.Description);
        Assert.Equal("https://acme.atlassian.net/browse/ABC-12", issue.Url);
        Assert.Equal(new DateTimeOffset(2024, 3, 5, 10, 11, 12, TimeSpan.FromHours(1)), issue.Updated);
    }

    [Fact]
    public void ParsesSparseIssueAndTransitions()
    {
        var issue = JiraClient.ParseIssue(new JsonObject { ["key"] = "X1-1", ["fields"] = new JsonObject { ["description"] = "plain" } }, new Uri("https://j.example.com/jira"));
        Assert.Equal("plain", issue.Description);
        Assert.Null(issue.Assignee);
        Assert.Null(issue.Updated);
        Assert.Equal("https://j.example.com/jira/browse/X1-1", issue.Url);
        var transitions = JiraClient.ParseTransitions((JsonObject)JsonNode.Parse("""{"transitions":[{"id":"11","name":"Start","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"21","name":"Done"},{"name":"broken"}]}""")!);
        Assert.Equal(2, transitions.Count);
        Assert.Equal("Start → In Progress", transitions[0].Title);
        Assert.Equal("Done", transitions[1].Title);
        Assert.Equal("", transitions[1].ToCategory);
    }

    [Fact]
    public void MapsErrors()
    {
        Assert.Equal("Jira rejected the credentials (401). Check the email and API token.", JiraClient.Failure(401, Array.Empty<byte>()).Message);
        Assert.Equal("Issue does not exist", JiraClient.Failure(404, Encoding.UTF8.GetBytes("""{"errorMessages":["Issue does not exist"]}""")).Message);
        Assert.Equal("No permission in Jira (403)", JiraClient.Failure(403, Encoding.UTF8.GetBytes("oops")).Message);
        Assert.Equal("Jira 500: boom", JiraClient.Failure(500, Encoding.UTF8.GetBytes("""{"message":"boom"}""")).Message);
    }

    [Fact]
    public async Task ClientSendsAuthAndParses()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/issue/ABC-12"] = (HttpStatusCode.OK, IssueJson);
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.OK, """{"displayName":"Ann"}""");
        var client = new JiraClient(new Uri("https://acme.atlassian.net"), "Bearer t", stub.Client());
        Assert.Equal("Ann", await client.Myself());
        var issue = await client.Issue("ABC-12");
        Assert.Equal("Login fails", issue.Summary);
        var req = stub.Requests[^1];
        Assert.Equal("Bearer t", req.Headers.GetValues("Authorization").Single());
        Assert.Equal("no-check", req.Headers.GetValues("X-Atlassian-Token").Single());
        Assert.Contains("expand=renderedFields", req.RequestUri!.Query);
        await Assert.ThrowsAsync<ApiException>(() => client.Issue("NOPE-1"));
    }

    [Fact]
    public async Task AccountConnectsCachesAndLinks()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.OK, """{"name":"ann"}""");
        stub.Routes["/rest/api/2/issue/ABC-12"] = (HttpStatusCode.OK, IssueJson);
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        var vault = new MemoryVault();
        var clock = DateTimeOffset.FromUnixTimeSeconds(1000);
        var account = new JiraAccount(settings, vault, stub.Client(), () => clock);
        Assert.False(account.IsConfigured);
        Assert.Null(account.Client());
        await account.Connect("acme.atlassian.net", "", " tok ");
        Assert.True(account.IsConfigured);
        Assert.Equal("ann", account.DisplayName);
        Assert.Equal("tok", vault.Values[JiraAccount.TokenKey]);
        Assert.Equal("Bearer tok", stub.Requests[0].Headers.GetValues("Authorization").Single());

        await account.Load("ABC-12");
        await account.Load("ABC-12");
        Assert.Single(stub.Containing("/issue/ABC-12"));
        clock = clock.AddSeconds(61);
        Assert.Null(account.CachedIssue("ABC-12"));
        await account.Load("ABC-12");
        Assert.Equal(2, stub.Containing("/issue/ABC-12").Count);

        var pr = new PullRequestDetail { Url = "https://github.com/a/b/pull/1", Title = "ONE-1 thing", HeadRefName = "main", Body = "" };
        Assert.Equal("MAN-5", account.Link(pr.Url, "man-5"));
        Assert.Null(account.Link(pr.Url, "??"));
        Assert.Equal(new[] { "MAN-5", "ONE-1" }, account.Keys(pr));
        var reloaded = new JiraAccount(new Settings(Path.Combine(dir, "settings.json")), vault);
        Assert.Equal(new[] { "MAN-5" }, reloaded.LinkedKeys(pr.Url));
        Assert.NotNull(reloaded.Client());
        account.Unlink(pr.Url, "MAN-5");
        Assert.Empty(account.LinkedKeys(pr.Url));

        account.Disconnect();
        Assert.False(account.IsConfigured);
        Assert.False(vault.Values.ContainsKey(JiraAccount.TokenKey));
        Assert.True(account.ShowsTab(pr));
        Assert.False(account.ShowsTab(new PullRequestDetail { Url = "u", Title = "plain", HeadRefName = "main" }));
    }

    [Fact]
    public async Task ConnectFailureKeepsTokenOut()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.Unauthorized, "{}");
        var vault = new MemoryVault();
        var account = new JiraAccount(new Settings(Path.Combine(dir, "settings.json")), vault, stub.Client());
        await Assert.ThrowsAsync<ApiException>(() => account.Connect("acme.atlassian.net", "me@x.com", "bad"));
        Assert.Empty(vault.Values);
        Assert.False(account.IsConfigured);
        await Assert.ThrowsAsync<ApiException>(() => account.Connect("http://insecure", "", "t"));
    }

    [Fact]
    public void OneClickNeedsBundledIdAndGitHub()
    {
        Assert.Null(OAuthApp.Normalize("  "));
        Assert.Null(OAuthApp.Normalize(null));
        Assert.Equal("Iv1.abc", OAuthApp.Normalize(" Iv1.abc "));
        Assert.True(OAuthApp.OneClick(GitProvider.GitHub, "Iv1.abc"));
        Assert.False(OAuthApp.OneClick(GitProvider.GitHub, ""));
        Assert.False(OAuthApp.OneClick(GitProvider.GitHubEnterprise, "Iv1.abc"));
        Assert.False(OAuthApp.OneClick(GitProvider.GitLab, "Iv1.abc"));
        Assert.Null(OAuthApp.Bundled);
    }
}
