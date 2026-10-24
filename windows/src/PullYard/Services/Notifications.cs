using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using PullYard.Core.Util;

namespace PullYard.Services;

public static class Notifications
{
    private static bool registered;

    public static event Action<string>? Invoked;

    public static void Register()
    {
        if (registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                var action = args.Arguments.TryGetValue("action", out var a) ? a : "";
                Invoked?.Invoke(action);
            };
            AppNotificationManager.Default.Register();
            registered = true;
        }
        catch
        {
        }
    }

    public static void Show(string title, string body, string action, string? tag = null, string? group = null)
    {
        if (!registered) return;
        try
        {
            var n = new AppNotificationBuilder()
                .AddArgument("action", action)
                .AddText(title)
                .AddText(body)
                .BuildNotification();
            if (tag is not null) n.Tag = tag.Length > 64 ? tag[..64] : tag;
            if (group is not null) n.Group = group;
            AppNotificationManager.Default.Show(n);
        }
        catch
        {
        }
    }

    public static void Remove(string tag, string group)
    {
        if (!registered) return;
        try
        {
            AppNotificationManager.Default.RemoveByTagAndGroupAsync(tag, group).AsTask().Forget();
        }
        catch
        {
        }
    }

    public static void Unregister()
    {
        if (!registered) return;
        try
        {
            AppNotificationManager.Default.Unregister();
        }
        catch
        {
        }
    }
}
