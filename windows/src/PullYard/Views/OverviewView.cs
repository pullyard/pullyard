using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
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

public sealed class OverviewView : Grid
{
    private static readonly FontFamily Serif = new("Sitka Display, Sitka Text, Georgia");
    private static readonly TimeSpan Fresh = TimeSpan.FromSeconds(120);
    private const string Dash = "–";

    private static (string? Account, OverviewCounts Counts)? latest;
    private static GitHubApi? loadingApi;
    private static Task? loading;

    public static OverviewCounts? Latest => latest is { } l && l.Account == AppViewModel.Shared.Account ? l.Counts : null;

    public static string? LatestError { get; private set; }

    public static event Action? LatestChanged;

    public static Task LoadLatest(bool force = false)
    {
        var app = AppViewModel.Shared;
        if (app.Api is not { } api) return Task.CompletedTask;
        if (loading is { IsCompleted: false } && ReferenceEquals(loadingApi, api)) return loading;
        if (!force && Latest is { } current && DateTimeOffset.Now - current.LoadedAt < Fresh) return Task.CompletedTask;
        loadingApi = api;
        loading = Fetch(api, app.Account);
        return loading;
    }

    private static async Task Fetch(GitHubApi api, string? account)
    {
        try
        {
            var counts = await OverviewCounts.Load(api);
            if (!ReferenceEquals(AppViewModel.Shared.Api, api)) return;
            var previous = latest is { } l && l.Account == account ? l.Counts : null;
            latest = (account, counts.Over(previous));
            LatestError = null;
        }
        catch (Exception e)
        {
            if (!ReferenceEquals(AppViewModel.Shared.Api, api)) return;
            LatestError = e.Message;
        }
        LatestChanged?.Invoke();
    }

    private sealed record TileSpec(OverviewTile? Query, bool Inbox, string Title, string Glyph, string Tint, Section? Section);

    private sealed record Tile(TileSpec Spec, Button Button, TextBlock Number, Counter Counter);

    private sealed class Counter
    {
        private readonly TextBlock text;
        private readonly Func<int, string> format;
        private DispatcherTimer? timer;
        private int? shown;

        public Counter(TextBlock text, Func<int, string>? format = null)
        {
            this.text = text;
            this.format = format ?? (n => n.ToString(Fmt.Culture));
        }

        public void Set(int? value)
        {
            if (value is not { } target)
            {
                if (shown is not null) return;
                Stop();
                text.Text = Dash;
                return;
            }
            if (shown == target) return;
            var from = shown ?? 0;
            shown = target;
            Stop();
            if (!Motion.Enabled || from == target)
            {
                text.Text = format(target);
                return;
            }
            var started = DateTimeOffset.Now;
            var duration = TimeSpan.FromMilliseconds(Math.Clamp(320 + Math.Abs(target - from) * 25, 320, 900));
            var tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
            tick.Tick += (_, _) =>
            {
                var t = Math.Min(1, (DateTimeOffset.Now - started) / duration);
                var eased = 1 - Math.Pow(1 - t, 3);
                text.Text = format((int)Math.Round(from + (target - from) * eased));
                if (t < 1) return;
                tick.Stop();
                if (ReferenceEquals(timer, tick)) timer = null;
            };
            timer = tick;
            text.Text = format(from);
            tick.Start();
        }

        public void Stop()
        {
            timer?.Stop();
            timer = null;
        }

        public void Reset()
        {
            Stop();
            shown = null;
            text.Text = Dash;
        }
    }

    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly Action<Section> openSection;
    private readonly Action<string, string> openQuery;
    private readonly LiveRefresh live;
    private ClaudeWorkspace? workspace;
    private bool subscribed;
    private bool appeared;

    private readonly StackPanel page = Ui.V(22);
    private readonly TextBlock greeting = Ui.Text("", 13.5, "muted", FontWeights.Medium);
    private readonly TextBlock firstName = Ui.Text("", 30, "text", FontWeights.SemiBold);
    private readonly TextBlock summary = Ui.Text("", 13, "muted", wrap: true);

    private readonly TextBlock heroNumber = Ui.Text(Dash, 52, "coral", FontWeights.Bold);
    private readonly TextBlock heroLabel = Ui.Text("", 18, "text", FontWeights.SemiBold);
    private readonly StackPanel heroQueue;
    private readonly StackPanel heroBody = Ui.V(10);
    private readonly Border heroGlow = new() { CornerRadius = new CornerRadius(16), IsHitTestVisible = false };
    private readonly Counter heroCounter;
    private string? heroSignature;

