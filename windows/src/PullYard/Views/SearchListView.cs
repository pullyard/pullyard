using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed class SearchListView : ListPane
{
    private readonly string kind;
    private readonly string baseQuery;
    private readonly bool grouped;
    private static readonly Dictionary<string, string> RememberedText = new();

    private readonly SearchListViewModel vm = new();
    private readonly string memoryKey;
    private StateFilter stateFilter = StateFilter.Open;
    private ListSort sort = ListSort.Updated;
    private string text = "";
    private readonly HashSet<string> collapsed = new();
    private readonly TextBox filterBox;
    private readonly DropDownButton sortButton = new() { Padding = new Thickness(8, 4, 8, 4), VerticalAlignment = VerticalAlignment.Center };
    private bool syncing;

    public SearchListView(string title, string kind, string baseQuery, bool grouped) : base(title, "FeedRowTemplate")
    {
        this.kind = kind;
        this.baseQuery = baseQuery;
        this.grouped = grouped;
        memoryKey = $"search|{kind}|{baseQuery}{(grouped ? "|grouped" : "")}";
        if (Enum.TryParse<StateFilter>(Settings.Shared.GetString(Keys.ListStatePrefix + kind), out var storedState) && Enum.IsDefined(storedState)) stateFilter = storedState;
        sort = ListSorts.Parse(Settings.Shared.GetString(Keys.ListSortPrefix + kind));
        if (RememberedText.TryGetValue(memoryKey, out var remembered)) text = remembered;
        var stateBar = StateBar(stateFilter, f =>
        {
            if (f == stateFilter) return;
            stateFilter = f;
            Settings.Shared.Set(Keys.ListStatePrefix + kind, f.ToString());
            Reload().Forget();
        });
        RenderSort();
        FilterRow.Children.Add(Ui.Columns((stateBar, Ui.Star), (sortButton, Ui.Auto)));
        filterBox = SearchBox(L.T("Search_Placeholder", "Filter: text, repo:org/name, label:bug"), t =>
        {
            var trimmed = t.Trim();
            if (trimmed == text) return;
            text = trimmed;
            if (text.Length == 0) RememberedText.Remove(memoryKey);
            else RememberedText[memoryKey] = text;
            Reload(typing: true).Forget();
        });
        if (text.Length > 0) filterBox.Text = text;
        FilterRow.Children.Add(filterBox);
        List.SelectionChanged += OnSelection;
        List.ItemClick += OnItemClick;
        List.ContainerContentChanging += (_, e) =>
        {
            if (!grouped && e.Item is SearchItem item && vm.Items.Count > 0 && ReferenceEquals(item, vm.Items[^1])) vm.LoadMore(Model.Api).Forget();
        };
        List.ContextRequested += OnContext;
        vm.PropertyChanged += OnVm;
        Model.PropertyChanged += OnModel;
        Unloaded += (_, _) => Model.PropertyChanged -= OnModel;
        Loaded += (_, _) =>
        {
            Model.PropertyChanged -= OnModel;
            Model.PropertyChanged += OnModel;
        };
    }

    private string Query => string.Join(" ", new[] { baseQuery, $"is:{kind}", stateFilter.Query(), "archived:false", sort.Query(), text }.Where(s => s.Length > 0));

    private static string SortTitle(ListSort value) => value switch
    {
        ListSort.Created => L.T("Sort_Newest", "Newest"),
        ListSort.Comments => L.T("Sort_MostCommented", "Most commented"),
        _ => L.T("Sort_RecentlyUpdated", "Recently updated")
    };

    private void RenderSort()
    {
        sortButton.Content = Ui.H(6, Ui.Glyph("\uE8CB", 12, "text"), Ui.Text(SortTitle(sort), 12.5));
        var label = L.F("Sort_Tooltip", "Sort: {0}", SortTitle(sort));
        Ui.Tip(sortButton, label);
        Ui.Named(sortButton, label);
        var menu = new MenuFlyout();
        foreach (var option in ListSorts.All)
        {
            var value = option;
            menu.Items.Add(Ui.CheckItem(SortTitle(value), value == sort, () => SetSort(value)));
        }
        sortButton.Flyout = menu;
    }

    private void SetSort(ListSort value)
    {
        if (value != sort)
        {
            sort = value;
            Settings.Shared.Set(Keys.ListSortPrefix + kind, value.Key());
            Reload().Forget();
        }
        RenderSort();
    }

    private Task LoadMore() => grouped ? vm.LoadAll(Model.Api) : vm.LoadMore(Model.Api);

    protected override void OnAttached() => Reload().Forget();

    protected override void OnLiveTick() => Reload(silent: true).Forget();

    protected override Task OnPullRefresh() => Reload(silent: true);

    private async Task Reload(bool silent = false, bool typing = false)
    {
        await vm.Load(Model.Api, Query, silent || typing, text.Length == 0);
        if (grouped) await vm.LoadAll(Model.Api);
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppViewModel.DetailRoot)) SyncSelection();
        if (e.PropertyName == nameof(AppViewModel.Api)) Reload().Forget();
    }

    private void OnVm(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(SearchListViewModel.Items):
                Appear.Ingest(vm.Items.Select(i => i.Id), vm.AppearMode);
                Render();
                break;
            case nameof(SearchListViewModel.CheckingCache):
            case nameof(SearchListViewModel.Loading):
            case nameof(SearchListViewModel.Refreshing):
            case nameof(SearchListViewModel.Error):
            case nameof(SearchListViewModel.LastUpdated):
            case nameof(SearchListViewModel.Total):
            case nameof(SearchListViewModel.LoadingMore):
            case nameof(SearchListViewModel.LoadMoreError):
                UpdateState();
                break;
        }
    }

    private void UpdateState()
    {
        CountText.Text = vm.Total > 0 ? vm.Total.ToString() : "";
        SetLoading(vm.Loading, vm.Items.Count > 0);
        Footer.Update(vm.LastUpdated, vm.Refreshing && !vm.Loading, vm.Items.Count == 0 ? null : vm.Error);
        var moreError = vm.Items.Count > 0 ? vm.LoadMoreError : null;
        var more = vm.Items.Count > 0 && moreError is null && vm.LoadingMore;
        SetNotice($"{more}|{moreError}",
            moreError is not null ? LoadMoreErrorRow(moreError, () => LoadMore().Forget()) : null,
            more ? LoadingMoreRow() : null);
        if (vm.Items.Count == 0)
        {
            if (vm.CheckingCache) ShowOverlay(null);
            else if (vm.Loading) ShowOverlay(Ui.Loading());
            else if (vm.Error is { } e) ShowOverlay(Ui.Error(e, () => Reload().Forget()));
            else
            {
                var copy = EmptyCopy.Search(kind, baseQuery, stateFilter);
                ShowOverlay(Ui.EmptyState(copy.Title, copy.Message, text, () => filterBox.Text = ""));
            }
        }
        else
        {
            ShowOverlay(null);
        }
    }

    private void Render()
    {
        syncing = true;
        if (grouped)
        {
            var rows = new List<object>();
            foreach (var g in vm.Groups)
            {
                var open = !collapsed.Contains(g.Id) || text.Length > 0;
                rows.Add(new GroupHeaderItem { Group = g, Expanded = open });
                if (open) rows.AddRange(g.Items.Select(i => (object)new GroupedSearchItem(i)));
            }
            List.ItemsSource = rows;
        }
        else
        {
            List.ItemsSource = vm.Items;
        }
        syncing = false;
        SyncSelection();
        UpdateState();
    }

    private void SyncSelection()
    {
        syncing = true;
        var route = Model.DetailRoot;
        object? match = null;
        if (route is not null && List.ItemsSource is System.Collections.IEnumerable items)
        {
            foreach (var i in items)
            {
                var r = i switch
                {
                    SearchItem s => s.Route,
                    GroupedSearchItem g => g.Item.Route,
                    _ => null
                };
                if (r == route)
                {
                    match = i;
                    break;
                }
            }
        }
        List.SelectedItem = match;
        syncing = false;
    }

    private void OnSelection(object sender, SelectionChangedEventArgs e)
    {
        if (syncing) return;
        var route = List.SelectedItem switch
        {
            SearchItem s => s.Route,
            GroupedSearchItem g => g.Item.Route,
            _ => null
        };
        if (route is not null && route != Model.DetailRoot) Model.Select(route);
    }

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is GroupHeaderItem h)
        {
            if (!collapsed.Remove(h.Group.Id)) collapsed.Add(h.Group.Id);
            Render();
        }
    }

    private void OnContext(UIElement sender, Microsoft.UI.Xaml.Input.ContextRequestedEventArgs args)
    {
        var element = args.OriginalSource as FrameworkElement;
        var item = element?.DataContext switch
        {
            SearchItem s => s,
            GroupedSearchItem g => g.Item,
            _ => null
        };
        if (item is null) return;
        args.Handled = true;
        ItemMenu(item).ShowAt(element!);
    }

    public static MenuFlyout ItemMenu(SearchItem item)
    {
        var menu = Ui.Menu(
            Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(item.Url), ""),
            Ui.MenuItem(L.T("Menu_CopyLink", "Copy Link"), () => ShellView.Copied(item.Url, L.T("Toast_CopiedLink", "Copied link")), ""),
            Ui.MenuItem(L.T("Menu_CopyShortLink", "Copy Short Link"), () => ShellView.CopyShortLink(ShortLink.Of(item.Repository.NameWithOwner, item.Number)), "\uE8C8"));
        if (item.IsPR) menu.Items.Add(Ui.MenuItem(L.T("Menu_CopyCheckout", "Copy “gh pr checkout”"), () => CopyCommand($"gh pr checkout {item.Number} -R {item.Repository.NameWithOwner}"), ""));
        return menu;
    }

    public static void CopyCommand(string command) => ShellView.Copied(command, L.F("Toast_CopiedQuoted", "Copied “{0}”", command));
}

