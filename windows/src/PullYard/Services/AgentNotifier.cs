using System.ComponentModel;
using Microsoft.UI.Xaml;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.ViewModels;

namespace PullYard.Services;

public static class AgentNotifier
{
    public const string ActionPrefix = "agent:";
    private const string Group = "agents";
    private static bool attached;

    public static bool Enabled
    {
        get => Settings.Shared.GetBool(Keys.AgentsNotify, true);
        set => Settings.Shared.Set(Keys.AgentsNotify, value);
    }

    public static void Attach(AppViewModel app, Window window)
    {
        if (attached) return;
        attached = true;
        var ws = app.Claude;
        ws.IsWatching = tab => app.IsActive && app.IsShown() && app.Section.Kind == SectionKind.Claude && ws.SelectedTab == tab;
        ws.Notify += (tab, kind, detail) => Post(tab, kind, detail);
        ws.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ClaudeWorkspace.BadgeCount)) UpdateBadge(ws, window);
            if (e.PropertyName == nameof(ClaudeWorkspace.SelectedTab) && ws.SelectedTab is { } t) Notifications.Remove(t.Id.ToString(), Group);
        };
        app.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.Section)) MarkWatched(app);
        };
        window.Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) return;
            window.DispatcherQueue.TryEnqueue(() =>
            {
                MarkWatched(app);
                TaskbarBadge.Reset();
                UpdateBadge(ws, window);
            });
        };
    }

    private static void MarkWatched(AppViewModel app)
    {
        if (app.Section.Kind != SectionKind.Claude || app.Claude.SelectedTab is not { } tab) return;
        app.Claude.MarkViewed(tab);
    }

    private static void UpdateBadge(ClaudeWorkspace ws, Window window)
    {
        var count = ws.BadgeCount;
        TaskbarBadge.Set(WindowInterop.Handle(window), count, L.F("Agents_BadgeDescription", "{0} agent sessions need attention", count));
    }

    private static void Post(ClaudeTab tab, AgentEvent kind, string? detail)
    {
        if (!Enabled) return;
        var (title, body) = kind switch
        {
            AgentEvent.Finished => (L.F("Agents_NotifyFinished", "Finished · {0}", tab.Title), ClaudeWorkspace.Snippet(detail)),
            AgentEvent.Question => (tab.Title, L.T("Agents_NotifyQuestion", "Claude has a question for you")),
            AgentEvent.Plan => (tab.Title, L.T("Agents_NotifyPlan", "Claude has a plan ready for review")),
            _ => (tab.Title, L.F("Agents_NotifyPermission", "Claude needs permission: {0}", detail ?? ""))
        };
        if (body.Length == 0) body = tab.ProjectName;
        Notifications.Show(title, body, ActionPrefix + tab.Id, tab.Id.ToString(), Group);
    }

    public static bool Handle(string action)
    {
        if (!action.StartsWith(ActionPrefix, StringComparison.Ordinal)) return false;
        var app = AppViewModel.Shared;
        if (app.Claude is not { } ws) return true;
        app.Section = Section.Claude;
        if (Guid.TryParse(action[ActionPrefix.Length..], out var id) && ws.Tabs.FirstOrDefault(t => t.Id == id) is { } tab)
        {
            ws.SelectedTab = tab;
            ws.MarkViewed(tab);
        }
        return true;
    }
}
