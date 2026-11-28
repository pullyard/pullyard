using PullYard.Core.Api;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class QueueStoreTests
{
    private static Settings Fresh() => new(Path.Combine(Path.GetTempPath(), $"queue-{Guid.NewGuid():N}.json"));

    private static readonly ItemRef Pr = new(new RepoRef("acme", "app"), 45);

    [Fact]
    public void SnoozeHidesUntilTheDeadline()
    {
        var now = new DateTimeOffset(2026, 11, 25, 10, 0, 0, TimeSpan.Zero);
        var store = new QueueStore(Fresh(), now);
        store.Snooze(Pr, now.AddHours(1));
        Assert.NotNull(store.SnoozedUntil(Pr, now));
        Assert.Null(store.SnoozedUntil(Pr, now.AddHours(2)));
        store.Wake(Pr);
        Assert.Null(store.SnoozedUntil(Pr, now));
    }

    [Fact]
    public void SnoozesSurviveReload()
    {
        var settings = Fresh();
        var now = new DateTimeOffset(2026, 11, 25, 10, 0, 0, TimeSpan.Zero);
        new QueueStore(settings, now).Snooze(Pr, now.AddDays(1));
        Assert.NotNull(new QueueStore(settings, now).SnoozedUntil(Pr, now));
    }

    [Fact]
    public void NewsComparesWithLastSeen()
    {
        var now = new DateTimeOffset(2026, 11, 25, 10, 0, 0, TimeSpan.Zero);
        var store = new QueueStore(Fresh(), now);
        Assert.False(store.HasNews(Pr, now.AddMinutes(-1)));
        Assert.True(store.HasNews(Pr, now.AddMinutes(1)));
        store.MarkSeen(Pr, now.AddMinutes(2));
        Assert.False(store.HasNews(Pr, now.AddMinutes(2)));
        Assert.True(store.HasNews(Pr, now.AddMinutes(3)));
    }

    [Fact]
    public void PresetsLandOnTheNextMorning()
    {
        var wednesday = new DateTimeOffset(2026, 11, 25, 15, 30, 0, TimeSpan.Zero).ToLocalTime();
        Assert.Equal(wednesday.AddHours(1), QueueStore.At(SnoozePreset.Hour, wednesday));
        var tomorrow = QueueStore.At(SnoozePreset.Tomorrow, wednesday);
        Assert.Equal(9, tomorrow.Hour);
        Assert.Equal(wednesday.Date.AddDays(1), tomorrow.Date);
        var monday = QueueStore.At(SnoozePreset.NextWeek, wednesday);
        Assert.Equal(DayOfWeek.Monday, monday.DayOfWeek);
        Assert.Equal(9, monday.Hour);
        Assert.True(monday > wednesday);
    }
}
