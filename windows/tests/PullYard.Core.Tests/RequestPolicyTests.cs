using System.Net;
using System.Text;
using PullYard.Core.Api;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

[Collection("Diagnostics")]
public class RequestPolicyTests : IDisposable
{
    private static readonly ItemRef Pr = new(new RepoRef("o", "r"), 7);

    public RequestPolicyTests()
    {
        Diagnostics.Enabled = false;
        Diagnostics.Shared.Clear();
    }

    public void Dispose()
    {
        Diagnostics.Enabled = false;
        Diagnostics.Shared.Clear();
    }

    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Queue<Func<HttpRequestMessage, HttpResponseMessage>> replies = new();

        public List<(HttpRequestMessage Request, string Body)> Seen { get; } = new();

        public FakeHandler Then(Func<HttpRequestMessage, HttpResponseMessage> reply)
        {
            replies.Enqueue(reply);
            return this;
        }

        public FakeHandler Then(HttpStatusCode status, string body = "{}", Action<HttpResponseMessage>? headers = null) => Then(_ =>
        {
            var r = new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            headers?.Invoke(r);
            return r;
        });

        public FakeHandler Throw(Exception e) => Then(_ => throw e);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            Func<HttpRequestMessage, HttpResponseMessage> reply;
            lock (replies)
            {
                if (replies.Count == 0) throw new InvalidOperationException("unexpected request " + request.RequestUri);
                reply = replies.Dequeue();
                Seen.Add((request, body));
            }
            return reply(request);
        }
    }

    private static (GitHubApi Api, FakeHandler Handler) Make()
    {
        var handler = new FakeHandler();
        return (new GitHubApi("t", new HttpClient(handler)), handler);
    }

    [Theory]
    [InlineData("GET", null, true)]
    [InlineData("POST", null, false)]
    [InlineData("PATCH", null, false)]
    [InlineData("DELETE", null, false)]
    [InlineData("POST", "query Badges { viewer { login } }", true)]
    [InlineData("POST", "  mutation AddComment($id: ID!) { x }", false)]
    public void ClassifiesReads(string method, string? query, bool read)
    {
        Assert.Equal(read, RetryPolicy.IsRead(new HttpMethod(method), query));
    }

    [Fact]
    public async Task RestReadIsRetriedOnceOnBadGateway()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.BadGateway).Then(HttpStatusCode.OK, "{\"login\":\"me\"}");
        var user = await api.Rest<RestUser>("GET", "/user");
        Assert.Equal("me", user.Login);
        Assert.Equal(2, h.Seen.Count);
    }

    [Fact]
    public async Task RestReadIsRetriedOnlyOnce()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.ServiceUnavailable).Then(HttpStatusCode.GatewayTimeout);
        var e = await Assert.ThrowsAsync<ApiException>(() => api.Rest<RestUser>("GET", "/user"));
        Assert.Equal(504, e.Status);
        Assert.Equal(2, h.Seen.Count);
    }

    [Fact]
    public async Task ReadIsRetriedOnConnectFailureAndTimeout()
    {
        var (api, h) = Make();
        h.Throw(new HttpRequestException(HttpRequestError.ConnectionError, "Connection refused")).Then(HttpStatusCode.OK, "{\"login\":\"a\"}");
        Assert.Equal("a", (await api.Rest<RestUser>("GET", "/user")).Login);
        h.Throw(new TaskCanceledException("timeout", new TimeoutException())).Then(HttpStatusCode.OK, "{\"login\":\"b\"}");
        Assert.Equal("b", (await api.Rest<RestUser>("GET", "/user")).Login);
        Assert.Equal(4, h.Seen.Count);
    }

    [Theory]
    [InlineData(HttpRequestError.NameResolutionError)]
    [InlineData(HttpRequestError.SecureConnectionError)]
    [InlineData(HttpRequestError.Unknown)]
    public async Task DnsAndTlsFailuresAreNotRetried(HttpRequestError error)
    {
        var (api, h) = Make();
        h.Throw(new HttpRequestException(error, "nope"));
        await Assert.ThrowsAsync<HttpRequestException>(() => api.Rest<RestUser>("GET", "/user"));
        Assert.Single(h.Seen);
    }

    [Fact]
    public async Task TotalTimeoutIsNotRetried()
    {
        var handler = new FakeHandler();
        var api = new GitHubApi("t", new HttpClient(handler) { Timeout = TimeSpan.FromMilliseconds(1200) });
        handler.Then(_ =>
        {
            Thread.Sleep(1300);
            throw new TaskCanceledException("timeout", new TimeoutException());
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => api.Rest<RestUser>("GET", "/user"));
        Assert.Single(handler.Seen);
    }

    [Fact]
    public async Task CallerCancellationIsNotRetried()
    {
        var (api, h) = Make();
        using var cts = new CancellationTokenSource();
        h.Then(_ =>
        {
            cts.Cancel();
            throw new TaskCanceledException();
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => api.Rest<RestUser>("GET", "/user", ct: cts.Token));
        Assert.Single(h.Seen);
    }

    [Fact]
    public async Task GraphQLQueryIsRetried()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.BadGateway).Then(HttpStatusCode.OK, "{\"data\":{}}");
        await api.GraphQL<GitHubApi.EmptyData>("query Badges { viewer { login } }");
        Assert.Equal(2, h.Seen.Count);
        Assert.Equal(h.Seen[0].Body, h.Seen[1].Body);
    }

    [Fact]
    public async Task GraphQLMutationIsNeverRetried()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.BadGateway);
        await Assert.ThrowsAsync<ApiException>(() => api.Mutate(Q.ResolveThread, new Dictionary<string, object?> { ["id"] = "x" }));
        Assert.Single(h.Seen);
        var (api2, h2) = Make();
        h2.Throw(new HttpRequestException("Connection reset"));
        await Assert.ThrowsAsync<HttpRequestException>(() => api2.Mutate(Q.ResolveThread, new Dictionary<string, object?> { ["id"] = "x" }));
        Assert.Single(h2.Seen);
    }

    [Theory]
    [InlineData("POST")]
    [InlineData("PATCH")]
    [InlineData("PUT")]
    [InlineData("DELETE")]
    public async Task RestWritesAreNeverRetried(string method)
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.ServiceUnavailable);
        await Assert.ThrowsAsync<ApiException>(() => api.Send(method, "/repos/o/r/pulls/7/requested_reviewers", new { reviewers = new[] { "a" } }));
        Assert.Single(h.Seen);
        var (api2, h2) = Make();
        h2.Throw(new TaskCanceledException("timeout", new TimeoutException()));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => api2.Send(method, "/notifications"));
        Assert.Single(h2.Seen);
    }

    [Fact]
    public async Task EachRetryIsItsOwnDiagnosticsEntry()
    {
        Diagnostics.Enabled = true;
        var (api, h) = Make();
        h.Then(HttpStatusCode.BadGateway).Then(HttpStatusCode.OK, "{}");
        await api.Rest<RestUser>("GET", "/user");
        var all = Diagnostics.Shared.Requests();
        Assert.Equal(2, all.Count);
        Assert.Equal(200, all[0].Status);
        Assert.Equal("retry", all[0].Note);
        Assert.Equal(502, all[1].Status);
        Assert.Null(all[1].Note);
    }

    [Fact]
    public async Task PartialGraphQLIsRecordedOkWithNote()
    {
        Diagnostics.Enabled = true;
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "{\"data\":{\"repository\":{\"pullRequest\":{\"headRefOid\":\"abc\"}}},\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"Resource not accessible\"}]}");
        var pr = await api.PullRequestPulse(Pr);
        Assert.Equal("abc", pr!.HeadRefOid);
        var entry = Assert.Single(Diagnostics.Shared.Requests());
        Assert.Equal(200, entry.Status);
        Assert.Null(entry.Error);
        Assert.Equal("partial", entry.Note);
        Assert.Equal("PullRequestPulse", entry.Name);
    }

    private static Action<HttpResponseMessage> LastModified(string value, int? poll = null) => r =>
    {
        r.Content.Headers.TryAddWithoutValidation("Last-Modified", value);
        if (poll is { } p) r.Headers.TryAddWithoutValidation("X-Poll-Interval", p.ToString());
    };

    [Fact]
    public async Task NotificationsSendIfModifiedSinceAndTreat304AsUnchanged()
    {
        Diagnostics.Enabled = true;
        var (api, h) = Make();
        const string stamp = "Thu, 15 Oct 2026 10:00:00 GMT";
        h.Then(HttpStatusCode.OK, "[{\"id\":\"1\",\"unread\":true},{\"id\":\"2\",\"unread\":true}]", LastModified(stamp))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified));
        Assert.Equal(2, await api.UnreadNotificationCount());
        Assert.Null(await api.UnreadNotificationCount(live: true));
        Assert.Equal(2, h.Seen.Count);
        Assert.False(h.Seen[0].Request.Headers.Contains("If-Modified-Since"));
        Assert.Equal(stamp, h.Seen[1].Request.Headers.GetValues("If-Modified-Since").Single());
        Assert.All(h.Seen, s => Assert.False(s.Request.Headers.CacheControl?.NoCache ?? false));
        Assert.Equal(304, Diagnostics.Shared.Requests()[0].Status);
    }

    [Fact]
    public async Task EmptyListWithoutLastModifiedIsValidatedByETag()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "[]", r => r.Headers.TryAddWithoutValidation("ETag", "W/\"abc\""))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified));
        Assert.Equal(0, await api.UnreadNotificationCount());
        Assert.Null(await api.UnreadNotificationCount(live: true));
        Assert.False(h.Seen[0].Request.Headers.Contains("If-None-Match"));
        Assert.Equal("W/\"abc\"", h.Seen[1].Request.Headers.GetValues("If-None-Match").Single());
        Assert.False(h.Seen[1].Request.Headers.Contains("If-Modified-Since"));
    }

    [Fact]
    public async Task NotModifiedListComesFromCache()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "[{\"id\":\"9\"}]", LastModified("Thu, 15 Oct 2026 10:00:00 GMT"))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified));
        Assert.Single((await api.NotificationsIfChanged(false, false))!);
        Assert.Null(await api.NotificationsIfChanged(false, true));
        Assert.Equal("9", Assert.Single((await api.NotificationsIfChanged(false, true, needData: true))!).Id);
    }

    [Fact]
    public async Task LiveTicksHonorPollInterval()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "[]", LastModified("Thu, 15 Oct 2026 10:00:00 GMT", poll: 60))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified));
        Assert.Equal(0, await api.UnreadNotificationCount(live: true));
        Assert.Null(await api.UnreadNotificationCount(live: true));
        Assert.Single(h.Seen);
    }

    [Fact]
    public async Task UserLoadsAreUnconditionalAndRefreshTheCache()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "[{\"id\":\"1\"},{\"id\":\"2\"}]", LastModified("Thu, 15 Oct 2026 10:00:00 GMT"))
            .Then(HttpStatusCode.OK, "[{\"id\":\"2\"}]", LastModified("Thu, 15 Oct 2026 10:00:00 GMT"))
            .Then(_ => new HttpResponseMessage(HttpStatusCode.NotModified));
        Assert.Equal(2, (await api.Notifications(false)).Count);
        Assert.Single(await api.Notifications(false));
        Assert.False(h.Seen[1].Request.Headers.Contains("If-Modified-Since"));
        Assert.Single((await api.NotificationsIfChanged(false, true, needData: true))!);
        Assert.True(h.Seen[2].Request.Headers.Contains("If-Modified-Since"));
    }

    [Fact]
    public async Task InFlightLiveFetchDoesNotOutliveInvalidation()
    {
        var (api, h) = Make();
        var release = new TaskCompletionSource();
        h.Then(r =>
        {
            release.Task.Wait();
            var m = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[{\"id\":\"1\",\"unread\":true}]") };
            m.Content.Headers.TryAddWithoutValidation("Last-Modified", "Thu, 15 Oct 2026 10:00:00 GMT");
            return m;
        }).Then(HttpStatusCode.ResetContent).Then(HttpStatusCode.OK, "[]");
        var live = Task.Run(() => api.UnreadNotificationCount(live: true));
        while (h.Seen.Count == 0) await Task.Delay(5);
        var mark = api.MarkNotificationRead("1");
        while (h.Seen.Count < 2) await Task.Delay(5);
        await mark;
        release.SetResult();
        Assert.Null(await live);
        Assert.Equal(0, await api.UnreadNotificationCount(live: true));
        Assert.False(h.Seen[2].Request.Headers.Contains("If-Modified-Since"));
    }

    [Fact]
    public async Task MarkingReadDropsTheValidator()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, "[{\"id\":\"1\"}]", LastModified("Thu, 15 Oct 2026 10:00:00 GMT"))
            .Then(HttpStatusCode.ResetContent)
            .Then(HttpStatusCode.OK, "[]");
        Assert.Equal(1, await api.UnreadNotificationCount());
        await api.MarkNotificationRead("1");
        Assert.Equal(0, await api.UnreadNotificationCount());
        Assert.False(h.Seen[2].Request.Headers.Contains("If-Modified-Since"));
    }

    [Fact]
    public async Task RateLimitPausesAndIsNotRetried()
    {
        var (api, h) = Make();
        var reset = DateTimeOffset.UtcNow.AddMinutes(5);
        DateTimeOffset? paused = null;
        api.RateLimit.Paused += u => paused = u;
        h.Then(HttpStatusCode.Forbidden, "{\"message\":\"API rate limit exceeded\"}", r =>
        {
            r.Headers.TryAddWithoutValidation("X-RateLimit-Remaining", "0");
            r.Headers.TryAddWithoutValidation("X-RateLimit-Reset", reset.ToUnixTimeSeconds().ToString());
        });
        await Assert.ThrowsAsync<ApiException>(() => api.Rest<RestUser>("GET", "/user"));
        Assert.Single(h.Seen);
        Assert.Equal(reset.ToUnixTimeSeconds(), paused?.ToUnixTimeSeconds());
        Assert.True(api.RateLimit.IsPaused(DateTimeOffset.Now));
        Assert.False(api.RateLimit.IsPaused(reset.AddSeconds(1)));
    }

    [Fact]
    public async Task PausedBucketRefusesReadsUntilReset()
    {
        var (api, h) = Make();
        var reset = DateTimeOffset.UtcNow.AddMinutes(5);
        h.Then(HttpStatusCode.Forbidden, "{\"message\":\"API rate limit exceeded\"}", r =>
        {
            r.Headers.TryAddWithoutValidation("X-RateLimit-Remaining", "0");
            r.Headers.TryAddWithoutValidation("X-RateLimit-Reset", reset.ToUnixTimeSeconds().ToString());
            r.Headers.TryAddWithoutValidation("X-RateLimit-Resource", "core");
        });
        await Assert.ThrowsAsync<ApiException>(() => api.Rest<RestUser>("GET", "/user"));
        var refused = await Assert.ThrowsAsync<ApiException>(() => api.Rest<RestUser>("GET", "/user"));
        Assert.Equal(429, refused.Status);
        Assert.Equal(reset.ToUnixTimeSeconds(), refused.RateLimitedUntil?.ToUnixTimeSeconds());
        Assert.Contains("rate limit", refused.Message);
        Assert.Contains("resume", refused.Message);
        Assert.Single(h.Seen);
        Assert.Equal(reset.ToUnixTimeSeconds(), api.RateLimit.BlockedUntil(RateLimitPause.Core, DateTimeOffset.Now)?.ToUnixTimeSeconds());
        Assert.Null(api.RateLimit.BlockedUntil(RateLimitPause.Core, reset.AddSeconds(1)));
    }

    [Fact]
    public async Task PausedBucketStillAllowsWritesAndOtherBuckets()
    {
        var (api, h) = Make();
        api.RateLimit.PauseUntil(DateTimeOffset.Now.AddMinutes(5), RateLimitPause.Core);
        h.Then(HttpStatusCode.NoContent)
            .Then(HttpStatusCode.OK, "{\"data\":{}}")
            .Then(HttpStatusCode.OK, "{\"total_count\":0,\"items\":[]}");
        await api.Send("POST", "/repos/o/r/issues/7/comments", new { body = "x" });
        await api.GraphQL<GitHubApi.EmptyData>("query Badges { viewer { login } }");
        await api.Fetch("/search/issues?q=x", "application/vnd.github+json");
        Assert.Equal(3, h.Seen.Count);
        await Assert.ThrowsAsync<ApiException>(() => api.Fetch("/repos/o/r", "application/vnd.github+json"));
        Assert.Equal(3, h.Seen.Count);
    }

    [Fact]
    public async Task GraphQLRateLimitRefusesQueriesButNotMutations()
    {
        var (api, h) = Make();
        var reset = DateTimeOffset.UtcNow.AddMinutes(3);
        h.Then(HttpStatusCode.OK, "{\"data\":null,\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"API rate limit exceeded\"}]}", r =>
        {
            r.Headers.TryAddWithoutValidation("X-RateLimit-Remaining", "0");
            r.Headers.TryAddWithoutValidation("X-RateLimit-Reset", reset.ToUnixTimeSeconds().ToString());
        });
        await Assert.ThrowsAsync<ApiException>(() => api.GraphQL<GitHubApi.EmptyData>("query Badges { viewer { login } }"));
        var refused = await Assert.ThrowsAsync<ApiException>(() => api.GraphQL<GitHubApi.EmptyData>("query Badges { viewer { login } }"));
        Assert.Equal(429, refused.Status);
        Assert.Single(h.Seen);
        Assert.NotNull(api.RateLimit.BlockedUntil(RateLimitPause.GraphQL, DateTimeOffset.Now));
        Assert.Null(api.RateLimit.BlockedUntil(RateLimitPause.Core, DateTimeOffset.Now));
        h.Then(HttpStatusCode.OK, "{\"data\":{}}");
        await api.Mutate(Q.ResolveThread, new Dictionary<string, object?> { ["id"] = "x" });
        Assert.Equal(2, h.Seen.Count);
    }

    [Fact]
    public void CarriesActiveBucketsToANewClient()
    {
        var now = DateTimeOffset.Now;
        var old = new RateLimitPause();
        old.PauseUntil(now.AddMinutes(2), RateLimitPause.GraphQL);
        old.PauseUntil(now.AddMinutes(-1), RateLimitPause.Core);
        var next = new RateLimitPause();
        DateTimeOffset? paused = null;
        next.Paused += u => paused = u;
        next.CarryFrom(old, now);
        Assert.Equal(now.AddMinutes(2), next.BlockedUntil(RateLimitPause.GraphQL, now));
        Assert.Null(next.BlockedUntil(RateLimitPause.Core, now));
        Assert.Equal(now.AddMinutes(2), paused);
        Assert.Equal(now.AddMinutes(2), next.Until);
        Assert.Equal(RateLimitPause.Search, RateLimitPause.Bucket(new Uri("https://api.github.com/search/issues?q=x"), false));
        Assert.Equal(RateLimitPause.Core, RateLimitPause.Bucket(new Uri("https://api.github.com/user"), false));
        Assert.Equal(RateLimitPause.GraphQL, RateLimitPause.Bucket(new Uri("https://api.github.com/graphql"), true));
    }

    [Fact]
    public void SecondaryLimitUsesRetryAfter()
    {
        var now = DateTimeOffset.UtcNow;
        var r = new HttpResponseMessage((HttpStatusCode)429);
        r.Headers.TryAddWithoutValidation("Retry-After", "120");
        Assert.Equal(now.AddSeconds(120), RateLimitPause.Evaluate(r, Array.Empty<byte>(), false, now));
        var secondary = new HttpResponseMessage(HttpStatusCode.Forbidden);
        Assert.Equal(now + RateLimitPause.Fallback, RateLimitPause.Evaluate(secondary, Encoding.UTF8.GetBytes("{\"message\":\"You have exceeded a secondary rate limit\"}"), false, now));
        Assert.Null(RateLimitPause.Evaluate(new HttpResponseMessage(HttpStatusCode.Forbidden), Encoding.UTF8.GetBytes("{\"message\":\"Resource not accessible\"}"), false, now));
        Assert.NotNull(RateLimitPause.Evaluate(new HttpResponseMessage(HttpStatusCode.OK), Encoding.UTF8.GetBytes("{\"data\":null,\"errors\":[{\"type\":\"RATE_LIMITED\"}]}"), true, now));
        Assert.Null(RateLimitPause.Evaluate(new HttpResponseMessage(HttpStatusCode.OK), Encoding.UTF8.GetBytes("{\"data\":{}}"), true, now));
    }

    private const string StackPage1 = "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c1\"},\"nodes\":[{\"number\":7,\"title\":\"t\",\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"b\",\"baseRefName\":\"a\",\"updatedAt\":\"2026-10-01T12:00:00Z\",\"reviewDecision\":\"APPROVED\",\"author\":{\"login\":\"me\"},\"headRepository\":{\"nameWithOwner\":\"o/r\"},\"commits\":{\"nodes\":[{\"commit\":{\"abbreviatedOid\":\"abc1234\",\"messageHeadline\":\"Fix\",\"statusCheckRollup\":{\"state\":\"SUCCESS\"}}}]}}]}}}}";
    private const string StackPage2 = "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[{\"number\":6,\"title\":\"base\",\"state\":\"OPEN\",\"isDraft\":true,\"headRefName\":\"a\",\"baseRefName\":\"main\",\"headRepository\":null,\"commits\":{\"nodes\":[]}}]}}}}";

    [Fact]
    public async Task OpenStackNodesPagesThroughOpenPullRequests()
    {
        var (api, h) = Make();
        h.Then(HttpStatusCode.OK, StackPage1).Then(HttpStatusCode.OK, StackPage2);
        var nodes = await api.OpenStackNodes(Pr.Repo);
        Assert.Equal(new[] { 7, 6 }, nodes.Select(n => n.Number));
        Assert.Equal(2, h.Seen.Count);
        Assert.Contains("RepoStack", h.Seen[0].Body);
        Assert.Contains("\"after\":\"c1\"", h.Seen[1].Body);
        var first = nodes[0];
        Assert.Equal("o/r", first.HeadRepo);
        Assert.Equal("me", first.Author);
        Assert.Equal("SUCCESS", first.Ci);
        Assert.Equal("abc1234", first.CommitOid);
        Assert.Equal("Fix", first.CommitHeadline);
        Assert.Equal(StackStatus.Ready, first.Status);
        Assert.Null(nodes[1].HeadRepo);
        Assert.Equal(StackStatus.Draft, nodes[1].Status);
    }
}
