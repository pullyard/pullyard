using System.Net;
using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Forges;
using PullYard.Core.Html;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class ForgeCodeOwnersTests
{
    private const string GitLabText = """
    * @everyone
    [Backend] @backend-team
    app/
    app/billing/ @billing @alice
    ^[Docs][2] @docs/writers
    *.md
    [Security]
    app/auth/ @security
    """;

    [Fact]
    public void GitLabSectionsUnionOwners()
    {
        var o = new CodeOwners(GitLabText, "CODEOWNERS", CodeOwnersFlavor.GitLab);
        Assert.Empty(o.InvalidLines);
        Assert.Equal(new[] { "@everyone", "@billing", "@alice" }, o.OwnersFor("app/billing/pay.rb"));
        Assert.Equal(new[] { "@everyone", "@backend-team" }, o.OwnersFor("app/models/user.rb"));
        Assert.Equal(new[] { "@everyone", "@backend-team", "@docs/writers" }, o.OwnersFor("app/README.md"));
        Assert.Equal(new[] { "@everyone", "@backend-team", "@security" }, o.OwnersFor("app/auth/login.rb"));
        Assert.Equal(new[] { "@everyone" }, o.OwnersFor("Gemfile"));

        var github = new CodeOwners(GitLabText);
        Assert.NotEmpty(github.InvalidLines);
        Assert.Equal(new[] { "@docs/writers" }, CodeOwners.SectionHeader("^[Docs][2] @docs/writers"));
        Assert.Equal(Array.Empty<string>(), CodeOwners.SectionHeader("[Security]"));
        Assert.Null(CodeOwners.SectionHeader("app/ @x"));
        Assert.Null(CodeOwners.SectionHeader("[]"));
    }

    [Fact]
    public void GitLabOwnersDeduplicateCaseInsensitively()
    {
        var o = new CodeOwners("* @Alice\n[A]\n*.rb @alice @bob\n", "CODEOWNERS", CodeOwnersFlavor.GitLab);
        Assert.Equal(new[] { "@Alice", "@bob" }, o.OwnersFor("x.rb"));
    }

    [Fact]
    public async Task GitLabBackendReadsFirstExistingFile()
    {
        var stub = new ForgeStub();
        stub.QueryRoutes.Add(("/repository/files/docs/CODEOWNERS/raw", HttpStatusCode.OK, "[Docs] @writers\n*.md\n"));
        var account = new GitAccount { Id = "t", Provider = GitProvider.GitLab, Host = "gitlab.example.com", Login = "s", CredentialKey = "t" };
        var backend = new GitLabPRBackend(new GitLabClient(account, GitCredential.Of("x"), client: stub.Client()));
        var owners = await backend.CodeOwners(new ItemRef(new RepoRef("group", "app"), 1), "base1");
        Assert.Equal("docs/CODEOWNERS", owners?.Path);
        Assert.Equal(CodeOwnersFlavor.GitLab, owners?.Flavor);
        Assert.Equal(new[] { "@writers" }, owners?.OwnersFor("README.md"));
        var urls = stub.Requests.Select(r => r.RequestUri!.AbsoluteUri).ToList();
        Assert.Contains(urls, u => u.Contains("files/CODEOWNERS/raw?ref=base1", StringComparison.Ordinal));
        Assert.Contains(urls, u => u.Contains("files/docs%2FCODEOWNERS/raw?ref=base1", StringComparison.Ordinal));
        Assert.DoesNotContain(urls, u => u.Contains(".gitlab", StringComparison.Ordinal));
    }

    [Fact]
    public async Task BitbucketBackendAndMissingFile()
    {
        var stub = new ForgeStub();
        stub.Routes["/src/base9/.bitbucket/CODEOWNERS"] = (HttpStatusCode.OK, "src/ @acme/core\n");
        var account = new GitAccount { Id = "t", Provider = GitProvider.Bitbucket, Host = "bitbucket.org", Login = "s", Email = "s@x", UserId = "{u}", CredentialKey = "t" };
        var backend = new BitbucketPRBackend(new BitbucketClient(account, GitCredential.Of("t"), stub.Client()));
        var r = new ItemRef(new RepoRef("acme", "api"), 5);
        var owners = await backend.CodeOwners(r, "base9");
        Assert.Equal(".bitbucket/CODEOWNERS", owners?.Path);
        Assert.Equal(CodeOwnersFlavor.GitHub, owners?.Flavor);
        Assert.Equal(new[] { "@acme/core" }, owners?.OwnersFor("src/a.swift"));
        stub.Routes.Clear();
        Assert.Null(await backend.CodeOwners(r, "base9"));
        Assert.Single(stub.Containing("/src/base9/CODEOWNERS"));
    }

    [Fact]
    public void OwnersOfFileAndHeaderLabel()
    {
        const string json = """
        {"id":"PR_1","number":7,"title":"T","url":"u","state":"OPEN","isDraft":false,"merged":false,"mergeable":"MERGEABLE",
         "body":"","bodyHTML":"","createdAt":"2026-01-01T00:00:00Z","headRefName":"f","baseRefName":"main","headRefOid":"h",
         "additions":1,"deletions":1,"changedFiles":2,"viewerCanUpdate":true,"viewerDidAuthor":false,
         "labels":{"nodes":[]},"assignees":{"nodes":[]},"reviewRequests":{"nodes":[]},
         "latestOpinionatedReviews":{"nodes":[{"state":"APPROVED","author":{"login":"alice","avatarUrl":""}}]},
         "lastCommit":{"nodes":[]},"allCommits":{"nodes":[]},"timelineItems":{"nodes":[]},"reviewThreads":{"nodes":[]}}
        """;
        var pr = JsonSerializer.Deserialize<PullRequestDetail>(json, Json.GraphQL)!;
        var summary = OwnershipSummary.Build(new CodeOwners("app/ @alice @bob @carol"), new[] { "app/a.rb", "README.md" }, pr);
        Assert.Equal(new[] { "alice", "bob", "carol" }, summary.OwnersOf("app/a.rb")!.Select(e => e.Handle));
        Assert.Equal(OwnerStatus.Approved, summary.OwnersOf("app/a.rb")![0].Status);
        Assert.Null(summary.OwnersOf("README.md"));
        Assert.Equal(new[] { "README.md" }, summary.Unowned);

        var label = DiffHtml.OwnersLabel(summary.OwnersOf("app/a.rb")!, new DiffRenderOptions());
        Assert.Contains("own ok", label);
        Assert.Contains("@alice, @bob +1", label);
        Assert.Contains("Code owners: @alice, @bob, @carol · approved", label);
        var muted = DiffHtml.OwnersLabel(new[] { new OwnerEntry("dev", false, OwnerStatus.Requested) }, new DiffRenderOptions());
        Assert.DoesNotContain("own ok", muted);
        Assert.DoesNotContain("approved", muted);
    }
}
