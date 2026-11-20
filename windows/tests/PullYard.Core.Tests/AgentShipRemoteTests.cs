using System.Text.Json.Nodes;
using PullYard.Core.Claude;
using PullYard.Core.Git;
using Xunit;

namespace PullYard.Core.Tests;

public class AgentShipRemoteTests
{
    [Fact]
    public void ParsesRemotes()
    {
        var gh = GitRemote.Parse("git@github.com:pullyard/pullyard.git\n");
        Assert.Equal(new GitRemote("github.com", "pullyard/pullyard", GitRemoteKind.GitHub), gh);
        Assert.Equal("pullyard/pullyard", gh!.GitHubRepo!.Full);
        Assert.Equal(GitRemoteKind.GitHub, GitRemote.Parse("https://github.com/o/r")!.Kind);
        Assert.Equal("github.com", GitRemote.Parse("ssh://git@ssh.github.com:443/o/r.git")!.Host);
        Assert.Equal("github.com", GitRemote.Parse("ssh://git@altssh.github.com:443/o/r.git")!.Host);

        var lab = GitRemote.Parse("git@gitlab.example.com:group/sub/app.git");
        Assert.Equal(new GitRemote("gitlab.example.com", "group/sub/app", GitRemoteKind.GitLab), lab);
        Assert.Null(lab!.GitHubRepo);
        Assert.Equal("group/app", GitRemote.Parse("https://gitlab.com/group/app.git/")!.Path);

        Assert.Equal(new GitRemote("bitbucket.org", "acme/api", GitRemoteKind.Bitbucket), GitRemote.Parse("https://sofia@bitbucket.org/acme/api.git"));
        Assert.Equal(GitRemoteKind.Bitbucket, GitRemote.Parse("git@bitbucket.org:acme/api.git")!.Kind);
        Assert.Equal("acme/api", GitRemote.Parse("https://bitbucket.org/scm/acme/api.git")!.Path);
        Assert.Equal(GitRemoteKind.Other, GitRemote.Parse("https://git.example.com/team/app.git")!.Kind);
        Assert.Null(GitRemote.Parse(""));
        Assert.Null(GitRemote.Parse("/Users/me/repo"));
        Assert.Null(GitRemote.Parse("C:\\code\\repo"));
        Assert.Equal("github/cli", GitCli.ParseRemote("git@github.com:github/cli.git")!.Full);
        Assert.Null(GitCli.ParseRemote("git@gitlab.com:group/app.git"));
    }

    [Fact]
    public void NewRequestLinks()
    {
        Assert.Equal("https://github.com/o/r/pull/new/feat/x", new GitRemote("github.com", "o/r", GitRemoteKind.GitHub).NewRequestUrl("feat/x"));
        Assert.Equal("https://gitlab.com/g/a/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix", new GitRemote("gitlab.com", "g/a", GitRemoteKind.GitLab).NewRequestUrl("fix"));
        Assert.Equal("https://bitbucket.org/acme/api/pull-requests/new?source=fix", new GitRemote("bitbucket.org", "acme/api", GitRemoteKind.Bitbucket).NewRequestUrl("fix"));
        Assert.Equal("https://git.example.com/t/a", new GitRemote("git.example.com", "t/a", GitRemoteKind.Other).NewRequestUrl("fix"));
        Assert.Equal("merge request", new GitRemote("gitlab.com", "g/a", GitRemoteKind.GitLab).Noun);
        Assert.Equal("pull request", new GitRemote("bitbucket.org", "acme/api", GitRemoteKind.Bitbucket).Noun);
    }

