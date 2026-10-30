using System.Text.Json.Nodes;
using PullYard.Core.Claude;
using Xunit;

namespace PullYard.Core.Tests;

public class AgentChatTests
{
    private static ToolItem Tool(string name, string input = "{}") => new(Guid.NewGuid().ToString(), name) { Input = (JsonObject)JsonNode.Parse(input)! };

    [Fact]
    public void GroupLabelCountsKindsInOrder()
    {
        Assert.Equal("Ran 3 commands, read 2 files", ToolGrouping.Label(new[] { "Read", "Bash", "Bash", "Read", "Bash" }));
        Assert.Equal("Edited 1 file, searched 2 patterns", ToolGrouping.Label(new[] { "Grep", "Edit", "Glob" }));
        Assert.Equal("Fetched 1 page, ran 1 agent, used 1 tool", ToolGrouping.Label(new[] { "mcp__x__y", "Task", "WebSearch" }));
        Assert.Equal("", ToolGrouping.Label(Array.Empty<string>()));
    }

    [Fact]
    public void StepTitlesDescribeEachCall()
    {
        const string folder = "C:\\code\\proj";
        Assert.Equal("List files", ToolGrouping.Title(Tool("Bash", """{"command":"ls","description":"List files"}"""), folder));
        Assert.Equal("git status", ToolGrouping.Title(Tool("Bash", """{"command":"git status\ngit diff"}"""), folder));
        Assert.Equal("Read a.cs", ToolGrouping.Title(Tool("Read", """{"file_path":"C:\\code\\proj\\a.cs"}"""), folder));
        Assert.Equal("Edited src\\b.cs", ToolGrouping.Title(Tool("Edit", """{"file_path":"C:\\code\\proj\\src\\b.cs"}"""), folder));
        Assert.Equal("Searched for \"TODO\"", ToolGrouping.Title(Tool("Grep", """{"pattern":"TODO"}"""), folder));
        Assert.Equal("Fetched example.com", ToolGrouping.Title(Tool("WebFetch", """{"url":"https://example.com/a"}"""), folder));
        Assert.Equal("Agent: scan", ToolGrouping.Title(Tool("Task", """{"description":"scan"}"""), folder));
        Assert.Equal("command", ToolGrouping.KindKey("BashOutput"));
    }

    [Fact]
    public void PendingPermissionsAndPlanToolsStayOutOfGroups()
    {
        Assert.True(ToolGrouping.Groupable(Tool("Bash")));
        Assert.False(ToolGrouping.Groupable(Tool("TodoWrite")));
        Assert.False(ToolGrouping.Groupable(Tool("AskUserQuestion")));
        var t = Tool("Bash");
        t.Permission = new PermissionRequest { Id = "p", ToolName = "Bash" };
        Assert.False(ToolGrouping.Groupable(t));
        t.Permission.Resolved = true;
        Assert.True(ToolGrouping.Groupable(t));
    }

    [Theory]
    [InlineData("Invalid API key · Please run /login", true)]
    [InlineData("OAuth token has expired. Please obtain a new token", true)]
    [InlineData("API Error: 401 {\"type\":\"error\"}", true)]
    [InlineData("Not logged in", true)]
    [InlineData("Claude exited with code 1\nENOENT: no such file", false)]
    [InlineData("", false)]
    public void DetectsAuthErrors(string text, bool expected) => Assert.Equal(expected, ChatSession.IsAuthError(text));

    [Fact]
    public void AuthErrorResultBecomesBannerNotNotice()
    {
        var chat = new ChatSession("C:\\code\\proj", null);
        chat.Consume("""{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}""");
        Assert.True(chat.AuthExpired);
        Assert.Empty(chat.Items);
        chat.Consume("""{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached max turns"}""");
        Assert.IsType<NoticeItem>(Assert.Single(chat.Items));
    }

    [Fact]
    public void QueuesPromptsUntilTheProcessRuns()
    {
        var chat = new ChatSession("C:\\code\\proj", null);
        chat.Send("first", new[] { new ChatImage { Data = new byte[] { 1 }, MediaType = "image/png" } });
        chat.Send("second");
        Assert.Equal(2, chat.Items.Count);
        var first = Assert.IsType<UserItem>(chat.Items[0]);
        Assert.Single(first.Images);
        Assert.True(chat.HasQueuedPrompts);
        Assert.False(chat.Busy);
    }

