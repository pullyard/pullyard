using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using PullYard.Controls;
using PullYard.Core;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Update;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public static class OpenLinkDialog
{
    public static async Task Show(XamlRoot? root)
    {
        if (root is null) return;
        var box = new TextBox { PlaceholderText = L.T("OpenLink_Placeholder", "https://github.com/org/repo/pull/123 or org/repo#123"), MinWidth = 480 };
        var invalid = Ui.Text(L.T("OpenLink_Invalid", "Couldn't recognize the link"), 12, "red");
        invalid.Visibility = Visibility.Collapsed;
        if (await WindowInterop.ReadClipboardText() is { } clip && GitHubUrl.Parse(clip) is not null) box.Text = clip.Trim();
        var d = Dialogs.Create(root, L.T("OpenLink_Title", "Open by link"), Ui.V(8, box, invalid), L.T("Common_Open", "Open"));
        d.PrimaryButtonClick += (_, args) =>
        {
            if (GitHubUrl.Parse(box.Text) is not { } route)
            {
                invalid.Visibility = Visibility.Visible;
                args.Cancel = true;
                return;
            }
            AppViewModel.Shared.Open(route);
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            if (GitHubUrl.Parse(box.Text) is { } route)
            {
                d.Hide();
                AppViewModel.Shared.Open(route);
            }
            else
            {
                invalid.Visibility = Visibility.Visible;
            }
        };
        d.Opened += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };
        await Dialogs.ShowAsync(d);
    }
}

