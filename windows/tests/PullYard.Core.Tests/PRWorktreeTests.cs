using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Git;
using Xunit;

namespace PullYard.Core.Tests;

public sealed class PRWorktreeTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "wt-" + Guid.NewGuid().ToString("N"));
    private readonly RepoRef repo = new("o", "r");
    private string Origin => Path.Combine(root, "o", "r");
    private string Clone => Path.Combine(root, "work", "r");

    private static Task<string> Git(string dir, params string[] args) =>
        PRWorktrees.Git(new[] { "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" }.Concat(args), dir);

    private async Task Setup()
    {
        Directory.CreateDirectory(Origin);
        Directory.CreateDirectory(Path.Combine(root, "work"));
        await Git(Origin, "init", "--quiet", "-b", "main");
        File.WriteAllText(Path.Combine(Origin, "a.txt"), "a");
        await Git(Origin, "add", ".");
        await Git(Origin, "commit", "--quiet", "-m", "base");
        await Git(Origin, "checkout", "--quiet", "-b", "feature");
        File.WriteAllText(Path.Combine(Origin, "b.txt"), "b");
        await Git(Origin, "add", ".");
        await Git(Origin, "commit", "--quiet", "-m", "pr");
        await Git(Origin, "update-ref", "refs/pull/7/head", "feature");
        await Git(Origin, "checkout", "--quiet", "main");
        await Git(root, "clone", "--quiet", Origin, Clone);
    }

    public void Dispose()
    {
        try
        {
            foreach (var f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal);
            Directory.Delete(root, true);
        }
        catch
        {
        }
    }

    [Fact]
    public async Task CreatesWorktreeAtPRHeadWithoutTouchingClone()
    {
        await Setup();
        var wt = await PRWorktrees.Prepare(Clone, repo, 7);
        Assert.Equal(Path.GetFullPath(Path.Combine(root, "work", "r-worktrees", "pr-7")), wt.Path);
        Assert.Equal("origin", wt.Remote);
        Assert.False(wt.Reused);
        Assert.True(File.Exists(Path.Combine(wt.Path, "b.txt")));
        Assert.Equal(await Git(Origin, "rev-parse", "feature"), wt.HeadOid);
        Assert.Equal("pullyard/pr-7", await Git(wt.Path, "branch", "--show-current"));
        Assert.Equal("main", await Git(Clone, "branch", "--show-current"));
        Assert.False(File.Exists(Path.Combine(Clone, "b.txt")));
        Assert.Equal(wt.Path, await PRWorktrees.Existing(Clone, 7));
    }

    [Fact]
    public async Task ReuseUpdatesCleanWorktreeAndKeepsDirtyOne()
    {
        await Setup();
        await PRWorktrees.Prepare(Clone, repo, 7);
        await Git(Origin, "checkout", "--quiet", "feature");
        File.WriteAllText(Path.Combine(Origin, "c.txt"), "c");
        await Git(Origin, "add", ".");
        await Git(Origin, "commit", "--quiet", "-m", "more");
        await Git(Origin, "update-ref", "refs/pull/7/head", "feature");
        var updated = await PRWorktrees.Prepare(Clone, repo, 7);
        Assert.True(updated.Reused);
        Assert.False(updated.Dirty);
        Assert.True(File.Exists(Path.Combine(updated.Path, "c.txt")));

        File.WriteAllText(Path.Combine(updated.Path, "b.txt"), "local");
        var dirty = await PRWorktrees.Prepare(Clone, repo, 7);
        Assert.True(dirty.Dirty);
        Assert.Equal("local", File.ReadAllText(Path.Combine(dirty.Path, "b.txt")));
        await Assert.ThrowsAsync<GitException>(() => PRWorktrees.Remove(Clone, 7));

        await Git(dirty.Path, "checkout", "--quiet", "--", "b.txt");
        await PRWorktrees.Remove(Clone, 7);
        Assert.False(Directory.Exists(dirty.Path));
        Assert.Null(await PRWorktrees.Existing(Clone, 7));
        Assert.DoesNotContain("pullyard/pr-7", await Git(Clone, "branch", "--list"));
    }

    [Fact]
    public async Task MissingPullRefFails()
    {
        await Setup();
        await Assert.ThrowsAsync<GitException>(() => PRWorktrees.Prepare(Clone, repo, 99));
    }

    [Fact]
    public void RemoteMatching()
    {
        const string remotes = "fork\tgit@github.com:me/r.git (fetch)\nupstream\thttps://github.com/O/R.git (fetch)\n";
        Assert.Equal("upstream", PRWorktrees.Remote(repo, remotes));
        Assert.Null(PRWorktrees.Remote(new RepoRef("x", "y"), remotes));
    }

    [Fact]
    public void PromptAdaptation()
    {
        var pr = new PullRequestDetail
        {
            Number = 7,
            Title = "T",
            Url = "u",
            HeadRefName = "feature",
            BaseRefName = "main",
            HeadRefOid = "abc",
            HeadRepository = new RepoName { NameWithOwner = "o/r" }
        };
        var wt = new PRWorktree("/tmp/r-worktrees/pr-7", "pullyard/pr-7", "upstream", "abcdef1234567890", false, false);
        var prompt = FixPrompt.Build(pr, repo, Array.Empty<ReviewThread>(), Array.Empty<GeneralFeedback>(), new FixOptions { Commit = true, Push = true });
        var adapted = PRWorktrees.Adapt(prompt, wt, pr, repo);
        Assert.DoesNotContain(FixPrompt.CheckoutStep(7), adapted);
        Assert.Contains("isolated git worktree at /tmp/r-worktrees/pr-7", adapted);
        Assert.Contains("`git push upstream HEAD:feature`", adapted);
        var other = PRWorktrees.Adapt("Custom prompt", wt, pr, new RepoRef("up", "r"));
        Assert.StartsWith("You are working in an isolated git worktree", other);
        var fork = PRWorktrees.Adapt(prompt, wt, pr, new RepoRef("up", "r"));
        Assert.Contains("ask me before pushing: this pull request's branch lives in the fork o/r", fork);
        var wrapped = PRWorktrees.Adapt(FixPromptExtractor.Wrap(new FoundFixPrompt("Do it", "a", null, null), pr, new FixOptions { Push = true }), wt, pr, repo);
        Assert.StartsWith("Before starting: You are working in an isolated git worktree", wrapped);
        Assert.Contains("(`git push upstream HEAD:feature`)", wrapped);
        var ci = PRWorktrees.Adapt(CiFixPrompt.Build(pr, repo, Array.Empty<CiFailure>(), new FixOptions()), wt, pr, repo);
        Assert.DoesNotContain(FixPrompt.CheckoutStep(7), ci);
        Assert.Contains("isolated git worktree", ci);
    }
}