public sealed class NotificationsView : ListPane
{
    private List<NotificationThread> items = new();
    private bool loading;
    private int shownLoads;
    private string? error;
    private bool showAll;
    private bool? loadedMode;
    private DateTimeOffset? lastUpdated;
    private bool syncing;
    private string? selectedId;

    public NotificationsView() : base(L.T("Section_Notifications", "Notifications"), "NotificationRowTemplate")
    {
        var bar = new SelectorBar();
        var unread = new SelectorBarItem { Text = L.T("Notifications_Unread", "Unread") };
        var all = new SelectorBarItem { Text = L.T("State_All", "All") };
        bar.Items.Add(unread);
        bar.Items.Add(all);
        bar.SelectedItem = unread;
        bar.SelectionChanged += (s, _) =>
        {
            showAll = s.SelectedItem == all;
            Load(true).Forget();
        };
        FilterRow.Children.Add(bar);
        Tools.Children.Add(Ui.IconButton("", L.T("Notifications_MarkAllRead", "Mark all as read"), () => MarkAll().Forget()));
        List.SelectionChanged += (_, _) =>
        {
            if (syncing) return;
            var n = List.SelectedItem as NotificationThread;
            selectedId = n?.Id;
            if (n?.Route is { } r) Model.Select(r);
            UpdateNotice();
        };
        List.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.E || List.SelectedItem is not NotificationThread n) return;
            if (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) return;
            e.Handled = true;
            MarkDone(n).Forget();
        };
        Loaded += (_, _) =>
        {
            NotificationRow.DoneRequested -= OnRowDone;
            NotificationRow.DoneRequested += OnRowDone;
        };
        Unloaded += (_, _) => NotificationRow.DoneRequested -= OnRowDone;
        OnRowOpen(item =>
        {
            if (item is NotificationThread n) Open(n);
        });
        List.ContextRequested += (s, args) =>
        {
            if ((args.OriginalSource as FrameworkElement)?.DataContext is not NotificationThread n) return;
            args.Handled = true;
            var menu = Ui.Menu(
                n.Unread ? Ui.MenuItem(L.T("Notifications_MarkRead", "Mark as read"), () => MarkRead(n).Forget()) : null,
                Ui.MenuItem(L.T("Notifications_Done", "Done (remove from inbox)"), () => MarkDone(n).Forget()),
                Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(n.WebUrl)),
                ShortLink.Of(n.Route) is { } shortLink ? Ui.MenuItem(L.T("Menu_CopyShortLink", "Copy Short Link"), () => ShellView.CopyShortLink(shortLink)) : null);
            menu.ShowAt((FrameworkElement)args.OriginalSource);
        };
    }

    private void OnRowDone(NotificationThread n)
    {
        if (items.Any(i => i.Id == n.Id)) MarkDone(n).Forget();
    }

    protected override void OnAttached() => Load(true).Forget();

    protected override void OnLiveTick() => Load(false, live: true).Forget();

    protected override Task OnPullRefresh() => Load(false);

    private async Task Load(bool reset, bool live = false)
    {
        if (Model.Api is not { } api) return;
        loading = true;
        if (!live) shownLoads++;
        Update();
        var changed = true;
        var appear = RowAppearMode.Refresh;
        try
        {
            var mode = showAll;
            var needData = loadedMode != mode || error is not null;
            var fetched = reset ? await api.Notifications(mode) : await api.NotificationsIfChanged(mode, live, needData);
            if (mode != showAll) return;
            lastUpdated = DateTimeOffset.Now;
            error = null;
            if (fetched is null)
            {
                changed = false;
                return;
            }
            if (items.Count == 0 || loadedMode != mode) appear = RowAppearMode.Cascade;
            items = fetched.Where(i => !pendingDone.ContainsKey(i.Id)).ToList();
            loadedMode = mode;
            if (!showAll) Model.UnreadCount = items.Count;
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        finally
        {
            loading = false;
            if (!live) shownLoads--;
            if (changed) Render(appear);
            else Update();
        }
    }

    private void Open(NotificationThread n)
    {
        if (n.Route is not { } r) LinkBrowser.Open(n.WebUrl);
        else if (r != Model.DetailRoot) Model.Select(r);
        if (n.Unread) MarkRead(n).Forget();
    }

    private void Render(RowAppearMode appear = RowAppearMode.Silent)
    {
        syncing = true;
        Appear.Ingest(items.Select(i => i.Id), appear);
        var rows = items.ToList();
        List.ItemsSource = rows;
        var selected = selectedId is null ? null : rows.FirstOrDefault(i => i.Id == selectedId);
        List.SelectedItem = selected;
        if (selected is null) selectedId = null;
        syncing = false;
        Update();
    }

    private void UpdateNotice()
    {
        var capped = items.Count >= GitHubApi.NotificationPageSize;
        var external = selectedId is null ? null : items.FirstOrDefault(i => i.Id == selectedId && i.Route is null);
        FrameworkElement? browserRow = null;
        if (external is { } target) browserRow = ActionRow("\uE774", L.T("Notifications_OpensInBrowser", "This notification opens in the browser"), L.T("Common_Open", "Open"), () => Open(target));
        SetNotice($"{(capped ? items.Count : 0)}|{external?.Id}",
            browserRow,
            capped ? NoteRow(L.F("Notifications_Capped", "Showing the latest {0} notifications. Mark some as done to see older ones.", items.Count)) : null);
    }

    private void Update()
    {
        CountText.Text = items.Count > 0 ? GitHubApi.CountLabel(items.Count) : "";
        UpdateNotice();
        SetLoading(shownLoads > 0, items.Count > 0);
        Footer.Update(lastUpdated, loading, items.Count == 0 ? null : error);
        if (items.Count == 0)
        {
            if (loading) ShowOverlay(Ui.Loading());
            else if (error is { } e) ShowOverlay(Ui.Error(e, () => Load(true).Forget()));
            else ShowOverlay(showAll
                ? Ui.EmptyState(L.T("Notifications_None", "No notifications"), L.T("Notifications_NoneMessage", "Activity on your repositories shows up here."))
                : Ui.EmptyState(L.T("Notifications_CaughtUp", "All caught up"), L.T("Notifications_CaughtUpMessage", "You’ve read everything. New activity shows up here.")));
        }
        else
        {
            ShowOverlay(null);
        }
    }

    private async Task MarkRead(NotificationThread n)
    {
        if (Model.Api is not { } api) return;
        try
        {
            await api.MarkNotificationRead(n.Id);
        }
        catch
        {
        }
        n.Unread = false;
        Model.UnreadCount = Math.Max(0, Model.UnreadCount - 1);
        Render();
    }

    private static readonly Dictionary<string, CancellationTokenSource> pendingDone = new();

    private async Task MarkDone(NotificationThread n)
    {
        if (Model.Api is not { } api || pendingDone.ContainsKey(n.Id)) return;
        var index = items.FindIndex(i => i.Id == n.Id);
        if (index < 0) return;
        var cancel = new CancellationTokenSource();
        pendingDone[n.Id] = cancel;
        items.RemoveAt(index);
        if (n.Unread) Model.UnreadCount = Math.Max(0, Model.UnreadCount - 1);
        if (selectedId == n.Id) selectedId = items.Count > index ? items[index].Id : items.LastOrDefault()?.Id;
        Render();
        if (selectedId is not null) List.Focus(FocusState.Programmatic);
        ShellView.Toast(L.T("Notifications_MarkedDone", "Marked as done"), false, L.T("Common_Undo", "Undo"), () =>
        {
            cancel.Cancel();
            pendingDone.Remove(n.Id);
            items.Insert(Math.Min(index, items.Count), n);
            if (n.Unread) Model.UnreadCount++;
            Render();
        }, "\uE73E", "green");
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(5), cancel.Token);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        pendingDone.Remove(n.Id);
        try
        {
            await api.MarkNotificationDone(n.Id);
        }
        catch
        {
        }
    }

    private async Task MarkAll()
    {
        if (Model.Api is not { } api) return;
        var message = items.Count >= GitHubApi.NotificationPageSize
            ? L.T("Notifications_MarkAllCapped", "This also marks notifications that aren't loaded in this list.")
            : L.T("Notifications_MarkAllMessage", "Every unread notification in your inbox is marked as read.");
        if (!await Dialogs.Confirm(XamlRoot, L.T("Notifications_MarkAllConfirm", "Mark all notifications as read?"), L.T("Notifications_MarkAllButton", "Mark All as Read"), false, message)) return;
        try
        {
            await api.MarkAllNotificationsRead();
        }
        catch
        {
        }
        foreach (var i in items) i.Unread = false;
        Model.UnreadCount = 0;
        Render();
    }
}

