using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Util;

namespace PullYard.Core.Stacks;

public sealed record StackHit(List<StackNode> Nodes, bool Fresh);

public sealed class StackStore
{
    public static readonly TimeSpan Ttl = TimeSpan.FromSeconds(120);
    public const int Version = 1;

    public static StackStore Shared { get; } = new(Path.Combine(AppInfo.DataDirectory, "Cache", "Stacks"));

    private static readonly JsonSerializerOptions Options = new(Json.Plain) { IgnoreReadOnlyProperties = true };

    private readonly string root;
    private readonly Func<DateTimeOffset> now;
    private readonly object gate = new();
    private readonly Dictionary<string, (List<StackNode> Nodes, DateTimeOffset At)> memory = new();
    private readonly Dictionary<string, Task<List<StackNode>?>> fetches = new();
    private long generation;

    public StackStore(string root, Func<DateTimeOffset>? now = null)
    {
        this.root = root;
        this.now = now ?? (() => DateTimeOffset.Now);
    }

    private sealed class Entry
    {
        public int V { get; set; }
        public string Repo { get; set; } = "";
        public DateTimeOffset Saved { get; set; }
        public List<StackNode> Nodes { get; set; } = new();
    }

    private static string Key(string? account, string host, RepoRef repo) => $"{account?.ToLowerInvariant() ?? ""}|{host}|{repo.Full.ToLowerInvariant()}";

    private string? DiskPath(string? account, string host, RepoRef repo)
    {
        if (ListSnapshotStore.AccountKey(account) is not { } key) return null;
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"stack|{host}|{repo.Full.ToLowerInvariant()}"))).ToLowerInvariant()[..32];
        return Path.Combine(root, key, hash + ".json");
    }

    public List<StackNode>? MemoryNodes(string? account, string host, RepoRef repo)
    {
        lock (gate) return memory.TryGetValue(Key(account, host, repo), out var hit) ? hit.Nodes : null;
    }

    public async Task<StackHit?> Cached(string? account, string host, RepoRef repo)
    {
        var k = Key(account, host, repo);
        long gen;
        lock (gate)
        {
            if (memory.TryGetValue(k, out var hit)) return new StackHit(hit.Nodes, now() - hit.At < Ttl);
            gen = generation;
        }
        if (DiskPath(account, host, repo) is not { } path) return null;
        var entry = await Task.Run(() => Read(path, repo)).ConfigureAwait(false);
        if (entry is null) return null;
        lock (gate)
        {
            if (gen != generation) return null;
            if (!memory.ContainsKey(k)) memory[k] = (entry.Nodes, entry.Saved);
            var hit = memory[k];
            return new StackHit(hit.Nodes, now() - hit.At < Ttl);
        }
    }

    public async Task<List<StackNode>?> Nodes(string? account, string host, RepoRef repo, Func<Task<List<StackNode>>> load, bool force = false)
    {
        if (!force && await Cached(account, host, repo).ConfigureAwait(false) is { Fresh: true } hit) return hit.Nodes;
        return await Fetch(account, host, repo, load).ConfigureAwait(false);
    }

    public Task<List<StackNode>?> Nodes(GitHubApi api, RepoRef repo, string? account, bool force = false) =>
        Nodes(account, api.Host, repo, () => api.OpenStackNodes(repo), force);

    public Task<List<StackNode>?> Fetch(GitHubApi api, RepoRef repo, string? account) =>
        Fetch(account, api.Host, repo, () => api.OpenStackNodes(repo));

    public async Task<List<StackNode>?> Fetch(string? account, string host, RepoRef repo, Func<Task<List<StackNode>>> load)
    {
        var k = Key(account, host, repo);
        Task<List<StackNode>?> task;
        long gen;
        lock (gate)
        {
            gen = generation;
            if (fetches.TryGetValue(k, out var existing))
            {
                task = existing;
            }
            else
            {
                task = Run(load);
                fetches[k] = task;
            }
        }
        var nodes = await task.ConfigureAwait(false);
        lock (gate)
        {
            if (fetches.TryGetValue(k, out var running) && running == task) fetches.Remove(k);
            if (nodes is null || gen != generation) return nodes;
            var changed = !memory.TryGetValue(k, out var old) || !old.Nodes.SequenceEqual(nodes);
            memory[k] = (nodes, now());
            if (changed && DiskPath(account, host, repo) is { } path)
            {
                var entry = new Entry { V = Version, Repo = repo.Full.ToLowerInvariant(), Saved = now(), Nodes = nodes };
                Task.Run(() => Write(path, entry, gen)).Forget();
            }
        }
        return nodes;
    }

    private static async Task<List<StackNode>?> Run(Func<Task<List<StackNode>>> load)
    {
        try
        {
            return await load().ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    public void Seed(string? account, string host, RepoRef repo, List<StackNode> nodes)
    {
        lock (gate) memory[Key(account, host, repo)] = (nodes, now());
    }

    public void Invalidate(string? account, string host, RepoRef repo)
    {
        lock (gate) memory.Remove(Key(account, host, repo));
    }

    public void Reset()
    {
        lock (gate)
        {
            generation++;
            memory.Clear();
            fetches.Clear();
        }
    }

    public void Clear(string? account)
    {
        Reset();
        if (ListSnapshotStore.AccountKey(account) is not { } key) return;
        try
        {
            var dir = Path.Combine(root, key);
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "stack cache clear failed");
        }
    }

    private static Entry? Read(string path, RepoRef repo)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var entry = JsonSerializer.Deserialize<Entry>(File.ReadAllBytes(path), Options);
            return entry is { V: Version } && entry.Repo == repo.Full.ToLowerInvariant() ? entry : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            return null;
        }
    }

    private void Write(string path, Entry entry, long gen)
    {
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(entry, Options);
            lock (gate)
            {
                if (gen != generation) return;
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var tmp = $"{path}.{Guid.NewGuid():N}.tmp";
                File.WriteAllBytes(tmp, bytes);
                File.Move(tmp, path, true);
            }
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "stack cache save failed");
        }
    }
}