    private readonly Grid tileGrid = new() { ColumnSpacing = 14, RowSpacing = 14 };
    private readonly List<Tile> tiles = new();
    private int tileColumns;
    private readonly StackPanel status = Ui.H(8);

    private readonly TextBlock agentLine = Ui.Text("", 13, "muted", wrap: true);
    private readonly FrameworkElement agentSpinner = Ui.Spinner(16);

    private readonly StackPanel recent = Ui.V(10);
    private readonly WrapPanel recentChips = new(8) { VerticalSpacing = 8 };
    private string? recentSignature;

    public OverviewView(Action<Section> openSection, Action<string, string> openQuery)
    {
        this.openSection = openSection;
        this.openQuery = openQuery;
        heroCounter = new Counter(heroNumber);
        heroQueue = Ui.H(4, Ui.Text(L.T("Overview_OpenQueue", "Open queue"), 13, "link", FontWeights.SemiBold), Ui.Glyph("", 10, "link"));
        firstName.FontFamily = Serif;
        summary.TextAlignment = TextAlignment.Right;
        summary.MaxWidth = 360;
        status.Visibility = Visibility.Collapsed;
        recent.Visibility = Visibility.Collapsed;

        page.Children.Add(BuildHeader());
        page.Children.Add(BuildHero());
        page.Children.Add(BuildTiles());
        page.Children.Add(status);
        page.Children.Add(BuildAgents());
        page.Children.Add(BuildRecent());
        page.Padding = new Thickness(32, 28, 32, 32);
        page.MaxWidth = 1080;
        page.HorizontalAlignment = HorizontalAlignment.Stretch;
        page.SizeChanged += (_, e) => LayoutTiles(e.NewSize.Width);

        Children.Add(new ScrollViewer
        {
            Content = page,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled
        });
        AutomationProperties.SetName(this, L.T("Overview_Title", "Overview"));

        live = new LiveRefresh(this, OnLive);
        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => Detach();
    }

    private void Attach()
    {
        if (subscribed) return;
        subscribed = true;
        app.PropertyChanged += OnModel;
        app.RefreshRequested += OnRefresh;
        app.LiveTick += live.Tick;
        LatestChanged += OnLatest;
        workspace = app.Claude;
        if (workspace is not null) workspace.PropertyChanged += OnWorkspace;
        heroSignature = null;
        recentSignature = null;
        RenderAll();
        if (!appeared)
        {
            appeared = true;
            if (Motion.Enabled)
                for (var i = 0; i < tiles.Count; i++) Rise(tiles[i].Button, TimeSpan.FromMilliseconds(50 + i * 30));
        }
        LoadLatest(force: Latest is null).Forget();
    }

    private void Detach()
    {
        subscribed = false;
        app.PropertyChanged -= OnModel;
        app.RefreshRequested -= OnRefresh;
        app.LiveTick -= live.Tick;
        LatestChanged -= OnLatest;
        if (workspace is not null) workspace.PropertyChanged -= OnWorkspace;
        workspace = null;
        heroCounter.Stop();
        foreach (var tile in tiles) tile.Counter.Stop();
    }

    private void OnRefresh() => LoadLatest(force: true).Forget();

    private void OnLive()
    {
        LoadLatest().Forget();
        RenderHeader();
        RenderAgents();
        RenderRecent();
    }

