using PullYard.Core.Claude;
using Xunit;

namespace PullYard.Core.Tests;

public class SessionCostTests
{
    private static ChatSession Chat(double budget) => new(Path.GetTempPath(), null) { BudgetSource = () => budget };

    private static void Result(ChatSession chat, double cost) =>
        chat.Consume($$"""{"type":"result","subtype":"success","is_error":false,"total_cost_usd":{{cost.ToString(System.Globalization.CultureInfo.InvariantCulture)}}}""");

    [Fact]
    public void CostMath()
    {
        Assert.Equal(0.75, SessionCost.Total(0.5, 0.25));
        Assert.Equal(0.5, SessionCost.Total(0.5, -1));
        Assert.False(SessionCost.OverBudget(10, 0, 0));
        Assert.True(SessionCost.OverBudget(2, 2, 0));
        Assert.False(SessionCost.OverBudget(3, 2, 2));
        Assert.Equal(2.5, SessionCost.NextAllowance(2.5, 2));
        Assert.Equal(2, SessionCost.NextAllowance(1, 2));
        Assert.Equal(0, SessionCost.NextAllowance(1, 0));
        Assert.Equal("$0.04", SessionCost.Format(0.043));
        Assert.Equal("$12.50", SessionCost.Format(12.5));
        Assert.Equal("$250", SessionCost.Format(250));
        Assert.Equal(new double[] { 0, 1, 2, 5, 10, 20, 50 }, SessionCost.Choices);
        Assert.Equal("agent.sessionBudget", SessionCost.BudgetKey);
    }

    [Fact]
    public void BilledPerUse()
    {
        Assert.True(SessionCost.IsBilledPerUse(true, null));
        Assert.False(SessionCost.IsBilledPerUse(false, null));
        Assert.True(SessionCost.IsBilledPerUse(false, new ClaudeAccountInfo("a@b.c", null, null, "console", null)));
        Assert.True(SessionCost.IsBilledPerUse(false, new ClaudeAccountInfo(null, null, null, "api_key", null)));
        Assert.True(SessionCost.IsBilledPerUse(false, new ClaudeAccountInfo(null, null, null, "oauth", "bedrock")));
        Assert.False(SessionCost.IsBilledPerUse(false, new ClaudeAccountInfo("a@b.c", null, "Max", "console", null)));
        Assert.False(SessionCost.IsBilledPerUse(false, new ClaudeAccountInfo("a@b.c", null, null, "claude.ai", "firstParty")));
    }

    [Fact]
    public void TrackerAddsEarlierProcessesToCumulativeReport()
    {
        var t = new SessionCostTracker();
        t.ProcessStarted();
        t.Report(0.0302, 0);
        t.Report(0.0432, 0);
        Assert.Equal(0.0432, t.Total, 9);
        t.ProcessStarted();
        t.Report(0.01, 0);
        Assert.Equal(0.0532, t.Total, 9);
        t.Report(-1, 0);
        Assert.Equal(0.0432, t.Total, 9);
        Assert.False(t.Paused);
    }

    [Fact]
    public void ReportedCostIsCumulativePerProcess()
    {
        var chat = Chat(0);
        Result(chat, 0.0302);
        Result(chat, 0.0432);
        Assert.Equal(0.0432, chat.TotalCost, 9);
        Assert.False(chat.BudgetPaused);
    }

    [Fact]
    public void BudgetPausesHoldsMessagesAndContinues()
    {
        var chat = Chat(0.04);
        Result(chat, 0.03);
        Assert.False(chat.BudgetPaused);
        Result(chat, 0.045);
        Assert.True(chat.BudgetPaused);
        var before = chat.Items.Count;
        chat.Send("next step");
        Assert.Equal(before + 1, chat.Items.Count);
        Assert.IsType<UserItem>(chat.Items[^1]);
        Assert.False(chat.Busy);
        Assert.False(chat.HasQueuedPrompts);
        chat.ContinuePastBudget();
        Assert.False(chat.BudgetPaused);
        Assert.True(chat.HasQueuedPrompts);
        Result(chat, 0.07);
        Assert.False(chat.BudgetPaused);
        Result(chat, 0.09);
        Assert.True(chat.BudgetPaused);
    }

    [Fact]
    public void NoBudgetNeverPauses()
    {
        var chat = Chat(0);
        Result(chat, 100);
        Assert.False(chat.BudgetPaused);
        Assert.Equal(100, chat.TotalCost);
    }
}
