using System.Globalization;
using System.Text.Json.Nodes;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public sealed record AgentUsageDay(double Cost, int Turns);

public sealed class AgentUsageLedger
{
    private const int Keep = 120;

    private static AgentUsageLedger? shared;

    public static AgentUsageLedger Shared
    {
        get => shared ??= new AgentUsageLedger(DefaultFile);
        internal set => shared = value;
    }

    public static string DefaultFile => Path.Combine(AppInfo.DataDirectory, "agent-usage.json");

    private readonly string? file;
    private readonly object gate = new();
    private readonly SortedDictionary<string, AgentUsageDay> days = new(StringComparer.Ordinal);

    public event Action? Changed;

    public AgentUsageLedger(string? file)
    {
        this.file = file;
        if (file is null) return;
        try
        {
            if (!File.Exists(file) || JsonNode.Parse(File.ReadAllText(file)) is not JsonObject saved) return;
            foreach (var (key, value) in saved)
                if (value is JsonObject day) days[key] = new AgentUsageDay(day.Dbl("cost") ?? 0, day.Int("turns") ?? 0);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, $"agent usage load failed for {file}");
        }
    }

    public IReadOnlyDictionary<string, AgentUsageDay> Days
    {
        get
        {
            lock (gate) return new Dictionary<string, AgentUsageDay>(days);
        }
    }

    public static string Key(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public void Record(double cost, DateTime? at = null)
    {
        lock (gate)
        {
            var key = Key(at ?? DateTime.Now);
            var day = days.TryGetValue(key, out var existing) ? existing : new AgentUsageDay(0, 0);
            days[key] = new AgentUsageDay(day.Cost + Math.Max(cost, 0), day.Turns + 1);
            while (days.Count > Keep) days.Remove(days.Keys.First());
            Save();
        }
        Changed?.Invoke();
    }

    public AgentUsageDay Total(int lastDays, DateTime? now = null)
    {
        var today = (now ?? DateTime.Now).Date;
        double cost = 0;
        var turns = 0;
        lock (gate)
        {
            for (var offset = 0; offset < Math.Max(lastDays, 1); offset++)
            {
                if (!days.TryGetValue(Key(today.AddDays(-offset)), out var day)) continue;
                cost += day.Cost;
                turns += day.Turns;
            }
        }
        return new AgentUsageDay(cost, turns);
    }

    public void Clear()
    {
        lock (gate)
        {
            days.Clear();
            Save();
        }
        Changed?.Invoke();
    }

    private void Save()
    {
        if (file is null) return;
        try
        {
            var json = new JsonObject();
            foreach (var (key, day) in days) json[key] = new JsonObject { ["cost"] = day.Cost, ["turns"] = day.Turns };
            if (Path.GetDirectoryName(file) is { Length: > 0 } dir) Directory.CreateDirectory(dir);
            var tmp = file + ".tmp";
            File.WriteAllText(tmp, json.ToJsonString());
            File.Move(tmp, file, true);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, $"agent usage save failed for {file}");
        }
    }
}
