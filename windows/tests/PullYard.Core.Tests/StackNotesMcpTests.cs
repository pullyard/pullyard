using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Stacks;
using Xunit;

namespace PullYard.Core.Tests;

public class StackNotesMcpTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "pullyard-mcp-" + Guid.NewGuid().ToString("N"));

    private string NotesFile => Path.Combine(dir, "stack-notes.json");

    private string Inbox => Path.Combine(dir, StackNotesFile.InboxName);

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    private StackNotesMcpServer Server(string? account = "Me") => new(account, "github.com", NotesFile, () => DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

    private static JsonObject Request(string method, JsonObject? parameters = null, JsonNode? id = null) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id ?? 1,
        ["method"] = method,
        ["params"] = parameters ?? new JsonObject()
    };

    private static JsonObject CallTool(string name, JsonObject args) => Request("tools/call", new JsonObject { ["name"] = name, ["arguments"] = args });

    private static string ReplyText(JsonObject reply) => reply["result"]!["content"]![0]!["text"]!.GetValue<string>();

    private static bool IsError(JsonObject reply) => reply["result"]!["isError"]!.GetValue<bool>();

    [Fact]
    public void InitializeNegotiatesVersion()
    {
        var known = Server().Handle(Request("initialize", new JsonObject { ["protocolVersion"] = "2024-11-05" }))!;
        Assert.Equal("2024-11-05", known["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal("pullyard", known["result"]!["serverInfo"]!["name"]!.GetValue<string>());
        Assert.NotNull(known["result"]!["capabilities"]!["tools"]);
        var unknown = Server().Handle(Request("initialize", new JsonObject { ["protocolVersion"] = "1999-01-01" }))!;
        Assert.Equal(StackNotesMcpServer.Versions[0], unknown["result"]!["protocolVersion"]!.GetValue<string>());
    }

    [Fact]
    public void NotificationsGetNoReplyAndUnknownMethodsError()
    {
        var notification = new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" };
        Assert.Null(Server().Handle(notification));
        var reply = Server().Handle(Request("resources/list", id: "abc"))!;
        Assert.Equal(-32601, reply["error"]!["code"]!.GetValue<int>());
        Assert.Equal("abc", reply["id"]!.GetValue<string>());
        Assert.Null(Server().HandleLine("not json"));
        Assert.Null(Server().HandleLine(""));
    }

    [Fact]
    public void ToolsListMatchesSchemas()
    {
        var tools = Server().Handle(Request("tools/list"))!["result"]!["tools"]!.AsArray();
        Assert.Equal(new[] { "add_stack_note", "list_stack_notes" }, tools.Select(t => t!["name"]!.GetValue<string>()));
        var add = tools[0]!["inputSchema"]!;
        Assert.Equal(new[] { "repo", "pr", "text" }, add["required"]!.AsArray().Select(n => n!.GetValue<string>()));
        Assert.Equal(new[] { "note", "question", "decision" }, add["properties"]!["kind"]!["enum"]!.AsArray().Select(n => n!.GetValue<string>()));
        Assert.True(tools[1]!["annotations"]!["readOnlyHint"]!.GetValue<bool>());
    }

    [Fact]
    public void AddNoteDropsIntoInboxWithLowercasedKey()
    {
        var reply = Server().Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = "Acme/App", ["pr"] = 7, ["kind"] = "decision", ["text"] = "  Merge API first \n" }))!;
        Assert.False(IsError(reply));
        Assert.Equal("Added a decision to Acme/App#7. It shows on the PR's card in PullYard's Stack tab.", ReplyText(reply));
        var entry = Assert.Single(StackNotesInbox.Peek(Inbox));
        Assert.Equal("me|github.com|acme/app#7", entry.Key);
        Assert.Equal("Merge API first", entry.Text);
        Assert.Equal(StackNoteKind.Decision, entry.KindValue);
    }

    [Fact]
    public void AcceptsStringNumberAndDefaultsKind()
    {
        var reply = Server(null).Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = "acme/app", ["pr"] = "12", ["text"] = "hi", ["kind"] = "bogus" }))!;
        Assert.False(IsError(reply));
        var entry = Assert.Single(StackNotesInbox.Peek(Inbox));
        Assert.Equal("|github.com|acme/app#12", entry.Key);
        Assert.Equal(StackNoteKind.Note, entry.KindValue);
    }

    [Theory]
    [InlineData("acme", 1)]
    [InlineData("/acme/app", 1)]
    [InlineData("acme/app/", 1)]
    [InlineData("acme/app", 0)]
    public void RejectsBadTargets(string repo, int pr)
    {
        var reply = Server().Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = repo, ["pr"] = pr, ["text"] = "x" }))!;
        Assert.True(IsError(reply));
        Assert.Equal("Pass repo as \"owner/name\" and pr as the pull request number.", ReplyText(reply));
    }

    [Fact]
    public void RejectsEmptyAndLongText()
    {
        var empty = Server().Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = "a/b", ["pr"] = 1, ["text"] = "   " }))!;
        Assert.Equal("text is empty", ReplyText(empty));
        var tooLong = Server().Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = "a/b", ["pr"] = 1, ["text"] = new string('x', 4001) }))!;
        Assert.Equal("Keep notes under 4000 characters.", ReplyText(tooLong));
        var unknown = Server().Handle(CallTool("delete_everything", new JsonObject { ["repo"] = "a/b", ["pr"] = 1 }))!;
        Assert.Equal("Unknown tool", ReplyText(unknown));
        Assert.Empty(StackNotesInbox.Peek(Inbox));
    }

    [Fact]
    public async Task ListIncludesSavedAndPendingNotes()
    {
        var server = Server();
        Assert.Equal("No notes on acme/app#3.", ReplyText(server.Handle(CallTool("list_stack_notes", new JsonObject { ["repo"] = "acme/app", ["pr"] = 3 }))!));
        var store = new StackNotes(NotesFile);
        var key = StackNotes.Key("me", "github.com", new RepoRef("acme", "app"), 3);
        store.Replace(key, new[] { new StackNote(Guid.NewGuid(), StackNoteKind.Question, "Why?", DateTimeOffset.Now) });
        await store.Flush();
        server.Handle(CallTool("add_stack_note", new JsonObject { ["repo"] = "acme/app", ["pr"] = 3, ["text"] = "Done" }));
        var listed = ReplyText(server.Handle(CallTool("list_stack_notes", new JsonObject { ["repo"] = "acme/app", ["pr"] = 3 }))!);
        Assert.Equal("- [question] Why?\n- [note] Done", listed);
    }

    [Fact]
    public void ImportInboxMergesAsAgentNotesAndClearsInbox()
    {
        var key = "me|github.com|acme/app#5";
        StackNotesInbox.Drop(Inbox, new StackNoteEntry { Key = key, Kind = "question", Text = "Second", Created = DateTimeOffset.FromUnixTimeSeconds(20) });
        StackNotesInbox.Drop(Inbox, new StackNoteEntry { Key = key, Kind = "note", Text = "First", Created = DateTimeOffset.FromUnixTimeSeconds(10) });
        File.WriteAllText(Path.Combine(Inbox, "junk.json"), "{nope");
        var store = new StackNotes(NotesFile);
        var fired = new List<string>();
        store.Changed += fired.Add;
        Assert.Equal(1, store.ImportInbox());
        var notes = store.Notes(key);
        Assert.Equal(new[] { "First", "Second" }, notes.Select(n => n.Text));
        Assert.All(notes, n => Assert.Equal(StackNotes.AgentSource, n.Source));
        Assert.Equal(StackNoteKind.Question, notes[1].Kind);
        Assert.Equal(new[] { key }, fired);
        Assert.Empty(Directory.GetFiles(Inbox, "*.json"));
        Assert.Equal(0, store.ImportInbox());
    }

    [Fact]
    public async Task SourceSurvivesSaveAndEdits()
    {
        var key = "k";
        StackNotesInbox.Drop(Inbox, new StackNoteEntry { Key = key, Kind = "note", Text = "From agent", Created = DateTimeOffset.Now });
        var store = new StackNotes(NotesFile);
        store.ImportInbox();
        var note = store.Notes(key)[0];
        store.Replace(key, new[] { note, new StackNote(Guid.NewGuid(), StackNoteKind.Note, "Mine", DateTimeOffset.Now) });
        await store.Flush();
        var reloaded = new StackNotes(NotesFile);
        Assert.Equal(new string?[] { "Claude", null }, reloaded.Notes(key).Select(n => n.Source));
    }

    [Fact]
    public async Task WatcherImportsDroppedNotes()
    {
        var store = new StackNotes(NotesFile);
        var arrived = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        store.Changed += k => arrived.TrySetResult(k);
        store.WatchInbox();
        StackNotesInbox.Drop(Inbox, new StackNoteEntry { Key = "w", Kind = "note", Text = "Live", Created = DateTimeOffset.Now });
        var done = await Task.WhenAny(arrived.Task, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.Same(arrived.Task, done);
        Assert.Equal("Live", Assert.Single(store.Notes("w")).Text);
    }

    [Fact]
    public void ConfigPointsAtExecutable()
    {
        var json = JsonNode.Parse(StackNotesMcp.Config("me", "github.com", @"C:\Apps\PullYard.exe"))!;
        var server = json["mcpServers"]!["pullyard"]!;
        Assert.Equal("stdio", server["type"]!.GetValue<string>());
        Assert.Equal(@"C:\Apps\PullYard.exe", server["command"]!.GetValue<string>());
        Assert.Equal(new[] { "--mcp-stack-notes", "--host", "github.com", "--account", "me" }, server["args"]!.AsArray().Select(n => n!.GetValue<string>()));
        var anonymous = JsonNode.Parse(StackNotesMcp.Config(null, "ghe.example.com", "x"))!;
        Assert.Equal(3, anonymous["mcpServers"]!["pullyard"]!["args"]!.AsArray().Count);
    }

    [Fact]
    public void LaunchArgsNeedCommandAndTarget()
    {
        var command = StackNotesMcp.Command;
        var target = StackNotesMcp.Target;
        try
        {
            StackNotesMcp.Command = null;
            StackNotesMcp.Target = () => ("me", "github.com");
            Assert.Empty(StackNotesMcp.LaunchArgs());
            StackNotesMcp.Command = "PullYard.exe";
            StackNotesMcp.Target = () => null;
            Assert.Empty(StackNotesMcp.LaunchArgs());
            StackNotesMcp.Target = () => ("me", "github.com");
            var args = StackNotesMcp.LaunchArgs();
            Assert.Equal("--mcp-config", args[0]);
            Assert.Contains("--mcp-stack-notes", args[1]);
        }
        finally
        {
            StackNotesMcp.Command = command;
            StackNotesMcp.Target = target;
        }
    }

    [Fact]
    public void RunReadsLinesAndWritesReplies()
    {
        var input = new StringReader("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n");
        var output = new StringWriter();
        var args = new[] { "--mcp-stack-notes", "--host", "github.com", "--account", "me" };
        Assert.Equal("me", StackNotesMcpServer.Value(args, "--account"));
        Assert.Equal(0, StackNotesMcpServer.Run(args, input, output));
        var lines = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        Assert.Equal(1, JsonNode.Parse(lines[0])!["id"]!.GetValue<int>());
        Assert.Equal(2, JsonNode.Parse(lines[1])!["id"]!.GetValue<int>());
    }
}
