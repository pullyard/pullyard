using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class RefreshFailureTests
{
    [Theory]
    [InlineData("No such host is known. (api.github.com:443)", RefreshFailureKind.Offline)]
    [InlineData("A connection attempt failed because the connected party did not properly respond", RefreshFailureKind.Offline)]
    [InlineData("API rate limit exceeded for user", RefreshFailureKind.RateLimited)]
    [InlineData("Bad credentials", RefreshFailureKind.SignIn)]
    [InlineData("Response status code does not indicate success: 401 (Unauthorized).", RefreshFailureKind.SignIn)]
    [InlineData("Something went wrong", RefreshFailureKind.Other)]
    public void ClassifiesMessages(string message, RefreshFailureKind kind)
    {
        Assert.Equal(kind, RefreshFailure.Classify(message, null).Kind);
    }

    [Fact]
    public void RateLimitDeadlineWins()
    {
        var until = new DateTimeOffset(2026, 11, 25, 14, 2, 0, TimeSpan.Zero);
        var failure = RefreshFailure.Classify("Bad credentials", until);
        Assert.Equal(RefreshFailureKind.RateLimited, failure.Kind);
        Assert.Equal(until, failure.Until);
    }

    [Fact]
    public void KnownOfflineStateBeatsMessage()
    {
        Assert.Equal(RefreshFailureKind.Offline, RefreshFailure.Classify("Something went wrong", null, online: false).Kind);
    }

    [Fact]
    public void StaleOnlyAfterFiveQuietMinutes()
    {
        var now = DateTimeOffset.Now;
        Assert.False(RefreshFailure.IsStale(now.AddMinutes(-4), false, false, now));
        Assert.True(RefreshFailure.IsStale(now.AddMinutes(-6), false, false, now));
        Assert.False(RefreshFailure.IsStale(now.AddMinutes(-6), true, false, now));
        Assert.False(RefreshFailure.IsStale(now.AddMinutes(-6), false, true, now));
        Assert.False(RefreshFailure.IsStale(null, false, false, now));
    }
}