public sealed class ReposView : ListPane
{
    private List<RepoSummary> repos = new();
    private string? cursor;
    private bool hasMore;
    private bool loading;
    private bool loadingMore;
    private string? loadMoreError;
    private bool refreshing;
    private string? error;
    private string text = "";
    private bool hideArchived = true;
    private DateTimeOffset? lastUpdated;
    private bool syncing;
    private readonly TextBox filterBox;

    public ReposView() : base(L.T("Section_Repositories", "Repositories"), "RepoRowTemplate")
    {
        filterBox = SearchBox(L.T("Repos_Filter", "Filter repositories"), t =>
        {
            text = t.Trim();
            Render();
            if (text.Length > 0 && hasMore) LoadAll().Forget();
        }, 200);
        FilterRow.Children.Add(filterBox);
        Tools.Children.Add(Toggle("", L.T("Repos_HideArchived", "Hide archived"), hideArchived, on =>
        {
            hideArchived = on;
            Render();
        }));
        List.SelectionChanged += (_, _) =>
        {
            if (syncing || List.SelectedItem is not RepoSummary r || r.Ref is not { } rr) return;
            Model.Select(Route.ForRepo(rr));
        };
        List.ContainerContentChanging += (_, e) =>
        {
            if (e.Item is RepoSummary r && repos.Count > 0 && ReferenceEquals(r, repos[^1]) && loadMoreError is null) LoadMore().Forget();
        };
        List.ContextRequested += (s, args) =>
        {
            if ((args.OriginalSource as FrameworkElement)?.DataContext is not RepoSummary r) return;
            args.Handled = true;
            Ui.Menu(
                Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(r.Url)),
                Ui.MenuItem(L.T("Menu_CopyLink", "Copy Link"), () => ShellView.Copied(r.Url, L.T("Toast_CopiedLink", "Copied link"))),
                Ui.MenuItem(L.T("Repos_CopyClone", "Copy “gh repo clone”"), () => SearchListView.CopyCommand($"gh repo clone {r.NameWithOwner}"))).ShowAt((FrameworkElement)args.OriginalSource);
        };
    }

    protected override void OnAttached()
    {
        if (repos.Count == 0) Load().Forget();
    }

    protected override Task OnPullRefresh() => Load();

    private IEnumerable<RepoSummary> Visible => repos.Where(r => (!hideArchived || !r.IsArchived) &&
        (text.Length == 0 || r.NameWithOwner.Contains(text, StringComparison.OrdinalIgnoreCase) || (r.Description ?? "").Contains(text, StringComparison.OrdinalIgnoreCase)));

    private async Task Load()
    {
        if (Model.Api is not { } api) return;
        loading = true;
        refreshing = true;
        Update();
        var appear = repos.Count == 0 ? RowAppearMode.Cascade : RowAppearMode.Refresh;
        try
        {
            var r = await api.Repos(null);
            var fresh = r.Nodes.Select(n => n.Id).ToHashSet();
            var keep = repos.Count > r.Nodes.Count ? repos.Skip(r.Nodes.Count).Where(n => !fresh.Contains(n.Id)).ToList() : new List<RepoSummary>();
            repos = r.Nodes.Concat(keep).ToList();
            if (keep.Count == 0)
            {
                cursor = r.PageInfo.EndCursor;
                hasMore = r.PageInfo.HasNextPage;
            }
            lastUpdated = DateTimeOffset.Now;
            error = null;
            loadMoreError = null;
        }
        catch (Exception e)
        {
            error = e.Message;
            appear = RowAppearMode.Silent;
        }
        finally
        {
            loading = false;
            refreshing = false;
            Render(appear);
        }
    }

    private async Task LoadMore()
    {
        if (Model.Api is not { } api || !hasMore || loading || loadingMore) return;
        loadingMore = true;
        loadMoreError = null;
        Update();
        try
        {
            var r = await api.Repos(cursor);
            if (!ReferenceEquals(Model.Api, api)) return;
            var known = repos.Select(x => x.Id).ToHashSet();
            repos.AddRange(r.Nodes.Where(n => !known.Contains(n.Id)));
            cursor = r.PageInfo.EndCursor;
            hasMore = r.PageInfo.HasNextPage;
        }
        catch (Exception e)
        {
            if (e is not OperationCanceledException && ReferenceEquals(Model.Api, api)) loadMoreError = e.Message;
        }
        finally
        {
            loadingMore = false;
            Render();
        }
    }

    private async Task LoadAll()
    {
        for (var i = 0; i < 20 && hasMore && loadMoreError is null; i++) await LoadMore();
    }

    private void Render(RowAppearMode appear = RowAppearMode.Silent)
    {
        syncing = true;
        Appear.Ingest(repos.Select(r => r.Id), appear);
        var visible = Visible.ToList();
        List.ItemsSource = visible;
        if (Model.DetailRoot is { Kind: RouteKind.Repo } route) List.SelectedItem = visible.FirstOrDefault(r => r.Ref == route.Repo);
        syncing = false;
        Update();
    }

    private void Update()
    {
        SetLoading(refreshing, repos.Count > 0);
        Footer.Update(lastUpdated, refreshing, repos.Count == 0 ? null : error);
        var moreError = repos.Count > 0 ? loadMoreError : null;
        var more = repos.Count > 0 && moreError is null && loadingMore;
        SetNotice($"{more}|{moreError}",
            moreError is not null ? LoadMoreErrorRow(moreError, () => LoadMore().Forget()) : null,
            more ? LoadingMoreRow() : null);
        if (repos.Count == 0 && loading) ShowOverlay(Ui.Loading());
        else if (repos.Count == 0 && error is { } e) ShowOverlay(Ui.Error(e, () => Load().Forget()));
        else if (!Visible.Any() && !loading && !loadingMore)
        {
            var archivedHidden = hideArchived && repos.Any(r => r.IsArchived);
            ShowOverlay(Ui.EmptyState(
                archivedHidden ? L.T("Repos_NoActive", "No active repositories") : L.T("Repos_None", "No repositories"),
                archivedHidden ? L.T("Repos_ArchivedHidden", "Archived repositories are hidden.") : L.T("Repos_NoneMessage", "Repositories you can access show up here."),
                text, () => filterBox.Text = ""));
        }
        else
        {
            ShowOverlay(null);
        }
    }
}

