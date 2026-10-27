using System.ComponentModel;
using Microsoft.UI.Xaml;
using PullYard.Core.Api;
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
        get => NotifyKind.AgentInput.Enabled(Settings.Shared) || NotifyKind.AgentFinished.Enabled(Settings.Shared);
        set
        {
            NotifyKind.AgentInput.SetEnabled(Settings.Shared, value);
            NotifyKind.AgentFinished.SetEnabled(Settings.Shared, value);
        }
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
                AppBadge.SetAgents(ws.BadgeCount);
                AppBadge.Refresh();
            });
        };
    }

    private static void MarkWatched(AppViewModel app)
    {
        if (app.Section.Kind != SectionKind.Claude || app.Claude.SelectedTab is not { } tab) return;
        app.Claude.MarkViewed(tab);
    }

    private static void UpdateBadge(ClaudeWorkspace ws, Window window) => AppBadge.SetAgents(ws.BadgeCount);

    private static void Post(ClaudeTab tab, AgentEvent kind, string? detail)
    {
        var notifyKind = kind == AgentEvent.Finished ? NotifyKind.AgentFinished : NotifyKind.AgentInput;
        if (!notifyKind.Enabled(Settings.Shared)) return;
        var (title, body) = kind switch
        {
            AgentEvent.Finished => (L.F("Agents_NotifyAgentFinished", "Agent finished · {0}", tab.Title), ClaudeWorkspace.Snippet(detail)),
            AgentEvent.Question => (tab.Title, L.T("Agents_NotifyAgentQuestion", "Your agent has a question for you")),
            AgentEvent.Plan => (tab.Title, L.T("Agents_NotifyAgentPlan", "Your agent has a plan ready for review")),
            _ => (tab.Title, L.F("Agents_NotifyAgentPermission", "Your agent needs permission: {0}", detail ?? ""))
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
