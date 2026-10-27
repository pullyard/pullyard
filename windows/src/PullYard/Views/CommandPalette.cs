using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
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
using Windows.System;

namespace PullYard.Views;

public enum PaletteSection { Link, GoTo, Items, Repos, Actions }

public sealed class PaletteHeader : IRowContent
{
    public PaletteHeader(string title) => Title = title;

    public string Title { get; }

    public UIElement BuildRow()
    {
        var t = Ui.Text(Title, 12, "dim", FontWeights.SemiBold);
        t.Margin = new Thickness(0, 8, 0, 2);
        return t;
    }

    public override string ToString() => Title;
}

public sealed class PaletteCommand : IRowContent
{
    public PaletteCommand(string id, PaletteSection section, string glyph, string color, string title, Action run)
    {
        Id = id;
        Section = section;
        Glyph = glyph;
        Color = color;
        Title = title;
        Run = run;
    }

    public string Id { get; }
    public PaletteSection Section { get; }
    public string Glyph { get; }
    public string Color { get; }
    public string Title { get; }
    public Action Run { get; }
    public string Detail { get; init; } = "";
    public string? Shortcut { get; init; }
    public string Keywords { get; init; } = "";

    public string Label => string.Join(", ", new[] { Title, Detail, CommandPalette.SectionTitle(Section) }.Where(s => s.Length > 0));

    public UIElement BuildRow()
    {
        var icon = Ui.Glyph(Glyph, 13, Color);
        icon.Width = 18;
        var title = Ui.Text(Title, 13.5);
        var detail = Ui.Text(Detail, 12, "dim");
        detail.Visibility = Detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var text = Ui.Columns((title, Ui.Auto), (detail, Ui.Star));
        text.ColumnSpacing = 10;
        UIElement? key = null;
        if (Shortcut is { } shortcut)
            key = new Border { Background = Palette.Brush("text", 0.08), CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 0, 5, 1), VerticalAlignment = VerticalAlignment.Center, Child = Ui.Text(shortcut, 11.5, "muted", mono: true) };
        var grid = Ui.Columns((icon, Ui.Auto), (text, Ui.Star), (key, Ui.Auto));
        grid.ColumnSpacing = 10;
        grid.Padding = new Thickness(0, 7, 0, 7);
        return grid;
    }

    public override string ToString() => Label;
}

public sealed class CommandPalette
{
    private static CommandPalette? current;
    private static readonly Dictionary<string, List<RepoSummary>> RepoCache = new(StringComparer.OrdinalIgnoreCase);

    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly XamlRoot root;
    private readonly Popup popup = new();
    private readonly Grid overlay = new();
    private readonly Border card = new();
    private readonly TextBox box = new();
    private readonly ContentControl leading = new() { Width = 18, VerticalAlignment = VerticalAlignment.Center, IsTabStop = false };
    private readonly ListView list = ListSupport.Create("GenericRowTemplate");
    private readonly TextBlock empty = Ui.Text("", 13, "muted");
    private readonly UIElement? previousFocus;
    private List<object> rows = new();
    private List<SearchItem> found = new();
    private CancellationTokenSource? searchCts;
    private string lastAnnounced = "";

    private CommandPalette(XamlRoot root)
    {
        this.root = root;
        previousFocus = FocusManager.GetFocusedElement(root) as UIElement;
    }

    public static void Toggle(XamlRoot? root)
    {
        if (current is not null)
        {
            current.Close();
            return;
        }
        if (root is null || AppViewModel.Shared.Phase != Phase.LoggedIn) return;
        current = new CommandPalette(root);
        current.Open();
    }

    public static string SectionTitle(PaletteSection section) => section switch
    {
        PaletteSection.Link => L.T("Palette_OpenLink", "Open link"),
        PaletteSection.GoTo => L.T("Palette_GoTo", "Go to"),
        PaletteSection.Items => L.T("Palette_Items", "Pull requests & issues"),
        PaletteSection.Repos => L.T("Palette_Repos", "Repositories"),
        _ => L.T("Palette_Actions", "Actions")
    };