    private void OnLatest()
    {
        RenderHeader();
        RenderHero();
        RenderTiles();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppViewModel.Api):
            case nameof(AppViewModel.Account):
                heroCounter.Reset();
                foreach (var tile in tiles) tile.Counter.Reset();
                heroSignature = null;
                recentSignature = null;
                RenderAll();
                LoadLatest(force: true).Forget();
                break;
            case nameof(AppViewModel.User):
                RenderHeader();
                break;
            case nameof(AppViewModel.ReviewRequests):
            case nameof(AppViewModel.ReviewRequestCount):
            case nameof(AppViewModel.LastBadgeRefresh):
                RenderHero();
                RenderTiles();
                break;
            case nameof(AppViewModel.MyPRCount):
            case nameof(AppViewModel.UnreadCount):
            case nameof(AppViewModel.Forge):
            case nameof(AppViewModel.ForgeCaps):
                RenderTiles();
                break;
            case nameof(AppViewModel.DetailRoot):
                RenderRecent();
                break;
        }
    }

    private void OnWorkspace(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ClaudeWorkspace.RunningCount) or nameof(ClaudeWorkspace.AttentionCount)) RenderAgents();
    }

    private void RenderAll()
    {
        RenderHeader();
        RenderHero();
        RenderTiles();
        RenderAgents();
        RenderRecent();
    }

    private bool BadgesKnown => app.LastBadgeRefresh is not null || Demo.IsOn;

    private bool Supported(Section section) => app.Forge is null || app.ForgeSupports(section);

    private static Button Pressable(UIElement content, Action onClick, Brush rest, Brush hover, Brush border, Brush hoverBorder, double radius, Thickness padding)
    {
        var b = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Padding = padding,
            CornerRadius = new CornerRadius(radius),
            Background = rest,
            BorderBrush = border,
            BorderThickness = new Thickness(1)
        };
        b.Resources["ButtonBackgroundPointerOver"] = hover;
        b.Resources["ButtonBackgroundPressed"] = hover;
        b.Resources["ButtonBorderBrushPointerOver"] = hoverBorder;
        b.Resources["ButtonBorderBrushPressed"] = hoverBorder;
        b.Click += (_, _) => onClick();
        return b;
    }

    private static SolidColorBrush NoFill => new(Microsoft.UI.Colors.Transparent);

    private static void Rise(UIElement element, TimeSpan delay)
    {
        var shift = new TranslateTransform { Y = 8 };
        element.RenderTransform = shift;
        element.Opacity = 0;
        var length = new Duration(TimeSpan.FromMilliseconds(450));
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var fade = new DoubleAnimation { From = 0, To = 1, Duration = length, BeginTime = delay, EasingFunction = ease };
        Storyboard.SetTarget(fade, element);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var slide = new DoubleAnimation { From = 8, To = 0, Duration = length, BeginTime = delay, EasingFunction = ease };
        Storyboard.SetTarget(slide, shift);
        Storyboard.SetTargetProperty(slide, "Y");
        var board = new Storyboard();
        board.Children.Add(fade);
        board.Children.Add(slide);
        board.Completed += (_, _) =>
        {
            element.Opacity = 1;
            shift.Y = 0;
            board.Stop();
        };
        board.Begin();
    }

    private UIElement BuildHeader()
    {
        var words = Ui.V(2, greeting, firstName);
        var refresh = Ui.RefreshButton(() => Task.WhenAll(LoadLatest(force: true), app.RefreshBadges()));
        var right = Ui.H(8, summary, refresh);
        right.VerticalAlignment = VerticalAlignment.Bottom;
        var grid = Ui.Columns((words, Ui.Star), (right, Ui.Auto));
        grid.ColumnSpacing = 12;
        return grid;
    }

    private void RenderHeader()
    {
        var hour = DateTime.Now.Hour;
        greeting.Text = hour switch
        {
            >= 5 and < 12 => L.T("Overview_GoodMorning", "Good morning"),
            >= 12 and < 18 => L.T("Overview_GoodAfternoon", "Good afternoon"),
            _ => L.T("Overview_GoodEvening", "Good evening")
        };
        var user = app.User;
        var first = user?.Name?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        firstName.Text = first is { Length: > 0 } ? first : user?.Login is { Length: > 0 } login ? login : L.T("Overview_Reviewer", "Reviewer");
        var parts = new List<string>();
        if (Latest is { } counts)
        {
            if (counts[OverviewTile.Failing] is int failing && failing > 0)
                parts.Add(failing == 1 ? L.F("Overview_FailingOne", "{0} PR with failing checks", failing) : L.F("Overview_FailingMany", "{0} PRs with failing checks", failing));
            if (counts[OverviewTile.ReadyToMerge] is int ready && ready > 0)
                parts.Add(L.F("Overview_ReadyCount", "{0} ready to merge", ready));
        }
        summary.Text = string.Join(" · ", parts);
        summary.Visibility = parts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private UIElement BuildHero()
    {
        var label = Ui.V(2, heroLabel, Ui.Text(L.T("Overview_ForYou", "for you"), 13, "muted"));
        label.VerticalAlignment = VerticalAlignment.Center;
        var head = Ui.Columns((heroNumber, Ui.Auto), (label, Ui.Star), (heroQueue, Ui.Auto));
        head.ColumnSpacing = 12;
        heroQueue.VerticalAlignment = VerticalAlignment.Center;
        var headButton = Pressable(head, () => openSection(Section.Prs(PRFilter.ReviewRequested)), NoFill, Palette.Brush("text", 0.03), NoFill, NoFill, 10, new Thickness(4, 0, 8, 0));
        Ui.Named(headButton, L.T("Overview_OpenReviewQueue", "Open review requests"));
        var content = Ui.V(14, headButton, heroBody);
        content.Padding = new Thickness(20);
        var card = new Grid
        {
            Background = Palette.Brush("raised"),
            BorderBrush = Palette.Brush("cardLine"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16)
        };
        card.Children.Add(heroGlow);
        card.Children.Add(content);
        return card;
    }

    private int? WaitingCount() => BadgesKnown ? app.ReviewRequestCount : Latest?.Waiting;

    private void RenderHero()
    {
        var count = WaitingCount();
        var items = app.ReviewRequests.Take(5).ToList();
        heroCounter.Set(count);
        heroNumber.Foreground = Palette.Brush(count switch
        {
            null => "dim",
            0 => "green",
            _ => "coral"
        });
        heroLabel.Text = count == 1 ? L.T("Overview_ReviewWaiting", "review waiting") : L.T("Overview_ReviewsWaiting", "reviews waiting");
        heroQueue.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var signature = $"{count}|{app.Forge is null}|{string.Join(",", items.Select(i => $"{i.Id}@{i.UpdatedAt.UtcTicks}:{i.CiState}"))}";
        if (signature == heroSignature) return;
        heroSignature = signature;
        heroGlow.Background = count > 0 ? Glow() : null;
        heroBody.Children.Clear();
        if (count == 0)
        {
            var calmTitle = Ui.Text(L.T("Overview_CalmWaters", "Calm waters"), 18, "text", FontWeights.SemiBold);
            calmTitle.FontFamily = Serif;
            var words = Ui.V(4, calmTitle, Ui.Text(L.T("Overview_CalmBody", "Nothing is waiting for your review."), 13, "muted", wrap: true));
            words.VerticalAlignment = VerticalAlignment.Center;
            var calm = Ui.Columns((new DrawnLogoMark("overview-calm", 72), Ui.Auto), (words, Ui.Star));
            calm.ColumnSpacing = 16;
            calm.Padding = new Thickness(0, 4, 0, 4);
            heroBody.Children.Add(calm);
            return;
        }
        if (count is null || items.Count == 0) return;
        var rows = Ui.V(0);
        for (var i = 0; i < items.Count; i++)
        {
            if (i > 0) rows.Children.Add(Ui.Line());
            rows.Children.Add(ReviewRow(items[i]));
        }
        heroBody.Children.Add(rows);
        if (count > items.Count)
        {
            var all = Ui.Link(L.F("Overview_ShowAll", "Show all {0}", count), () => openSection(Section.Prs(PRFilter.ReviewRequested)), 12.5);
            heroBody.Children.Add(all);
        }
    }

    private static LinearGradientBrush Glow()
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0.5, 0.5)
        };
        brush.GradientStops.Add(new GradientStop { Color = Palette.Get("coral", 26), Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = Palette.Get("coral", 0), Offset = 1 });
        return brush;
    }

    private Button ReviewRow(SearchItem item)
    {
        var prefix = app.Forge is null ? "#" : app.Provider.NumberPrefix();
        var title = Ui.Text(item.Title, 13.5, "text", FontWeights.Medium);
        var metaParts = new List<string> { $"{item.Repository.NameWithOwner}{prefix}{item.Number}" };
        if (item.Author?.Login is { Length: > 0 } login) metaParts.Add(login);
        metaParts.Add(Fmt.Rel(item.UpdatedAt));
        var meta = Ui.Text(string.Join(" · ", metaParts), 12, "muted");
        var stat = item.IsPR && item.Additions is { } add && item.Deletions is { } del ? Ui.DiffStat(add, del, 11.5) : null;
        var grid = Ui.Columns(
            (Ui.Avatar(item.Author?.AvatarUrl, 26, ring: true), Ui.Auto),
            (Ui.V(2, title, meta), Ui.Star),
            (Ui.CiIcon(item.CiState, 12), Ui.Auto),
            (stat, Ui.Auto),
            (Ui.Glyph("", 10, "dim"), Ui.Auto));
        grid.ColumnSpacing = 12;
        var route = item.Route;
        var row = Pressable(grid, () => app.Open(route), NoFill, Palette.Brush("text", 0.04), NoFill, NoFill, 8, new Thickness(6, 9, 6, 9));
        row.ContextFlyout = SearchListView.ItemMenu(item);
        Ui.Tip(row, item.Title);
        Ui.Named(row, FeedRow.SpokenLabel(item));
        return row;
    }

    private static IReadOnlyList<TileSpec> TileSpecs() => new TileSpec[]
    {
        new(OverviewTile.Mine, false, L.T("Overview_MyPullRequests", "My pull requests"), PRFilter.Mine.Glyph(), "violet", Section.Prs(PRFilter.Mine)),
        new(OverviewTile.ReadyToMerge, false, L.T("Overview_ReadyToMerge", "Ready to merge"), "", "green", null),
        new(OverviewTile.Failing, false, L.T("Overview_FailingChecks", "Failing checks"), "", "red", null),
        new(OverviewTile.ChangesRequested, false, L.T("Overview_ChangesRequested", "Changes requested"), "", "amber", null),
        new(OverviewTile.Assigned, false, L.T("Overview_Assigned", "Assigned to me"), PRFilter.Assigned.Glyph(), "teal", Section.Prs(PRFilter.Assigned)),
        new(OverviewTile.Mentioned, false, L.T("Overview_Mentioned", "Mentioned"), PRFilter.Mentioned.Glyph(), "indigo", Section.Prs(PRFilter.Mentioned)),
        new(OverviewTile.Reviewed, false, L.T("Overview_ReviewedByMe", "Reviewed by me"), PRFilter.Reviewed.Glyph(), "sky", Section.Prs(PRFilter.Reviewed)),
        new(null, true, L.T("Overview_UnreadInbox", "Unread inbox"), "", "slate", Section.Notifications)
    };

    private UIElement BuildTiles()
    {
        foreach (var spec in TileSpecs())
        {
            var icon = Ui.IconTile(spec.Glyph, spec.Tint == "amber" ? "amberInk" : spec.Tint, 32);
            icon.CornerRadius = new CornerRadius(16);
            icon.Background = Palette.Brush(spec.Tint, 0.14);
            var top = Ui.Columns((icon, Ui.Auto), ((UIElement?)null, Ui.Star), (Ui.Glyph("", 10, "dim"), Ui.Auto));
            var number = Ui.Text(Dash, 28, "dim", FontWeights.Bold);
            var title = Ui.Text(spec.Title, 12.5, "muted", FontWeights.SemiBold);
            var body = Ui.V(10, top, number, title);
            var tileSpec = spec;
            var button = Pressable(body, () => OpenTile(tileSpec), Palette.Brush("raised"), Palette.Brush("raised"), Palette.Brush("cardLine"), Palette.Brush(spec.Tint, 0.45), 14, new Thickness(14));
            Ui.Tip(button, spec.Title);
            tiles.Add(new Tile(spec, button, number, new Counter(number, spec.Inbox ? new Func<int, string>(InboxLabel) : null)));
            tileGrid.Children.Add(button);
        }
        LayoutTiles(0);
        return tileGrid;
    }

    private string InboxLabel(int n) => app.Forge is null ? GitHubApi.CountLabel(n) : n.ToString(Fmt.Culture);

    private void LayoutTiles(double width)
    {
        var columns = width > 0 && width < 640 ? 2 : 4;
        if (columns == tileColumns) return;
        tileColumns = columns;
        tileGrid.ColumnDefinitions.Clear();
        tileGrid.RowDefinitions.Clear();
        for (var c = 0; c < columns; c++) tileGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rows = (tiles.Count + columns - 1) / columns;
        for (var r = 0; r < rows; r++) tileGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < tiles.Count; i++)
        {
            SetColumn(tiles[i].Button, i % columns);
            SetRow(tiles[i].Button, i / columns);
        }
    }

    private bool TileEnabled(TileSpec spec)
    {
        if (spec.Section is { } section) return Supported(section);
        return app.Api is not null;
    }

    private int? TileCount(TileSpec spec)
    {
        if (spec.Inbox) return BadgesKnown ? app.UnreadCount : null;
        if (spec.Query is not { } query) return null;
        if (query == OverviewTile.Mine && BadgesKnown) return app.MyPRCount;
        return Latest?[query];
    }

    private void RenderTiles()
    {
        foreach (var tile in tiles)
        {
            var enabled = TileEnabled(tile.Spec);
            var count = enabled ? TileCount(tile.Spec) : null;
            tile.Button.IsEnabled = enabled;
            if (tile.Button.Content is UIElement body) body.Opacity = enabled ? 1 : 0.55;
            tile.Counter.Set(count);
            tile.Number.Foreground = Palette.TextBrush(count > 0 ? "text" : "dim");
            var spoken = count is { } n ? (tile.Spec.Inbox ? InboxLabel(n) : n.ToString(Fmt.Culture)) : L.T("Overview_Loading", "loading");
            Ui.Named(tile.Button, $"{tile.Spec.Title}, {spoken}");
        }
        var failed = app.Api is not null && Latest is null && LatestError is not null;
        status.Children.Clear();
        status.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        if (!failed) return;
        var message = Ui.Text(LatestError, 12.5, "red", maxLines: 2);
        message.TextWrapping = TextWrapping.WrapWholeWords;
        status.Children.Add(Ui.Glyph("", 12, "red"));
        status.Children.Add(message);
        status.Children.Add(Ui.Link(L.T("Common_Retry", "Retry"), () => LoadLatest(force: true).Forget(), 12.5));
    }

    private void OpenTile(TileSpec spec)
    {
        if (spec.Section is { } section)
        {
            openSection(section);
            return;
        }
        if (spec.Query is { } query) openQuery(spec.Title, OverviewCounts.ListQuery(query));
    }

    private UIElement BuildAgents()
    {
        var icon = Ui.IconTile("", "coral", 40);
        icon.CornerRadius = new CornerRadius(11);
        var words = Ui.V(2, Ui.Text(L.T("Section_Claude", "Agents"), 15, "text", FontWeights.SemiBold), agentLine);
        words.VerticalAlignment = VerticalAlignment.Center;
        var open = Ui.Button(L.T("Overview_OpenAgents", "Open Agents"), () => openSection(Section.Claude));
        var start = Ui.Tint(Ui.Button(L.T("Claude_NewSession", "New session"), NewSession), "coral");
        var buttons = Ui.H(8, open, start);
        buttons.VerticalAlignment = VerticalAlignment.Center;
        agentSpinner.VerticalAlignment = VerticalAlignment.Center;
        var grid = Ui.Columns((icon, Ui.Auto), (words, Ui.Star), (agentSpinner, Ui.Auto), (buttons, Ui.Auto));
        grid.ColumnSpacing = 14;
        return Ui.Card(grid, 16, padding: 16);
    }

    private void NewSession()
    {
        if (ClaudeAccountStore.Shared.IsLoggedIn && XamlRoot is { } root) AgentQuickOpen.Show(root).Forget();
        else openSection(Section.Claude);
    }

    private void RenderAgents()
    {
        var running = workspace?.RunningCount ?? 0;
        var attention = workspace?.AttentionCount ?? 0;
        agentLine.Text = attention > 0
            ? attention == 1 ? L.F("Overview_AgentsNeedYouOne", "{0} session needs you", attention) : L.F("Overview_AgentsNeedYouMany", "{0} sessions need you", attention)
            : running > 0
                ? running == 1 ? L.F("Overview_AgentsWorkingOne", "{0} session working", running) : L.F("Overview_AgentsWorkingMany", "{0} sessions working", running)
                : L.T("Overview_AgentsIdle", "Fix review comments and failing checks with an agent");
        agentLine.Foreground = Palette.TextBrush(attention > 0 ? "coral" : "muted");
        agentSpinner.Visibility = running > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private UIElement BuildRecent()
    {
        var label = Ui.Text(L.T("Overview_RecentlyOpened", "Recently opened").ToUpper(System.Globalization.CultureInfo.CurrentCulture), 11, "muted", FontWeights.SemiBold);
        label.CharacterSpacing = 60;
        recent.Children.Add(Ui.H(6, Ui.Glyph("", 11, "muted"), label));
        recent.Children.Add(recentChips);
        return recent;
    }

    private void RenderRecent()
    {
        var routes = app.RecentRoutes.Where(r => ShortLink.Of(r) is not null).Take(8).ToList();
        var signature = string.Join(",", routes.Select(r => r.Key));
        if (signature == recentSignature) return;
        recentSignature = signature;
        recentChips.Children.Clear();
        foreach (var route in routes)
        {
            var text = ShortLink.Of(route)!;
            var target = route;
            var chip = Pressable(Ui.Text(text, 12.5, "text", mono: true), () => app.Open(target), Palette.Brush("raised"), Palette.Brush("hover"), Palette.Brush("cardLine"), Palette.Brush("lineStrong"), 14, new Thickness(12, 6, 12, 7));
            chip.HorizontalAlignment = HorizontalAlignment.Left;
            chip.VerticalAlignment = VerticalAlignment.Top;
            Ui.Tip(chip, text);
            recentChips.Children.Add(chip);
        }
        recent.Visibility = routes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
