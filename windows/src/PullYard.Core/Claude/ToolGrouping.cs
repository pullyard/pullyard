using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public enum ToolKind { Command, Read, Edit, Search, Web, Agent, Other }

public static class ToolGrouping
{
    public static ToolKind Kind(string name) => name switch
    {
        "Bash" or "BashOutput" or "KillShell" => ToolKind.Command,
        "Read" => ToolKind.Read,
        "Edit" or "MultiEdit" or "Write" or "NotebookEdit" => ToolKind.Edit,
        "Grep" or "Glob" => ToolKind.Search,
        "WebFetch" or "WebSearch" => ToolKind.Web,
        "Task" or "Agent" => ToolKind.Agent,
        _ => ToolKind.Other
    };

    public static string KindKey(string name) => Kind(name).ToString().ToLowerInvariant();

    public static bool Groupable(ToolItem item)
    {
        if (item.Permission is { Resolved: false }) return false;
        return item.Name is not ("TodoWrite" or "ExitPlanMode" or "AskUserQuestion");
    }

    private static string Verb(ToolKind k) => k switch
    {
        ToolKind.Command or ToolKind.Agent => "ran",
        ToolKind.Read => "read",
        ToolKind.Edit => "edited",
        ToolKind.Search => "searched",
        ToolKind.Web => "fetched",
        _ => "used"
    };

    private static string Noun(ToolKind k, int n) => k switch
    {
        ToolKind.Command => n == 1 ? "command" : "commands",
        ToolKind.Read or ToolKind.Edit => n == 1 ? "file" : "files",
        ToolKind.Search => n == 1 ? "pattern" : "patterns",
        ToolKind.Web => n == 1 ? "page" : "pages",
        ToolKind.Agent => n == 1 ? "agent" : "agents",
        _ => n == 1 ? "tool" : "tools"
    };

    public static string Label(IEnumerable<string> toolNames)
    {
        var counts = toolNames.GroupBy(Kind).ToDictionary(g => g.Key, g => g.Count());
        var parts = Enum.GetValues<ToolKind>().Where(counts.ContainsKey).Select(k => $"{Verb(k)} {counts[k]} {Noun(k, counts[k])}");
        var text = string.Join(", ", parts);
        return text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];
    }

    public static string Title(ToolItem item, string folder)
    {
        string S(string key) => item.Input.Str(key) ?? "";
        string P(string key) => ToolItem.Relative(S(key), folder);
        switch (item.Name)
        {
            case "Bash":
                if (S("description") is { Length: > 0 } d) return d;
                var first = S("command").Split('\n')[0];
                return first.Length > 0 ? first : "Command";
            case "Read": return "Read " + P("file_path");
            case "Edit" or "MultiEdit": return "Edited " + P("file_path");
            case "Write": return "Wrote " + P("file_path");
            case "NotebookEdit": return "Edited " + P("notebook_path");
            case "Grep": return $"Searched for \"{S("pattern")}\"";
            case "Glob": return "Found files matching " + S("pattern");
            case "WebFetch":
                return "Fetched " + (Uri.TryCreate(S("url"), UriKind.Absolute, out var u) && u.Host.Length > 0 ? u.Host : "page");
            case "WebSearch": return $"Searched the web for \"{S("query")}\"";
            case "Task" or "Agent": return "Agent: " + (S("description") is { Length: > 0 } t ? t : "task");
            default:
                var summary = item.Summary(folder);
                return summary.Length == 0 ? item.Title : item.Title + " " + summary;
        }
    }
}
