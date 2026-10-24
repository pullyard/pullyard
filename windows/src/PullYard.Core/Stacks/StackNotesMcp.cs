using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Stacks;

public sealed class StackNoteEntry
{
    public string Key { get; set; } = "";
    public string Kind { get; set; } = "note";
    public string Text { get; set; } = "";
    public DateTimeOffset Created { get; set; }

    public StackNoteKind KindValue => StackNotesFile.ParseKind(Kind) ?? StackNoteKind.Note;
}

public static class StackNotesFile
{
    public const string InboxName = "stack-notes-inbox";

    public static string DefaultFile => Path.Combine(AppInfo.DataDirectory, "stack-notes.json");

    public static string InboxFor(string notesFile) => Path.Combine(Path.GetDirectoryName(notesFile) ?? ".", InboxName);

    public static string Key(string? account, string host, string repo, int number) =>
        $"{account?.ToLowerInvariant() ?? ""}|{host}|{repo.ToLowerInvariant()}#{number}";

    public static StackNoteKind? ParseKind(string? raw) => raw?.ToLowerInvariant() switch
    {
        "note" => StackNoteKind.Note,
        "question" => StackNoteKind.Question,
        "decision" => StackNoteKind.Decision,
        _ => null
    };

    public static string KindName(StackNoteKind kind) => kind.ToString().ToLowerInvariant();

