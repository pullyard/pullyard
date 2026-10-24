using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public sealed class SessionIndex
{
    private static SessionIndex? shared;
    public static SessionIndex Shared => shared ??= new SessionIndex(Path.Combine(AppInfo.DataDirectory, "session-index"));

    private readonly string dir;
    private readonly object gate = new();
    private Dictionary<string, string> stamps = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, (string Stamp, byte[] Data)> blobs = new(StringComparer.OrdinalIgnoreCase);
    private bool loaded;
    private int warmed;

    public SessionIndex(string directory)
    {
        dir = directory;
    }

    private string StampsFile => Path.Combine(dir, "stamps.json");

    private void Load()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            Directory.CreateDirectory(dir);
            if (File.Exists(StampsFile) && JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(StampsFile)) is { } s)
                stamps = new Dictionary<string, string>(s, StringComparer.OrdinalIgnoreCase);
        }
        catch
        {
            stamps = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private void Save()
    {
        try
        {
            var tmp = StampsFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(stamps));
            File.Move(tmp, StampsFile, true);
        }
        catch
        {
        }
    }

    public static string Key(string file)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(file));
        return Convert.ToHexString(hash, 0, 12).ToLowerInvariant();
    }

    public static string? Stamp(string file)
    {
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists) return null;
            return $"{info.LastWriteTimeUtc.Ticks}-{info.Length}";
        }
        catch
        {
            return null;
        }
    }

    private string BlobPath(string file) => Path.Combine(dir, Key(file) + ".txt");

    public bool Warm(IReadOnlyList<string> files, CancellationToken ct = default)
    {
        if (Interlocked.Exchange(ref warmed, 1) == 1) return false;
        Update(files, ct);
        return true;
    }

    public void Update(IEnumerable<string> files, CancellationToken ct = default)
    {
        lock (gate)
        {
            Load();
            var changed = false;
            var i = 0;
            foreach (var file in files)
            {
                if (i++ % 16 == 0 && ct.IsCancellationRequested) break;
                if (Stamp(file) is not { } st || (stamps.TryGetValue(file, out var cur) && cur == st)) continue;
                var text = Extract(file);
                try
                {
                    File.WriteAllBytes(BlobPath(file), Encoding.UTF8.GetBytes(text));
                }
                catch
                {
                    continue;
                }
                stamps[file] = st;
                blobs.Remove(file);
                changed = true;
            }
            if (changed) Save();
        }
    }

    public Dictionary<string, string> Search(string query, IReadOnlyList<string> files, CancellationToken ct = default)
    {
        var output = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var q = query.Trim().ToLowerInvariant();
        if (q.Length == 0) return output;
        lock (gate)
        {
            Load();
            var missing = files.Where(f => !stamps.ContainsKey(f)).ToList();
            var stale = files.Where(f => stamps.TryGetValue(f, out var st) && st != Stamp(f)).ToList();
            if (stale.Count > 6) stale.Clear();
            Update(missing.Concat(stale), ct);
            var needle = Encoding.UTF8.GetBytes(q);
            for (var i = 0; i < files.Count; i++)
            {
                if (i % 32 == 0 && ct.IsCancellationRequested) return output;
                if (Blob(files[i]) is not { } data) continue;
                var at = data.AsSpan().IndexOf(needle);
                if (at < 0) continue;
                output[files[i]] = Snippet(data, at, needle.Length);
            }
        }
        return output;
    }

    private byte[]? Blob(string file)
    {
        if (!stamps.TryGetValue(file, out var st)) return null;
        if (blobs.TryGetValue(file, out var hit) && hit.Stamp == st) return hit.Data;
        try
        {
            var data = File.ReadAllBytes(BlobPath(file));
            blobs[file] = (st, data);
            return data;
        }
        catch
        {
            return null;
        }
    }

    public static string Snippet(byte[] data, int index, int length)
    {
        var start = Math.Max(0, index - 90);
        var end = Math.Min(data.Length, index + length + 140);
        var text = Encoding.UTF8.GetString(data, start, end - start).Trim('�').Replace('\n', ' ').Replace('\r', ' ');
        return (start > 0 ? "…" : "") + text + (end < data.Length ? "…" : "");
    }

    private static readonly byte[] UserMarker = Encoding.UTF8.GetBytes("\"type\":\"user\"");
    private static readonly byte[] AssistantMarker = Encoding.UTF8.GetBytes("\"type\":\"assistant\"");
    private static readonly byte[] ToolResultMarker = Encoding.UTF8.GetBytes("\"tool_use_id\"");

    public static string Extract(string file)
    {
        byte[] data;
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            data = new byte[fs.Length];
            fs.ReadExactly(data, 0, data.Length);
        }
        catch
        {
            return "";
        }
        return ExtractText(data);
    }

    public static string ExtractText(ReadOnlySpan<byte> data)
    {
        var parts = new List<string>();
        while (data.Length > 0)
        {
            var nl = data.IndexOf((byte)'\n');
            var line = nl < 0 ? data : data[..nl];
            data = nl < 0 ? ReadOnlySpan<byte>.Empty : data[(nl + 1)..];
            if (line.Length == 0 || line.Length >= 400_000) continue;
            var isUser = line.IndexOf(UserMarker) >= 0;
            if (!isUser && line.IndexOf(AssistantMarker) < 0) continue;
            if (isUser && line.IndexOf(ToolResultMarker) >= 0) continue;
            JsonObject? o;
            try
            {
                o = JsonNode.Parse(line) as JsonObject;
            }
            catch
            {
                continue;
            }
            if (o is null) continue;
            if (isUser)
            {
                if (PromptText(o) is { } t) parts.Add(t);
            }
            else if (o.Str("type") == "assistant")
            {
                foreach (var b in o.Obj("message").Arr("content").Objects())
                    if (b.Str("type") == "text" && b.Str("text") is { Length: > 0 } t) parts.Add(t);
            }
        }
        return string.Join("\n", parts).ToLowerInvariant();
    }

    public static string? PromptText(JsonObject o)
    {
        if (o.Str("type") != "user" || o.Bool("isSidechain") == true || o.Bool("isMeta") == true || o.Bool("isCompactSummary") == true) return null;
        if (o.Obj("message") is not { } msg) return null;
        string raw;
        if (msg["content"] is JsonValue v && v.TryGetValue<string>(out var s))
        {
            raw = s;
        }
        else if (msg["content"] is JsonArray blocks)
        {
            if (blocks.Objects().Any(b => b.Str("type") == "tool_result")) return null;
            var texts = blocks.Objects().Where(b => b.Str("type") == "text").Select(b => b.Str("text")).Where(t => t is not null && !t.StartsWith('<')).ToList();
            if (texts.Count == 0) return null;
            raw = string.Join("\n", texts);
        }
        else
        {
            return null;
        }
        var clean = raw.Trim();
        if (clean.Length == 0 || clean.StartsWith("<command-name>") || clean.StartsWith("<local-command") || clean.StartsWith("Caveat:") || clean.StartsWith("[Request interrupted")) return null;
        return clean;
    }
}