    [Fact]
    public void PromptsFollowTheHost()
    {
        var github = AgentShip.OpenPRPrompt("feat", "main", true, 0);
        Assert.Contains("gh pr create", github);
        Assert.StartsWith("Open a pull request", github);

        var gitlab = AgentShip.OpenPRPrompt("feat", "main", false, 2, new GitRemote("gitlab.com", "g/a", GitRemoteKind.GitLab));
        Assert.StartsWith("Open a merge request", gitlab);
        Assert.Contains("glab mr create", gitlab);
        Assert.Contains("merge_request.create", gitlab);
        Assert.Contains("into main", gitlab);
        Assert.DoesNotContain("gh pr create", gitlab);

        var bitbucket = AgentShip.OpenPRPrompt("feat", null, false, 1, new GitRemote("bitbucket.org", "acme/api", GitRemoteKind.Bitbucket));
        Assert.Contains("https://bitbucket.org/acme/api/pull-requests/new?source=feat", bitbucket);
        Assert.DoesNotContain("gh pr create", bitbucket);

        var onDefault = AgentShip.OpenPRPrompt("main", "main", true, 0, new GitRemote("git.example.com", "t/a", GitRemoteKind.Other));
        Assert.Contains("Create a new branch", onDefault);
        Assert.Contains("link to create a pull request", onDefault);
    }

    [Fact]
    public void WelcomeSuggestionFollowsTheRemote()
    {
        var lab = AgentWelcome.Suggestions(2, "feat", new GitRemote("gitlab.com", "g/a", GitRemoteKind.GitLab), 0, null, null);
        Assert.Contains(lab, s => s.Kind == WelcomeSuggestionKind.OpenPR && s.Prompt.Contains("glab mr create"));
        var none = AgentWelcome.Suggestions(2, "feat", (GitRemote?)null, 0, null, null);
        Assert.DoesNotContain(none, s => s.Kind == WelcomeSuggestionKind.OpenPR);
    }

    [Fact]
    public void DetectsCreatedRequests()
    {
        Assert.Equal("https://github.com/o/r/pull/12", AgentShip.PullRequestUrl("Done:\nhttps://github.com/o/r/pull/12\n"));
        Assert.Equal("https://gitlab.com/group/sub/app/-/merge_requests/7", AgentShip.PullRequestUrl("remote: View merge request:\nremote:   https://gitlab.com/group/sub/app/-/merge_requests/7 \n"));
        Assert.Equal("https://bitbucket.org/acme/api/pull-requests/5", AgentShip.PullRequestUrl("https://bitbucket.org/acme/api/pull-requests/5"));
        Assert.Null(AgentShip.PullRequestUrl("https://bitbucket.org/acme/api/pull-requests/new?source=feat"));
        Assert.Equal("https://gitlab.com/g/a/-/merge_requests/2", AgentShip.PullRequestUrl("first https://gitlab.com/g/a/-/merge_requests/2 then https://github.com/o/r/pull/3"));
        Assert.Equal(new CreatedRequest("group/sub/app", "7", true), AgentShip.Describe("https://gitlab.com/group/sub/app/-/merge_requests/7"));
        Assert.Equal("Pull request #12 is open", AgentShip.Describe("https://github.com/o/r/pull/12")!.Title);
        Assert.Equal("Merge request !3 is open", AgentShip.Describe("https://gitlab.com/g/a/-/merge_requests/3")!.Title);
        Assert.Equal((5, "acme/api"), AgentShip.ParsePullRequestUrl("https://bitbucket.org/acme/api/pull-requests/5"));
        Assert.Contains(AgentShip.CreateCommands, c => "git push -u origin HEAD -o merge_request.create".Contains(c));
    }

    [Fact]
    public void CreatedRequestComesFromAnyCreateCommand()
    {
        var tool = new ToolItem(Guid.NewGuid().ToString(), "Bash")
        {
            Input = (JsonObject)JsonNode.Parse("""{"command":"glab mr create --fill"}""")!,
            ResultText = "https://gitlab.com/g/a/-/merge_requests/9"
        };
        Assert.Equal("https://gitlab.com/g/a/-/merge_requests/9", AgentShip.CreatedPullRequest(tool));
    }
}
