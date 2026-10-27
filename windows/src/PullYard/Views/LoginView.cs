using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using PullYard.Controls;
using PullYard.Core;
using PullYard.Core.Auth;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed class LoginView : Grid
{
    private const string ProviderKey = "loginProvider";

    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly bool embedded;
    private readonly Action? onDone;
    private readonly WakeLoader busyRing = Ui.Spinner(18);
    private readonly InfoBar errorBar = new() { Severity = InfoBarSeverity.Error, IsClosable = true, IsOpen = false };
    private readonly StackPanel providerArea = Ui.V(18);
    private readonly TextBox hostBox = new();
    private readonly TextBox emailBox = new() { PlaceholderText = L.T("Login_BitbucketEmail", "Atlassian account email") };
    private readonly PasswordBox tokenBox = new();
    private readonly TextBox clientIdBox = new();
    private readonly StackPanel devicePanel = Ui.V(8);
    private readonly StackPanel oneClickPanel = Ui.V(8);
    private readonly SelectorBar picker = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private GitProvider provider;
    private GitAccount? prefill;
    private CancellationTokenSource? deviceCts;

    private bool OneClick => OAuthApp.OneClick(provider, OAuthApp.Bundled);

    public LoginView(bool embedded = false, Action? onDone = null)
    {
        this.embedded = embedded;
        this.onDone = onDone;
        busyRing.Visibility = Visibility.Collapsed;
        busyRing.HorizontalAlignment = HorizontalAlignment.Center;
        provider = Enum.TryParse<GitProvider>(Settings.Shared.GetString(ProviderKey), out var saved) ? saved : GitProvider.GitHub;

        var stack = Ui.V(18);
        stack.MaxWidth = 520;
        stack.Padding = new Thickness(embedded ? 4 : 40);
        stack.HorizontalAlignment = embedded ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
        var controls = embedded ? stack : Ui.V(18);

        if (!embedded)
        {
            var pace = app.Accounts.All.Count == 0 ? 1.0 : 0.5;
            stack.Children.Add(Hero(pace));
            var features = Features(pace);
            features.Margin = new Thickness(0, 0, 0, 4);
            stack.Children.Add(features);
            if (SavedAccounts() is { } accounts)
            {
                Stage(accounts, 1.85 * pace);
                stack.Children.Add(accounts);
            }
            Stage(controls, 1.95 * pace);
            stack.Children.Add(controls);
        }

        foreach (var p in GitProviders.All)
        {
            var item = new SelectorBarItem { Text = p.ShortTitle(), Tag = p };
            Ui.Tip(item, p.Title());
            picker.Items.Add(item);
            if (p == provider) picker.SelectedItem = item;
        }
        picker.SelectionChanged += (s, _) =>
        {
            if (s.SelectedItem?.Tag is not GitProvider p || p == provider) return;
            provider = p;
            Settings.Shared.Set(ProviderKey, p.ToString());
            RenderProvider();
        };
        controls.Children.Add(picker);
        controls.Children.Add(providerArea);

        controls.Children.Add(busyRing);
        controls.Children.Add(errorBar);

        tokenBox.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) LoginWithToken();
        };
        clientIdBox.TextChanged += (_, _) => Settings.Shared.Set(ClientIdKey, clientIdBox.Text);
        RenderProvider();

        if (!embedded && !ThemeService.IsHighContrast) Children.Add(Backdrop());
        Children.Add(new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Unloaded += (_, _) => deviceCts?.Cancel();
    }

    private static FrameworkElement Hero(double pace)
    {
        var logo = new LogoLoader(210, once: true, drawSeconds: 1.7) { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 4) };
        AutomationProperties.SetAccessibilityView(logo, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var title = Ui.Text(AppInfo.DisplayName, 36, "text", FontWeights.Bold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        Stage(title, 1.15 * pace);
        var tagline = Ui.Text(AppInfo.Tagline, 17, "muted", wrap: true);
        tagline.HorizontalAlignment = HorizontalAlignment.Center;
        tagline.TextAlignment = TextAlignment.Center;
        Stage(tagline, 1.3 * pace);
        var hero = Ui.V(10, logo, title, tagline);
        hero.Margin = new Thickness(0, 8, 0, 0);
        return hero;
    }

    private static Grid Features(double pace)
    {
        var features = new[]
        {
            (Glyph: PRFilter.ReviewRequested.Glyph(), Color: "sky", Title: L.T("Welcome_InboxTitle", "Inbox for reviews"), Detail: L.T("Welcome_InboxDetail", "Review requests, mentions and your PRs in one live list.")),
            (Glyph: PullYard.Core.Api.VisualStates.Glyph(PullYard.Core.Api.VisualState.Merged), Color: "violet", Title: L.T("Welcome_ReviewTitle", "Review & merge"), Detail: L.T("Welcome_ReviewDetail", "Diffs, threads and checks — no browser tab needed.")),
            (Glyph: "\uE945", Color: "coral", Title: L.T("Fix_Button", "Fix with agent"), Detail: L.T("Welcome_FixDetail", "Hand a failing check or review comment to an agent."))
        };
        var grid = new Grid { ColumnSpacing = 10 };
        for (var i = 0; i < features.Length; i++)
        {
            var f = features[i];
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var tile = Ui.IconTile(f.Glyph, f.Color, 28);
            tile.HorizontalAlignment = HorizontalAlignment.Left;
            AutomationProperties.SetAccessibilityView(tile, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            var card = Ui.Card(Ui.V(8, tile, Ui.Text(f.Title, 13.5, "text", FontWeights.SemiBold, wrap: true), Ui.Text(f.Detail, 12, "muted", wrap: true)), 12, "raised", 12);
            AutomationProperties.SetName(card, $"{f.Title}. {f.Detail}");
            Grid.SetColumn(card, i);
            Stage(card, (1.5 + i * 0.1) * pace);
            grid.Children.Add(card);
        }
        return grid;
    }

    private static void Stage(UIElement element, double delay)
    {
        if (!Motion.Enabled) return;
        var shift = new TranslateTransform { Y = 12 };
        element.RenderTransform = shift;
        element.Opacity = 0;
        var board = new Storyboard();
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var fade = new DoubleAnimation { From = 0, To = 1, Duration = new Duration(TimeSpan.FromSeconds(0.5)), BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = ease };
        var rise = new DoubleAnimation { From = 12, To = 0, Duration = new Duration(TimeSpan.FromSeconds(0.6)), BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = ease };
        Storyboard.SetTarget(fade, element);
        Storyboard.SetTargetProperty(fade, "Opacity");
        Storyboard.SetTarget(rise, shift);
        Storyboard.SetTargetProperty(rise, "Y");
        board.Children.Add(fade);
        board.Children.Add(rise);
        if (element is FrameworkElement fe)
        {
            var started = false;
            fe.Loaded += (_, _) =>
            {
                if (started) return;
                started = true;
                board.Begin();
            };
        }
        else
        {
            board.Begin();
        }
    }

    private static FrameworkElement Backdrop()
    {
        var host = new Grid { IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var strength = ThemeService.IsDark ? 0.2 : 0.13;
        var blobs = new[]
        {
            (Color: "violet", H: HorizontalAlignment.Left, V: VerticalAlignment.Top, Dx: 70.0, Dy: 40.0, Seconds: 13.0),
            (Color: "sky", H: HorizontalAlignment.Right, V: VerticalAlignment.Center, Dx: -60.0, Dy: 50.0, Seconds: 16.0),
            (Color: "coral", H: HorizontalAlignment.Center, V: VerticalAlignment.Bottom, Dx: 50.0, Dy: -40.0, Seconds: 19.0)
        };
        var board = Motion.Enabled ? new Storyboard() : null;
        foreach (var b in blobs)
        {
            var brush = new RadialGradientBrush();
            brush.GradientStops.Add(new GradientStop { Color = Palette.Get(b.Color, (byte)Math.Round(255 * strength)), Offset = 0 });
            brush.GradientStops.Add(new GradientStop { Color = Palette.Get(b.Color, 0), Offset = 1 });
            var shift = new TranslateTransform();
            var blob = new Ellipse
            {
                Width = 900,
                Height = 900,
                Fill = brush,
                HorizontalAlignment = b.H,
                VerticalAlignment = b.V,
                Margin = new Thickness(-300),
                RenderTransform = shift
            };
            host.Children.Add(blob);
            if (board is null) continue;
            foreach (var (property, to) in new[] { ("X", b.Dx), ("Y", b.Dy) })
            {
                var drift = new DoubleAnimation { From = 0, To = to, Duration = new Duration(TimeSpan.FromSeconds(b.Seconds)), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
                Storyboard.SetTarget(drift, shift);
                Storyboard.SetTargetProperty(drift, property);
                board.Children.Add(drift);
            }
        }
        if (board is not null)
        {
            host.Loaded += (_, _) => board.Begin();
            host.Unloaded += (_, _) => board.Stop();
        }
        return host;
    }

    private string ClientIdKey => provider == GitProvider.GitHub ? Keys.OAuthClientId : $"{Keys.OAuthClientId}.{provider}";

    private string Host => provider.EffectiveHost(hostBox.Text);

    private FrameworkElement? SavedAccounts()
    {
        var accounts = app.Accounts.All;
        if (accounts.Count == 0) return null;
        var rows = new List<UIElement>();
        foreach (var a in accounts)
        {
            var id = a.Id;
            var info = Ui.V(0, Ui.Text(a.Name ?? (a.Login.Length > 0 ? a.Login : a.Provider.Title()), 13, "text", FontWeights.Medium), Ui.Caption($"{a.Provider.Title()} · {a.Subtitle}"));
            var target = a;
            var go = app.Accounts.HasCredential(a)
                ? Ui.Button(L.T("Login_Continue", "Continue"), () => RunLogin(() => Continue(target)))
                : Ui.Button(L.T("Login_SignInAgain", "Sign in again"), () => Prefill(target));
            var row = Ui.Columns((Ui.Avatar(a.AvatarUrl, 24), Ui.Auto), (info, Ui.Star), (go, Ui.Auto));
            row.ColumnSpacing = 10;
            rows.Add(row);
        }
        return Card(L.T("Login_YourAccounts", "Your accounts"), "", "green", rows.ToArray());
    }

    private async Task Continue(GitAccount account)
    {
        if (app.Lock.IsProtected(account.Id))
        {
            switch (await LockDialogs.Unlock(XamlRoot, account, L.T("Lock_EnterPin", "Enter PIN")))
            {
                case UnlockOutcome.Cancelled:
                    return;
                case UnlockOutcome.NeedsSignIn:
                    Prefill(account);
                    return;
            }
        }
        await app.SwitchAccount(account.Id);
    }

    private void Prefill(GitAccount account)
    {
        prefill = account;
        if (provider == account.Provider) RenderProvider();
        else picker.SelectedItem = picker.Items.FirstOrDefault(i => i.Tag is GitProvider p && p == account.Provider);
    }

    private void RenderProvider()
    {
        deviceCts?.Cancel();
        ShowError(null);
        providerArea.Children.Clear();
        hostBox.Text = provider.DefaultHost();
        hostBox.PlaceholderText = provider switch
        {
            GitProvider.GitHubEnterprise => "github.example.com",
            GitProvider.GitLab => L.T("Login_GitLabHostPlaceholder", "gitlab.com or gitlab.example.com"),
            GitProvider.Gitea => L.T("Login_GiteaHostPlaceholder", "codeberg.org or git.example.com"),
            _ => provider.DefaultHost()
        };
        tokenBox.Password = "";
        tokenBox.PlaceholderText = provider.TokenPlaceholder();
        clientIdBox.PlaceholderText = provider == GitProvider.GitLab ? L.T("Login_ApplicationId", "Application ID") : L.T("Login_ClientId", "Client ID");
        clientIdBox.Text = Settings.Shared.GetString(ClientIdKey) ?? "";
        if (prefill is { } again && again.Provider == provider)
        {
            if (provider.HostEditable()) hostBox.Text = again.Host;
            emailBox.Text = again.Email ?? "";
            prefill = null;
            DispatcherQueue.TryEnqueue(() => tokenBox.Focus(FocusState.Programmatic));
        }

        if (provider.HostEditable())
            providerArea.Children.Add(Card(L.F("Login_ServerTitle", "{0} server", provider.Title()), "", "teal", hostBox));

        if (OneClick)
        {
            RenderOneClick(null);
            providerArea.Children.Add(Card(L.T("Login_OneClickTitle", "Sign in with GitHub"), "\uE774", "indigo",
                Ui.Text(L.T("Login_OneClickBody", "Opens github.com in your browser. Enter the code shown here and you're in — no token to copy."), 13, "muted", wrap: true),
                oneClickPanel));
        }

        var cli = provider switch
        {
            GitProvider.GitHub or GitProvider.GitHubEnterprise when GhCli.Binary is not null => (Title: L.T("Login_GhTitle", "GitHub CLI"), Body: L.T("Login_GhBody", "Use the token you're signed in with in gh."), Button: L.T("Login_SignInWithGh", "Sign in with gh")),
            GitProvider.GitLab when GLabCli.Binary is not null => (Title: L.T("Login_GlabTitle", "GitLab CLI"), Body: L.T("Login_GlabBody", "Use the token you're signed in with in glab."), Button: L.T("Login_SignInWithGlab", "Sign in with glab")),
            _ => default
        };
        if (cli.Title is not null)
        {
            var button = Ui.Button(cli.Button, SignInWithCli, accent: true, glyph: "");
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            providerArea.Children.Add(Card(cli.Title, "", "sky", Ui.Text(cli.Body, 13, "muted", wrap: true), button));
        }

        var signIn = Ui.Button(L.T("Login_SignIn", "Sign in"), LoginWithToken, accent: true);
        var tokenRow = Ui.Columns((tokenBox, Ui.Star), (signIn, Ui.Auto));
        tokenRow.ColumnSpacing = 8;
        var tokenContent = new List<UIElement> { Ui.Text(provider.TokenHint(), 13, "muted", wrap: true) };
        if (provider == GitProvider.Bitbucket) tokenContent.Add(emailBox);
        tokenContent.Add(tokenRow);
        tokenContent.Add(Ui.Link(provider == GitProvider.Bitbucket ? L.T("Login_CreateAtlassianToken", "Create an API token at id.atlassian.com") : L.F("Login_CreateTokenOn", "Create a token on {0}", provider == GitProvider.GitHub ? GitProviders.GitHubHost : L.T("Login_YourServer", "your server")), () =>
        {
            if (provider.TokenCreateUrl(Host) is { } url) LinkBrowser.Open(url);
            else ShowError(L.T("Login_EnterServer", "Enter the server address"));
        }));
        providerArea.Children.Add(Card(provider.TokenTitle(), "", "amber", tokenContent.ToArray()));

        if (provider.SupportsDeviceFlow())
        {
            RenderDevice(null);
            providerArea.Children.Add(new Expander
            {
                Header = Ui.H(8, Ui.IconTile(OneClick ? "\uE713" : "", "indigo", 22), Ui.Text(OneClick ? L.T("Login_OwnOAuthApp", "Use your own OAuth App") : L.T("Login_DeviceTitle", "Sign in via browser (OAuth Device Flow)"), 14, "text", FontWeights.SemiBold)),
                Content = Ui.V(8, Ui.Text(provider.DeviceHelp(), 13, "muted", wrap: true), clientIdBox, devicePanel),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch
            });
        }
    }

    private static Border Card(string title, string glyph, string color, params UIElement[] content)
    {
        var panel = Ui.V(8, Ui.H(8, Ui.IconTile(glyph, color, 22), Ui.Text(title, 14, "text", FontWeights.SemiBold)));
        foreach (var c in content) panel.Children.Add(c);
        return Ui.Card(panel, 12, "raised", 16);
    }

    private void RenderOneClick(DeviceCode? code)
    {
        oneClickPanel.Children.Clear();
        if (code is null)
        {
            var button = Ui.Button(L.T("Login_OneClickTitle", "Sign in with GitHub"), () => StartDevice(OAuthApp.Bundled), accent: true, glyph: "\uE8A7");
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.MinHeight = 40;
            oneClickPanel.Children.Add(button);
            return;
        }
        AddCodeRow(oneClickPanel, code);
    }

    private void RenderDevice(DeviceCode? code)
    {
        devicePanel.Children.Clear();
        if (code is null)
        {
            devicePanel.Children.Add(Ui.Button(L.T("Login_GetCode", "Get code"), () => StartDevice()));
            return;
        }
        AddCodeRow(devicePanel, code);
    }

    private void AddCodeRow(StackPanel panel, DeviceCode code)
    {
        var codeText = Ui.Text(code.UserCode, 24, "text", FontWeights.Bold, mono: true, select: true);
        var copy = Ui.Button(L.T("Login_CopyAndOpen", "Copy and open"), () =>
        {
            WindowInterop.Copy(code.UserCode);
            LinkBrowser.Open(code.VerificationUri);
        }, accent: true);
        var cancel = Ui.Button(L.T("Common_Cancel", "Cancel"), CancelDevice);
        panel.Children.Add(Ui.H(12, Ui.Card(codeText, 8, "sunken", 6), copy, cancel, Ui.Spinner(16)));
        panel.Children.Add(Ui.Text(L.F("Login_DeviceHintAt", "Enter the code at {0} — you'll be signed in automatically.", code.VerificationUri), 12, "muted", wrap: true));
    }

    private void CancelDevice()
    {
        deviceCts?.Cancel();
        deviceCts = null;
        RenderDevice(null);
        RenderOneClick(null);
    }

    private void ShowError(string? message)
    {
        errorBar.Message = message ?? "";
        errorBar.IsOpen = message is not null;
    }

    private async void RunLogin(Func<Task> op)
    {
        busyRing.Visibility = Visibility.Visible;
        ShowError(null);
        try
        {
            await op();
        }
        catch (Exception e)
        {
            ShowError(e.Message);
        }
        finally
        {
            busyRing.Visibility = Visibility.Collapsed;
        }
    }

    private async Task Finish(GitProvider p, string host, GitCredential credential, string? email)
    {
        await app.AddAccount(p, host, credential, email);
        onDone?.Invoke();
    }

    private void SignInWithCli()
    {
        var p = provider;
        var host = Host;
        if (host.Length == 0)
        {
            ShowError(L.T("Login_EnterServer", "Enter the server address"));
            return;
        }
        RunLogin(async () =>
        {
            var token = p == GitProvider.GitLab ? await GLabCli.Token(host) : await GhCli.Token(host);
            await Finish(p, host, GitCredential.Of(token), null);
        });
    }

    private void LoginWithToken()
    {
        var p = provider;
        var host = Host;
        var token = tokenBox.Password.Trim();
        var email = emailBox.Text.Trim();
        if (token.Length == 0) return;
        if (host.Length == 0)
        {
            ShowError(L.T("Login_EnterServer", "Enter the server address"));
            return;
        }
        if (p == GitProvider.Bitbucket && email.Length == 0)
        {
            ShowError(L.T("Login_EnterEmail", "Enter your Atlassian account email"));
            return;
        }
        RunLogin(() => Finish(p, host, GitCredential.Of(token), p == GitProvider.Bitbucket ? email : null));
    }

    private async void StartDevice(string? clientOverride = null)
    {
        var id = clientOverride ?? clientIdBox.Text.Trim();
        var p = provider;
        var host = Host;
        if (id.Length == 0) return;
        if (host.Length == 0)
        {
            ShowError(L.T("Login_EnterServer", "Enter the server address"));
            return;
        }
        var endpoint = p == GitProvider.GitLab ? DeviceFlow.GitLab(host) : DeviceFlow.GitHub(host);
        ShowError(null);
        deviceCts?.Cancel();
        var cts = new CancellationTokenSource();
        deviceCts = cts;
        try
        {
            var code = await DeviceFlow.Start(id, endpoint, cts.Token);
            if (clientOverride is not null) RenderOneClick(code);
            else RenderDevice(code);
            WindowInterop.Copy(code.UserCode);
            LinkBrowser.Open(code.VerificationUri);
            var token = await DeviceFlow.Poll(id, code, endpoint, cts.Token);
            var credential = p == GitProvider.GitLab ? token.Credential(id) : GitCredential.Of(token.AccessToken);
            await Finish(p, host, credential, null);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            ShowError(e.Message);
        }
        if (ReferenceEquals(deviceCts, cts))
        {
            RenderDevice(null);
            RenderOneClick(null);
        }
    }
}
