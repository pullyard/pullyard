using System.ComponentModel;
using Microsoft.UI.Xaml;
using PullYard.Core.Api;
using PullYard.Core.Util;
using PullYard.ViewModels;

namespace PullYard.Services;

public static class ActivityNotifier
{
    private const string Group = "activity";
    private static ActivityTracker tracker = new();
    private static string? scope;
    private static RecentEvents? recent;
    private static bool attached;

    public static void Attach(AppViewModel app, Window window)
    {
        if (attached) return;
        attached = true;
        AppBadge.Attach(window);
        AppBadge.SetReviews(app.ReviewRequestCount);
        app.BadgesObserved += Observe;
        app.SessionReset += Reset;
        app.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.ReviewRequestCount)) AppBadge.SetReviews(app.ReviewRequestCount);
        };
    }

    public static void Reset()
    {
        tracker = new ActivityTracker();
        scope = null;
    }

    private static void Observe(string? account, List<SearchItem>? reviews, int reviewTotal, List<SearchItem>? mine)
    {
        if (scope != account)
        {
            tracker = new ActivityTracker();
            scope = account;
        }
        recent ??= new RecentEvents(Settings.Shared.GetObject<List<string>>(Keys.NotifyRecent));
        var events = tracker.Update(
            reviews?.Where(i => i.IsPR).Select(ActivityItem.From).ToList(),
            reviewTotal,
            mine?.Where(i => i.IsPR).Select(ActivityItem.From).ToList());
        var changed = false;
        foreach (var e in events.Where(e => e.Kind.Enabled(Settings.Shared)))
        {
            if (!recent.Insert(e.Key)) continue;
            changed = true;
            Post(e, account);
        }
        if (changed) Settings.Shared.Set(Keys.NotifyRecent, recent.Keys.ToList());
    }

    private static string Headline(ActivityEvent e) => e.Type switch
    {
        ActivityEventType.ReviewRequested => L.T("Activity_ReviewRequested", "Review requested"),
        ActivityEventType.CiFailed => L.T("Activity_ChecksFailed", "Checks failed"),
        ActivityEventType.Approved => L.T("Activity_Approved", "Approved"),
        _ => L.T("Activity_ChangesRequested", "Changes requested")
    };

    private static void Post(ActivityEvent e, string? account)
    {
        var item = e.Item;
        var target = new ActivityTarget(item.Id, item.Ref.Repo.Full, item.Ref.Number, account);
        Notifications.Show(Headline(e) + " · " + item.Ref.Title, item.Title, target.Encode(), e.Key, Group);
    }

    public static bool Handle(string action)
    {
        if (ActivityTarget.Decode(action) is not { } target) return false;
        var app = AppViewModel.Shared;
        if (app.Phase != Phase.LoggedIn) return true;
        if (target.Account is not null && target.Account != app.Account)
        {
            LinkBrowser.Open(target.Url);
            return true;
        }
        if (app.Forge is not null)
        {
            var item = app.ReviewRequests.Concat(app.MyPRs).FirstOrDefault(i => i.Url == target.Url);
            if (item is null)
            {
                LinkBrowser.Open(target.Url);
                return true;
            }
            if (app.Section.Kind == SectionKind.Claude)
                app.Section = Section.Prs(app.ForgeCaps.PullFilters.Count > 0 ? app.ForgeCaps.PullFilters[0].Filter() : PRFilter.Mine);
            app.ForgeSelection = item;
            return true;
        }
        if (RepoRef.Parse(target.Repo) is { } repo) app.Open(Route.Pr(new ItemRef(repo, target.Number)));
        else LinkBrowser.Open(target.Url);
        return true;
    }
}

public static class AppBadge
{
    private static Window? window;
    private static int reviews;
    private static int agents;

    public static bool Enabled
    {
        get => Settings.Shared.GetBool(TaskbarCount.EnabledKey, true);
        set
        {
            Settings.Shared.Set(TaskbarCount.EnabledKey, value);
            Refresh();
        }
    }

    public static bool IncludesAgents
    {
        get => Settings.Shared.GetBool(TaskbarCount.AgentsKey, true);
        set
        {
            Settings.Shared.Set(TaskbarCount.AgentsKey, value);
            Refresh();
        }
    }

    public static void Attach(Window w)
    {
        window = w;
        Apply();
    }

    public static void SetReviews(int count)
    {
        reviews = count;
        Apply();
    }

    public static void SetAgents(int count)
    {
        agents = count;
        Apply();
    }

    public static void Refresh()
    {
        TaskbarBadge.Reset();
        Apply();
    }

    public static void Apply()
    {
        if (window is null) return;
        var total = TaskbarCount.Count(reviews, agents, Enabled, IncludesAgents);
        TaskbarBadge.Set(WindowInterop.Handle(window), total, L.F("Badge_Description", "{0} items need your attention", total));
    }
}