    public static List<(StackNoteKind Kind, string Text, string? Source)> Read(string notesFile, string key)
    {
        var output = new List<(StackNoteKind, string, string?)>();
        try
        {
            if (File.Exists(notesFile) && JsonNode.Parse(File.ReadAllBytes(notesFile)) is JsonObject root && root[key] is JsonArray saved)
            {
                foreach (var n in saved.Objects())
                {
                    var text = n.Str("text");
                    if (string.IsNullOrWhiteSpace(text)) continue;
                    output.Add((ParseKind(n.Str("kind")) ?? StackNoteKind.Note, text, n.Str("source")));
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
        }
        foreach (var e in StackNotesInbox.Peek(InboxFor(notesFile)).Where(e => e.Key == key))
            output.Add((e.KindValue, e.Text, StackNotes.AgentSource));
        return output;
    }
}

public static class StackNotesInbox
{
    private static readonly JsonSerializerOptions Options = new(Json.Plain);

    public static void Drop(string directory, StackNoteEntry entry)
    {
        Directory.CreateDirectory(directory);
        var tmp = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(entry, Options));
        File.Move(tmp, Path.Combine(directory, $"{Guid.NewGuid():N}.json"));
    }

    private static IEnumerable<string> Files(string directory)
    {
        try
        {
            return Directory.Exists(directory) ? Directory.GetFiles(directory, "*.json") : Array.Empty<string>();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<string>();
        }
    }

    private static StackNoteEntry? Decode(byte[] data)
    {
        try
        {
            var e = JsonSerializer.Deserialize<StackNoteEntry>(data, Options);
            return e is null || string.IsNullOrEmpty(e.Key) ? null : e;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static List<StackNoteEntry> Peek(string directory)
    {
        var output = new List<StackNoteEntry>();
        foreach (var f in Files(directory))
        {
            try
            {
                if (Decode(File.ReadAllBytes(f)) is { } e) output.Add(e);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
        return output.OrderBy(e => e.Created).ToList();
    }

    public static List<StackNoteEntry> Drain(string directory)
    {
        var output = new List<StackNoteEntry>();
        foreach (var f in Files(directory))
        {
            byte[] data;
            try
            {
                data = File.ReadAllBytes(f);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            if (Decode(data) is { } e) output.Add(e);
            try
            {
                File.Delete(f);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
        return output.OrderBy(e => e.Created).ToList();
    }
}

public sealed class StackNotesMcpServer
{
    public static readonly string[] Versions = { "2025-06-18", "2025-03-26", "2024-11-05" };

    public const string Instructions = "PullYard stack notes. Use add_stack_note when the user asks you to leave a note, question or decision on a pull request in their stack, or when you finish work on a stacked PR and something is worth remembering for the reviewer. Notes stay on the user's PC and are never posted to GitHub.";

    public string? Account { get; }
    public string Host { get; }
    private readonly string notesFile;
    private readonly Func<DateTimeOffset> now;

    public StackNotesMcpServer(string? account, string host, string notesFile, Func<DateTimeOffset>? now = null)
    {
        Account = string.IsNullOrEmpty(account) ? null : account;
        Host = host;
        this.notesFile = notesFile;
        this.now = now ?? (() => DateTimeOffset.Now);
    }

    public static string? Value(IReadOnlyList<string> args, string name)
    {
        for (var i = 0; i < args.Count - 1; i++)
            if (args[i] == name) return args[i + 1];
        return null;
    }

    public static StackNotesMcpServer FromArgs(IReadOnlyList<string> args, string? notesFile = null) =>
        new(Value(args, "--account"), Value(args, "--host") ?? "github.com", notesFile ?? StackNotesFile.DefaultFile);

    public static int Run(IReadOnlyList<string> args, TextReader input, TextWriter output)
    {
        var server = FromArgs(args);
        while (input.ReadLine() is { } line)
        {
            if (server.HandleLine(line) is not { } reply) continue;
            output.Write(reply);
            output.Write('\n');
            output.Flush();
        }
        return 0;
    }

    public string? HandleLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        JsonObject? message;
        try
        {
            message = JsonNode.Parse(line) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
        return message is null ? null : Handle(message)?.ToJsonString();
    }

    public JsonObject? Handle(JsonObject message)
    {
        if (!message.TryGetPropertyValue("id", out var id) || id is null) return null;
        var parameters = message.Obj("params") ?? new JsonObject();
        switch (message.Str("method"))
        {
            case "initialize":
                var requested = parameters.Str("protocolVersion") ?? "";
                return Result(id, new JsonObject
                {
                    ["protocolVersion"] = Versions.Contains(requested) ? requested : Versions[0],
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
                    ["serverInfo"] = new JsonObject { ["name"] = StackNotesMcp.ServerName, ["version"] = "1.0" },
                    ["instructions"] = Instructions
                });
            case "ping":
                return Result(id, new JsonObject());
            case "tools/list":
                return Result(id, new JsonObject { ["tools"] = Tools() });
            case "tools/call":
                return Call(id, parameters.Str("name"), parameters.Obj("arguments") ?? new JsonObject());
            default:
                return new JsonObject
                {
                    ["jsonrpc"] = "2.0",
                    ["id"] = id.DeepClone(),
                    ["error"] = new JsonObject { ["code"] = -32601, ["message"] = "Method not found" }
                };
        }
    }

    private static JsonObject Result(JsonNode id, JsonObject value) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id.DeepClone(),
        ["result"] = value
    };

    private static JsonObject Text(JsonNode id, string text, bool error = false) => Result(id, new JsonObject
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }),
        ["isError"] = error
    });

    private static int? Number(JsonObject args)
    {
        if (args["pr"] is not JsonValue v) return null;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<long>(out var l) && l is > 0 and <= int.MaxValue) return (int)l;
        if (v.TryGetValue<double>(out var d) && d == Math.Floor(d) && d is > 0 and <= int.MaxValue) return (int)d;
        if (v.TryGetValue<string>(out var s) && int.TryParse(s, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var parsed)) return parsed;
        return null;
    }

    private static bool ValidRepo(string? repo) =>
        repo is not null && repo.Split('/').Length == 2 && repo.Split('/').All(p => p.Length > 0);

    private JsonObject Call(JsonNode id, string? name, JsonObject args)
    {
        var repo = args.Str("repo");
        if (!ValidRepo(repo) || Number(args) is not { } number || number <= 0)
            return Text(id, "Pass repo as \"owner/name\" and pr as the pull request number.", true);
        var key = StackNotesFile.Key(Account, Host, repo!, number);
        switch (name)
        {
            case "add_stack_note":
                var body = (args.Str("text") ?? "").Trim();
                if (body.Length == 0) return Text(id, "text is empty", true);
                if (new System.Globalization.StringInfo(body).LengthInTextElements > 4000) return Text(id, "Keep notes under 4000 characters.", true);
                var kind = StackNotesFile.ParseKind(args.Str("kind")) ?? StackNoteKind.Note;
                try
                {
                    StackNotesInbox.Drop(StackNotesFile.InboxFor(notesFile), new StackNoteEntry { Key = key, Kind = StackNotesFile.KindName(kind), Text = body, Created = now() });
                    return Text(id, $"Added a {StackNotesFile.KindName(kind)} to {repo}#{number}. It shows on the PR's card in PullYard's Stack tab.");
                }
                catch (Exception e)
                {
                    return Text(id, $"Couldn't save the note: {e.Message}", true);
                }
            case "list_stack_notes":
                var notes = StackNotesFile.Read(notesFile, key);
                if (notes.Count == 0) return Text(id, $"No notes on {repo}#{number}.");
                return Text(id, string.Join("\n", notes.Select(n => $"- [{StackNotesFile.KindName(n.Kind)}] {n.Text}")));
            default:
                return Text(id, "Unknown tool", true);
        }
    }

    public static JsonArray Tools()
    {
        JsonObject Target() => new()
        {
            ["repo"] = new JsonObject { ["type"] = "string", ["description"] = "Repository as owner/name, e.g. pullyard/pullyard" },
            ["pr"] = new JsonObject { ["type"] = "integer", ["description"] = "Pull request number" }
        };
        var add = Target();
        add["kind"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("note", "question", "decision"), ["description"] = "note (default), question or decision" };
        add["text"] = new JsonObject { ["type"] = "string", ["description"] = "The note text, plain text or short Markdown" };
        return new JsonArray(
            new JsonObject
            {
                ["name"] = "add_stack_note",
                ["description"] = "Add a note, question or decision to a pull request card in the user's PullYard Stack view. Local to the user's PC, never posted to GitHub.",
                ["inputSchema"] = new JsonObject { ["type"] = "object", ["properties"] = add, ["required"] = new JsonArray("repo", "pr", "text") }
            },
            new JsonObject
            {
                ["name"] = "list_stack_notes",
                ["description"] = "List the PullYard stack notes on a pull request.",
                ["inputSchema"] = new JsonObject { ["type"] = "object", ["properties"] = Target(), ["required"] = new JsonArray("repo", "pr") },
                ["annotations"] = new JsonObject { ["readOnlyHint"] = true }
            });
    }
}

public static class StackNotesMcp
{
    public const string Flag = "--mcp-stack-notes";
    public const string ServerName = "pullyard";

    public static string? Command { get; set; }

    public static Func<(string? Account, string Host)?> Target { get; set; } = () => null;

    public static string Config(string? account, string host, string command)
    {
        var args = new JsonArray(Flag, "--host", host);
        if (!string.IsNullOrEmpty(account))
        {
            args.Add("--account");
            args.Add(account);
        }
        var root = new JsonObject
        {
            ["mcpServers"] = new JsonObject
            {
                [ServerName] = new JsonObject { ["type"] = "stdio", ["command"] = command, ["args"] = args }
            }
        };
        return root.ToJsonString();
    }

    public static List<string> LaunchArgs()
    {
        try
        {
            if (string.IsNullOrEmpty(Command) || Target() is not { } t || string.IsNullOrEmpty(t.Host)) return new List<string>();
            return new List<string> { "--mcp-config", Config(t.Account, t.Host, Command) };
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "stack notes mcp config failed");
            return new List<string>();
        }
    }
}
