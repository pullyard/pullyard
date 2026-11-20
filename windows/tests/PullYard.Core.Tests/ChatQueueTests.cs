using System.Text.Json.Nodes;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class ChatControlTests
{
    private readonly List<JsonObject> sent = new();

    private ChatSession MakeSession(bool delivers = true)
    {
        var chat = new ChatSession("C:\\code\\proj", null) { Ledger = null, Running = true };
        chat.Transport = obj =>
        {
            sent.Add(obj);
            return delivers;
        };
        return chat;
    }

    private string LastRequestId() => sent[^1].Str("request_id") ?? "";

    private static string Error(string id, string error) =>
        new JsonObject { ["type"] = "control_response", ["response"] = new JsonObject { ["subtype"] = "error", ["request_id"] = id, ["error"] = error } }.ToJsonString();

    [Fact]
    public void RejectedModelChangeRollsBack()
    {
        var chat = MakeSession();
        chat.ModelValue = "sonnet";
        chat.SetModel("nope");
        Assert.Equal("nope", chat.ModelValue);
        chat.Consume(Error(LastRequestId(), "Unknown model"));
        Assert.Equal("sonnet", chat.ModelValue);
        var notice = Assert.IsType<NoticeItem>(chat.Items[^1]);
        Assert.True(notice.IsError);
        Assert.Equal("Couldn't change model: Unknown model", notice.Text);
    }

    [Fact]
    public void RejectedModeAndEffortChangesRollBack()
    {
        var chat = MakeSession();
        chat.SetPermissionMode("plan");
        chat.Consume(Error(LastRequestId(), "Not allowed"));
        Assert.Equal("default", chat.PermissionMode);
        Assert.Contains("permission mode", Assert.IsType<NoticeItem>(chat.Items[^1]).Text);
        chat.SetEffort("high");
        Assert.Equal("high", sent[^1].Obj("request").Obj("settings").Str("effortLevel"));
        chat.Consume(Error(LastRequestId(), "Unsupported"));
        Assert.Equal("", chat.Effort);
        Assert.Equal("Couldn't change effort: Unsupported", Assert.IsType<NoticeItem>(chat.Items[^1]).Text);
    }

    [Fact]
    public void AcceptedModeChangeSticks()
    {
        var chat = MakeSession();
        chat.SetPermissionMode("auto");
        var id = LastRequestId();
        chat.Consume(new JsonObject { ["type"] = "control_response", ["response"] = new JsonObject { ["subtype"] = "success", ["request_id"] = id, ["response"] = new JsonObject() } }.ToJsonString());
        Assert.Equal("auto", chat.PermissionMode);
        Assert.Empty(chat.Items);
        chat.Consume(Error(id, "late"));
        Assert.Equal("auto", chat.PermissionMode);
        Assert.Empty(chat.Items);
    }

    [Fact]
    public void ErrorsForOtherRequestsAreIgnored()
    {
        var chat = MakeSession();
        chat.RefreshContext();
        chat.Consume(Error(LastRequestId(), "nope"));
        Assert.Empty(chat.Items);
    }

    [Fact]
    public void ChangesWhileStoppedAreNotSent()
    {
        var chat = MakeSession();
        chat.Running = false;
        chat.SetModel("opus");
        Assert.Equal("opus", chat.ModelValue);
        Assert.Empty(sent);
    }

    [Fact]
    public void UndeliveredMessageIsReported()
    {
        var chat = MakeSession(delivers: false);
        chat.Send("hello");
        Assert.False(chat.Busy);
        var notice = Assert.IsType<NoticeItem>(chat.Items[^1]);
        Assert.True(notice.IsError);
        Assert.Contains("wasn't delivered", notice.Text);
    }

    [Theory]
    [InlineData("Invalid API key · Please run /login", true)]
    [InlineData("API Error: 401 authentication_error", true)]
    [InlineData("OAuth token has expired", true)]
    [InlineData("MCP server returned 401 for tool fetch", false)]
    [InlineData("Set your api key in the tool config", false)]
    [InlineData("Wrote credential helper to disk", false)]
    public void AuthErrorHeuristic(string text, bool expected) => Assert.Equal(expected, ChatSession.IsAuthError(text));
}

public class ChatQueueTests
{
    private readonly List<string> delivered = new();

