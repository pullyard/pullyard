using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Controls;

public sealed class RefreshFooter : Grid
{
    private readonly TextBlock label = Ui.Caption("");
    private readonly FontIcon icon = Ui.Glyph("", 11);
    private readonly FrameworkElement ring = Ui.Spinner(12);
    private readonly HyperlinkButton retry;
    private readonly HyperlinkButton signIn;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private DateTimeOffset? updated;
    private bool refreshing;
    private string? error;
    private readonly bool compact;

    public Action? Retry { get; set; }

    public RefreshFooter(bool compact = false, bool line = true)
    {
        this.compact = compact;
        retry = Ui.Link(L.T("Common_Retry", "Retry"), () => Retry?.Invoke(), 12);
        retry.Visibility = Visibility.Collapsed;
        signIn = Ui.Link(L.T("Refresh_SignIn", "Sign in"), () => AppViewModel.Shared.RequestAddAccount(), 12);
        signIn.Visibility = Visibility.Collapsed;
        ring.Visibility = Visibility.Collapsed;
        var row = Ui.H(5, ring, icon, label, retry, signIn);
        row.HorizontalAlignment = compact ? HorizontalAlignment.Left : HorizontalAlignment.Center;
        row.VerticalAlignment = VerticalAlignment.Center;
        if (!compact) Height = 26;
        if (line && !compact)
        {
            var l = Ui.Line();
            l.VerticalAlignment = VerticalAlignment.Top;
            Children.Add(l);
        }
        Children.Add(row);
        timer.Tick += (_, _) => Render();
        Loaded += (_, _) => timer.Start();
        Unloaded += (_, _) => timer.Stop();
        Render();
    }

    public bool Refreshing => refreshing;

    public string SpokenStatus => label.Text;

    public event Action? Rendered;

    public void Update(DateTimeOffset? updated, bool refreshing, string? error = null)
    {
        this.updated = updated;
        this.refreshing = refreshing;
        this.error = error;
        Render();
    }

    public static string FailureText(RefreshFailure failure) => failure.Kind switch
    {
        RefreshFailureKind.Offline => L.T("Refresh_Offline", "Offline"),
        RefreshFailureKind.RateLimited when failure.Until is { } until => L.F("Refresh_RateLimitedUntil", "Rate-limited until {0}", until.ToLocalTime().ToString("t", Fmt.Culture)),
        RefreshFailureKind.RateLimited => L.T("Refresh_RateLimited", "Rate-limited"),
        RefreshFailureKind.SignIn => L.T("Refresh_SignInAgain", "Sign in again"),
        _ => L.T("Refresh_Failed", "Couldn't refresh")
    };

    private void Render()
    {
        var now = DateTimeOffset.Now;
        RefreshFailure? failure = error is { } e ? RefreshFailure.Classify(e, AppViewModel.Shared.RateLimitedUntil) : null;
        var stale = RefreshFailure.IsStale(updated, refreshing, error is not null, now);
        ring.Visibility = refreshing ? Visibility.Visible : Visibility.Collapsed;
        icon.Visibility = refreshing ? Visibility.Collapsed : Visibility.Visible;
        icon.Glyph = failure is not null ? "" : "";
        var tint = failure is not null || stale ? "amberInk" : "muted";
        icon.Foreground = Palette.Brush(failure is not null ? "amber" : tint);
        label.Foreground = Palette.Brush(tint);
        retry.Visibility = failure is { Kind: not RefreshFailureKind.SignIn } && !refreshing && Retry is not null ? Visibility.Visible : Visibility.Collapsed;
        signIn.Visibility = failure is { Kind: RefreshFailureKind.SignIn } && !refreshing ? Visibility.Visible : Visibility.Collapsed;
        string text;
        if (refreshing && !compact && updated is { } since && now - since >= TimeSpan.FromMinutes(1)) text = L.F("Refresh_UpdatedUpdating", "Updated {0} · updating…", Fmt.Ago(since, now));
        else if (refreshing) text = L.T("Refresh_Updating", "Updating…");
        else if (failure is { } f) text = FailureText(f);
        else if (updated is not { } u) text = compact ? "" : L.T("Refresh_NotYet", "Not updated yet");
        else
        {
            var ago = Fmt.Ago(u, now);
            text = compact ? ago : L.F("Refresh_Updated", "Updated {0}", ago);
        }
        label.Text = text;
        label.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(this, error is not null ? L.F("Refresh_LastFailed", "Last refresh failed: {0}", error) : L.T("Refresh_Hint", "Pull down to refresh (Ctrl+R)"));
        Rendered?.Invoke();
    }
}

public sealed class RefreshPill : Button
{
    private readonly RefreshFooter status = new(compact: true, line: false);
    private readonly Func<Task> refresh;
    private string? error;

    public RefreshPill(Func<Task> refresh)
    {
        this.refresh = refresh;
        Content = status;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        BorderThickness = new Thickness(0);
        Padding = new Thickness(8, 4, 8, 4);
        MinHeight = 0;
        VerticalAlignment = VerticalAlignment.Center;
        status.IsHitTestVisible = false;
        status.Retry = () => Run().Forget();
        status.Rendered += Describe;
        Click += (_, _) => Run().Forget();
        Describe();
    }

    public void Update(DateTimeOffset? updated, bool refreshing, string? error = null)
    {
        this.error = error;
        status.Update(updated, refreshing, error);
        IsEnabled = !refreshing;
    }

    private void Describe()
    {
        var tip = error is not null
            ? L.F("Refresh_PillFailed", "Last refresh failed: {0}. Click to retry", error)
            : L.T("Refresh_PillHint", "Refresh this view · Ctrl+R refreshes everything");
        ToolTipService.SetToolTip(this, tip);
        AutomationProperties.SetName(this, L.T("Common_Refresh", "Refresh"));
        AutomationProperties.SetItemStatus(this, status.SpokenStatus);
    }

    private async Task Run()
    {
        if (status.Refreshing) return;
        IsEnabled = false;
        try
        {
            await refresh();
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "refresh failed");
        }
        finally
        {
            IsEnabled = true;
        }
    }
}
