namespace PullYard.Core.Util;

public enum RefreshFailureKind { Offline, RateLimited, SignIn, Other }

public readonly record struct RefreshFailure(RefreshFailureKind Kind, DateTimeOffset? Until = null)
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(5);

    private static readonly string[] OfflineHints =
    {
        "offline", "not connected", "network connection was lost", "could not be found", "no such host", "name could not be resolved",
        "connection attempt failed", "no connection could be made", "network is unreachable", "nameresolutionfailure", "host is down"
    };

    private static readonly string[] SignInHints = { "bad credentials", "401", "sign in", "unauthorized", "requires authentication", "token expired" };

    public static RefreshFailure Classify(string message, DateTimeOffset? rateLimitedUntil, bool? online = null)
    {
        var m = message.ToLowerInvariant();
        if (rateLimitedUntil is { } until) return new(RefreshFailureKind.RateLimited, until);
        if (m.Contains("rate limit")) return new(RefreshFailureKind.RateLimited);
        if (online == false || OfflineHints.Any(m.Contains)) return new(RefreshFailureKind.Offline);
        if (SignInHints.Any(m.Contains)) return new(RefreshFailureKind.SignIn);
        return new(RefreshFailureKind.Other);
    }

    public static bool IsStale(DateTimeOffset? updated, bool refreshing, bool failed, DateTimeOffset now) =>
        !refreshing && !failed && updated is { } u && now - u > StaleAfter;
}
