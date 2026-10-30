using System.Text;
using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public static class SessionRewind
{
    public const string InterruptedMarker = "[Request interrupted by user";

    public static string? SessionFile(string id, params string?[] configDirs)
    {
        foreach (var dir in configDirs.Where(d => !string.IsNullOrEmpty(d)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var root = Path.Combine(dir!, "projects");
            string[] subdirs;
            try
            {
                subdirs = Directory.GetDirectories(root);
            }
            catch
            {
                continue;
            }
            foreach (var sub in subdirs)
            {
                var file = Path.Combine(sub, id + ".jsonl");
                if (File.Exists(file)) return file;
            }
        }
        return null;
    }

    public static string? RawPrompt(JsonObject o)
    {
        if (o.Str("type") != "user" || o.Bool("isSidechain") == true || o.Bool("isMeta") == true) return null;
        if (o.Obj("message") is not { } msg) return null;
        if (msg["content"] is JsonValue v && v.TryGetValue<string>(out var s))
            return o.Bool("isCompactSummary") == true ? null : s;
        if (msg.Arr("content") is not { } blocks) return null;
        var texts = blocks.Objects()
            .Where(b => b.Str("type") == "text" && b.Str("text") is not null)
            .Select(b => HistoryPrompt.StripPasted(b.Str("text")!).Trim())
            .Where(t => t.Length > 0 && (!t.StartsWith('<') || HistoryPrompt.IsTaskNotification(t)))
            .ToList();
        return texts.Count == 0 ? null : string.Join("\n", texts);
    }

    public static string? PromptText(JsonObject o)
    {
        if (RawPrompt(o) is not { } raw) return null;
        var clean = HistoryPrompt.StripPasted(raw).Trim();
        if (clean.StartsWith(InterruptedMarker) || HistoryPrompt.IsTaskNotification(clean) || HistoryPrompt.IsHidden(clean)) return null;
        return clean;
    }

    public static int? CutIndex(IReadOnlyList<string> lines, string text, int occurrenceFromEnd)
    {
        var target = text.Trim();
        var seen = 0;
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            if (!lines[i].Contains("\"type\":\"user\"")) continue;
            JsonObject? o;
            try
            {
                o = JsonNode.Parse(lines[i]) as JsonObject;
            }
            catch
            {
                continue;
            }
            if (o is null || PromptText(o) is not { } t || t != target) continue;
            if (seen == occurrenceFromEnd) return i;
            seen++;
        }
        return null;
    }

    public static (string Id, string File) Fork(string file, string text, int occurrenceFromEnd)
    {
        var data = File.ReadAllBytes(file);
        var lines = Encoding.UTF8.GetString(data).Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (CutIndex(lines, text, occurrenceFromEnd) is not { } cut)
            throw new InvalidOperationException("Couldn't find this message in the session file");
        var newId = Guid.NewGuid().ToString().ToLowerInvariant();
        var oldId = Path.GetFileNameWithoutExtension(file);
        var oldKey = $"\"sessionId\":\"{oldId}\"";
        var newKey = $"\"sessionId\":\"{newId}\"";
        var sb = new StringBuilder();
        foreach (var line in lines.Take(cut)) sb.Append(line.Replace(oldKey, newKey)).Append('\n');
        var target = Path.Combine(Path.GetDirectoryName(file)!, newId + ".jsonl");
        var temp = target + ".tmp";
        File.WriteAllText(temp, sb.ToString(), new UTF8Encoding(false));
        File.Move(temp, target, true);
        return (newId, target);
    }

    public static int OccurrenceFromEnd(IReadOnlyList<ChatItem> items, string itemId)
    {
        var index = -1;
        for (var i = 0; i < items.Count; i++)
            if (items[i].Id == itemId)
            {
                index = i;
                break;
            }
        if (index < 0 || items[index] is not UserItem user) return -1;
        return items.Skip(index + 1).OfType<UserItem>().Count(u => u.Text == user.Text);
    }
}