public sealed class ProjectsView : ListPane
{
    private List<ProjectSummary> projects = new();
    private bool loading;
    private int shownLoads;
    private string? error;
    private bool showClosed;
    private DateTimeOffset? lastUpdated;
    private bool syncing;
    private readonly ContentControl hint = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private readonly AppBarToggleButton closedToggle;

    public ProjectsView() : base(L.T("Section_Projects", "Projects"), "ProjectRowTemplate")
    {
        closedToggle = Toggle("", L.T("Projects_ShowClosed", "Show closed"), showClosed, on =>
        {
            showClosed = on;
            Render();
        });
        Tools.Children.Add(closedToggle);
        FilterRow.Children.Add(hint);
        List.SelectionChanged += (_, _) =>
        {
            if (syncing || List.SelectedItem is not ProjectSummary p) return;
            Model.Select(Route.ForProject(p.Ref));
        };
        List.ContextRequested += (s, args) =>
        {
            if ((args.OriginalSource as FrameworkElement)?.DataContext is not ProjectSummary p) return;
            args.Handled = true;
            Ui.Menu(Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(p.Url))).ShowAt((FrameworkElement)args.OriginalSource);
        };
    }

    protected override void OnAttached() => Load().Forget();

    protected override void OnLiveTick() => Load(true).Forget();

    protected override Task OnPullRefresh() => Load();

    private async Task Load(bool live = false)
    {
        if (Model.Api is not { } api) return;
        loading = true;
        if (!live) shownLoads++;
        Update();
        var appear = projects.Count == 0 ? RowAppearMode.Cascade : RowAppearMode.Refresh;
        try
        {
            projects = await api.Projects();
            lastUpdated = DateTimeOffset.Now;
            error = null;
        }
        catch (Exception e)
        {
            error = e.Message;
            appear = RowAppearMode.Silent;
        }
        finally
        {
            loading = false;
            if (!live) shownLoads--;
            Render(appear);
        }
    }

    private void Render(RowAppearMode appear = RowAppearMode.Silent)
    {
        syncing = true;
        Appear.Ingest(projects.Select(p => p.Id), appear);
        var visible = projects.Where(p => showClosed || !p.Closed).ToList();
        List.ItemsSource = visible;
        if (Model.DetailRoot is { Kind: RouteKind.Project } route) List.SelectedItem = visible.FirstOrDefault(p => p.Id == route.Project!.Id);
        syncing = false;
        Update();
    }

    private void Update()
    {
        var scopeProblem = !Model.HasProjectScope || (error?.Contains("scope", StringComparison.OrdinalIgnoreCase) ?? false);
        hint.Content = scopeProblem ? ScopeHint() : null;
        SetLoading(shownLoads > 0, projects.Count > 0);
        Footer.Update(lastUpdated, loading, projects.Count == 0 ? null : error);
        if (projects.Count == 0 && loading) ShowOverlay(Ui.Loading());
        else if (projects.Count == 0 && error is { } e && !scopeProblem) ShowOverlay(Ui.Error(e, () => Load().Forget()));
        else if (!scopeProblem && error is null && !loading && !projects.Any(p => showClosed || !p.Closed))
        {
            ShowOverlay(projects.Count == 0
                ? Ui.EmptyState(L.T("Projects_None", "No projects"), L.T("Projects_NoneMessage", "Projects you can access show up here."))
                : Ui.EmptyState(L.T("Projects_NoOpen", "No open projects"), L.T("Projects_ClosedHidden", "Closed projects are hidden."), actionTitle: L.T("Projects_ShowClosed", "Show closed"), action: () =>
                {
                    showClosed = true;
                    closedToggle.IsChecked = true;
                    Render();
                }));
        }
        else
        {
            ShowOverlay(null);
        }
    }

    private FrameworkElement ScopeHint()
    {
        const string command = "gh auth refresh -s read:project,project";
        var code = Ui.Card(Ui.Text(command, 12, "text", mono: true, select: true), 6, "sunken", 8);
        var copy = Ui.Button(L.T("Projects_CopyCommand", "Copy Command"), () => ShellView.Copied(command, L.T("Toast_CopiedCommand", "Copied command")));
        var refresh = Ui.Button(L.T("Projects_RefreshToken", "Refresh Token from gh"), () => RefreshToken().Forget());
        var panel = Ui.V(8,
            Ui.H(8, Ui.IconTile("", "amber", 22), Ui.Text(L.T("Projects_MissingScopes", "Token is missing Projects scopes"), 13, "text", Microsoft.UI.Text.FontWeights.SemiBold)),
            Ui.Text(L.T("Projects_ScopeHelp", "Run this in a terminal, then click “Refresh Token”:"), 12, "muted", wrap: true),
            code,
            Ui.H(8, copy, refresh));
        var card = new Border { Background = Palette.Brush("amber", 0.08), CornerRadius = new CornerRadius(10), Padding = new Thickness(10), Child = panel };
        return card;
    }

    private async Task RefreshToken()
    {
        await Model.RefreshTokenFromGh();
        Model.Refresh();
        await Load();
    }
}
