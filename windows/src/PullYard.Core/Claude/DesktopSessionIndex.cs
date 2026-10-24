using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public sealed record DesktopLink(string? Local, string? Parent, string? Title, bool Archived);

public sealed record DesktopRecord(string Local, string Cli, string? ParentLocal, string? Title, bool Archived);

public static class DesktopSessionIndex
{
    private static readonly Dictionary<string, (DateTime Stamp, DesktopRecord? Record)> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object Gate = new();

    public static IEnumerable<string> Directories()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (roaming.Length > 0) yield return Path.Combine(roaming, "Claude", "claude-code-sessions");
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (local.Length == 0) yield break;
        var packages = Path.Combine(local, "Packages");
        string[] found;
        try
        {
            found = Directory.Exists(packages) ? Directory.GetDirectories(packages, "Claude_*") : Array.Empty<string>();
        }
        catch
        {
            found = Array.Empty<string>();
        }
        foreach (var p in found) yield return Path.Combine(p, "LocalCache", "Roaming", "Claude", "claude-code-sessions");
    }

    public static bool IsInstalled => Directories().Any(Directory.Exists);

    public static string ContinueUrl(string localId) => "claude://code/continue?session=" + Uri.EscapeDataString(localId);

    public static Dictionary<string, DesktopLink> Load() => Load(Directories());

    public static Dictionary<string, DesktopLink> Load(IEnumerable<string> directories)
    {
        var records = new List<DesktopRecord>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var dir in directories)
        {
            foreach (var file in JsonFiles(dir, 3))
            {
                seen.Add(file);
                if (Record(file) is { } r) records.Add(r);
            }
        }
        lock (Gate)
        {
            foreach (var stale in Cache.Keys.Where(k => !seen.Contains(k)).ToList()) Cache.Remove(stale);
        }
        return Link(records);
    }

    public static Dictionary<string, DesktopLink> Link(IEnumerable<DesktopRecord> records)
    {
        var list = records.ToList();
        var cliByLocal = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var r in list) cliByLocal.TryAdd(r.Local, r.Cli);
        var output = new Dictionary<string, DesktopLink>(StringComparer.Ordinal);
        foreach (var r in list)
        {
            var parent = r.ParentLocal is { } p && cliByLocal.TryGetValue(p, out var cli) && cli != r.Cli ? cli : null;
            output[r.Cli] = new DesktopLink(r.Local, parent, r.Title, r.Archived);
        }
        return output;
    }

    public static DesktopRecord? ParseRecord(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o) return null;
            if (o.Str("sessionId") is not { Length: > 0 } local || o.Str("cliSessionId") is not { Length: > 0 } cli) return null;
            var parent = o.Obj("spawnedFrom").Str("sessionId") ?? o.Str("forkedFromSessionId");
            return new DesktopRecord(local, cli, string.IsNullOrEmpty(parent) ? null : parent, o.Str("title"), o.Bool("isArchived") ?? false);
        }
        catch
        {
            return null;
        }
    }

    private static DesktopRecord? Record(string file)
    {
        DateTime stamp;
        try
        {
            stamp = File.GetLastWriteTimeUtc(file);
        }
        catch
        {
            return null;
        }
        lock (Gate)
        {
            if (Cache.TryGetValue(file, out var hit) && hit.Stamp == stamp) return hit.Record;
        }
        DesktopRecord? r = null;
        try
        {
            var info = new FileInfo(file);
            if (info.Length < 4 * 1024 * 1024)
            {
                using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(fs);
                r = ParseRecord(reader.ReadToEnd());
            }
        }
        catch
        {
            r = null;
        }
        lock (Gate) Cache[file] = (stamp, r);
        return r;
    }

    private static IEnumerable<string> JsonFiles(string dir, int depth)
    {
        if (depth < 0 || !Directory.Exists(dir)) yield break;
        string[] files, subdirs;
        try
        {
            files = Directory.GetFiles(dir, "*.json");
            subdirs = depth > 0 ? Directory.GetDirectories(dir) : Array.Empty<string>();
        }
        catch
        {
            yield break;
        }
        foreach (var f in files) yield return f;
        foreach (var d in subdirs)
            foreach (var f in JsonFiles(d, depth - 1)) yield return f;
    }
}
