using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

internal static class LedgerIsolation
{
    [ModuleInitializer]
    internal static void Init() => AgentUsageLedger.Shared = new AgentUsageLedger(null);
}

public class AgentUsageLedgerTests
{
    [Fact]
    public void RecordsPerDayAndPersists()
    {
        var file = Path.Combine(Path.GetTempPath(), $"ledger-{Guid.NewGuid()}.json");
        try
        {
            var now = new DateTime(2027, 1, 15, 8, 0, 0);
            var ledger = new AgentUsageLedger(file);
            ledger.Record(0.5, now);
            ledger.Record(0.25, now);
            ledger.Record(1, now.AddDays(-3));
            ledger.Record(-4, now.AddDays(-40));
            Assert.Equal(new AgentUsageDay(0.75, 2), ledger.Total(1, now));
            Assert.Equal(new AgentUsageDay(1.75, 3), ledger.Total(7, now));
            Assert.Equal(3, ledger.Total(30, now).Turns);
            var reloaded = new AgentUsageLedger(file);
            Assert.Equal(new AgentUsageDay(1.75, 4), reloaded.Total(60, now));
            Assert.Equal(0.75, JsonNode.Parse(File.ReadAllText(file)).Obj("2027-01-15").Dbl("cost"));
            reloaded.Clear();
            Assert.Empty(new AgentUsageLedger(file).Days);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void KeepsOnlyTheMostRecentDays()
    {
        var ledger = new AgentUsageLedger(null);
        var start = new DateTime(2027, 1, 1);
        for (var i = 0; i < 130; i++) ledger.Record(1, start.AddDays(i));
        Assert.Equal(120, ledger.Days.Count);
        Assert.DoesNotContain("2027-01-01", ledger.Days.Keys);
        Assert.Contains(AgentUsageLedger.Key(start.AddDays(129)), ledger.Days.Keys);
    }

    [Fact]
    public void ChatRecordsCostDeltaPerTurn()
    {
        var ledger = new AgentUsageLedger(null);
        var chat = new ChatSession("C:\\code\\proj", null) { Ledger = ledger };
        chat.Consume("""{"type":"result","total_cost_usd":0.01}""");
        chat.Consume("""{"type":"result","total_cost_usd":0.03}""");
        var today = ledger.Total(1);
        Assert.Equal(2, today.Turns);
        Assert.Equal(0.03, today.Cost, 4);
    }

    [Fact]
    public void SharedLedgerStaysInMemoryUnderTest()
    {
        Assert.Same(AgentUsageLedger.Shared, new ChatSession("C:\\code\\proj", null).Ledger);
    }
}