    [Fact]
    public void DetectsCreatedPullRequest()
    {
        Assert.Equal("https://github.com/o/r/pull/42", AgentShip.PullRequestUrl("Created\nhttps://github.com/o/r/pull/42\n"));
        Assert.Null(AgentShip.PullRequestUrl("https://github.com/o/r/issues/42"));
        Assert.Equal((42, "o/r"), AgentShip.ParsePullRequestUrl("https://github.com/o/r/pull/42"));
        var chat = new ChatSession("C:\\code\\proj", null);
        chat.Consume("""{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr create --title x --body y"}}]}}""");
        chat.Consume("""{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"https://github.com/o/r/pull/7","is_error":false}]}}""");
        Assert.Equal("https://github.com/o/r/pull/7", chat.CreatedPR);
        var other = new ChatSession("C:\\code\\proj", null);
        other.Consume("""{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr view"}}]}}""");
        other.Consume("""{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"https://github.com/o/r/pull/7","is_error":false}]}}""");
        Assert.Null(other.CreatedPR);
    }

    [Fact]
    public void ShipPromptsFollowBranchState()
    {
        var onMain = AgentShip.OpenPRPrompt("main", null, true, 0);
        Assert.Contains("Create a new branch", onMain);
        Assert.Contains("Commit the current changes", onMain);
        Assert.Contains("gh pr create", onMain);
        var clean = AgentShip.OpenPRPrompt("feature", null, false, 0);
        Assert.Contains("say so and stop", clean);
        Assert.DoesNotContain("Create a new branch", clean);
        Assert.Contains("#12", AgentShip.CommitPrompt(12));
    }

    [Fact]
    public void ParsesLatestTodoProgress()
    {
        var chat = new ChatSession("C:\\code\\proj", null);
        chat.Consume("""{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Old","status":"pending"}]}}]}}""");
        chat.Consume("""{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"Read code","activeForm":"Reading code","status":"completed"},{"content":"Fix bug","activeForm":"Fixing bug","status":"in_progress"},{"content":"Test","status":"pending"}]}}]}}""");
        var p = TodoProgress.Latest(chat.Items)!;
        Assert.Equal(1, p.Done);
        Assert.Equal(3, p.Total);
        Assert.Equal("Fixing bug", p.Current);
        Assert.Equal("Read code", p.Todos[0].Title);
        Assert.False(p.Finished);
        Assert.Null(TodoProgress.From(new JsonArray()));
    }

    [Fact]
    public void WelcomeSuggestionsReflectRepoState()
    {
        var dirty = AgentWelcome.Suggestions(3, "feature", true, 1, null, null);
        Assert.Equal(new[] { WelcomeSuggestionKind.ReviewChanges, WelcomeSuggestionKind.OpenPR, WelcomeSuggestionKind.ExplainStructure, WelcomeSuggestionKind.FindBugs }, dirty.Select(s => s.Kind));
        var withPr = AgentWelcome.Suggestions(0, "feature", true, 0, 9, "https://github.com/o/r/pull/9");
        Assert.Equal(WelcomeSuggestionKind.AddressReview, withPr[0].Kind);
        Assert.Contains("#9", withPr[0].Prompt);
        var clean = AgentWelcome.Suggestions(0, null, false, 0, null, null);
        Assert.Equal(3, clean.Count);
    }

    private static string Line(string type, string uuid, string sid, string content) =>
        "{\"type\":\"" + type + "\",\"uuid\":\"" + uuid + "\",\"sessionId\":\"" + sid + "\",\"message\":{\"role\":\"" + type + "\",\"content\":" + content + "}}";

