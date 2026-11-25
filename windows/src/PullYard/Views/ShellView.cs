using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed class ShellView : Grid
{
    public static ShellView? Current { get; private set; }

    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly NavigationView nav = new();
    private readonly Grid body = new();
    private readonly ContentControl listHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly Border listBackground = new();
    private readonly Grid detailArea = new();
    private readonly ContentControl detailHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly Border clipboardBanner = new();
    private readonly Border toast = new();
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? toastTimer;
    private readonly StackPanel footer = Ui.V(0);
    private readonly ColumnDefinition listColumn = new() { Width = new GridLength(380) };
    private readonly Dictionary<string, NavigationViewItem> navItems = new();
    private readonly Dictionary<string, string> navTitles = new();
    private readonly List<(Route Route, FrameworkElement View)> stack = new();
    private readonly RouteHistory history = new();
    private static (string Text, bool IsError)? pendingToast;
    private const double SidebarDefault = 236;
    private const double SidebarMin = 180;
    private const double SidebarMax = 340;
    private ClaudeWorkspaceView? claudeView;
    private bool syncingSelection;

    public ShellView()
    {
        Current = this;
        BuildNav();
        BuildBody();
        nav.Content = body;
        Children.Add(nav);
        app.PropertyChanged += OnAppChanged;
        app.RouteRequested += OnRoute;
        app.AddAccountRequested += OnAddAccount;
        app.Claude.PropertyChanged += OnClaudeChanged;
        app.Updater.PropertyChanged += OnUpdaterChanged;
        ThemeService.Changed += OnTheme;
        Unloaded += (_, _) =>
        {
            app.PropertyChanged -= OnAppChanged;
            app.RouteRequested -= OnRoute;
            app.AddAccountRequested -= OnAddAccount;
            app.Claude.PropertyChanged -= OnClaudeChanged;
            app.Updater.PropertyChanged -= OnUpdaterChanged;
            ThemeService.Changed -= OnTheme;
            if (Current == this) Current = null;
        };
        ShowSection();
        UpdateBadges();
        RenderFooter();
        if (app.DetailRoot is { } root) OnRoute(root, false);
        else ShowEmptyDetail();
        Loaded += (_, _) =>
        {
            if (!Program.SmokeUi && !Program.SmokeTour && !Core.Util.Demo.IsOn)
                DispatcherQueue.TryEnqueue(() => WelcomeTour.ShowIfNeeded(XamlRoot, () => app.Section = Section.Overview).Forget());
            if (pendingToast is not { } queued) return;
            pendingToast = null;
            ShowToast(queued.Text, queued.IsError);
        };
    }

    private void OnAddAccount() => AccountDialogs.Add(XamlRoot).Forget();

    private bool shownHighContrast = ThemeService.IsHighContrast;

    private void OnTheme()
    {
        var highContrast = ThemeService.IsHighContrast;
        if (highContrast == shownHighContrast) return;
        shownHighContrast = highContrast;
        DispatcherQueue.TryEnqueue(() =>
        {
            BuildNavItems();
            ShowSection(force: true);
            RenderFooter();
            if (stack.Count > 0)
            {
                var top = stack[^1].Route;
                stack.Clear();
                OnRoute(top, false);
            }
        });
    }

    private void UpdateBackground()
    {
        listBackground.Background = Palette.Brush("list");
        detailArea.Background = Palette.Brush("panel");
        nav.Resources["NavigationViewExpandedPaneBackground"] = Palette.Brush("sidebar");
        nav.Resources["NavigationViewContentBackground"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    private void BuildNav()
    {
        nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Auto;
        nav.CompactModeThresholdWidth = 0;
        nav.ExpandedModeThresholdWidth = 1180;
        nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        nav.IsSettingsVisible = false;
        nav.OpenPaneLength = Math.Clamp(Settings.Shared.GetDouble(Keys.SidebarWidth, SidebarDefault), SidebarMin, SidebarMax);
        nav.IsPaneToggleButtonVisible = true;
        nav.IsTitleBarAutoPaddingEnabled = false;
        nav.SelectionChanged += (_, e) =>
        {
            if (syncingSelection) return;
            if (e.SelectedItem is NavigationViewItem { Tag: string key } && Section.FromKey(key) is { } s) app.Section = s;
        };
        BuildNavItems();
        nav.PaneFooter = footer;
        nav.PaneOpened += (_, _) => today.Visibility = Visibility.Visible;
        nav.PaneClosed += (_, _) => today.Visibility = nav.DisplayMode == NavigationViewDisplayMode.Expanded ? Visibility.Visible : Visibility.Collapsed;
        UpdateBackground();
    }

    private void BuildNavItems()
    {
        nav.MenuItems.Clear();
        navItems.Clear();
        navTitles.Clear();
        var group = "";
        NavigationViewItem? parent = null;
        void Header(string text)
        {
            group = text;
            parent = null;
            nav.MenuItems.Add(new NavigationViewItemHeader { Content = text });
        }
        void Item(Section s, string title, string glyph)
        {
            var item = new NavigationViewItem
            {
                Content = title,
                Tag = s.Key,
                Icon = new FontIcon { Glyph = glyph, FontFamily = Ui.Icons }
            };
            navItems[s.Key] = item;
            navTitles[s.Key] = s.Kind is SectionKind.Prs or SectionKind.Issues && group.Length > 0 ? $"{group}: {title}" : title;
            if (parent is not null) parent.MenuItems.Add(item);
            else nav.MenuItems.Add(item);
        }
        void Collapsible(string title, string glyph, bool expanded)
        {
            group = title;
            parent = new NavigationViewItem
            {
                Content = title,
                SelectsOnInvoked = false,
                IsExpanded = expanded,
                Icon = new FontIcon { Glyph = glyph, FontFamily = Ui.Icons }
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(parent, title);
            nav.MenuItems.Add(parent);
        }
        void Top(bool inbox, string inboxTitle)
        {
            group = "";
            parent = null;
            Item(Section.Overview, L.T("Section_Overview", "Overview"), "\uE80F");
            if (inbox) Item(Section.Notifications, inboxTitle, "\uEA8F");
            Item(Section.Claude, L.T("Section_Claude", "Agents"), "\uE945");
        }
        var issuesOpen = app.Section.Kind == SectionKind.Issues;
        if (app.Forge is not null)
        {
            var caps = app.ForgeCaps;
            var provider = app.Provider;
            Top(caps.HasInbox, caps.Inbox.Title());
            Header(provider.RequestsTitle());
            foreach (var f in caps.PullFilters) Item(Section.Prs(f.Filter()), f.Filter().Title(), f.Filter().Glyph());
            if (caps.PullFilters.Contains(Core.Auth.ForgeFilter.Mine)) Item(Section.MyPrsByRepo, provider.ByProjectTitle(), "\uE8B7");
            if (caps.IssueFilters.Count > 0)
            {
                Collapsible(L.T("Nav_Issues", "Issues"), "\uE7C3", issuesOpen);
                foreach (var f in caps.IssueFilters) Item(Section.Issues(f.Filter()), f.Filter().Title(), f.Filter().Glyph());
            }
            if (caps.Repositories)
            {
                Header(L.T("Nav_Code", "Code"));
                Item(Section.Repos, provider.RepositoriesTitle(), "\uE8F1");
            }
            SyncNavSelection();
            UpdateBadges();
            return;
        }
        Top(true, L.T("Section_Notifications", "Notifications"));
        Header(L.T("Nav_PullRequests", "Pull requests"));
        foreach (var f in Enum.GetValues<PRFilter>()) Item(Section.Prs(f), f.Title(), f.Glyph());
        Item(Section.MyPrsByRepo, L.T("Section_MyPrsByProject", "My PRs by project"), "\uE8B7");
        Item(Section.Stacks, L.T("Section_Stacks", "Stacks"), "\uE81E");
        Collapsible(L.T("Nav_Issues", "Issues"), "\uE7C3", issuesOpen);
        foreach (var f in Enum.GetValues<IssueFilter>()) Item(Section.Issues(f), f.Title(), f.Glyph());
        Header(L.T("Nav_Code", "Code"));
        Item(Section.Repos, L.T("Section_Repositories", "Repositories"), "\uE8F1");
        Item(Section.Projects, L.T("Section_Projects", "Projects"), "\uE8A9");
        SyncNavSelection();
        UpdateBadges();
    }

    private void SyncNavSelection()
    {
        if (!navItems.TryGetValue(app.Section.Key, out var item)) return;
        syncingSelection = true;
        nav.SelectedItem = item;
        syncingSelection = false;
    }

    private void UpdateBadges()
    {
        void Badge(string key, int count, bool attention, string spoken)
        {
            if (!navItems.TryGetValue(key, out var item)) return;
            if (count <= 0)
            {
                item.InfoBadge = null;
            }
            else
            {
                var (fill, text) = attention ? Palette.Filled("accent") : (Palette.Brush("text", 0.12), Palette.Brush("text"));
                item.InfoBadge = new InfoBadge { Value = count, Background = fill, Foreground = text };
            }
            var title = navTitles.GetValueOrDefault(key, "");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, count > 0 ? $"{title}, {spoken}" : title);
            ToolTipService.SetToolTip(item, count > 0 ? $"{title} ({spoken})" : title);
        }
        foreach (var (key, item) in navItems)
        {
            var title = navTitles.GetValueOrDefault(key, "");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, title);
            ToolTipService.SetToolTip(item, title);
        }
        Badge(Section.Notifications.Key, app.UnreadCount, false, L.F("Nav_UnreadCountLabel", "{0} unread", app.Forge is null ? GitHubApi.CountLabel(app.UnreadCount) : app.UnreadCount.ToString()));
        Badge(Section.Prs(PRFilter.ReviewRequested).Key, app.ReviewRequestCount, true, L.F("Nav_WaitingCount", "{0} waiting", app.ReviewRequestCount));
        Badge(Section.Prs(PRFilter.Mine).Key, app.MyPRCount, false, L.F("Nav_OpenCount", "{0} open", app.MyPRCount));
        var attention = app.Claude.AttentionCount;
        var claude = attention > 0 ? attention : app.Claude.RunningCount;
        Badge(Section.Claude.Key, claude, attention > 0, attention > 0 ? L.F("Nav_NeedYouCount", "{0} need you", attention) : L.F("Nav_RunningCount", "{0} running", claude));
        RenderToday();
    }

    private readonly ContentControl today = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };

    private void RenderToday()
    {
        var waiting = app.ReviewRequestCount;
        var running = app.Claude.RunningCount;
        var attention = app.Claude.AttentionCount;
        var unread = app.UnreadCount;
        var lines = Ui.V(3, Ui.Text(L.T("Today_Title", "Today").ToUpperInvariant(), 10, "coralInk", FontWeights.SemiBold));
        void Line(string glyph, string color, string text)
        {
            var row = Ui.Columns((Ui.Glyph(glyph, 11, color), Ui.Auto), (Ui.Text(text, 12, "text", maxLines: 1), Ui.Star));
            row.ColumnSpacing = 6;
            lines.Children.Add(row);
        }
        Line("\uE7B3", waiting > 0 ? "link" : "muted", waiting == 0 ? L.T("Today_NoReviews", "No reviews waiting") : waiting == 1 ? L.T("Today_OneReview", "1 review waiting") : L.F("Today_Reviews", "{0} reviews waiting", waiting));
        if (attention > 0) Line("\uE945", "coral", L.F("Today_AgentsNeedYou", "{0} agents need you", attention));
        else if (running > 0) Line("\uE945", "violet", running == 1 ? L.T("Today_OneAgent", "1 agent running") : L.F("Today_Agents", "{0} agents running", running));
        if (unread > 0) Line("\uEA8F", "link", L.F("Today_Unread", "{0} unread", app.Forge is null ? GitHubApi.CountLabel(unread) : unread.ToString()));
        var card = new Button
        {
            Content = lines,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(8, 0, 8, 8),
            Background = Palette.Brush("raised"),
            BorderBrush = Palette.Brush("line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10)
        };
        card.Click += (_, _) => app.Section = Section.Overview;
        var spoken = string.Join(", ", lines.Children.OfType<Grid>().Select(g => g.Children.OfType<TextBlock>().FirstOrDefault()?.Text).Where(t => t is not null));
        Ui.Tip(card, L.T("Today_Open", "Open Overview"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"{L.T("Today_Title", "Today")}: {spoken}");
        today.Content = card;
        today.Visibility = nav.DisplayMode == NavigationViewDisplayMode.Expanded || nav.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderFooter()
    {
        footer.Children.Clear();
        RenderToday();
        footer.Children.Add(today);
        if (app.Updater.AvailableVersion is { } version)
        {
            var row = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = Palette.Brush("sky", 0.12),
                BorderThickness = new Thickness(0),
                Margin = new Thickness(8, 0, 8, 8),
                Content = Ui.H(8, Ui.Glyph("", 14, "sky"), Ui.Text(L.F("Update_To", "Update to {0}", version), 13, "text", FontWeights.Medium))
            };
            Ui.Tip(row, L.F("Update_Available", "A new version of {0} is available", PullYard.Core.AppInfo.DisplayName));
            row.Click += (_, _) => app.Updater.Present();
            footer.Children.Add(row);
        }
        if (app.RateLimitedUntil is { } until)
        {
            var text = Ui.Text(L.F("RateLimit_Paused", "Rate limited — live updates resume at {0}", until.ToLocalTime().ToString("t", Fmt.Culture)), 12, "muted", wrap: true);
            var row = Ui.Columns((Ui.Glyph("\uE823", 13, "amber"), Ui.Auto), (text, Ui.Star));
            row.ColumnSpacing = 8;
            row.Margin = new Thickness(14, 0, 10, 8);
            Ui.Tip(row, L.F("RateLimit_ProviderHint", "{0} rate limit reached. Live polling and refreshes are paused until the limit resets.", app.Provider.Title()));
            footer.Children.Add(row);
        }
        if (app.User is { } user)
        {
            footer.Children.Add(Ui.Line());
            footer.Children.Add(new AccountFooter(user.Name ?? user.Login, app.GitAccount?.Subtitle ?? "@" + user.Login, user.AvatarUrl));
        }
    }

    private void BuildBody()
    {
        body.ColumnDefinitions.Add(listColumn);
        splitterColumn = new ColumnDefinition { Width = new GridLength(1) };
        body.ColumnDefinitions.Add(splitterColumn);
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(listBackground, 0);
        Grid.SetColumn(listHost, 0);
        body.Children.Add(listBackground);
        body.Children.Add(listHost);

        var paneGrip = new Border { Width = 8, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-4, 0, 0, 0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Canvas.SetZIndex(paneGrip, 5);
        Ui.Tip(paneGrip, L.T("Sidebar_ResizeHint", "Drag to resize the sidebar. Double-click to reset."));
        body.Children.Add(paneGrip);
        double paneStart = 0, paneStartX = 0;
        var paneDragging = false;
        bool PaneResizable() => nav.DisplayMode == NavigationViewDisplayMode.Expanded && nav.IsPaneOpen;
        paneGrip.PointerEntered += (_, _) =>
        {
            if (PaneResizable()) ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        };
        paneGrip.PointerExited += (_, _) =>
        {
            if (!paneDragging) ProtectedCursor = null;
        };
        paneGrip.PointerPressed += (_, e) =>
        {
            if (!PaneResizable()) return;
            paneDragging = true;
            paneStart = nav.OpenPaneLength;
            paneStartX = e.GetCurrentPoint(this).Position.X;
            paneGrip.CapturePointer(e.Pointer);
        };
        paneGrip.PointerMoved += (_, e) =>
        {
            if (!paneDragging) return;
            nav.OpenPaneLength = Math.Clamp(paneStart + e.GetCurrentPoint(this).Position.X - paneStartX, SidebarMin, SidebarMax);
        };
        paneGrip.PointerReleased += (_, e) =>
        {
            if (!paneDragging) return;
            paneDragging = false;
            paneGrip.ReleasePointerCapture(e.Pointer);
            ProtectedCursor = null;
            Settings.Shared.Set(Keys.SidebarWidth, nav.OpenPaneLength);
        };
        paneGrip.DoubleTapped += (_, _) =>
        {
            if (!PaneResizable()) return;
            nav.OpenPaneLength = SidebarDefault;
            Settings.Shared.Set(Keys.SidebarWidth, SidebarDefault);
        };

        var splitter = new Border { Background = Palette.Brush("line"), Width = 1 };
        var grip = new Border { Width = 9, Margin = new Thickness(-4, 0, -4, 0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Grid.SetColumn(splitter, 1);
        Grid.SetColumn(grip, 1);
        body.Children.Add(splitter);
        body.Children.Add(grip);
        double startWidth = 0, startX = 0;
        var dragging = false;
        grip.PointerEntered += (_, _) => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        grip.PointerExited += (_, _) => { if (!dragging) ProtectedCursor = null; };
        grip.PointerPressed += (s, e) =>
        {
            dragging = true;
            startWidth = listColumn.ActualWidth;
            startX = e.GetCurrentPoint(body).Position.X;
            grip.CapturePointer(e.Pointer);
        };
        grip.PointerMoved += (_, e) =>
        {
            if (!dragging) return;
            var x = e.GetCurrentPoint(body).Position.X;
            listColumn.Width = new GridLength(Math.Clamp(startWidth + x - startX, 280, 620));
        };
        grip.PointerReleased += (_, e) =>
        {
            dragging = false;
            grip.ReleasePointerCapture(e.Pointer);
            ProtectedCursor = null;
        };

        Grid.SetColumn(detailArea, 2);
        detailArea.Children.Add(detailHost);
        clipboardBanner.VerticalAlignment = VerticalAlignment.Bottom;
        clipboardBanner.HorizontalAlignment = HorizontalAlignment.Center;
        clipboardBanner.Margin = new Thickness(0, 0, 0, 16);
        clipboardBanner.Visibility = Visibility.Collapsed;
        detailArea.Children.Add(clipboardBanner);
        toast.VerticalAlignment = VerticalAlignment.Bottom;
        toast.HorizontalAlignment = HorizontalAlignment.Center;
        toast.MaxWidth = 560;
        toast.IsHitTestVisible = false;
        toast.Opacity = 0;
        toast.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(160) };
        detailArea.Children.Add(toast);
        body.Children.Add(detailArea);
    }

    private void OnUpdaterChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(UpdaterViewModel.State) or nameof(UpdaterViewModel.Release)) RenderFooter();
    }

    private void OnClaudeChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ClaudeWorkspace.AttentionCount) or nameof(ClaudeWorkspace.RunningCount)) UpdateBadges();
    }

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppViewModel.Section):
                ShowSection();
                break;
            case nameof(AppViewModel.UnreadCount):
            case nameof(AppViewModel.ReviewRequestCount):
            case nameof(AppViewModel.MyPRCount):
                UpdateBadges();
                break;
            case nameof(AppViewModel.User):
            case nameof(AppViewModel.GitAccount):
            case nameof(AppViewModel.RateLimitedUntil):
                RenderFooter();
                break;
            case nameof(AppViewModel.ClipboardRoute):
                RenderClipboard();
                break;
            case nameof(AppViewModel.ForgeSelection):
                ShowForgeDetail();
                break;
            case nameof(AppViewModel.ForgeCaps):
                BuildNavItems();
                break;
        }
    }

    private string? shownSection;

    private void ShowSection(bool force = false)
    {
        SyncNavSelection();
        var s = app.Section;
        if (!force && shownSection == s.Key) return;
        shownSection = s.Key;
        SetListVisible(s.Kind != SectionKind.Overview);
        if (s.Kind == SectionKind.Overview)
        {
            ShowOverview();
            return;
        }
        if (app.Forge is not null)
        {
            ShowForgeSection(s);
            return;
        }
        FrameworkElement list = s.Kind switch
        {
            SectionKind.Notifications => new NotificationsView(),
            SectionKind.Prs => new SearchListView(s.Title, "pr", s.Pr.Query(), false),
            SectionKind.MyPrsByRepo => new SearchListView(s.Title, "pr", PRFilter.Mine.Query(), true),
            SectionKind.Stacks => new StacksView(),
            SectionKind.Issues => new SearchListView(s.Title, "issue", s.Issue.Query(), false),
            SectionKind.Repos => new ReposView(),
            SectionKind.Projects => new ProjectsView(),
            SectionKind.Claude => new ClaudeSessionsView(),
            SectionKind.Search => new SearchListView(s.Title, "pr", s.Query ?? "", false),
            _ => new Grid()
        };
        list.Transitions = new TransitionCollection { new ContentThemeTransition() };
        TextZoom.ApplyWhenLoaded(list);
        listHost.Content = list;
        App.MainWindow?.SetSubtitle(s.Title);
        if (s.Kind == SectionKind.Claude)
        {
            claudeView ??= new ClaudeWorkspaceView();
            detailHost.Content = claudeView;
        }
        else if (stack.Count > 0)
        {
            TextZoom.ApplyWhenLoaded(stack[^1].View);
            detailHost.Content = stack[^1].View;
        }
        else
        {
            ShowEmptyDetail();
        }
    }

    private ColumnDefinition? splitterColumn;
    private GridLength listWidth = new(380);

    private void SetListVisible(bool visible)
    {
        if (splitterColumn is null) return;
        var hidden = listColumn.Width.Value == 0;
        if (visible == !hidden) return;
        if (!visible)
        {
            listWidth = listColumn.Width;
            listColumn.Width = new GridLength(0);
            splitterColumn.Width = new GridLength(0);
            listHost.Content = null;
        }
        else
        {
            listColumn.Width = listWidth;
            splitterColumn.Width = new GridLength(1);
        }
    }

    private void ShowOverview()
    {
        listHost.Content = null;
        App.MainWindow?.SetSubtitle(Section.Overview.Title);
        var view = new OverviewView(section =>
        {
            if (app.Forge is null || app.ForgeSupports(section)) app.Section = section;
        }, (title, query) => app.Section = Section.Search(title, query));
        view.Transitions = new TransitionCollection { new ContentThemeTransition() };
        TextZoom.ApplyWhenLoaded(view);
        detailHost.Content = view;
    }

    private void ShowForgeSection(Section s)
    {
        var title = s.ForgeTitle(app.Provider, app.ForgeCaps.Inbox);
        FrameworkElement list = !app.ForgeSupports(s) ? ForgeDetailView.Unavailable(app.Provider) : s.Kind switch
        {
            SectionKind.Prs or SectionKind.MyPrsByRepo or SectionKind.Issues => new ForgeListView(s, title),
            SectionKind.Notifications => new ForgeInboxView(title),
            SectionKind.Repos => new ForgeReposView(title),
            SectionKind.Claude => new ClaudeSessionsView(),
            _ => ForgeDetailView.Unavailable(app.Provider)
        };
        list.Transitions = new TransitionCollection { new ContentThemeTransition() };
        TextZoom.ApplyWhenLoaded(list);
        listHost.Content = list;
        App.MainWindow?.SetSubtitle(title);
        if (s.Kind == SectionKind.Claude)
        {
            claudeView ??= new ClaudeWorkspaceView();
            detailHost.Content = claudeView;
        }
        else
        {
            ShowForgeDetail();
        }
    }

    private void ShowForgeDetail()
    {
        if (app.Forge is null || app.Section.Kind is SectionKind.Claude or SectionKind.Overview) return;
        if (app.ForgeSelection is not { } item)
        {
            detailHost.Content = ForgeDetailView.Empty(app.Provider);
            return;
        }
        var view = new ForgeDetailView(item, app.Provider)
        {
            Transitions = new TransitionCollection { new EntranceThemeTransition { FromVerticalOffset = 10, FromHorizontalOffset = 0 } }
        };
        detailHost.Content = view;
    }

    private void ShowEmptyDetail()
    {
        if (app.Forge is not null)
        {
            ShowForgeDetail();
            return;
        }
        if (app.Section.Kind is SectionKind.Claude or SectionKind.Overview) return;
        detailHost.Content = new EmptyHarbor("detail-empty", L.T("Detail_EmptyTitle", "Nothing open yet"), L.T("Detail_Empty", "Select a pull request, issue or project"), new[]
        {
            ("Ctrl+L", L.T("Detail_HintLink", "Open by link")),
            ("Ctrl+K", L.T("Detail_HintPalette", "Command palette")),
            ("Ctrl+/", L.T("Detail_HintShortcuts", "All shortcuts"))
        }, nextUp: true);
    }

    private void OnRoute(Route route, bool push)
    {
        if (app.Section.Kind is SectionKind.Claude or SectionKind.Overview || app.Forge is not null) return;
        if (!push) stack.Clear();
        if (stack.Count > 0 && stack[^1].Route == route) return;
        if (!goingForward) history.Navigated();
        var view = CreateDetail(route);
        stack.Add((route, view));
        if (stack.Count > 12) stack.RemoveAt(0);
        if (!app.TakeQuietRoute()) view.Transitions = new TransitionCollection { new EntranceThemeTransition { FromVerticalOffset = 10, FromHorizontalOffset = 0 } };
        TextZoom.ApplyWhenLoaded(view);
        detailHost.Content = view;
    }

    public Route? CurrentRoute => stack.Count > 0 ? stack[^1].Route : null;

    public bool IsPaneOpen => nav.IsPaneOpen;

    public void TogglePane() => nav.IsPaneOpen = !nav.IsPaneOpen;

    public bool CanGoBack => stack.Count > 1;

    public bool CanGoBackAfterPush() => stack.Count > 0;

    private bool goingForward;

    public bool CanGoForward => history.CanGoForward && stack.Count > 0 && app.Section.Kind != SectionKind.Claude && app.Forge is null;

    public void GoForward()
    {
        if (!CanGoForward || history.TakeForward() is not { } next) return;
        goingForward = true;
        try
        {
            OnRoute(next, true);
        }
        finally
        {
            goingForward = false;
        }
    }

    public void GoBack()
    {
        if (stack.Count <= 1 || app.Section.Kind == SectionKind.Claude) return;
        history.WentBack(stack[^1].Route);
        stack.RemoveAt(stack.Count - 1);
        TextZoom.ApplyWhenLoaded(stack[^1].View);
        detailHost.Content = stack[^1].View;
        app.DetailRoot = stack[^1].Route;
    }

    private FrameworkElement CreateDetail(Route route)
    {
        var content = route.Kind switch
        {
            RouteKind.PullRequest => (FrameworkElement)new PRDetailView(route.Item!),
            RouteKind.Issue => new IssueDetailView(route.Item!),
            RouteKind.Repo => new RepoDetailView(route.Repo!),
            RouteKind.Project => new ProjectBoardView(route.Project!),
            RouteKind.Commit => new CommitDetailView(route.Repo!, route.Sha!),
            _ => new Grid()
        };
        return new DetailFrame(content, this);
    }

    public static void CopyShortLink(string? link)
    {
        if (string.IsNullOrEmpty(link)) return;
        WindowInterop.Copy(link);
        Toast(L.F("Toast_CopiedShortLink", "Copied {0}", link));
    }

    public static void Copied(string value, string message)
    {
        WindowInterop.Copy(value);
        Toast(message);
    }

    public static void Toast(string text, bool isError = false) => Toast(text, isError, null, null);

    public static void Toast(string text, bool isError, string? actionTitle, Action? action, string? glyph = null, string glyphColor = "green")
    {
        if (Current is { } shell) shell.ShowToast(text, isError, actionTitle, action, glyph, glyphColor);
        else if (isError) pendingToast = (text, true);
    }

    private void DismissToast()
    {
        toastTimer?.Stop();
        toast.Opacity = 0;
        toast.IsHitTestVisible = false;
    }

    private static Brush FloatingBrush()
    {
        var overlay = Palette.Get("overlay");
        if (ThemeService.IsHighContrast) return Palette.Brush("overlay");
        return new AcrylicBrush { TintColor = overlay, TintOpacity = 0.72, TintLuminosityOpacity = 0.9, FallbackColor = overlay };
    }

    private void ShowToast(string text, bool isError = false, string? actionTitle = null, Action? action = null, string? glyph = null, string glyphColor = "green")
    {
        if (isError)
        {
            var message = Ui.Text(text, 13, "text", wrap: true, maxLines: 6, select: true);
            var copy = Ui.IconButton("\uE8C8", L.T("Toast_CopyAndDismiss", "Copy the message and dismiss"), () =>
            {
                WindowInterop.Copy(text);
                DismissToast();
            });
            var dismiss = Ui.IconButton("\uE711", L.T("Common_Dismiss", "Dismiss"), DismissToast);
            var row = Ui.Columns((Ui.Glyph("\uE7BA", 13, "red"), Ui.Auto), (message, Ui.Star), (copy, Ui.Auto), (dismiss, Ui.Auto));
            row.ColumnSpacing = 8;
            toast.Child = row;
        }
        else
        {
            var row = Ui.H(8, Ui.Glyph(glyph ?? "\uE73E", 13, glyphColor), Ui.Text(text, 13));
            if (actionTitle is not null && action is not null)
            {
                var button = new HyperlinkButton { Content = actionTitle, Padding = new Thickness(6, 2, 6, 2), FontWeight = FontWeights.SemiBold };
                button.Click += (_, _) =>
                {
                    DismissToast();
                    action();
                };
                row.Children.Add(TextZoom.Track(button, 13));
            }
            toast.Child = row;
        }
        toast.IsHitTestVisible = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toast, actionTitle is null ? text : $"{text}, {actionTitle}");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetLiveSetting(toast, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        toast.Padding = new Thickness(14, 7, actionTitle is null ? 16 : 8, 7);
        toast.CornerRadius = new CornerRadius(20);
        toast.Background = FloatingBrush();
        toast.BorderBrush = isError ? Palette.Brush("red", 0.5) : Palette.Brush("lineStrong");
        toast.BorderThickness = new Thickness(1);
        toast.Shadow = new ThemeShadow();
        toast.Translation = new System.Numerics.Vector3(0, 0, 16);
        toast.Margin = new Thickness(0, 0, 0, clipboardBanner.Visibility == Visibility.Visible ? 64 : 16);
        toast.Opacity = 1;
        toastTimer ??= DispatcherQueue.CreateTimer();
        toastTimer.Stop();
        toastTimer.Interval = TimeSpan.FromMilliseconds(isError ? 8000 : action is not null ? 5000 : 1800);
        toastTimer.IsRepeating = false;
        toastTimer.Tick -= HideToast;
        toastTimer.Tick += HideToast;
        toastTimer.Start();
    }

    private void HideToast(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        toast.Opacity = 0;
        toast.IsHitTestVisible = false;
    }

    private void RenderClipboard()
    {
        if (app.ClipboardRoute is not { } route)
        {
            clipboardBanner.Visibility = Visibility.Collapsed;
            return;
        }
        var title = route.Kind == RouteKind.PullRequest ? $"PR {route.Item!.Title}" : $"Issue {route.Item!.Title}";
        var open = Ui.Button(L.T("Common_Open", "Open"), () =>
        {
            app.Open(route);
            app.ClipboardRoute = null;
        }, accent: true);
        var close = Ui.IconButton("", L.T("Common_Dismiss", "Dismiss"), () => app.ClipboardRoute = null);
        clipboardBanner.Child = Ui.H(10, Ui.Glyph("", 14), Ui.Text(L.F("Clipboard_InClipboard", "In clipboard: {0}", title), 13), open, close);
        clipboardBanner.Padding = new Thickness(14, 6, 6, 6);
        clipboardBanner.CornerRadius = new CornerRadius(20);
        clipboardBanner.Background = Palette.Brush("overlay");
        clipboardBanner.BorderBrush = Palette.Brush("lineStrong");
        clipboardBanner.BorderThickness = new Thickness(1);
        clipboardBanner.Shadow = new ThemeShadow();
        clipboardBanner.Translation = new System.Numerics.Vector3(0, 0, 16);
        clipboardBanner.Visibility = Visibility.Visible;
    }
}

public sealed class DetailFrame : Grid
{
    public DetailFrame(FrameworkElement content, ShellView shell)
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        if (content is PRDetailView)
        {
            Children.Add(new Border { Background = Palette.Brush("bar") });
        }
        if (shell.CanGoBackAfterPush())
        {
            var back = Ui.IconButton("", L.T("Common_BackHint", "Back (Alt+Left)"), shell.GoBack);
            back.Margin = new Thickness(8, 4, 0, 0);
            back.HorizontalAlignment = HorizontalAlignment.Left;
            Children.Add(back);
        }
        Grid.SetRow(content, 1);
        Children.Add(content);
    }
}
