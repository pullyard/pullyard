using PullYard.Core.Api;
using PullYard.Core.Stacks;
using Xunit;

namespace PullYard.Core.Tests;

public class StackStoreTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "pullyard-stacks-" + Guid.NewGuid().ToString("N"));
    private readonly RepoRef repo = new("acme", "app");
    private DateTimeOffset clock = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static List<StackNode> Nodes(params int[] numbers) =>
        numbers.Select(n => new StackNode(n, $"PR {n}", "OPEN", false, $"b{n}", "dev", "acme/app", null, null, null, null, null, null)).ToList();

    [Fact]
    public async Task ConcurrentFetchesShareOneLoad()
    {
        var store = new StackStore(root, () => clock);
        var gate = new TaskCompletionSource<List<StackNode>>();
        var calls = 0;
        Task<List<StackNode>> Load()
        {
            calls++;
            return gate.Task;
        }
        var a = store.Fetch("alice", "github.com", repo, Load);
        var b = store.Fetch("alice", "github.com", repo, Load);
        gate.SetResult(Nodes(1, 2));
        Assert.Equal(new[] { 1, 2 }, (await a)!.Select(n => n.Number));
        Assert.Equal(new[] { 1, 2 }, (await b)!.Select(n => n.Number));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task FreshCacheIsReusedUntilTtl()
    {
        var store = new StackStore(root, () => clock);
        var calls = 0;
        Task<List<StackNode>> Load()
        {
            calls++;
            return Task.FromResult(Nodes(1, 2));
        }
        await store.Nodes("alice", "github.com", repo, Load);
        await store.Nodes("alice", "github.com", repo, Load);
        Assert.Equal(1, calls);
        clock += StackStore.Ttl + TimeSpan.FromSeconds(1);
        Assert.False((await store.Cached("alice", "github.com", repo))!.Fresh);
        await store.Nodes("alice", "github.com", repo, Load);
        Assert.Equal(2, calls);
        await store.Nodes("alice", "github.com", repo, Load, force: true);
        Assert.Equal(3, calls);
    }

    [Fact]
    public async Task CacheIsPerAccountAndSurvivesOnDisk()
    {
        var store = new StackStore(root, () => clock);
        await store.Fetch("alice", "github.com", repo, () => Task.FromResult(Nodes(1, 2)));
        Assert.Null(store.MemoryNodes("bob", "github.com", repo));
        Assert.Null(await store.Cached("bob", "github.com", repo));
        var deadline = DateTime.UtcNow.AddSeconds(5);
        StackHit? hit = null;
        while (DateTime.UtcNow < deadline)
        {
            hit = await new StackStore(root, () => clock).Cached("alice", "github.com", repo);
            if (hit is not null) break;
            await Task.Delay(20);
        }
        Assert.NotNull(hit);
        Assert.True(hit!.Fresh);
        Assert.Equal(new[] { 1, 2 }, hit.Nodes.Select(n => n.Number));
    }

    [Fact]
    public async Task ResetDropsMemoryAndFailedLoadReturnsNull()
    {
        var store = new StackStore(root, () => clock);
        await store.Fetch(null, "github.com", repo, () => Task.FromResult(Nodes(1)));
        Assert.NotNull(store.MemoryNodes(null, "github.com", repo));
        store.Reset();
        Assert.Null(store.MemoryNodes(null, "github.com", repo));
        Assert.Null(await store.Fetch(null, "github.com", repo, () => Task.FromException<List<StackNode>>(new HttpRequestException("offline"))));
    }
}
