using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Git;
using Xunit;

namespace PullYard.Core.Tests;

public class GitRemoteTests
{
    [Fact]
    public void ParsesCommonUrlForms()
    {
        Assert.Equal(new GitRemote("github.com", "acme/app"), GitRemote.Parse("git@github.com:acme/app.git\n"));
        Assert.Equal(new GitRemote("github.com", "acme/app"), GitRemote.Parse("https://github.com/acme/app"));
        Assert.Equal(new GitRemote("gitlab.example.com", "group/sub/app"), GitRemote.Parse("https://user@gitlab.example.com:8443/group/sub/app.git"));
        Assert.Equal(new GitRemote("bitbucket.org", "team/app"), GitRemote.Parse("ssh://git@bitbucket.org/team/app.git"));
        Assert.Null(GitRemote.Parse(""));
        Assert.Null(GitRemote.Parse(null));
        Assert.Null(GitRemote.Parse("/local/path/repo.git"));
        Assert.Null(GitRemote.Parse("C:\\code\\acme\\repo.git"));
        Assert.Null(GitRemote.Parse("C:/code/acme/repo.git"));
        Assert.Null(GitRemote.Parse("https://github.com/only-owner"));
    }

    [Fact]
    public void OnlyGitHubDotComYieldsRepoRef()
    {
        Assert.Equal("acme/app", GitRemote.Parse("git@github.com:acme/app.git")?.Repo?.Full);
        Assert.Null(GitRemote.Parse("git@gitlab.com:acme/app.git")?.Repo);
        Assert.Equal("acme/app", GitCli.ParseRemote("git@github.com:acme/app.git")?.Full);
        Assert.Null(GitCli.ParseRemote("git@gitlab.com:acme/app.git"));
    }

    [Fact]
    public void KindAndNewRequestUrl()
    {
        var lab = new GitRemote("gitlab.com", "acme/app");
        Assert.Equal(GitRemoteKind.GitLab, lab.Kind);
        Assert.Equal("https://gitlab.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/x", lab.NewRequestUrl("feat/x", lab.Kind));
        var bb = new GitRemote("bitbucket.org", "team/app");
        Assert.Equal("https://bitbucket.org/team/app/pull-requests/new?source=a%26b", bb.NewRequestUrl("a&b", bb.Kind));
        var own = new GitRemote("git.example.com", "acme/app");
        Assert.Equal(GitRemoteKind.Other, own.Kind);
        Assert.Equal(GitRemoteKind.GitLab, own.KindFor(GitProvider.GitLab));
        Assert.Equal(GitRemoteKind.Other, own.KindFor(null));
        Assert.Equal("https://git.example.com/acme/app/pulls", own.NewRequestUrl("x", GitRemoteKind.Other));
        Assert.Equal("https://github.com/acme/app/pull/new/feat/x", new GitRemote("github.com", "acme/app").NewRequestUrl("feat/x", GitRemoteKind.GitHub));
    }

    [Fact]
    public void OpenPromptMatchesHost()
    {
        Assert.Contains("gh pr create", AgentShip.OpenPRPrompt("feat/x", "main", true, 0));
        var lab = AgentShip.OpenPRPrompt("feat/x", "main", true, 0, GitRemoteKind.GitLab);
        Assert.Contains("glab mr create", lab);
        Assert.DoesNotContain("gh pr create", lab);
        Assert.StartsWith("Open a merge request for this work:", lab);
        var other = AgentShip.OpenPRPrompt("feat/x", "main", true, 0, GitRemoteKind.Bitbucket);
        Assert.DoesNotContain("gh pr create", other);
        Assert.Contains("reply with the web URL", other);
        Assert.Equal("https://gitlab.com/group/sub/app/-/merge_requests/12", AgentShip.PullRequestUrl("done: https://gitlab.com/group/sub/app/-/merge_requests/12 ok"));
        Assert.Equal("https://github.com/acme/app/pull/7", AgentShip.PullRequestUrl("https://github.com/acme/app/pull/7"));
        Assert.Equal("https://bitbucket.org/team/app/pull-requests/3", AgentShip.PullRequestUrl("see https://bitbucket.org/team/app/pull-requests/3"));
        var welcome = AgentWelcome.Suggestions(2, "feat/x", true, 0, null, null, GitRemoteKind.GitLab);
        Assert.Contains(welcome, s => s.Kind == WelcomeSuggestionKind.OpenPR && s.Prompt.Contains("glab mr create"));
    }
}
