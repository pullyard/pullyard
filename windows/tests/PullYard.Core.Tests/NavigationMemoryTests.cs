using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class NavigationMemoryTests
{
    [Fact]
    public void RouteRoundTripIsScopedToAccount()
    {
        var repo = new RepoRef("acme", "storefront");
        var routes = new[] { Route.Pr(new ItemRef(repo, 42)), Route.Issue(new ItemRef(repo, 7)), Route.ForRepo(repo) };
        foreach (var route in routes)
        {
            var stored = NavigationMemory.Encode(route, "github.com/octo");
            Assert.NotNull(stored);
            Assert.Equal(route, NavigationMemory.Decode(stored, "github.com/octo"));
            Assert.Null(NavigationMemory.Decode(stored, "github.com/other"));
        }
        Assert.Null(NavigationMemory.Encode(Route.Commit(repo, "abc123"), null));
        Assert.Null(NavigationMemory.Decode("garbage", null));
        Assert.Null(NavigationMemory.Decode(null, null));
        Assert.Null(NavigationMemory.Decode("|pr|acme|x", null));
        Assert.Null(NavigationMemory.Decode("|pr|acme/app|x", null));
    }

    [Fact]
    public void SectionKeysFallBackWhenFilterWasRemoved()
    {
        var known = new[] { "Notifications", "prs:ReviewRequested", "prs:Mine", "issues:Assigned", "Claude" };
        Assert.Equal("prs:Mine", NavigationMemory.NormalizeSection("prs:Mine", known, "prs:ReviewRequested", "issues:Assigned"));
        Assert.Equal("prs:ReviewRequested", NavigationMemory.NormalizeSection("prs:Removed", known, "prs:ReviewRequested", "issues:Assigned"));
        Assert.Equal("issues:Assigned", NavigationMemory.NormalizeSection("issues:Removed", known, "prs:ReviewRequested", "issues:Assigned"));
        Assert.Null(NavigationMemory.NormalizeSection("unknown", known, "prs:ReviewRequested", "issues:Assigned"));
        Assert.Null(NavigationMemory.NormalizeSection(null, known, "prs:ReviewRequested", "issues:Assigned"));
    }

    [Fact]
    public void ListSortQueries()
    {
        Assert.Equal("sort:updated-desc", ListSort.Updated.Query());
        Assert.Equal("sort:created-desc", ListSorts.Parse("created").Query());
        Assert.Equal("sort:comments-desc", ListSorts.Parse(ListSort.Comments.Key()).Query());
        Assert.Equal(ListSort.Updated, ListSorts.Parse("nonsense"));
        Assert.Equal(ListSort.Updated, ListSorts.Parse(null));
        Assert.Equal(3, ListSorts.All.Length);
    }

    [Fact]
    public void ForwardHistoryReplaysBackStepsAndClearsOnNavigation()
    {
        var repo = new RepoRef("acme", "app");
        var a = Route.Pr(new ItemRef(repo, 1));
        var b = Route.Commit(repo, "abc");
        var history = new RouteHistory();
        Assert.False(history.CanGoForward);
        Assert.Null(history.TakeForward());
        history.WentBack(b);
        history.WentBack(a);
        Assert.True(history.CanGoForward);
        Assert.Equal(a, history.TakeForward());
        Assert.Equal(b, history.TakeForward());
        Assert.False(history.CanGoForward);
        history.WentBack(b);
        history.Navigated();
        Assert.False(history.CanGoForward);
    }

    [Fact]
    public void DropHighlightClearsAfterDropAndIgnoresLateHover()
    {
        var hover = new DropHover();
        var now = DateTimeOffset.Now;
        hover.Set(true, now);
        Assert.True(hover.Targeted);
        hover.FinishDrop(now);
        Assert.False(hover.Targeted);
        hover.Set(true, now.AddMilliseconds(100));
        Assert.False(hover.Targeted);
        hover.Set(true, now.AddSeconds(1));
        Assert.True(hover.Targeted);
        hover.Set(false, now.AddSeconds(1));
        Assert.False(hover.Targeted);
    }

    [Fact]
    public void FriendlyErrors()
    {
        var unreadable = ApiException.Unreadable("GitHub", new FormatException("$.data.x: bad token"));
        Assert.DoesNotContain("bad token", unreadable.Message);
        Assert.StartsWith("GitHub sent a response", unreadable.Message);
        Assert.Equal("$.data.x: bad token", unreadable.Detail);
        var forbidden = ApiException.Http("GitHub", 403, "Resource not accessible by personal access token");
        Assert.Equal(403, forbidden.Status);
        Assert.Equal("GitHub refused the request: Resource not accessible by personal access token.", forbidden.Message);
        Assert.DoesNotContain("403:", forbidden.Message);
        Assert.Contains("try again", ApiException.Http("GitLab", 502, "Bad Gateway").Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Gitea couldn't find this, or your token has no access to it.", ApiException.Http("Gitea", 404, "Not Found").Message);
        Assert.Equal("Sign-in was cancelled in the browser.", DeviceFlow.Friendly("access_denied", "The user denied"));
        Assert.Equal("From server", DeviceFlow.Friendly("something_else", "From server"));
        Assert.Equal("Something else", DeviceFlow.Friendly("something_else", null));
    }

    [Fact]
    public void ThreadSignatureChangesOnlyWithThreadContent()
    {
        static ReviewThread Thread(string body, bool resolved = false) => new()
        {
            Id = "T1",
            Path = "a.cs",
            Line = 3,
            IsResolved = resolved,
            Comments = new Nodes<ThreadComment> { Items = { new ThreadComment { Id = "C1", Body = body } } }
        };
        var baseline = PullRequestSignature.Threads(new[] { Thread("one") });
        Assert.Equal(baseline, PullRequestSignature.Threads(new[] { Thread("one") }));
        Assert.NotEqual(baseline, PullRequestSignature.Threads(new[] { Thread("two") }));
        Assert.NotEqual(baseline, PullRequestSignature.Threads(new[] { Thread("one", true) }));
        Assert.NotEqual(baseline, PullRequestSignature.Threads(Array.Empty<ReviewThread>()));
        Assert.Equal(0, PullRequestSignature.Hidden(null, 100));
        Assert.Equal(12, PullRequestSignature.Hidden(112, 100));
        Assert.Equal(0, PullRequestSignature.Hidden(40, 100));
        Assert.Equal("100+", GitHubApi.CountLabel(100));
        Assert.Equal("99", GitHubApi.CountLabel(99));
    }
}