    private ChatSession MakeSession()
    {
        var chat = new ChatSession("C:\\code\\proj", null) { Ledger = null, Running = true };
        chat.Transport = obj =>
        {
            if (obj.Str("type") == "user" && obj.Obj("message").Arr("content").Objects().LastOrDefault().Str("text") is { } text) delivered.Add(text);
            return true;
        };
        return chat;
    }

    private const string Result = """{"type":"result","total_cost_usd":0.01}""";

    [Fact]
    public void MessagesSentWhileBusyWaitForTheTurnToEnd()
    {
        var chat = MakeSession();
        chat.Send("first");
        chat.Send("second");
        chat.Send("third");
        Assert.Equal(new[] { "first" }, delivered);
        Assert.Equal(2, chat.QueuedIds.Count);
        Assert.True(chat.IsQueued(chat.Items[1]));
        Assert.False(chat.IsQueued(chat.Items[0]));
        var finished = 0;
        chat.OnTurnFinished += () => finished++;
        chat.Consume(Result);
        Assert.Equal(new[] { "first", "second" }, delivered);
        Assert.True(chat.Busy);
        Assert.Equal(0, finished);
        chat.Consume(Result);
        Assert.Equal(new[] { "first", "second", "third" }, delivered);
        Assert.Empty(chat.QueuedIds);
        chat.Consume(Result);
        Assert.Equal(1, finished);
        Assert.False(chat.Busy);
    }

    [Fact]
    public void QueuedMessageMovesBelowTheReplyWhenDelivered()
    {
        var chat = MakeSession();
        chat.Send("first");
        chat.Send("second");
        chat.Consume("""{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Answer"}]}}""");
        chat.Consume(Result);
        Assert.Equal("second", Assert.IsType<UserItem>(chat.Items[^1]).Text);
        Assert.IsType<TextItem>(chat.Items[1]);
    }

    [Fact]
    public void CancellingAQueuedMessageRemovesItAndReturnsItsText()
    {
        var chat = MakeSession();
        chat.Send("first");
        chat.Send("second");
        var id = chat.QueuedIds[0];
        Assert.Equal("second", chat.CancelQueued(id));
        Assert.Null(chat.CancelQueued(id));
        Assert.Empty(chat.QueuedIds);
        Assert.Single(chat.Items);
        var finished = 0;
        chat.OnTurnFinished += () => finished++;
        chat.Consume(Result);
        Assert.Equal(new[] { "first" }, delivered);
        Assert.Equal(1, finished);
    }

    [Fact]
    public void QueuedMessageIsDeliveredOnInit()
    {
        var chat = MakeSession();
        chat.Running = false;
        chat.Send("early");
        Assert.Empty(delivered);
        chat.Running = true;
        chat.Consume("""{"type":"system","subtype":"init","session_id":"s1"}""");
        Assert.Equal(new[] { "early" }, delivered);
        Assert.True(chat.Busy);
    }

    [Fact]
    public void PromptHistoryAndTranscript()
    {
        var chat = MakeSession();
        chat.Send("alpha");
        chat.Consume("""{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Sure"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls\n-la"}}]}}""");
        chat.Consume("""{"type":"system","subtype":"compact_boundary"}""");
        chat.Consume(Result);
        chat.Send("beta");
        Assert.Equal(new[] { "alpha", "beta" }, chat.SentPrompts);
        var markdown = chat.MarkdownTranscript("Demo");
        Assert.StartsWith("# Demo\n\n## You\n\nalpha\n", markdown);
        Assert.Contains("## Claude\n\nSure\n", markdown);
        Assert.Contains("- `Bash` ls -la", markdown);
        Assert.Contains("_Context compacted_", markdown);
        Assert.Contains("beta", markdown);
    }

    [Fact]
    public void TrimDropsOldestItems()
    {
        var chat = new ChatSession("C:\\code\\proj", null) { Ledger = null };
        for (var i = 0; i < 50; i++) chat.Items.Add(new NoticeItem($"i{i}", i.ToString(), false));
        chat.TakeChanges();
        chat.TrimItems(40);
        Assert.Equal(33, chat.Items.Count);
        Assert.Equal("nolder", chat.Items[0].Id);
        Assert.Equal("ni49", chat.Items[^1].Id);
        Assert.True(chat.TakeChanges().Reset);
        chat.TrimItems(40);
        Assert.Equal(33, chat.Items.Count);
    }
}