public static class SettingsDialog
{
    public static async Task Show(XamlRoot? root)
    {
        if (root is null) return;
        var scroll = new ScrollViewer { Content = Build(), MaxHeight = 620, Padding = new Thickness(0, 0, 12, 0) };
        openScroll = scroll;
        var d = Dialogs.Create(root, L.T("Common_Settings", "Settings"), scroll, close: L.T("Common_Done", "Done"), maxWidth: 640);
        openDialog = d;
        var pending = false;
        void Rebuild()
        {
            if (pending) return;
            pending = true;
            scroll.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                pending = false;
                var focused = FocusedSelector(scroll);
                var offset = scroll.VerticalOffset;
                scroll.Content = Build();
                scroll.UpdateLayout();
                scroll.ChangeView(null, offset, null, true);
                if (focused is { } f && (f.Key == "style" ? styleBar : modeBar)?.SelectedItem is { } item) item.Focus(f.State);
            });
        }
        void SyncZoom()
        {
            if (zoomBox is not { } z) return;
            var match = z.Items.OfType<ComboBoxItem>().FirstOrDefault(i => Math.Abs((double)i.Tag! - TextZoom.Scale) < 0.001);
            if (match is not null && !ReferenceEquals(z.SelectedItem, match)) z.SelectedItem = match;
        }
        ThemeService.Changed += Rebuild;
        TextZoom.Changed += SyncZoom;
        try
        {
            await Dialogs.ShowAsync(d);
        }
        finally
        {
            ThemeService.Changed -= Rebuild;
            TextZoom.Changed -= SyncZoom;
            openDialog = null;
            openScroll = null;
            styleBar = null;
            modeBar = null;
            zoomBox = null;
            ghButton = null;
            ghStatus = null;
            ghResult = null;
        }
    }

    private static SelectorBar? styleBar;
    private static SelectorBar? modeBar;
    private static ComboBox? zoomBox;
    private static bool ghBusy;
    private static (string Text, bool Failed)? ghResult;
    private static Button? ghButton;
    private static TextBlock? ghStatus;

    private static void ShowGhState()
    {
        if (ghButton is { } button)
        {
            button.IsEnabled = !ghBusy;
            button.Content = ghBusy ? L.T("Settings_RefreshingFromGh", "Refreshing…") : L.T("Settings_RefreshFromGh", "Refresh token from gh");
        }
        if (ghStatus is { } status)
        {
            status.Text = ghResult?.Text ?? "";
            status.Foreground = Palette.Brush(ghResult?.Failed == true ? "red" : "muted");
            status.Visibility = ghResult is null ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private static async Task RefreshFromGh(AppViewModel app)
    {
        if (ghBusy) return;
        ghBusy = true;
        ghResult = null;
        ShowGhState();
        string? failure;
        try
        {
            failure = await app.RefreshTokenFromGh();
        }
        catch (Exception e)
        {
            failure = e.Message;
        }
        ghBusy = false;
        var failed = failure is not null;
        var text = failed ? L.F("Settings_GhFailed", "Couldn’t read the token from gh: {0}", failure!) : L.T("Settings_GhRefreshed", "Token refreshed from gh.");
        if (openDialog is null)
        {
            ShellView.Toast(text, failed);
            return;
        }
        ghResult = (text, failed);
        ShowGhState();
    }

    private static (string Key, FocusState State)? FocusedSelector(ScrollViewer scroll)
    {
        if (scroll.XamlRoot is null || Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(scroll.XamlRoot) is not DependencyObject focused) return null;
        var state = focused is Control c && c.FocusState != FocusState.Unfocused ? c.FocusState : FocusState.Keyboard;
        for (var node = focused; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, styleBar)) return ("style", state);
            if (ReferenceEquals(node, modeBar)) return ("mode", state);
        }
        return null;
    }

    private static StackPanel Build()
    {
        var app = AppViewModel.Shared;
        var panel = Ui.V(18);
        ghButton = null;
        ghStatus = null;

        var style = styleBar = Segmented(new[] { ("brand", AppInfo.DisplayName), ("system", L.T("Settings_System", "System")) }, ThemeService.Style == ThemeStyle.System ? "system" : "brand",
            v => ThemeService.Style = v == "system" ? ThemeStyle.System : ThemeStyle.PullYard);
        var mode = modeBar = Segmented(new[] { ("auto", L.T("Settings_MatchSystem", "Match system")), ("light", L.T("Settings_Light", "Light")), ("dark", L.T("Settings_Dark", "Dark")) },
            ThemeService.Appearance switch { AppearanceMode.Light => "light", AppearanceMode.Dark => "dark", _ => "auto" },
            v => ThemeService.Appearance = v switch { "light" => AppearanceMode.Light, "dark" => AppearanceMode.Dark, _ => AppearanceMode.Auto });
        var zoom = zoomBox = new ComboBox { MinWidth = 160 };
        foreach (var level in ZoomLevels.All)
        {
            var percent = (int)Math.Round(level * 100);
            zoom.Items.Add(new ComboBoxItem { Content = Math.Abs(level - 1) < 0.001 ? L.F("Settings_TextSizeDefault", "{0}% (default)", percent) : $"{percent}%", Tag = level });
        }
        zoom.SelectedItem = zoom.Items.OfType<ComboBoxItem>().FirstOrDefault(i => Math.Abs((double)i.Tag! - TextZoom.Scale) < 0.001);
        zoom.SelectionChanged += (_, _) =>
        {
            if ((zoom.SelectedItem as ComboBoxItem)?.Tag is double v) TextZoom.Set(v);
        };
        panel.Children.Add(Group(L.T("Settings_Appearance", "Appearance"), "", "violet", Row(L.T("Settings_Theme", "Theme"), style), Row(L.T("Settings_Mode", "Mode"), mode), Row(L.T("Settings_TextSize", "Text size"), zoom)));

        var account = Ui.V(8);
        if (app.User is { } u)
        {
            account.Children.Add(Ui.H(10, Ui.Avatar(u.AvatarUrl, 36), Ui.V(0, Ui.Text(u.Name ?? u.Login, 14, "text", FontWeights.SemiBold), Ui.Caption(app.GitAccount?.Subtitle ?? "@" + u.Login))));
            account.Children.Add(Row(L.T("Settings_Service", "Service"), Ui.Text(app.Provider.Title(), 12, "muted")));
            if (app.Provider.IsGitHub()) account.Children.Add(Row(L.T("Settings_Scopes", "Token scopes"), Ui.Text(app.Scopes.Count == 0 ? "fine-grained / unknown" : string.Join(", ", app.Scopes), 12, "muted", wrap: true)));
            var buttons = Ui.H(8);
            if (app.Provider.IsGitHub() && app.GitAccount is not null && GhCli.Binary is not null)
            {
                var gh = ghButton = Ui.Button(L.T("Settings_RefreshFromGh", "Refresh token from gh"), () => RefreshFromGh(app).Forget());
                buttons.Children.Add(gh);
            }
            buttons.Children.Add(Ui.Button(L.T("Accounts_Add", "Add Account…"), () =>
            {
                CloseOpenDialog();
                AccountDialogs.Add(App.MainWindow?.Content?.XamlRoot).Forget();
            }));
            buttons.Children.Add(Ui.Button(L.T("Accounts_SignOut", "Sign Out…"), () =>
            {
                CloseOpenDialog();
                AccountDialogs.ConfirmSignOut(App.MainWindow?.Content?.XamlRoot).Forget();
            }));
            account.Children.Add(buttons);
            var status = ghStatus = Ui.Text("", 12, "muted", wrap: true, select: true);
            account.Children.Add(status);
            ShowGhState();
            if (app.GitAccount is { } signedIn) account.Children.Add(LockSettings(app, signedIn));
        }
        else
        {
            account.Children.Add(Ui.Text(L.T("Settings_NotSignedIn", "Not signed in"), 13, "muted"));
        }
        panel.Children.Add(Group(L.T("Settings_Account", "Account"), "", "teal", account));

        var browsers = new ComboBox { MinWidth = 240 };
        browsers.Items.Add(new ComboBoxItem { Content = L.T("Settings_SystemDefault", "System default"), Tag = LinkBrowser.SystemDefault });
        foreach (var b in LinkBrowser.Installed) browsers.Items.Add(new ComboBoxItem { Content = b.Name, Tag = b.Id });
        browsers.SelectedItem = browsers.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == LinkBrowser.Selected) ?? browsers.Items[0];
        browsers.SelectionChanged += (_, _) => LinkBrowser.Selected = (browsers.SelectedItem as ComboBoxItem)?.Tag as string ?? LinkBrowser.SystemDefault;
        var clipboard = new ToggleSwitch { IsOn = Settings.Shared.GetBool(Keys.ClipboardWatch, true), OnContent = "", OffContent = "" };
        clipboard.Toggled += (_, _) =>
        {
            Settings.Shared.Set(Keys.ClipboardWatch, clipboard.IsOn);
            if (!clipboard.IsOn) app.ClipboardRoute = null;
        };
        panel.Children.Add(Group(L.T("Settings_Links", "Links"), "", "indigo", Row(L.T("Settings_OpenLinksIn", "Open links in"), browsers), Row(L.T("Settings_ClipboardWatch", "Offer to open a copied pull request or issue link"), clipboard)));

        var poll = new ComboBox { MinWidth = 240 };
        var intervals = new[] { (15.0, L.T("Settings_Every15s", "Every 15 seconds")), (30.0, L.T("Settings_Every30s", "Every 30 seconds")), (60.0, L.T("Settings_EveryMinute", "Every minute")), (120.0, L.T("Settings_Every2m", "Every 2 minutes")), (300.0, L.T("Settings_Every5m", "Every 5 minutes")), (900.0, L.T("Settings_Every15m", "Every 15 minutes")) };
        var current = Settings.Shared.GetDouble(Keys.PollInterval, 30);
        foreach (var (v, t) in intervals) poll.Items.Add(new ComboBoxItem { Content = t, Tag = v });
        poll.SelectedItem = poll.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (double)i.Tag! == current) ?? poll.Items[1];
        poll.SelectionChanged += (_, _) =>
        {
            if ((poll.SelectedItem as ComboBoxItem)?.Tag is double v)
            {
                Settings.Shared.Set(Keys.PollInterval, v);
                app.StartPolling();
            }
        };
        var tray = new ToggleSwitch { IsOn = Settings.Shared.GetBool(Keys.CloseToTray, true), OnContent = "", OffContent = "" };
        tray.Toggled += (_, _) => Settings.Shared.Set(Keys.CloseToTray, tray.IsOn);
        var showTray = new ToggleSwitch { IsOn = Settings.Shared.GetBool(Keys.TrayShow, true), OnContent = "", OffContent = "" };
        tray.IsEnabled = showTray.IsOn;
        showTray.Toggled += (_, _) =>
        {
            Settings.Shared.Set(Keys.TrayShow, showTray.IsOn);
            tray.IsEnabled = showTray.IsOn;
        };
        panel.Children.Add(Group(L.T("Settings_Refresh", "Refresh"), "", "green", Row(L.T("Settings_AutoRefreshLists", "Auto-refresh lists"), poll), Row(L.F("Settings_TrayShow", "Show {0} in the notification area", AppInfo.DisplayName), showTray), Row(L.T("Settings_CloseToTray", "Keep running in the notification area when the window is closed"), tray)));

        panel.Children.Add(Group(L.T("Settings_Notifications", "Notifications"), "\uEA8F", "amber", NotificationSettings()));

        if (app.Phase == Phase.LoggedIn) panel.Children.Add(Group(L.T("Section_Claude", "Agents"), "", "coral", ClaudeSettings(app)));

        panel.Children.Add(Group(L.T("Jira_Title", "Jira"), "\uE8EC", "sky", new JiraConnectForm()));

        var auto = new ToggleSwitch { IsOn = UpdaterViewModel.AutoCheck, OnContent = "", OffContent = "" };
        auto.Toggled += (_, _) => UpdaterViewModel.AutoCheck = auto.IsOn;
        var check = Ui.Button(L.T("Settings_CheckNow", "Check Now"), () =>
        {
            CloseOpenDialog();
            app.Updater.Check(true).Forget();
        });
        panel.Children.Add(Group(L.T("Settings_Updates", "Updates"), "", "green",
            Row(L.T("Settings_AutoUpdates", "Check for updates automatically"), auto),
            Ui.Columns((Ui.Text(L.F("Settings_CurrentVersion", "Current version {0}", AppInfo.Version), 13, "muted"), Ui.Star), (check, Ui.Auto))));

        var diagnostics = new ToggleSwitch { IsOn = DiagnosticsService.Enabled, OnContent = "", OffContent = "" };
        diagnostics.Toggled += (_, _) => DiagnosticsService.Enabled = diagnostics.IsOn;
        panel.Children.Add(Group(L.T("Settings_Diagnostics", "Diagnostics"), "\uE9D9", "slate",
            Row(L.T("Settings_DiagnosticsRecord", "Record network requests and timings"), diagnostics),
            Ui.Columns((Ui.Text(L.T("Settings_DiagnosticsHint", "Kept in memory only, without tokens or request bodies."), 12.5, "muted", wrap: true), Ui.Star), (Ui.Button(L.T("Settings_OpenDiagnostics", "Open diagnostics"), DiagnosticsWindow.Show), Ui.Auto))));

        var clientId = new TextBox { PlaceholderText = L.T("Login_ClientId", "Client ID"), Text = Settings.Shared.GetString(Keys.OAuthClientId) ?? "", MinWidth = 240 };
        clientId.TextChanged += (_, _) => Settings.Shared.Set(Keys.OAuthClientId, clientId.Text);
        panel.Children.Add(Group(L.T("Settings_DeviceFlow", "OAuth Device Flow"), "", "amber", Row(L.T("Login_ClientId", "Client ID"), clientId)));

        var pizzaContent = Ui.Columns(
            (Ui.V(2, Ui.Text(L.T("Support_Pizza", "Buy me a pizza 🍕"), 14, "text", FontWeights.SemiBold), Ui.Text(L.T("Support_PizzaDescription", "Pay what you want, from $3. PullYard stays free and open source."), 12.5, "muted", wrap: true)), Ui.Star),
            (Ui.Glyph("\uE8A7", 13, "muted"), Ui.Auto));
        var pizza = new Button
        {
            Content = pizzaContent,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 10, 12, 10)
        };
        Ui.Tip(pizza, AppInfo.DonateUrl);
        pizza.Click += (_, _) => LinkBrowser.OpenDonation();
        panel.Children.Add(Group(L.F("Support_Title", "Support {0}", AppInfo.DisplayName), "\uEB51", "coral", pizza));
        panel.Children.Add(Group(L.T("Settings_About", "About"), "\uE946", "slate", AboutSection()));
        return panel;
    }

    private static FrameworkElement AboutSection()
    {
        var notices = Path.Combine(AppContext.BaseDirectory, "THIRD-PARTY-NOTICES.txt");
        var license = Path.Combine(AppContext.BaseDirectory, "LICENSE.txt");
        var licenses = Path.Combine(AppContext.BaseDirectory, "licenses");
        var links = Ui.H(16);
        links.Children.Add(Ui.Link(L.T("Shortcuts_Title", "Keyboard Shortcuts"), () =>
        {
            var root = App.MainWindow?.Content?.XamlRoot;
            CloseOpenDialog();
            App.MainWindow?.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => ShortcutsDialog.Show(root).Forget());
        }, 13));
        if (File.Exists(notices)) links.Children.Add(Ui.Link(L.T("About_ThirdPartyLicenses", "Third-party licenses"), () => OpenPath(notices), 13));
        if (Directory.Exists(licenses)) links.Children.Add(Ui.Link(L.T("About_LicenseFiles", "License files"), () => OpenPath(licenses), 13));
        if (File.Exists(license)) links.Children.Add(Ui.Link(L.T("About_License", "MIT License"), () => OpenPath(license), 13));
        return Ui.V(8,
            Ui.Text(L.F("About_Acknowledgements", "{0} is open source and builds on the .NET runtime, the Windows App SDK, WebView2, CommunityToolkit.Mvvm, xterm.js and marked. Their licenses and copyright notices are listed in the third-party notices.", AppInfo.DisplayName), 12.5, "muted", wrap: true),
            Ui.Text(L.F("About_Disclaimer", "{0} is an independent project and is not affiliated with or endorsed by GitHub, Inc., Anthropic, PBC or Atlassian. GitHub, Claude, Claude Code and Jira are trademarks of their respective owners.", AppInfo.DisplayName), 12.5, "muted", wrap: true),
            links);
    }

    private static void OpenPath(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch
        {
        }
    }

    private static ContentDialog? openDialog;
    private static ScrollViewer? openScroll;

    public static void ScrollToEnd() => openScroll?.ChangeView(null, openScroll.ScrollableHeight, null);

    private static void CloseOpenDialog() => openDialog?.Hide();

    private static FrameworkElement LockSettings(AppViewModel app, GitAccount account)
    {
        var panel = Ui.V(6);
        var protectedNow = app.Lock.IsProtected(account.Id);
        var pin = new ToggleSwitch { IsOn = protectedNow, OnContent = "", OffContent = "" };
        pin.Toggled += (_, _) =>
        {
            if (pin.IsOn == app.Lock.IsProtected(account.Id)) return;
            var root = App.MainWindow?.Content?.XamlRoot;
            CloseOpenDialog();
            if (pin.IsOn) LockDialogs.SetPin(root, account).Forget();
            else TurnOffPin(root, account).Forget();
        };
        panel.Children.Add(Row(L.T("Lock_RequirePin", "Require PIN for this account"), pin));
        if (protectedNow && app.CanLock && app.GitAccount?.Id == account.Id)
        {
            panel.Children.Add(Row(L.F("Lock_NowHint", "Lock {0} until the PIN is entered again", AppInfo.DisplayName), Ui.Button(L.T("Lock_Now", "Lock Now"), () =>
            {
                CloseOpenDialog();
                app.LockNow();
            })));
        }
        if (protectedNow && WindowsHello.Available)
        {
            var hello = new ToggleSwitch { IsOn = app.Lock.HelloEnabled(account.Id), OnContent = "", OffContent = "" };
            hello.Toggled += async (_, _) =>
            {
                if (hello.IsOn == app.Lock.HelloEnabled(account.Id)) return;
                if (hello.IsOn && !await WindowsHello.Verify(L.F("Lock_HelloEnableReason", "Turn on Windows Hello for {0}", account.Subtitle)))
                {
                    hello.IsOn = false;
                    return;
                }
                app.Lock.SetHello(hello.IsOn, account.Id);
            };
            panel.Children.Add(Row(L.T("Lock_UnlockWithHello", "Unlock with Windows Hello"), hello));
            panel.Children.Add(Ui.Text(L.T("Lock_HelloNote", "Windows Hello accepts anyone who can unlock this Windows account, with their face, fingerprint or Windows PIN. Turn it off if other people can sign in to this PC."), 12, "muted", wrap: true));
        }
        return panel;
    }

    private static async Task TurnOffPin(XamlRoot? root, GitAccount account)
    {
        var app = AppViewModel.Shared;
        var outcome = await LockDialogs.Unlock(root, account, L.T("Lock_EnterPinToTurnOff", "Enter the PIN to turn it off"));
        if (outcome == UnlockOutcome.Unlocked) app.Lock.RemoveLock(account.Id);
    }

    private static FrameworkElement ClaudeSettings(AppViewModel app)
    {
        var panel = Ui.V(8);
        var profiles = new ComboBox { MinWidth = 240 };
        foreach (var p in ClaudeProfiles.Shared.Visible) profiles.Items.Add(new ComboBoxItem { Content = p.MenuTitle, Tag = p.Id });
        profiles.SelectedItem = profiles.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == ClaudeProfiles.Shared.ActiveId);
        profiles.SelectionChanged += (_, _) =>
        {
            if ((profiles.SelectedItem as ComboBoxItem)?.Tag is string id) app.SwitchClaudeProfile(id);
        };
        var add = Ui.Button(L.T("Claude_AddAccount", "Add…"), () =>
        {
            CloseOpenDialog();
            ClaudeDialogs.AddProfile(App.MainWindow?.Content?.XamlRoot).Forget();
        });
        panel.Children.Add(Row(L.T("Claude_Account", "Account"), Ui.H(8, profiles, add)));
        var store = ClaudeAccountStore.Shared;
        switch (store.Status)
        {
            case ClaudeAccountStatus.LoggedIn when store.Info is { } info:
                panel.Children.Add(Ui.Text(info.Email ?? L.T("Claude_SignedIn", "Signed in") + (info.Subscription is { } s ? $" · {s}" : ""), 13, "text"));
                panel.Children.Add(Ui.Button(L.T("Claude_SignOut", "Sign out of Claude Code"), () => ConfirmLogout(app).Forget()));
                break;
            case ClaudeAccountStatus.NotInstalled:
                panel.Children.Add(Ui.Text(L.T("Claude_NotInstalled", "claude CLI isn't installed"), 13, "muted"));
                break;
            default:
                panel.Children.Add(Ui.Columns((Ui.Text(L.T("Claude_NotSignedIn", "Not signed in to Claude"), 13, "muted"), Ui.Star), (Ui.Button(L.T("Claude_SignIn", "Sign in…"), () =>
                {
                    CloseOpenDialog();
                    app.Section = Section.Claude;
                }), Ui.Auto)));
                break;
        }
        var ws = app.Claude;
        var kind = new ComboBox { MinWidth = 160 };
        kind.Items.Add(new ComboBoxItem { Content = L.T("Claude_Chat", "Chat"), Tag = ClaudeTabKind.Chat });
        kind.Items.Add(new ComboBoxItem { Content = L.T("Claude_Terminal", "Terminal"), Tag = ClaudeTabKind.Terminal });
        kind.SelectedItem = kind.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (ClaudeTabKind)i.Tag! == ws.PreferredKind);
        kind.SelectionChanged += (_, _) =>
        {
            if ((kind.SelectedItem as ComboBoxItem)?.Tag is ClaudeTabKind k) ws.PreferredKind = k;
        };
        panel.Children.Add(Row(L.T("Claude_OpenAs", "Open new sessions as"), kind));
        var model = new ComboBox { MinWidth = 160 };
        foreach (var m in Enum.GetValues<ClaudeModelOption>()) model.Items.Add(new ComboBoxItem { Content = m.Title(), Tag = m.Raw() });
        if (ws.ModelValue.Length > 0 && ws.Model == ClaudeModelOption.Standard) model.Items.Add(new ComboBoxItem { Content = ws.ModelValue, Tag = ws.ModelValue });
        model.SelectedItem = model.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag! == ws.ModelValue);
        model.SelectionChanged += (_, _) =>
        {
            if ((model.SelectedItem as ComboBoxItem)?.Tag is string v) ws.ModelValue = v;
        };
        panel.Children.Add(Row(L.T("Claude_DefaultModel", "Model for new sessions"), model));
        var effort = new ComboBox { MinWidth = 160 };
        foreach (var e in Enum.GetValues<ClaudeEffort>()) effort.Items.Add(new ComboBoxItem { Content = e.Title(), Tag = e });
        effort.SelectedItem = effort.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (ClaudeEffort)i.Tag! == ws.Effort);
        effort.SelectionChanged += (_, _) =>
        {
            if ((effort.SelectedItem as ComboBoxItem)?.Tag is ClaudeEffort e) ws.Effort = e;
        };
        panel.Children.Add(Row(L.T("Claude_DefaultEffort", "Effort for new sessions"), effort));
        var modeHelp = Ui.Text(ws.Mode.Detail(), 12, "muted", wrap: true);
        var mode = new ComboBox { MinWidth = 160 };
        foreach (var m in Enum.GetValues<ClaudeMode>()) mode.Items.Add(new ComboBoxItem { Content = m.Title(), Tag = m });
        mode.SelectedItem = mode.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (ClaudeMode)i.Tag! == ws.Mode);
        mode.SelectionChanged += (_, _) =>
        {
            if ((mode.SelectedItem as ComboBoxItem)?.Tag is not ClaudeMode m) return;
            ws.Mode = m;
            modeHelp.Text = m.Detail();
        };
        panel.Children.Add(Row(L.T("Claude_DefaultMode", "Permission mode for new sessions"), mode));
        panel.Children.Add(modeHelp);
        var remember = new ToggleSwitch { IsOn = ws.RememberComposerChoice, OnContent = "", OffContent = "" };
        remember.Toggled += (_, _) => ws.RememberComposerChoice = remember.IsOn;
        panel.Children.Add(Row(L.T("Claude_RememberComposer", "Remember changes made in the chat composer"), remember));
        panel.Children.Add(Ui.Text(L.T("Claude_RememberComposerHelp", "When on, picking a model, effort or mode in a chat also makes it the default for the next chats."), 12, "muted", wrap: true));
        var idle = new ComboBox { MinWidth = 160 };
        foreach (var (m, t) in new[] { (0, L.T("Claude_Never", "Never")), (5, "5 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour") })
            idle.Items.Add(new ComboBoxItem { Content = t, Tag = m });
        idle.SelectedItem = idle.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag! == app.Claude.IdleMinutes);
        idle.SelectionChanged += (_, _) =>
        {
            if ((idle.SelectedItem as ComboBoxItem)?.Tag is int m) app.Claude.IdleMinutes = m;
        };
        panel.Children.Add(Row(L.T("Claude_SleepAfter", "Sleep idle sessions after"), idle));
        panel.Children.Add(Ui.Text(L.T("Claude_SleepHelp", "A sleeping session uses no memory: the claude process stops, the conversation stays, and the next message resumes it."), 12, "muted", wrap: true));
        var usageToday = AgentUsageLedger.Shared.Total(1);
        var usageWeek = AgentUsageLedger.Shared.Total(7);
        var usageMonth = AgentUsageLedger.Shared.Total(30);
        panel.Children.Add(Row(L.T("Claude_UsageTotals", "Chat usage on this PC"), Ui.Text(L.F("Claude_UsageCosts", "Today ${0:0.00} · 7 days ${1:0.00} · 30 days ${2:0.00}", usageToday.Cost, usageWeek.Cost, usageMonth.Cost), 13, "muted")));
        panel.Children.Add(Ui.Text(L.F("Claude_UsageTurns", "Turns: {0} today, {1} in 7 days, {2} in 30 days. Cost is what the claude CLI reports per turn.", usageToday.Turns, usageWeek.Turns, usageMonth.Turns), 12, "muted", wrap: true));
        store.Refresh().Forget();
        return panel;
    }

    private static async Task ConfirmLogout(AppViewModel app)
    {
        CloseOpenDialog();
        var root = App.MainWindow?.Content?.XamlRoot;
        if (!await Dialogs.Confirm(root, L.T("Claude_SignOutQ", "Sign out of Claude Code?"), L.T("Settings_SignOut", "Sign out"), true,
                L.T("Claude_SignOutHelp", "This also signs out Claude Code in the terminal. Open sessions will go to sleep. You can sign in again (including with another account) here or in the Agents section."))) return;
        app.Claude.SleepAll();
        await ClaudeAccountStore.Shared.Logout();
    }

    private static FrameworkElement Group(string title, string glyph, string color, params UIElement[] rows)
    {
        var panel = Ui.V(10, Ui.H(8, Ui.IconTile(glyph, color, 18), Ui.Text(title, 14, "text", FontWeights.SemiBold)));
        var inner = Ui.V(10);
        foreach (var r in rows) inner.Children.Add(r);
        panel.Children.Add(Ui.Card(inner, 10, "raised", 12));
        return panel;
    }

    private static string NotifyTitle(NotifyKind kind) => kind switch
    {
        NotifyKind.ReviewRequest => L.T("Notify_ReviewRequest", "New review requests"),
        NotifyKind.CiFailed => L.T("Notify_CiFailed", "Checks failed on my pull requests"),
        NotifyKind.ReviewDecision => L.T("Notify_ReviewDecision", "My pull requests approved or changes requested"),
        NotifyKind.AgentInput => L.T("Notify_AgentInput", "Agent needs permission or an answer"),
        _ => L.T("Notify_AgentFinished", "Agent finished")
    };

    private static FrameworkElement NotificationSettings()
    {
        var rows = new List<UIElement>();
        foreach (var kind in NotifyKinds.All)
        {
            var toggle = new ToggleSwitch { IsOn = kind.Enabled(Settings.Shared), OnContent = "", OffContent = "" };
            var k = kind;
            toggle.Toggled += (_, _) => k.SetEnabled(Settings.Shared, toggle.IsOn);
            rows.Add(Row(NotifyTitle(kind), toggle));
        }
        rows.Add(Ui.Text(L.F("Notify_Help", "Pull request alerts compare each refresh with the previous one, so nothing fires for what was already waiting when {0} opened or switched accounts. Agent alerts only appear when you aren't looking at that session.", AppInfo.DisplayName), 12.5, "muted", wrap: true));
        var badge = new ToggleSwitch { IsOn = AppBadge.Enabled, OnContent = "", OffContent = "" };
        var agents = new ToggleSwitch { IsOn = AppBadge.IncludesAgents, IsEnabled = AppBadge.Enabled, OnContent = "", OffContent = "" };
        badge.Toggled += (_, _) =>
        {
            AppBadge.Enabled = badge.IsOn;
            agents.IsEnabled = badge.IsOn;
        };
        agents.Toggled += (_, _) => AppBadge.IncludesAgents = agents.IsOn;
        rows.Add(Row(L.T("Notify_TaskbarBadge", "Show pending reviews on the taskbar icon"), badge));
        rows.Add(Row(L.T("Notify_TaskbarAgents", "Count agents waiting for you"), agents));
        rows.Add(Ui.Link(L.T("Notify_WindowsSettings", "Open Windows notification settings"), () => Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications")).AsTask().Forget(), 12.5));
        return Ui.V(10, rows.ToArray());
    }

    private static FrameworkElement Row(string label, UIElement control)
    {
        var l = Ui.Text(label, 13, "text", wrap: true);
        l.MaxWidth = 260;
        l.HorizontalAlignment = HorizontalAlignment.Left;
        if (string.IsNullOrEmpty(Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(control))) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, label);
        var g = Ui.Columns((l, Ui.Star), (control, Ui.Auto));
        g.ColumnSpacing = 16;
        return g;
    }

    private static SelectorBar Segmented((string Id, string Title)[] options, string selected, Action<string> changed)
    {
        var bar = new SelectorBar();
        foreach (var (id, title) in options)
        {
            var item = new SelectorBarItem { Text = title, Tag = id };
            bar.Items.Add(item);
            if (id == selected) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (s, _) =>
        {
            if (s.SelectedItem?.Tag is string id) changed(id);
        };
        return bar;
    }
}

public static class ShortcutsDialog
{
    public static async Task Show(XamlRoot? root)
    {
        if (root is null) return;
        var groups = new (string Title, (string Combo, string What)[] Rows)[]
        {
            (L.T("Shortcuts_Navigation", "Navigation"), new[]
            {
                ("Ctrl+K", L.T("Shortcuts_Palette", "Command palette")),
                ("Ctrl+L", L.T("Shortcuts_OpenLink", "Open by link")),
                ("Ctrl+1 – Ctrl+6", L.T("Shortcuts_Sections", "Review requests, mine, notifications, repositories, projects, agents")),
                ("Alt+Left   Ctrl+[", L.T("Shortcuts_Back", "Back")),
                ("Alt+Right   Ctrl+]", L.T("Shortcuts_Forward", "Forward")),
                ("Ctrl+R   F5", L.T("Shortcuts_Refresh", "Refresh")),
                ("Ctrl+P", L.T("Shortcuts_GoToFile", "Go to file in a repository")),
                ("Ctrl+Alt+L", L.T("Shortcuts_Lock", "Lock now")),
                ("Ctrl+,", L.T("Shortcuts_Settings", "Settings")),
                ("Ctrl+/   F1", L.T("Shortcuts_This", "Keyboard shortcuts")),
                ("Ctrl+Q", L.F("Shortcuts_Quit", "Quit {0}", AppInfo.DisplayName))
            }),
            (L.T("Shortcuts_PullRequest", "Pull request"), new[]
            {
                ("Ctrl+Shift+1 – 6", L.T("Shortcuts_Tabs", "Switch tab")),
                ("Ctrl+Shift+R", L.T("Shortcuts_WriteReview", "Write review")),
                ("Ctrl+Shift+A", L.T("Shortcuts_Approve", "Approve")),
                ("Ctrl+Shift+M", L.T("Shortcuts_Merge", "Merge")),
                ("Ctrl+Shift+C", L.T("Shortcuts_ShortLink", "Copy short link")),
                ("Ctrl+Enter", L.T("Shortcuts_SendComment", "Send comment"))
            }),
            (L.T("Shortcuts_Files", "Files changed"), new[]
            {
                ("N   P", L.T("Shortcuts_NextFile", "Next and previous file")),
                ("]   [", L.T("Shortcuts_NextHunk", "Next and previous hunk")),
                ("V", L.T("Shortcuts_Viewed", "Mark file as viewed")),
                ("W", L.T("Shortcuts_Wrap", "Wrap lines")),
                ("S", L.T("Shortcuts_Split", "Split view"))
            }),
            (L.T("Section_Claude", "Agents"), new[]
            {
                ("Ctrl+N", L.T("Shortcuts_NewSession", "New agent session")),
                ("Ctrl+Shift+K", L.T("Shortcuts_GoToSession", "Go to session")),
                ("Ctrl+Shift+]   Ctrl+Shift+[", L.T("Shortcuts_CycleSession", "Next and previous session")),
                ("Ctrl+J", L.T("Shortcuts_FocusComposer", "Focus the message box")),
                ("Shift+Tab", L.T("Shortcuts_CycleMode", "Switch permission mode in the message box")),
                ("Shift+Enter", L.T("Shortcuts_NewLine", "New line in the message box"))
            }),
            (L.T("Shortcuts_View", "View"), new[]
            {
                ("Ctrl+=   Ctrl+-   Ctrl+0", L.T("Shortcuts_TextSize", "Text size")),
                ("Ctrl+Alt+B", L.T("Shortcuts_Blame", "Blame"))
            })
        };
        var panel = Ui.V(18);
        foreach (var group in groups)
        {
            var heading = Ui.Text(group.Title, 14, "text", FontWeights.SemiBold);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            var section = Ui.V(6, heading);
            foreach (var (keys, action) in group.Rows)
            {
                var row = Ui.Columns((Ui.Text(keys, 12.5, "text", mono: true), new GridLength(Math.Round(214 * TextZoom.Scale))), (Ui.Text(action, 13, "muted", wrap: true), Ui.Star));
                row.ColumnSpacing = 12;
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, $"{keys}: {action}");
                section.Children.Add(row);
            }
            panel.Children.Add(section);
        }
        var scroll = new ScrollViewer { Content = panel, MaxHeight = 560, Padding = new Thickness(0, 0, 12, 0), VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var d = Dialogs.Create(root, L.T("Shortcuts_Title", "Keyboard Shortcuts"), scroll, close: L.T("Common_Done", "Done"), maxWidth: 600);
        await Dialogs.ShowAsync(d);
    }
}

public static class UpdateDialog
{
    private static bool showing;

    public static async Task Show(XamlRoot? root)
    {
        if (root is null || showing) return;
        showing = true;
        var updater = AppViewModel.Shared.Updater;
        var title = Ui.Text("", 17, "text", FontWeights.SemiBold);
        var current = Ui.Text(L.F("Update_YouHave", "You have {0}", updater.CurrentVersion), 13, "muted");
        var date = Ui.Text("", 12, "dim");
        var spinner = Ui.Spinner(16);
        var icon = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/AppIcon-256.png")), Width = 64, Height = 64 };
        var changelog = Ui.Link(L.T("Update_WhatsNew", "What's new in all versions"), () => LinkBrowser.Open(AppInfo.ChangelogUrl(updater.ShowsRelease && updater.Release is { } rel ? rel.Version : updater.CurrentVersion)), 12);
        var header = Ui.Columns((icon, Ui.Auto), (Ui.V(4, title, current, date, changelog), Ui.Star), (spinner, Ui.Auto));
        header.ColumnSpacing = 14;
        var notes = new HtmlView { Height = 220 };
        var notesHost = new Border { CornerRadius = new CornerRadius(10), Background = Palette.Brush("sunken"), Child = notes };
        var progress = new ProgressBar { Minimum = 0, Maximum = 1 };
        var progressText = Ui.Caption("");
        var progressRow = Ui.V(4, progress, progressText);
        var error = Ui.Text("", 13, "red", wrap: true, select: true);
        var errorLink = Ui.Link(L.T("Update_ViewOnGitHub", "View on GitHub"), () => LinkBrowser.Open(updater.PageUrl), 13);
        var errorRow = Ui.V(4, error, errorLink);
        var panel = Ui.V(14, header, notesHost, progressRow, errorRow);
        panel.Width = 500;
        var d = Dialogs.Create(root, "", panel, "", "", L.T("Update_Later", "Later"), 600);
        d.Title = null;
        var notesShown = "";

        void Render()
        {
            var s = updater.State;
            var r = updater.Release;
            title.Text = s switch
            {
                UpdateState.Idle or UpdateState.Checking => L.T("Update_Checking", "Checking for updates…"),
                UpdateState.UpToDate => L.T("Update_UpToDate", "You're up to date"),
                UpdateState.Failed => r is not null && updater.ShowsRelease ? L.F("Update_IsAvailable", "{0} {1} is available", AppInfo.DisplayName, r.Version) : L.T("Update_CheckFailed", "Couldn't check for updates"),
                UpdateState.Installing => L.T("Update_Preparing", "Preparing update…"),
                UpdateState.ReadyToRelaunch => L.F("Update_Ready", "{0} {1} is ready to install", AppInfo.DisplayName, r?.Version ?? ""),
                _ => L.F("Update_IsAvailable", "{0} {1} is available", AppInfo.DisplayName, r?.Version ?? "")
            };
            date.Text = updater.ShowsRelease && r?.PublishedAt is { } p ? Fmt.Full(p) : "";
            spinner.Visibility = s is UpdateState.Checking or UpdateState.Installing ? Visibility.Visible : Visibility.Collapsed;
            string body;
            if (updater.ShowsRelease && r is not null)
                body = $"<div class=\"tl\"><h3 style=\"margin:0 0 8px\">{Core.Html.ConversationHtml.Esc(r.Name)}</h3><div class=\"md\" style=\"padding:0;white-space:pre-wrap\">{(string.IsNullOrWhiteSpace(r.Notes) ? L.T("Update_NoNotes", "No release notes.") : Core.Html.ConversationHtml.Esc(r.Notes))}</div></div>";
            else if (s == UpdateState.UpToDate)
                body = $"<div class=\"tl\"><p class=\"empty\">{Core.Html.ConversationHtml.Esc(L.F("Update_Newest", "{0} {1} is the newest version available.", AppInfo.DisplayName, updater.CurrentVersion))}</p></div>";
            else body = "";
            if (body != notesShown)
            {
                notesShown = body;
                notes.Render(body, "conversation", "top");
            }
            progressRow.Visibility = s == UpdateState.Downloading ? Visibility.Visible : Visibility.Collapsed;
            progress.Value = updater.Progress;
            var size = r?.InstallerSize ?? 0;
            progressText.Text = size > 0 ? $"{L.T("Update_Downloading", "Downloading…")} {Fmt.Bytes((long)(size * updater.Progress))} / {Fmt.Bytes(size)}" : L.T("Update_Downloading", "Downloading…");
            errorRow.Visibility = s == UpdateState.Failed ? Visibility.Visible : Visibility.Collapsed;
            error.Text = updater.Error ?? "";
            switch (s)
            {
                case UpdateState.Available:
                case UpdateState.Downloading:
                case UpdateState.Failed when updater.ShowsRelease:
                    d.PrimaryButtonText = updater.IsInstalled ? L.T("Update_DownloadInstall", "Download & Install") : L.T("Update_OpenDownload", "Open download page");
                    d.SecondaryButtonText = L.T("Update_Skip", "Skip This Version");
                    d.IsPrimaryButtonEnabled = !updater.IsBusy;
                    d.IsSecondaryButtonEnabled = !updater.IsBusy;
                    break;
                case UpdateState.ReadyToRelaunch:
                    d.PrimaryButtonText = L.T("Update_Restart", "Restart to Update");
                    d.SecondaryButtonText = "";
                    d.IsPrimaryButtonEnabled = true;
                    break;
                case UpdateState.Installing:
                    d.PrimaryButtonText = "";
                    d.SecondaryButtonText = "";
                    break;
                case UpdateState.Failed:
                    d.PrimaryButtonText = L.T("Update_TryAgain", "Try Again");
                    d.SecondaryButtonText = "";
                    d.IsPrimaryButtonEnabled = true;
                    break;
                default:
                    d.PrimaryButtonText = "";
                    d.SecondaryButtonText = "";
                    d.CloseButtonText = s == UpdateState.Checking ? L.T("Update_Later", "Later") : L.T("Common_OK", "OK");
                    break;
            }
        }

        PropertyChangedEventHandler handler = (_, _) => d.DispatcherQueue.TryEnqueue(Render);
        updater.PropertyChanged += handler;
        d.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            switch (updater.State)
            {
                case UpdateState.ReadyToRelaunch:
                    updater.Relaunch();
                    break;
                case UpdateState.Failed when !updater.ShowsRelease:
                    updater.Check(true).Forget();
                    break;
                default:
                    updater.DownloadAndInstall().Forget();
                    break;
            }
        };
        d.SecondaryButtonClick += (_, _) => updater.Skip();
        Render();
        if (updater.State == UpdateState.Idle) updater.Check(true).Forget();
        await Dialogs.ShowAsync(d);
        updater.PropertyChanged -= handler;
        updater.Later();
        showing = false;
    }
}
