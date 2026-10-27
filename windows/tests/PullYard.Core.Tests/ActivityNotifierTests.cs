using PullYard.Core.Api;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class ActivityNotifierTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "pullyard-activity-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static ActivityItem Item(int n, string? ci = null, string? decision = null, long updated = 1000) =>
        new($"https://github.com/o/r/pull/{n}", new ItemRef(new RepoRef("o", "r"), n), $"PR {n}", DateTimeOffset.FromUnixTimeSeconds(updated), ci, decision);

    private static ActivityEvent Rr(ActivityItem i) => new(ActivityEventType.ReviewRequested, i);

    [Fact]
    public void FirstLoadIsSilent()
    {
        var t = new ActivityTracker();
        Assert.Empty(t.Update(new[] { Item(1), Item(2) }, 2, new[] { Item(3, "FAILURE", "APPROVED") }));
    }

    [Fact]
    public void NewReviewRequest()
    {
        var t = new ActivityTracker();
        t.Update(new[] { Item(1) }, 1, null);
        Assert.Equal(new[] { Rr(Item(2)) }, t.Update(new[] { Item(2), Item(1) }, 2, null));
        Assert.Empty(t.Update(new[] { Item(2), Item(1) }, 2, null));
    }

    [Fact]
    public void FailedFetchDoesNotPrime()
    {
        var t = new ActivityTracker();
        t.Update(null, 0, null);
        Assert.Empty(t.Update(new[] { Item(1) }, 1, null));
        t.Update(null, 0, null);
        Assert.Equal(new[] { Rr(Item(2)) }, t.Update(new[] { Item(1), Item(2) }, 2, null));
    }

    [Fact]
    public void TruncatedListOnlyCountsGrowth()
    {
        var t = new ActivityTracker();
        t.Update(new[] { Item(1), Item(2) }, 15, null);
        Assert.Empty(t.Update(new[] { Item(3), Item(1) }, 15, null));
        Assert.Equal(new[] { Rr(Item(4)) }, t.Update(new[] { Item(4), Item(5), Item(3) }, 16, null));
    }

    [Fact]
    public void CiFailureTransition()
    {
        var t = new ActivityTracker();
        t.Update(null, 0, new[] { Item(1, "PENDING"), Item(2, "FAILURE") });
        var events = t.Update(null, 0, new[] { Item(1, "FAILURE"), Item(2, "ERROR") });
        Assert.Equal(new[] { new ActivityEvent(ActivityEventType.CiFailed, Item(1, "FAILURE")) }, events);
        Assert.Empty(t.Update(null, 0, new[] { Item(1, "FAILURE") }));
    }

    [Fact]
    public void CiFailureIgnoresNewlySeenPR()
    {
        var t = new ActivityTracker();
        t.Update(null, 0, Array.Empty<ActivityItem>());
        Assert.Empty(t.Update(null, 0, new[] { Item(1, "FAILURE") }));
    }

    [Fact]
    public void ReviewDecisionTransitions()
    {
        var t = new ActivityTracker();
        t.Update(null, 0, new[] { Item(1, decision: "REVIEW_REQUIRED"), Item(2) });
        var events = t.Update(null, 0, new[] { Item(1, decision: "APPROVED"), Item(2, decision: "CHANGES_REQUESTED") });
        Assert.Equal(new[]
        {
            new ActivityEvent(ActivityEventType.Approved, Item(1, decision: "APPROVED")),
            new ActivityEvent(ActivityEventType.ChangesRequested, Item(2, decision: "CHANGES_REQUESTED"))
        }, events);
        Assert.Empty(t.Update(null, 0, new[] { Item(1, decision: "APPROVED") }));
    }

    [Fact]
    public void EventKeysAndKinds()
    {
        var a = new ActivityEvent(ActivityEventType.CiFailed, Item(1, updated: 10));
        Assert.Equal(NotifyKind.CiFailed, a.Kind);
        Assert.NotEqual(a.Key, new ActivityEvent(ActivityEventType.CiFailed, Item(1, updated: 20)).Key);
        Assert.NotEqual(a.Key, new ActivityEvent(ActivityEventType.ReviewRequested, Item(1, updated: 10)).Key);
        Assert.Equal(NotifyKind.ReviewDecision, new ActivityEvent(ActivityEventType.Approved, Item(1)).Kind);
        Assert.Equal(NotifyKind.ReviewDecision, new ActivityEvent(ActivityEventType.ChangesRequested, Item(1)).Kind);
        Assert.Equal(NotifyKind.ReviewRequest, Rr(Item(1)).Kind);
    }

    [Fact]
    public void RecentEventsDedupesAndCaps()
    {
        var r = new RecentEvents(limit: 2);
        Assert.True(r.Insert("a"));
        Assert.False(r.Insert("a"));
        Assert.True(r.Insert("b"));
        Assert.True(r.Insert("c"));
        Assert.Equal(new[] { "b", "c" }, r.Keys);
        Assert.True(r.Insert("a"));
    }

    [Fact]
    public void RecentEventsKeepsNewestOnLoad()
    {
        var r = new RecentEvents(new[] { "a", "b", "c" }, 2);
        Assert.Equal(new[] { "b", "c" }, r.Keys);
        Assert.False(r.Contains("a"));
    }

    [Fact]
    public void TargetRoundTrip()
    {
        var t = new ActivityTarget("https://github.com/o/r/pull/1?x=a|b", "o/r", 1, "acct|1");
        var back = ActivityTarget.Decode(t.Encode());
        Assert.Equal(t, back);
        Assert.Null(ActivityTarget.Decode(new ActivityTarget("u", "o/r", 2, null).Encode())?.Account);
        Assert.Null(ActivityTarget.Decode("agent:123"));
        Assert.Null(ActivityTarget.Decode("activity:x"));
        Assert.Null(ActivityTarget.Decode(null));
    }

    [Fact]
    public void TaskbarBadgeCount()
    {
        Assert.Equal(5, TaskbarCount.Count(3, 2, true, true));
        Assert.Equal(3, TaskbarCount.Count(3, 2, true, false));
        Assert.Equal(0, TaskbarCount.Count(3, 2, false, true));
        Assert.Equal(2, TaskbarCount.Count(-1, 2, true, true));
    }

    [Fact]
    public void NotifyKindSettingsFallBackToLegacyAgentToggle()
    {
        var settings = new Settings(Path.Combine(root, "settings.json"));
        Assert.True(NotifyKind.ReviewRequest.Enabled(settings));
        Assert.True(NotifyKind.AgentFinished.Enabled(settings));
        settings.Set(Keys.AgentsNotify, false);
        Assert.False(NotifyKind.AgentFinished.Enabled(settings));
        Assert.False(NotifyKind.AgentInput.Enabled(settings));
        Assert.True(NotifyKind.CiFailed.Enabled(settings));
        NotifyKind.AgentInput.SetEnabled(settings, true);
        Assert.True(NotifyKind.AgentInput.Enabled(settings));
        Assert.False(NotifyKind.AgentFinished.Enabled(settings));
        NotifyKind.CiFailed.SetEnabled(settings, false);
        Assert.False(NotifyKind.CiFailed.Enabled(settings));
        Assert.Equal(5, NotifyKinds.All.Select(k => k.Key()).Distinct().Count());
    }
}
