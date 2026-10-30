using System.Text.RegularExpressions;

namespace PullYard.Core.Claude;

public static class HistoryPrompt
{
    public const string TaskNotificationTag = "<task-notification>";

    private static readonly Regex PastedRx = new(@"</?pasted_content[^>]*>", RegexOptions.Compiled);
    private static readonly Regex FailedExitRx = new(@"exit code [1-9]", RegexOptions.Compiled);
    private static readonly Regex SpaceRx = new(@"\s+", RegexOptions.Compiled);

    public static string StripPasted(string text) => PastedRx.Replace(text, "");

    public static bool IsTaskNotification(string text) => text.TrimStart().StartsWith(TaskNotificationTag, StringComparison.Ordinal);

    public static bool IsHidden(string clean) =>
        clean.Length == 0 || clean.StartsWith("<command-name>") || clean.StartsWith("<local-command") ||
        clean.StartsWith("<command-message>") || clean.StartsWith("Caveat:");

    public static ChatItem? Item(string id, string raw)
    {
        var text = StripPasted(raw).Trim();
        if (IsTaskNotification(text))
        {
            var (notice, failed) = TaskNotice(text);
            return new NoticeItem(id, notice, failed);
        }
        if (text.StartsWith(SessionRewind.InterruptedMarker)) return new NoticeItem(id, "Interrupted", false);
        if (IsHidden(text)) return null;
        return new UserItem(id, text, Array.Empty<ChatImage>());
    }

    public static (string Text, bool Failed) TaskNotice(string text)
    {
        var status = Tag(text, "status") ?? "";
        var summary = Tag(text, "summary") ?? "";
        var failed = status == "failed" || FailedExitRx.IsMatch(summary);
        var verb = status switch
        {
            "completed" => failed ? "failed" : "finished",
            "failed" => "failed",
            "killed" or "stopped" => "stopped",
            "" => "updated",
            _ => status
        };
        var subject = summary;
        var open = summary.IndexOf('"');
        var close = summary.LastIndexOf('"');
        if (open >= 0 && close > open) subject = summary[(open + 1)..close];
        subject = SpaceRx.Replace(subject, " ").Trim();
        if (subject.Length > 60) subject = subject[..59] + "…";
        var label = summary.StartsWith("Agent") ? "Agent" : "Background task";
        return (subject.Length == 0 ? $"{label} {verb}" : $"{label} {verb} · {subject}", failed);
    }

    private static string? Tag(string text, string name)
    {
        var m = Regex.Match(text, $"<{name}>([\\s\\S]*?)</{name}>");
        if (!m.Success) return null;
        return m.Groups[1].Value
            .Replace("&lt;", "<")
            .Replace("&gt;", ">")
            .Replace("&quot;", "\"")
            .Replace("&#39;", "'")
            .Replace("&amp;", "&")
            .Trim();
    }
}
