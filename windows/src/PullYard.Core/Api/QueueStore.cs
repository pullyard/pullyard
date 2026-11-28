using PullYard.Core.Util;

namespace PullYard.Core.Api;

public enum SnoozePreset { Hour, Tomorrow, NextWeek }

public sealed class QueueStore
{
    public const string SnoozeKey = "queue.snoozed";
    public const string SeenKey = "queue.seen";
    public const string SinceKey = "queue.since";

    private static QueueStore? shared;
    private readonly Settings settings;
    private readonly Dictionary<string, long> snoozed;
    private readonly Dictionary<string, long> seen;
    private readonly DateTimeOffset since;

    public static QueueStore Shared => shared ??= new QueueStore(Settings.Shared, DateTimeOffset.Now);

    public event Action? Changed;

    public QueueStore(Settings settings, DateTimeOffset now)
    {
        this.settings = settings;
        snoozed = settings.GetObject<Dictionary<string, long>>(SnoozeKey) ?? new();
        seen = settings.GetObject<Dictionary<string, long>>(SeenKey) ?? new();
        if (settings.GetDate(SinceKey) is { } stored) since = stored;
        else
        {
            since = now;
            settings.Set(SinceKey, now);
        }
        foreach (var expired in snoozed.Where(p => p.Value <= now.ToUnixTimeSeconds()).Select(p => p.Key).ToList()) snoozed.Remove(expired);
    }

    private static string Key(ItemRef r) => ShortLink.Of(r).ToLowerInvariant();

    public DateTimeOffset? SnoozedUntil(ItemRef r, DateTimeOffset now)
    {
        if (!snoozed.TryGetValue(Key(r), out var until) || until <= now.ToUnixTimeSeconds()) return null;
        return DateTimeOffset.FromUnixTimeSeconds(until).ToLocalTime();
    }

    public void Snooze(ItemRef r, DateTimeOffset until)
    {
        snoozed[Key(r)] = until.ToUnixTimeSeconds();
        Save();
    }

    public void Wake(ItemRef r)
    {
        if (snoozed.Remove(Key(r))) Save();
    }

    public void MarkSeen(ItemRef r, DateTimeOffset now)
    {
        seen[Key(r)] = now.ToUnixTimeSeconds();
        if (seen.Count > 600)
        {
            foreach (var old in seen.OrderByDescending(p => p.Value).Skip(400).Select(p => p.Key).ToList()) seen.Remove(old);
        }
        Save();
    }

    public bool HasNews(ItemRef r, DateTimeOffset updatedAt)
    {
        if (seen.TryGetValue(Key(r), out var last)) return updatedAt > DateTimeOffset.FromUnixTimeSeconds(last).AddSeconds(5);
        return updatedAt > since;
    }

    private void Save()
    {
        settings.Set(SnoozeKey, new Dictionary<string, long>(snoozed));
        settings.Set(SeenKey, new Dictionary<string, long>(seen));
        Changed?.Invoke();
    }

    public static DateTimeOffset At(SnoozePreset preset, DateTimeOffset now)
    {
        var local = now.ToLocalTime();
        var nine = new DateTimeOffset(local.Year, local.Month, local.Day, 9, 0, 0, local.Offset);
        switch (preset)
        {
            case SnoozePreset.Hour:
                return now.AddHours(1);
            case SnoozePreset.Tomorrow:
                return nine.AddDays(1);
            default:
                var days = ((int)DayOfWeek.Monday - (int)local.DayOfWeek + 7) % 7;
                if (days == 0) days = 7;
                return nine.AddDays(days);
        }
    }
}