    private static int Limit(PaletteSection section, bool searching) => section switch
    {
        PaletteSection.Link => 1,
        PaletteSection.GoTo => searching ? 6 : 20,
        PaletteSection.Items => searching ? 20 : 6,
        PaletteSection.Repos => searching ? 12 : 3,
        _ => searching ? 10 : 40
    };

    private void Open()
    {
        box.PlaceholderText = L.T("Palette_Placeholder", "Search commands, pull requests, repositories, or paste a link…");
        box.FontSize = 15;
        box.BorderThickness = new Thickness(0);
        box.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        box.Resources["TextControlBackgroundFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        box.Resources["TextControlBackgroundPointerOver"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        AutomationProperties.SetName(box, L.T("Palette_Name", "Command palette"));
        AutomationProperties.SetHelpText(box, L.T("Palette_Help", "Type to filter. Use the up and down arrow keys to choose, Enter to run, Escape to close."));
        box.TextChanged += (_, _) =>
        {
            Rebuild(true);
            Search();
        };
        box.PreviewKeyDown += OnKey;
        leading.Content = Ui.Glyph("", 14, "muted");
        AutomationProperties.SetAccessibilityView(leading, AccessibilityView.Raw);

        list.MaxHeight = 8 * 38 + 2 * 30;
        list.SelectionMode = ListViewSelectionMode.Single;
        list.Padding = new Thickness(6);
        AutomationProperties.SetName(list, L.T("Palette_Results", "Results"));
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is PaletteCommand c) Run(c);
        };
        list.ContainerContentChanging += (_, e) =>
        {
            if (e.ItemContainer is not ListViewItem item) return;
            var header = e.Item is PaletteHeader;
            item.IsHitTestVisible = !header;
            item.IsTabStop = !header;
            item.MinHeight = 0;
            AutomationProperties.SetName(item, e.Item?.ToString() ?? "");
            AutomationProperties.SetHeadingLevel(item, header ? AutomationHeadingLevel.Level2 : AutomationHeadingLevel.None);
            if (e.Item is PaletteCommand { Shortcut: { } key }) AutomationProperties.SetAcceleratorKey(item, key);
        };
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is PaletteHeader) Move(1);
            else Announce();
        };
        empty.Text = L.T("Palette_NoResults", "No results");
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.Margin = new Thickness(0, 20, 0, 20);
        empty.Visibility = Visibility.Collapsed;
        var results = new Grid();
        results.Children.Add(list);
        results.Children.Add(empty);

        var top = Ui.Columns((leading, Ui.Auto), (box, Ui.Star));
        top.ColumnSpacing = 10;
        top.Padding = new Thickness(16, 10, 16, 10);
        var hints = Ui.H(14, Hint("↑↓", L.T("Agents_HintSelect", "select")), Hint("↵", L.T("Palette_HintRun", "run")), Hint("Esc", L.T("Agents_HintClose", "close")));
        hints.Padding = new Thickness(16, 8, 16, 8);
        AutomationProperties.SetAccessibilityView(hints, AccessibilityView.Raw);
        card.Child = Ui.V(0, top, Ui.Line(), results, Ui.Line(), hints);
        card.Width = 560;
        card.HorizontalAlignment = HorizontalAlignment.Center;
        card.VerticalAlignment = VerticalAlignment.Top;
        card.Margin = new Thickness(0, 72, 0, 0);
        card.CornerRadius = new CornerRadius(14);
        card.Background = Palette.Brush("raised");
        card.BorderBrush = Palette.Brush("text", 0.14);
        card.BorderThickness = new Thickness(1);
        card.Shadow = new ThemeShadow();
        card.Translation = new System.Numerics.Vector3(0, 0, 32);
        card.Tapped += (_, e) => e.Handled = true;
        AutomationProperties.SetName(card, L.T("Palette_Name", "Command palette"));
        AutomationProperties.SetLandmarkType(card, AutomationLandmarkType.Search);

        overlay.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x24, 0, 0, 0));
        overlay.Children.Add(card);
        overlay.TabFocusNavigation = KeyboardNavigationMode.Cycle;
        overlay.RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default;
        overlay.Tapped += (_, _) => Close();
        overlay.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Escape) return;
            e.Handled = true;
            Close();
        };
        TextZoom.ApplyWhenLoaded(overlay);
        Resize();
        root.Changed += OnRootChanged;

        popup.XamlRoot = root;
        popup.Child = overlay;
        popup.Closed += (_, _) => Cleanup();
        popup.IsOpen = true;
        Animate();
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);

        Rebuild(true);
        LoadRepos().Forget();
    }

    private void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Resize();

    private void Resize()
    {
        overlay.Width = root.Size.Width;
        overlay.Height = root.Size.Height;
    }

    private void Animate()
    {
        if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) return;
        var move = new TranslateTransform { Y = -10 };
        card.RenderTransform = move;
        card.Opacity = 0;
        overlay.Opacity = 0;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var story = new Storyboard();
        void Add(DependencyObject target, string property, double from, double to, int ms)
        {
            var a = new DoubleAnimation { From = from, To = to, Duration = TimeSpan.FromMilliseconds(ms), EasingFunction = ease };
            Storyboard.SetTarget(a, target);
            Storyboard.SetTargetProperty(a, property);
            story.Children.Add(a);
        }
        Add(overlay, "Opacity", 0, 1, 120);
        Add(card, "Opacity", 0, 1, 160);
        Add(move, "Y", -10, 0, 200);
        story.Begin();
    }

    private void Close()
    {
        if (popup.IsOpen) popup.IsOpen = false;
        else Cleanup();
    }

    private void Cleanup()
    {
        if (current != this) return;
        current = null;
        searchCts?.Cancel();
        root.Changed -= OnRootChanged;
        if (previousFocus is { } focus) focus.Focus(FocusState.Programmatic);
    }

    private static FrameworkElement Hint(string key, string text)
    {
        var k = new Border { Background = Palette.Brush("text", 0.08), CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 0, 5, 1), Child = Ui.Text(key, 11.5, "muted", mono: true) };
        return Ui.H(4, k, Ui.Text(text, 12, "muted"));
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                Move(1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                Move(-1);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                if (list.SelectedItem is PaletteCommand c) Run(c);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                Close();
                e.Handled = true;
                break;
            case VirtualKey.K when Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down):
                Close();
                e.Handled = true;
                break;
        }
    }

    private void Move(int delta)
    {
        var commands = rows.Count(r => r is PaletteCommand);
        if (commands == 0) return;
        var i = list.SelectedIndex < 0 ? -1 : list.SelectedIndex;
        for (var step = 0; step < rows.Count; step++)
        {
            i = ((i + delta) % rows.Count + rows.Count) % rows.Count;
            if (rows[i] is PaletteCommand) break;
        }
        list.SelectedIndex = i;
        list.ScrollIntoView(rows[i]);
        if (i <= 1) list.ScrollIntoView(rows[0]);
    }

    private void Announce()
    {
        if (list.SelectedItem is not PaletteCommand c || c.Label == lastAnnounced) return;
        lastAnnounced = c.Label;
        var peer = FrameworkElementAutomationPeer.FromElement(box) ?? FrameworkElementAutomationPeer.CreatePeerForElement(box);
        peer?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.MostRecent, c.Label, "palette-selection");
    }

    private void Run(PaletteCommand command)
    {
        Close();
        try
        {
            command.Run();
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "palette command failed");
        }
    }

    private void Rebuild(bool resetSelection)
    {
        var tokens = PaletteMatch.Tokens(box.Text);
        var searching = tokens.Length > 0;
        var selectedId = resetSelection ? null : (list.SelectedItem as PaletteCommand)?.Id;
        var next = new List<object>();
        foreach (var section in Enum.GetValues<PaletteSection>())
        {
            var ranked = PaletteMatch.Rank(Commands(section), tokens, c => c.Title, c => c.Detail + " " + c.Keywords).Take(Limit(section, searching)).ToList();
            if (ranked.Count == 0) continue;
            next.Add(new PaletteHeader(SectionTitle(section)));
            next.AddRange(ranked);
        }
        rows = next;
        list.ItemsSource = rows;
        var index = selectedId is null ? -1 : rows.FindIndex(r => r is PaletteCommand c && c.Id == selectedId);
        if (index < 0) index = rows.FindIndex(r => r is PaletteCommand);
        if (index >= 0) list.SelectedIndex = index;
        empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        list.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private List<PaletteCommand> Commands(PaletteSection section) => section switch
    {
        PaletteSection.Link => LinkCommands(),
        PaletteSection.GoTo => GoToCommands(),
        PaletteSection.Items => ItemCommands(),
        PaletteSection.Repos => RepoCommands(),
        _ => ActionCommands()
    };

    private List<PaletteCommand> LinkCommands()
    {
        var query = box.Text.Trim();
        if (app.Api is null || GitHubUrl.Parse(query) is not { } route) return new();
        void Go() => app.Open(route);
        var command = route.Kind switch
        {
            RouteKind.PullRequest => new PaletteCommand("link", PaletteSection.Link, "", "green", L.F("Palette_OpenItem", "Open {0}", route.Item!.Title), Go) { Detail = L.T("Palette_PullRequest", "Pull request") },
            RouteKind.Issue => new PaletteCommand("link", PaletteSection.Link, "", "green", L.F("Palette_OpenItem", "Open {0}", route.Item!.Title), Go) { Detail = L.T("Palette_Issue", "Issue") },
            RouteKind.Repo => new PaletteCommand("link", PaletteSection.Link, "", "teal", L.F("Palette_OpenItem", "Open {0}", route.Repo!.Full), Go) { Detail = L.T("Palette_Repository", "Repository") },
            RouteKind.Commit => new PaletteCommand("link", PaletteSection.Link, "", "muted", L.F("Palette_OpenItem", "Open {0}", $"{route.Repo!.Full}@{(route.Sha ?? "")[..Math.Min(7, (route.Sha ?? "").Length)]}"), Go) { Detail = L.T("Palette_Commit", "Commit") },
            _ => new PaletteCommand("link", PaletteSection.Link, "", "indigo", L.F("Palette_OpenItem", "Open {0}", route.Project?.Title ?? query), Go) { Detail = L.T("Palette_Project", "Project") }
        };
        return new() { command };
    }

    private PaletteCommand Destination(Section section, string title, string glyph, string color, string group, string? shortcut = null) =>
        new("go-" + section.Key, PaletteSection.GoTo, glyph, color, title, () => app.Section = section) { Detail = group, Shortcut = shortcut, Keywords = "go open show" };

    private static string? SectionShortcut(Section section) => section.Key switch
    {
        "prs:ReviewRequested" => "Ctrl+1",
        "prs:Mine" => "Ctrl+2",
        "Notifications" => "Ctrl+3",
        "Repos" => "Ctrl+4",
        "Projects" => "Ctrl+5",
        "Claude" => "Ctrl+6",
        _ => null
    };

    private List<PaletteCommand> GoToCommands()
    {
        var output = new List<PaletteCommand>();
        void Add(Section s, string title, string glyph, string color, string group) => output.Add(Destination(s, title, glyph, color, group, SectionShortcut(s)));
        if (app.Forge is not null)
        {
            var caps = app.ForgeCaps;
            var provider = app.Provider;
            if (caps.HasInbox) Add(Section.Notifications, caps.Inbox.Title(), "", "amber", L.T("Nav_Inbox", "Inbox"));
            foreach (var f in caps.PullFilters) Add(Section.Prs(f.Filter()), f.Filter().Title(), f.Filter().Glyph(), f.Filter().ColorKey(), provider.RequestsTitle());
            if (caps.PullFilters.Contains(ForgeFilter.Mine)) Add(Section.MyPrsByRepo, provider.ByProjectTitle(), "", "coral", provider.RequestsTitle());
            foreach (var f in caps.IssueFilters) Add(Section.Issues(f.Filter()), f.Filter().Title(), f.Filter().Glyph(), f.Filter().ColorKey(), L.T("Nav_Issues", "Issues"));
            if (caps.Repositories) Add(Section.Repos, provider.RepositoriesTitle(), "", "teal", L.T("Nav_Code", "Code"));
        }
        else
        {
            Add(Section.Notifications, L.T("Section_Notifications", "Notifications"), "", "amber", L.T("Nav_Inbox", "Inbox"));
            foreach (var f in Enum.GetValues<PRFilter>()) Add(Section.Prs(f), f.Title(), f.Glyph(), f.ColorKey(), L.T("Nav_PullRequests", "Pull requests"));
            Add(Section.MyPrsByRepo, L.T("Section_MyPrsByProject", "My PRs by project"), "", "coral", L.T("Nav_PullRequests", "Pull requests"));
            Add(Section.Stacks, L.T("Section_Stacks", "Stacks"), "", "indigo", L.T("Nav_PullRequests", "Pull requests"));
            foreach (var f in Enum.GetValues<IssueFilter>()) Add(Section.Issues(f), f.Title(), f.Glyph(), f.ColorKey(), L.T("Nav_Issues", "Issues"));
            Add(Section.Repos, L.T("Section_Repositories", "Repositories"), "", "teal", L.T("Nav_Code", "Code"));
            Add(Section.Projects, L.T("Section_Projects", "Projects"), "", "indigo", L.T("Nav_Code", "Code"));
        }
        Add(Section.Claude, L.T("Section_Claude", "Agents"), "", "coral", L.T("Nav_AI", "AI"));
        output.Add(new PaletteCommand("go-settings", PaletteSection.GoTo, "", "slate", L.T("Palette_Settings", "Settings"), app.RequestSettings) { Detail = Core.AppInfo.DisplayName, Shortcut = "Ctrl+,", Keywords = "preferences options" });
        return output;
    }

    private List<SearchItem> KnownItems()
    {
        var cached = SearchListViewModel.CachedItems.Concat(ForgeListViewModel.CachedItems).OrderByDescending(i => i.UpdatedAt);
        var seen = new HashSet<string>();
        return found.Concat(app.ReviewRequests).Concat(app.MyPRs).Concat(cached).Where(i => seen.Add(i.Id)).ToList();
    }

    private List<PaletteCommand> ItemCommands()
    {
        var items = KnownItems();
        var byRoute = new Dictionary<Route, SearchItem>();
        foreach (var i in items) byRoute.TryAdd(i.Route, i);
        var seen = new HashSet<string>();
        var output = new List<PaletteCommand>();
        foreach (var route in app.RecentRoutes)
        {
            if (route.Kind is not (RouteKind.PullRequest or RouteKind.Issue) || route.Item is not { } item) continue;
            if (byRoute.TryGetValue(route, out var known))
            {
                if (seen.Add(known.Id)) output.Add(ItemCommand(known, true));
                continue;
            }
            var pr = route.Kind == RouteKind.PullRequest;
            var target = route;
            output.Add(new PaletteCommand("recent-" + route.Key, PaletteSection.Items, pr ? "" : "", "muted", item.Title, () => app.Open(target))
            {
                Detail = L.T("Palette_Recent", "Recently viewed"),
                Keywords = $"{item.Number} {(pr ? "pr pull request" : "issue")}"
            });
        }
        foreach (var i in items.Where(i => !seen.Contains(i.Id))) output.Add(ItemCommand(i, false));
        return output;
    }

    private PaletteCommand ItemCommand(SearchItem item, bool recent)
    {
        var state = item.VisualState;
        var detail = $"{item.Repo.Full}#{item.Number}" + (recent ? " · " + L.T("Palette_Recent", "Recently viewed") : "");
        return new PaletteCommand("item-" + item.Id, PaletteSection.Items, state.Glyph(), state.ColorKey(), item.Title, () => OpenItem(item))
        {
            Detail = detail,
            Keywords = $"{item.Number} {item.Author?.Login ?? ""} {(item.IsPR ? "pr pull request" : "issue")} {state.Title()}"
        };
    }

    private void OpenItem(SearchItem item)
    {
        if (app.Forge is not null)
        {
            if (app.Section.Kind == SectionKind.Claude || !app.ForgeSupports(app.Section))
                app.Section = Section.Prs(app.ForgeCaps.PullFilters.FirstOrDefault(ForgeFilter.Mine).Filter());
            app.ForgeSelection = item;
        }
        else
        {
            app.Open(item.Route);
        }
    }

    private List<PaletteCommand> RepoCommands()
    {
        if (app.Api is null || app.Forge is not null) return new();
        var repos = app.Account is { } account && RepoCache.TryGetValue(account, out var cached) ? cached : new List<RepoSummary>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var output = new List<PaletteCommand>();
        foreach (var route in app.RecentRoutes)
        {
            if (route.Kind != RouteKind.Repo || route.Repo is not { } repo || !seen.Add(repo.Full)) continue;
            var summary = repos.FirstOrDefault(r => string.Equals(r.NameWithOwner, repo.Full, StringComparison.OrdinalIgnoreCase));
            output.Add(RepoCommand(repo, summary?.IsPrivate ?? false, L.T("Palette_Recent", "Recently viewed")));
        }
        foreach (var r in repos.Where(r => !r.IsArchived).OrderByDescending(r => r.PushedAt ?? DateTimeOffset.MinValue))
        {
            if (r.Ref is not { } repo || !seen.Add(repo.Full)) continue;
            output.Add(RepoCommand(repo, r.IsPrivate, r.Description ?? ""));
        }
        return output;
    }

    private PaletteCommand RepoCommand(RepoRef repo, bool locked, string detail) =>
        new("repo-" + repo.Full, PaletteSection.Repos, locked ? "" : "", "teal", repo.Full, () => app.Open(Route.ForRepo(repo))) { Detail = detail, Keywords = repo.Name };

    private string? CurrentUrl()
    {
        if (app.Section.Kind == SectionKind.Claude) return null;
        if (app.Forge is not null) return app.ForgeSelection?.Url;
        if (ShellView.Current?.CurrentRoute is not { } route) return null;
        var host = "https://" + (app.Api?.Host ?? GitProviders.GitHubHost);
        string? Known(Route r) => KnownItems().FirstOrDefault(i => i.Route == r)?.Url;
        return route.Kind switch
        {
            RouteKind.PullRequest => Known(route) ?? $"{host}/{route.Item!.Repo.Full}/pull/{route.Item.Number}",
            RouteKind.Issue => Known(route) ?? $"{host}/{route.Item!.Repo.Full}/issues/{route.Item.Number}",
            RouteKind.Repo => $"{host}/{route.Repo!.Full}",
            RouteKind.Commit => $"{host}/{route.Repo!.Full}/commit/{route.Sha}",
            RouteKind.Project => route.Project?.Url,
            _ => null
        };
    }

    private List<PaletteCommand> ActionCommands()
    {
        var output = new List<PaletteCommand>
        {
            new("refresh", PaletteSection.Actions, "", "sky", L.T("Palette_Refresh", "Refresh"), app.Refresh) { Shortcut = "Ctrl+R", Keywords = "reload sync" }
        };
        output.Add(new PaletteCommand("open-link", PaletteSection.Actions, "\uE71B", "sky", L.T("Palette_OpenByLink", "Open by Link…"), app.RequestOpenLink) { Shortcut = "Ctrl+L", Keywords = "url paste" });
        if (ClaudeAccountStore.Shared.IsLoggedIn)
            output.Add(new PaletteCommand("quick-open", PaletteSection.Actions, "\uE945", "coral", L.T("Palette_GoToSession", "Go to Session…"), () => AgentQuickOpen.Show(root).Forget()) { Detail = L.T("Section_Claude", "Agents"), Shortcut = "Ctrl+Shift+K", Keywords = "agent session" });
        if (ShellView.Current is { } shell)
        {
            var title = shell.IsPaneOpen ? L.T("Palette_HidePane", "Hide Navigation Pane") : L.T("Palette_ShowPane", "Show Navigation Pane");
            output.Add(new PaletteCommand("pane", PaletteSection.Actions, "", "muted", title, shell.TogglePane) { Keywords = "toggle sidebar navigation menu" });
        }
        if (CurrentUrl() is { } url)
        {
            output.Add(new PaletteCommand("browser", PaletteSection.Actions, "", "sky", L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(url)) { Detail = L.T("Palette_CurrentItem", "Current item"), Keywords = "web github" });
            output.Add(new PaletteCommand("copy-link", PaletteSection.Actions, "", "muted", L.T("Menu_CopyLink", "Copy Link"), () =>
            {
                WindowInterop.Copy(url);
                ShellView.Toast(L.T("Palette_CopiedLink", "Copied link"));
            }) { Detail = L.T("Palette_CurrentItem", "Current item"), Keywords = "url clipboard" });
        }
        var appearance = ThemeService.Appearance;
        foreach (var (mode, glyph, title) in new[]
        {
            (AppearanceMode.Auto, "", L.T("Settings_MatchSystem", "Match system")),
            (AppearanceMode.Light, "", L.T("Settings_Light", "Light")),
            (AppearanceMode.Dark, "", L.T("Settings_Dark", "Dark"))
        })
        {
            var m = mode;
            output.Add(new PaletteCommand("appearance-" + mode, PaletteSection.Actions, glyph, "amber", L.F("Palette_Appearance", "Appearance: {0}", title), () => ThemeService.Appearance = m)
            {
                Detail = mode == appearance ? L.T("Palette_Current", "Current") : "",
                Keywords = "theme mode light dark auto"
            });
        }
        foreach (var (style, title) in new[] { (ThemeStyle.PullYard, Core.AppInfo.DisplayName), (ThemeStyle.System, L.T("Settings_System", "System")) })
        {
            var s = style;
            output.Add(new PaletteCommand("style-" + style, PaletteSection.Actions, "", "violet", L.F("Palette_Theme", "Theme: {0}", title), () => ThemeService.Style = s)
            {
                Detail = style == ThemeService.Style ? L.T("Palette_Current", "Current") : "",
                Keywords = "theme style colors"
            });
        }
        foreach (var account in app.Accounts.All.Where(a => a.Id != app.GitAccount?.Id))
        {
            var target = account;
            output.Add(new PaletteCommand("account-" + account.Id, PaletteSection.Actions, "", "violet", L.F("Palette_SwitchTo", "Switch to {0}", account.Subtitle), () => AccountDialogs.Switch(root, target).Forget())
            {
                Detail = account.Provider.Title(),
                Keywords = "account switch"
            });
        }
        if (TextZoom.CanZoomIn) output.Add(new PaletteCommand("zoom-in", PaletteSection.Actions, "", "muted", L.T("Palette_ZoomIn", "Zoom In"), TextZoom.ZoomIn) { Shortcut = "Ctrl+=", Keywords = "text size bigger" });
        if (TextZoom.CanZoomOut) output.Add(new PaletteCommand("zoom-out", PaletteSection.Actions, "", "muted", L.T("Palette_ZoomOut", "Zoom Out"), TextZoom.ZoomOut) { Shortcut = "Ctrl+-", Keywords = "text size smaller" });
        if (!TextZoom.IsDefault) output.Add(new PaletteCommand("zoom-reset", PaletteSection.Actions, "", "muted", L.T("Palette_ActualSize", "Actual Size"), TextZoom.Reset) { Shortcut = "Ctrl+0", Keywords = "text size zoom reset" });
        output.Add(new PaletteCommand("updates", PaletteSection.Actions, "", "sky", L.T("Menu_CheckForUpdates", "Check for Updates…"), () => app.Updater.Check(true).Forget()) { Keywords = "version upgrade" });
        return output;
    }

    private async Task LoadRepos()
    {
        if (app.Api is not { } api || app.Forge is not null || app.Account is not { } account || RepoCache.ContainsKey(account)) return;
        try
        {
            var r = await api.Repos(null);
            RepoCache[account] = r.Nodes;
            if (current == this) Rebuild(false);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "palette repositories failed");
        }
    }

    private void Search()
    {
        searchCts?.Cancel();
        var q = box.Text.Trim();
        if (app.Api is not { } api || app.Forge is not null || q.Length < 3 || GitHubUrl.Parse(q) is not null)
        {
            SetSearching(false);
            if (found.Count > 0)
            {
                found = new();
                Rebuild(false);
            }
            return;
        }
        var cts = new CancellationTokenSource();
        searchCts = cts;
        Query().Forget();

        async Task Query()
        {
            try
            {
                await Task.Delay(350, cts.Token);
                SetSearching(true);
                var result = await api.Search(Demo.Query($"{q} involves:@me sort:updated-desc"), ct: cts.Token);
                if (cts.IsCancellationRequested || current != this) return;
                found = result.Nodes;
                Rebuild(false);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "palette search failed");
            }
            finally
            {
                if (searchCts == cts) SetSearching(false);
            }
        }
    }

    private void SetSearching(bool on) => leading.Content = on ? Ui.Spinner(14) : Ui.Glyph("", 14, "muted");
}