    [Fact]
    public void ForksSessionBeforeTheEditedPrompt()
    {
        var dir = Path.Combine(Path.GetTempPath(), "rewind-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(dir, "projects", "p"));
        const string sid = "11111111-2222-3333-4444-555555555555";
        var file = Path.Combine(dir, "projects", "p", sid + ".jsonl");
        File.WriteAllText(file, string.Join("\n", new[]
        {
            Line("user", "u1", sid, "\"Fix it\""),
            Line("assistant", "a1", sid, """[{"type":"text","text":"Done"}]"""),
            Line("user", "u2", sid, "\"Again\""),
            Line("assistant", "a2", sid, """[{"type":"text","text":"Ok"}]"""),
            Line("user", "u3", sid, """[{"type":"text","text":"Again"}]"""),
            Line("assistant", "a3", sid, """[{"type":"text","text":"Ok"}]""")
        }) + "\n");
        try
        {
            Assert.Equal(file, SessionRewind.SessionFile(sid, null, dir));
            var (id, forked) = SessionRewind.Fork(file, " Again ", 1);
            var lines = File.ReadAllLines(forked);
            Assert.Equal(2, lines.Length);
            Assert.All(lines, l => Assert.Contains($"\"sessionId\":\"{id}\"", l));
            Assert.DoesNotContain(sid, File.ReadAllText(forked));
            var (_, latest) = SessionRewind.Fork(file, "Again", 0);
            Assert.Equal(4, File.ReadAllLines(latest).Length);
            Assert.Throws<InvalidOperationException>(() => SessionRewind.Fork(file, "Missing", 0));
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void OccurrenceCountsLaterIdenticalPrompts()
    {
        var items = new List<ChatItem>
        {
            new UserItem("1", "Again", Array.Empty<ChatImage>()),
            new TextItem("x", false, "Ok"),
            new UserItem("2", "Again", Array.Empty<ChatImage>()),
            new UserItem("3", "Other", Array.Empty<ChatImage>())
        };
        Assert.Equal(1, SessionRewind.OccurrenceFromEnd(items, "u1"));
        Assert.Equal(0, SessionRewind.OccurrenceFromEnd(items, "u2"));
        Assert.Equal(-1, SessionRewind.OccurrenceFromEnd(items, "missing"));
    }

    [Fact]
    public void PromptTextSkipsCommandsAndToolResults()
    {
        JsonObject O(string s) => (JsonObject)JsonNode.Parse(s)!;
        Assert.Equal("Hi", SessionRewind.PromptText(O("""{"type":"user","message":{"content":"  Hi \n"}}""")));
        Assert.Null(SessionRewind.PromptText(O("""{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}""")));
        Assert.Null(SessionRewind.PromptText(O("""{"type":"user","isMeta":true,"message":{"content":"Hi"}}""")));
        Assert.Null(SessionRewind.PromptText(O("""{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}""")));
        Assert.Null(SessionRewind.PromptText(O("""{"type":"user","message":{"content":"[Request interrupted by user]"}}""")));
    }

    [Fact]
    public void TaskNotificationBecomesNotice()
    {
        const string raw = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"pnpm run ship &amp;&amp; echo ok\" completed (exit code 0)</summary>\n</task-notification>";
        var ok = Assert.IsType<NoticeItem>(HistoryPrompt.Item("1", raw));
        Assert.Equal("Background task finished · pnpm run ship && echo ok", ok.Text);
        Assert.False(ok.IsError);
        var failed = Assert.IsType<NoticeItem>(HistoryPrompt.Item("2", raw.Replace("exit code 0", "exit code 2")));
        Assert.True(failed.IsError);
        Assert.StartsWith("Background task failed", failed.Text);
        var killed = Assert.IsType<NoticeItem>(HistoryPrompt.Item("3", raw.Replace("completed</status>", "killed</status>")));
        Assert.StartsWith("Background task stopped", killed.Text);
        var user = Assert.IsType<UserItem>(HistoryPrompt.Item("4", "<pasted_content id=\"1\">Fix the build</pasted_content>"));
        Assert.Equal("Fix the build", user.Text);
        Assert.Null(SessionRewind.PromptText((JsonObject)JsonNode.Parse("""{"type":"user","message":{"content":"<task-notification><status>completed</status></task-notification>"}}""")!));
        Assert.Null(ClaudeSessionParser.CleanPrompt(raw));
    }

    [Fact]
    public void ReauthPollingBacksOff()
    {
        Assert.Equal(3, ClaudeAccountStore.ReauthDelay(0));
        Assert.Equal(10, ClaudeAccountStore.ReauthDelay(20));
    }
}
