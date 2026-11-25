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
        Assert.Equal(new[] { "MAN-9", "TWO-2" }, JiraKeys.ForPullRequest(new[] { "MAN-9" }, "ONE-1 TWO-2", "", "", new[] { "ONE-1", "MAN-9" }));
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
    [InlineData("https://minitok.atlassian.net/jira/software/c/projects/COM/list?jql=project%20%3D%20COM", "https://minitok.atlassian.net")]
    [InlineData("https://jira.example.com/jira/browse/PAY-1", "https://jira.example.com/jira")]
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
        "updated": "2024-03-05T10:11:12.000+0100",
        "parent": { "key": "ABC-1", "fields": { "summary": "Auth epic" } }
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
        Assert.Equal("Steps:\n\n• Open & tap\n• See <error>\nDone", issue.Description);
        Assert.Equal("https://acme.atlassian.net/browse/ABC-12", issue.Url);
        Assert.Equal(new DateTimeOffset(2024, 3, 5, 10, 11, 12, TimeSpan.FromHours(1)), issue.Updated);
        Assert.Equal("ABC-1", issue.ParentKey);
        Assert.Equal("Auth epic", issue.ParentSummary);
    }

    [Fact]
    public void TablesAndPanelsBecomeReadableText()
    {
        const string html = "<p>PR 2 of 2 for</p><div class=\"table-wrap\"><table><tbody><tr><td>\n  <a href=\"x\">COM-1563</a>\n</td><td>\n\n DONE \n</td></tr></tbody></table></div><p>&nbsp;</p><p>Next</p>";
        Assert.Equal("PR 2 of 2 for\nCOM-1563 · DONE\n\nNext", JiraText.PlainText(html));
    }

    [Fact]
    public void PreformattedTextKeepsLineBreaks()
    {
        Assert.Equal("Run:\nnpm ci\nnpm test", JiraText.PlainText("<p>Run:</p><pre>npm   ci\nnpm test</pre>"));
    }

    [Fact]
    public void ParsesSparseIssueAndTransitions()
    {
        var issue = JiraClient.ParseIssue(new JsonObject { ["key"] = "X1-1", ["fields"] = new JsonObject { ["description"] = "plain" } }, new Uri("https://j.example.com/jira"));
        Assert.Equal("plain", issue.Description);
        Assert.Null(issue.Assignee);
        Assert.Null(issue.Updated);
        Assert.Null(issue.ParentKey);
        Assert.Null(issue.ParentSummary);
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
        Assert.Contains("parent", req.RequestUri!.Query);
        await Assert.ThrowsAsync<ApiException>(() => client.Issue("NOPE-1"));
    }

    [Fact]
    public async Task ConnectionsConnectCacheAndLink()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.OK, """{"name":"ann"}""");
        stub.Routes["/rest/api/3/project/search"] = (HttpStatusCode.OK, """{"values":[{"key":"ABC"},{"key":"OPS"}],"isLast":true,"total":2}""");
        stub.Routes["/rest/api/2/issue/ABC-12"] = (HttpStatusCode.OK, IssueJson);
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        var vault = new MemoryVault();
        var clock = DateTimeOffset.FromUnixTimeSeconds(1000);
        var store = new JiraConnections(settings, vault, stub.Client(), () => clock);
        Assert.False(store.IsConfigured);
        var added = await store.Add("", "acme.atlassian.net/browse/ABC-1", "", " tok ");
        Assert.True(store.IsConfigured);
        Assert.False(store.HasSeveral);
        Assert.Equal("Acme", added.Name);
        Assert.Equal("ann", added.DisplayName);
        Assert.Equal(new[] { "ABC", "OPS" }, added.ProjectKeys);
        Assert.Equal("acme.atlassian.net · ABC, OPS", added.ProjectSummary);
        Assert.Equal("tok", vault.Values[JiraConnections.TokenKey(added.Id)]);
        Assert.Equal("Bearer tok", stub.Requests[0].Headers.GetValues("Authorization").Single());

        var issue = await store.FetchIssue("ABC-12", null);
        Assert.Equal(added.Id, issue.ConnectionId);
        Assert.Equal("https://acme.atlassian.net", issue.SiteBase);
        await store.FetchIssue("ABC-12", null);
        Assert.Single(stub.Containing("/issue/ABC-12"));
        clock = clock.AddSeconds(61);
        Assert.Null(store.CachedIssue("ABC-12", null));
        await store.FetchIssue("ABC-12", null);
        Assert.Equal(2, stub.Containing("/issue/ABC-12").Count);
        store.ClearCache();
        Assert.Null(store.CachedIssue("ABC-12", null));

        var pr = new PullRequestDetail { Url = "https://github.com/a/b/pull/1", Title = "ONE-1 thing", HeadRefName = "main", Body = "" };
        Assert.Equal("MAN-5", store.Link(pr.Url, "man-5"));
        Assert.Null(store.Link(pr.Url, "??"));
        Assert.Equal(new[] { "MAN-5", "ONE-1" }, store.Keys(pr));
        var reloaded = new JiraConnections(new Settings(Path.Combine(dir, "settings.json")), vault);
        Assert.Equal(new[] { "MAN-5" }, reloaded.LinkedKeys(pr.Url));
        Assert.NotNull(reloaded.Client(added.Id));
        Assert.Equal(new[] { "ABC", "OPS" }, reloaded.Connection(added.Id)!.ProjectKeys);
        store.Unlink(pr.Url, "MAN-5");
        Assert.Empty(store.LinkedKeys(pr.Url));

        store.Hide(pr.Url, "ONE-1");
        Assert.Empty(store.Keys(pr));
        store.ShowHidden(pr.Url);
        Assert.Equal(new[] { "ONE-1" }, store.Keys(pr));
        store.Hide(pr.Url, "ONE-1");
        Assert.Equal("ONE-1", store.Link(pr.Url, "one-1"));
        Assert.Empty(store.HiddenKeys(pr.Url));
        store.Unlink(pr.Url, "ONE-1");

        store.SetRepoOverride(added.Id, new RepoRef("Acme", "App"));
        store.Remove(added.Id);
        Assert.False(store.IsConfigured);
        Assert.Empty(store.RepoOverrides);
        Assert.False(vault.Values.ContainsKey(JiraConnections.TokenKey(added.Id)));
        Assert.True(store.ShowsTab(pr));
        Assert.False(store.ShowsTab(new PullRequestDetail { Url = "u", Title = "plain", HeadRefName = "main" }));
    }

    [Fact]
    public async Task FetchFallsBackAcrossConnectionsAndLearns()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.OK, """{"name":"ann"}""");
        stub.Routes["/rest/api/3/project/search"] = (HttpStatusCode.NotFound, "{}");
        stub.Routes["/rest/api/2/project"] = (HttpStatusCode.OK, """[{"key":"OLD"}]""");
        stub.Routes["/rest/api/2/issue/ABC-12"] = (HttpStatusCode.OK, IssueJson);
        var store = new JiraConnections(new Settings(Path.Combine(dir, "settings.json")), new MemoryVault(), stub.Client());
        var a = await store.Add("A", "a.atlassian.net", "", "t1");
        var b = await store.Add("B", "b.atlassian.net", "", "t2");
        Assert.True(store.HasSeveral);
        Assert.Equal(new[] { "OLD" }, a.ProjectKeys);
        Assert.Null(store.Resolve("ABC-12", null));
        var issue = await store.FetchIssue("ABC-12", null);
        Assert.Equal(a.Id, issue.ConnectionId);
        Assert.Equal((a.Id, JiraRouteSource.Learned), store.Route("ABC-12", null)!.Value);
        Assert.Equal("A", store.Names(new[] { issue }));
        var repo = new RepoRef("Mabrook", "App");
        store.SetOrgOverride(b.Id, "Mabrook");
        Assert.Equal(b.Id, store.ConnectionForRepo(repo));
        Assert.Null(store.Override(repo).Repo);
        Assert.Equal(b.Id, store.Override(repo).Org);
        store.SetOrgOverride(null, "mabrook");
        Assert.Null(store.ConnectionForRepo(repo));
    }

    [Fact]
    public void MigratesLegacyConnectionOnce()
    {
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        settings.Set("jira.site", "acme.atlassian.net");
        settings.Set("jira.email", "a@b.c");
        settings.Set("jira.name", "Ann");
        settings.Set("jira.hasToken", true);
        var vault = new MemoryVault();
        vault.Save(JiraConnections.LegacyTokenKey, "legacy");
        var store = new JiraConnections(settings, vault, new ForgeStub().Client());
        var only = Assert.Single(store.Connections);
        Assert.Equal("Acme", only.Name);
        Assert.Equal("a@b.c", only.Email);
        Assert.Equal("Ann", only.DisplayName);
        Assert.Equal("legacy", vault.Values[JiraConnections.TokenKey(only.Id)]);
        Assert.False(vault.Values.ContainsKey(JiraConnections.LegacyTokenKey));
        Assert.False(settings.Contains("jira.hasToken"));
        store.Remove(only.Id);
        vault.Save(JiraConnections.LegacyTokenKey, "again");
        Assert.Empty(new JiraConnections(settings, vault).Connections);
        Assert.Equal("Acme", JiraConnections.ShortName("acme.atlassian.net"));
    }

    [Fact]
    public void RoutesByOverrideThenProjectKeyThenLearned()
    {
        var a = new JiraConnection { Id = "a", Name = "Work A", Site = "a.atlassian.net", Email = "", ProjectKeys = new() { "COM", "PAY" } };
        var b = new JiraConnection { Id = "b", Name = "Work B", Site = "b.atlassian.net", Email = "", ProjectKeys = new() { "OPS", "PAY" } };
        var both = new List<JiraConnection> { a, b };
        var repo = new RepoRef("Mabrook", "App");
        string? Route(string key, RepoRef? r = null, Dictionary<string, string>? org = null, Dictionary<string, string>? repos = null, Dictionary<string, string>? learned = null, List<JiraConnection>? list = null) =>
            JiraConnections.Route(key, r, list ?? both, org ?? new(), repos ?? new(), learned ?? new())?.Id;
        Assert.Equal("a", Route("COM-1"));
        Assert.Equal("b", Route("OPS-12"));
        Assert.Null(Route("PAY-3"));
        Assert.Equal("b", Route("PAY-3", learned: new() { ["PAY"] = "b" }));
        Assert.Null(Route("NEW-1"));
        Assert.Equal("a", Route("NEW-1", learned: new() { ["NEW"] = "a" }));
        Assert.Equal("a", Route("OPS-1", repo, org: new() { ["mabrook"] = "a" }));
        Assert.Equal("b", Route("OPS-1", repo, org: new() { ["mabrook"] = "a" }, repos: new() { ["mabrook/app"] = "b" }));
        Assert.Equal("b", Route("OPS-1", repo, org: new() { ["mabrook"] = "gone" }));
        Assert.Equal("a", Route("XYZ-9", list: new() { a }));
        Assert.Equal("COM", JiraConnections.ProjectKey("com-12"));
    }

    [Fact]
    public void FixPromptListsUpToThreeTickets()
    {
        JiraIssue Ticket(string key, string description) => new(key, "Sum " + key, "To Do", "new", null, null, null, null, null, description, "https://a.atlassian.net/browse/" + key, null);
        var text = Claude.FixPrompt.Tickets(new[] { Ticket("A-1", new string('x', 1300)), Ticket("A-2", ""), Ticket("A-3", "line1\nline2"), Ticket("A-4", "") });
        Assert.StartsWith("\n## Linked Jira tickets\n", text);
        Assert.Contains("**A-1** — Sum A-1 (To Do)\nhttps://a.atlassian.net/browse/A-1\n> " + new string('x', 1200) + "…", text);
        Assert.Contains("> line1\n> line2", text);
        Assert.DoesNotContain("A-4", text);
        Assert.Equal("", Claude.FixPrompt.Tickets(Array.Empty<JiraIssue>()));
    }

    [Fact]
    public async Task ConnectFailureKeepsTokenOut()
    {
        var stub = new ForgeStub();
        stub.Routes["/rest/api/2/myself"] = (HttpStatusCode.Unauthorized, "{}");
        var vault = new MemoryVault();
        var store = new JiraConnections(new Settings(Path.Combine(dir, "settings.json")), vault, stub.Client());
        await Assert.ThrowsAsync<ApiException>(() => store.Add("", "acme.atlassian.net", "me@x.com", "bad"));
        Assert.Empty(vault.Values);
        Assert.False(store.IsConfigured);
        await Assert.ThrowsAsync<ApiException>(() => store.Add("", "http://insecure", "", "t"));
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
