using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PullYard.Controls;
using PullYard.Core;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed class ClaudeSessionsView : ListPane
{
    private ClaudeWorkspace Ws => Model.Claude;
    private static AgentSessionPrefs Prefs => AgentSessionPrefs.Shared;
    private readonly HashSet<string> expanded = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> collapsedParents = new();
    private bool showArchived;
    private string query = "";
    private readonly ContentControl accountHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private readonly DispatcherTimer stateTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private string? lastSignature;
    private bool renderQueued;

    public ClaudeSessionsView() : base(L.T("Section_Claude", "Agents"), "SessionRowTemplate")
    {
        FilterRow.Children.Add(accountHost);
        FilterRow.Children.Add(SearchBox(L.T("Claude_SearchSessions", "Search sessions"), t =>
        {
            query = t.Trim();
            Render();
        }, 200));
        var open = Ui.IconButton("\uE8F4", L.T("Claude_OpenFolder", "New session in folder…"), () => OpenFolder().Forget(), "text");
        Tools.Children.Add(open);
        List.SelectionMode = ListViewSelectionMode.None;
        List.ItemClick += (_, e) =>
        {
            switch (e.ClickedItem)
            {
                case SessionListItem s:
                    Ws.Resume(s.Session);
                    break;
                case ProjectHeaderItem p:
                    if (!expanded.Remove(p.Project.Id)) expanded.Add(p.Project.Id);
                    Render();
                    break;
                case OpenTabItem t:
                    Ws.SelectedTab = t.Tab;
                    break;
                case ArchivedToggleItem:
                    showArchived = !showArchived;
                    Render();
                    break;
            }
        };
        List.ContextRequested += (_, args) =>
        {
            var element = args.OriginalSource as FrameworkElement;
            MenuFlyout? menu = element?.DataContext switch
            {
                SessionListItem s => SessionMenu(s.Session),
                OpenTabItem t => TabMenu(t.Tab),
                _ => null
            };
            if (menu is null || element is null) return;
            args.Handled = true;
            menu.ShowAt(element);
        };
        stateTimer.Tick += (_, _) =>
        {
            if (Ws.Tabs.Count > 0) Render();
        };
    }

    protected override void OnAttached()
    {
        Ws.PropertyChanged += OnWs;
        Ws.Tabs.CollectionChanged += OnTabs;
        ClaudeAccountStore.Shared.PropertyChanged += OnAccount;
        ClaudeProfiles.Shared.PropertyChanged += OnAccount;
        Prefs.Changed += QueueRender;
        Unloaded += Detach;
        stateTimer.Start();
        lastSignature = null;
        RenderAccount();
        Render();
        Initial().Forget();
    }

    private void Detach(object sender, RoutedEventArgs e)
    {
        Ws.PropertyChanged -= OnWs;
        Ws.Tabs.CollectionChanged -= OnTabs;
        ClaudeAccountStore.Shared.PropertyChanged -= OnAccount;
        ClaudeProfiles.Shared.PropertyChanged -= OnAccount;
        Prefs.Changed -= QueueRender;
        Unloaded -= Detach;
        stateTimer.Stop();
    }

    private async Task Initial()
    {
        await ClaudeAccountStore.Shared.Refresh();
        await Ws.ReloadProjects(force: Ws.Projects.Count == 0);
        if (expanded.Count == 0 && Ws.Projects.FirstOrDefault() is { } first)
        {
            expanded.Add(first.Id);
            Render();
        }
    }

    protected override async Task OnPullRefresh()
    {
        await ClaudeAccountStore.Shared.Refresh();
        await Ws.ReloadProjects();
    }

    protected override void OnLiveTick()
    {
        if (ClaudeAccountStore.Shared.IsLoggedIn) Ws.ReloadProjects(force: false).Forget();
    }

    private void OnTabs(object? sender, NotifyCollectionChangedEventArgs e) => QueueRender();

    private void QueueRender()
    {
        if (renderQueued) return;
        renderQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            renderQueued = false;
            Render();
        });
    }

    private void OnWs(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ClaudeWorkspace.Projects):
            case nameof(ClaudeWorkspace.SelectedTab):
            case nameof(ClaudeWorkspace.TotalMemory):
                QueueRender();
                break;
            case nameof(ClaudeWorkspace.LoadingProjects):
            case nameof(ClaudeWorkspace.ProjectsUpdated):
                Footer.Update(Ws.ProjectsUpdated, Ws.LoadingProjects);
                if (Ws.Projects.Count == 0) QueueRender();
                break;
        }
    }

    private void OnAccount(object? sender, PropertyChangedEventArgs e)
    {
        RenderAccount();
        lastSignature = null;
        Render();
    }

    private void RenderAccount()
    {
        var store = ClaudeAccountStore.Shared;
        accountHost.Content = store.Status switch
        {
            ClaudeAccountStatus.LoggedIn when store.Info is { } info => ClaudeAccountCard.Create(info, compact: true),
            ClaudeAccountStatus.LoggedOut => Ui.V(6, Ui.H(6, Ui.Glyph("\uE7BA", 12, "amber"), Ui.Text(L.T("Claude_SignInRight", "Not signed in to Claude — sign in on the right"), 12.5, "amber", wrap: true)),
                ClaudeProfiles.Shared.Visible.Count > 1 ? ClaudeAccountCard.Switcher() : null),
            ClaudeAccountStatus.NotInstalled => Ui.H(6, Ui.Glyph("\uE7BA", 12, "amber"), Ui.Text(L.T("Claude_NotFound", "claude CLI not found — see the right side"), 12.5, "amber", wrap: true)),
            _ => null
        };
    }

    private bool Matches(ClaudeSessionInfo s) =>
        query.Length == 0 || Prefs.Title(s).Contains(query, StringComparison.OrdinalIgnoreCase) || (s.Branch ?? "").Contains(query, StringComparison.OrdinalIgnoreCase);

    private List<object> BuildItems()
    {
        var items = new List<object>();
        if (Ws.Tabs.Count > 0)
        {
            var mem = Ws.TotalMemory > 0 ? Fmt.Memory(Ws.TotalMemory) : "0 MB";
            var awake = Ws.Tabs.Any(t => t.Running && t.State is not (ClaudeTabState.Working or ClaudeTabState.Waiting));
            items.Add(new SectionLabelItem($"{L.T("Claude_Open", "Open")}  ·  {mem}")
            {
                Glyph = "\uE8BD",
                ActionText = awake ? L.T("Agents_SleepAll", "Sleep all") : null,
                OnAction = awake ? Ws.SleepAll : null
            });
            foreach (var t in Ws.Tabs) items.Add(new OpenTabItem(t, Ws.SelectedTab == t));
        }
        var pinned = new List<ClaudeSessionInfo>();
        foreach (var id in Prefs.Pinned)
            if (Ws.SessionsById.TryGetValue(id, out var s) && Matches(s) && !Prefs.IsArchived(s)) pinned.Add(Prefs.Apply(s));
        if (pinned.Count > 0)
        {
            items.Add(new SectionLabelItem(L.T("Agents_Pinned", "Pinned")) { Glyph = "\uE718" });
            foreach (var s in pinned) items.Add(new SessionListItem(s, Ws.TabForSession(s.Id) is not null));
        }
        var any = false;
        foreach (var project in Ws.Projects)
        {
            var nameHit = query.Length > 0 && project.Name.Contains(query, StringComparison.OrdinalIgnoreCase);
            var visible = project.Sessions.Where(s => (showArchived || !Prefs.IsArchived(s)) && !Prefs.IsPinned(s.Id) && (nameHit || Matches(s))).ToList();
            if (query.Length > 0 && visible.Count == 0 && !nameHit) continue;
            any = true;
            var isOpen = expanded.Contains(project.Id) || query.Length > 0;
            var path = project.Path;
            items.Add(new ProjectHeaderItem(project, isOpen) { OnNew = () => Ws.NewSession(path), Count = project.Sessions.Count(s => !Prefs.IsArchived(s)) });
            if (!isOpen) continue;
            foreach (var node in SessionTree.Build(visible.Take(query.Length == 0 ? 40 : 200)))
            {
                var parentId = node.Id;
                var collapsed = collapsedParents.Contains(parentId);
                items.Add(new SessionListItem(Prefs.Apply(node.Session), Ws.TabForSession(parentId) is not null)
                {
                    ChildCount = node.Children.Count,
                    Collapsed = collapsed,
                    OnToggle = () =>
                    {
                        if (!collapsedParents.Remove(parentId)) collapsedParents.Add(parentId);
                        Render();
                    }
                });
                if (collapsed) continue;
                for (var i = 0; i < node.Children.Count; i++)
                {
                    var child = node.Children[i];
                    items.Add(new SessionListItem(Prefs.Apply(child), Ws.TabForSession(child.Id) is not null) { Depth = 1, Last = i == node.Children.Count - 1 });
                }
            }
        }
        if (any || showArchived) items.Add(new ArchivedToggleItem(showArchived));
        return items;
    }

    private static string Signature(List<object> items)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var item in items)
        {
            switch (item)
            {
                case SectionLabelItem l:
                    sb.Append("L|").Append(l.Text).Append('|').Append(l.ActionText);
                    break;
                case OpenTabItem t:
                    sb.Append("T|").Append(t.Tab.Id).Append('|').Append(t.Selected).Append('|').Append(t.Tab.Title).Append('|').Append(t.Tab.Kind);
                    break;
                case ProjectHeaderItem p:
                    sb.Append("P|").Append(p.Project.Id).Append('|').Append(p.Expanded).Append('|').Append(p.Count).Append('|').Append(p.Project.Exists);
                    break;
                case SessionListItem s:
                    sb.Append("S|").Append(s.Session.Id).Append('|').Append(s.Session.Title).Append('|').Append(s.Open).Append('|').Append(s.Depth).Append('|').Append(s.Last)
                        .Append('|').Append(s.ChildCount).Append('|').Append(s.Collapsed).Append('|').Append(s.Session.Modified.Ticks).Append('|').Append(s.Session.PrNumber);
                    break;
                case ArchivedToggleItem a:
                    sb.Append("A|").Append(a.Showing);
                    break;
            }
            sb.Append('\n');
        }
        return sb.ToString();
    }

    private void Render()
    {
        var store = ClaudeAccountStore.Shared;
        var items = store.IsLoggedIn ? BuildItems() : new List<object>();
        var signature = store.IsLoggedIn + "\n" + Signature(items);
        if (signature != lastSignature)
        {
            lastSignature = signature;
            List.ItemsSource = items;
        }
        Footer.Update(Ws.ProjectsUpdated, Ws.LoadingProjects);
        if (!store.IsLoggedIn)
        {
            ShowOverlay(store.Status is ClaudeAccountStatus.Checking or ClaudeAccountStatus.Unknown ? Ui.Loading() : Ui.Empty("\uE72E", "slate", L.T("Claude_HistoryAfterSignIn", "Session history and projects appear after you sign in to Claude.")));
        }
        else if (items.Count == 0 || (items.Count == 1 && items[0] is ArchivedToggleItem && Ws.Projects.Count == 0))
        {
            ShowOverlay(Ws.LoadingProjects ? Ui.Loading() : Ui.EmptyState(L.T("Claude_NoSessionsTitle", "No agent sessions yet"), L.T("Claude_NoSessionsMessage", "Start a session in a project folder and it shows up here.")));
        }
        else
        {
            ShowOverlay(null);
        }
    }

    private MenuFlyout SessionMenu(ClaudeSessionInfo s)
    {
        var archived = Prefs.IsArchived(s);
        var menu = Ui.Menu(
            Ui.MenuItem(Prefs.IsPinned(s.Id) ? L.T("Agents_Unpin", "Unpin") : L.T("Agents_Pin", "Pin to top"), () => Prefs.TogglePin(s.Id), "\uE718", enabled: !archived),
            Ui.MenuItem(L.T("Agents_Rename", "Rename…"), () => Rename(s).Forget(), "\uE8AC"),
            Ui.MenuItem(archived ? L.T("Agents_Unarchive", "Unarchive") : L.T("Agents_Archive", "Archive"), () => Prefs.SetArchived(s.Id, !archived), "\uE7B8"),
            Ui.Separator(),
            Ui.MenuItem(L.T("Claude_ResumeChat", "Resume as chat"), () => Ws.Resume(s, kind: ClaudeTabKind.Chat), "\uE8BD"),
            Ui.MenuItem(L.T("Claude_ResumeTerminal", "Resume in terminal"), () => Ws.Resume(s, kind: ClaudeTabKind.Terminal), "\uE756"),
            Ui.MenuItem(L.T("Claude_Fork", "Fork session"), () => Ws.Resume(s, fork: true), "\uE8C8"));
        if (s.DesktopId is { } local && DesktopSessionIndex.IsInstalled)
            menu.Items.Add(Ui.MenuItem(L.T("Agents_OpenInDesktop", "Open in Claude Desktop"), () => Proc.OpenUrl(DesktopSessionIndex.ContinueUrl(local))));
        menu.Items.Add(Ui.Separator());
        menu.Items.Add(Ui.MenuItem(L.T("Claude_CopyId", "Copy session ID"), () => WindowInterop.Copy(s.Id)));
        menu.Items.Add(Ui.MenuItem(L.T("Claude_CopyResume", "Copy resume command"), () => WindowInterop.Copy($"cd {Proc.QuoteArg(s.Cwd)} && claude --resume {s.Id}")));
        menu.Items.Add(Ui.MenuItem(L.T("Claude_Reveal", "Show transcript in Explorer"), () => Proc.Reveal(s.File)));
        if (s.PrUrl is { } pr && GitHubUrl.Parse(pr) is { } route)
            menu.Items.Add(Ui.MenuItem(L.T("Claude_OpenPR", "Open PR"), () => Model.Open(route)));
        return menu;
    }

    private async Task Rename(ClaudeSessionInfo s)
    {
        if (XamlRoot is null) return;
        var box = new TextBox { Text = Prefs.Title(s), MinWidth = 360 };
        var panel = Ui.V(8, Ui.Text(L.F("Agents_RenameHelp", "The new name is only shown in {0}.", AppInfo.DisplayName), 13, "muted", wrap: true), box);
        var d = Dialogs.Create(XamlRoot, L.T("Agents_RenameTitle", "Rename session"), panel, L.T("Agents_RenameButton", "Rename"));
        d.Opened += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };
        if (await Dialogs.ShowAsync(d) == ContentDialogResult.Primary) Prefs.Rename(s.Id, box.Text);
    }

    private MenuFlyout TabMenu(ClaudeTab tab)
    {
        return Ui.Menu(
            tab.Running
                ? Ui.MenuItem(L.T("Claude_FreeMemory", "Free memory (sleep)"), tab.SleepNow, enabled: tab.State is not (ClaudeTabState.Working or ClaudeTabState.Waiting))
                : Ui.MenuItem(L.T("Claude_WakeUp", "Wake up"), () => Ws.Restart(tab)),
            Ui.MenuItem(L.T("Common_Close", "Close"), () => Ws.Close(tab)));
    }

    private async Task OpenFolder()
    {
        if (!ClaudeAccountStore.Shared.IsLoggedIn || App.MainWindow is null) return;
        if (await WindowInterop.PickFolder(App.MainWindow) is { } folder) Ws.NewSession(folder);
    }
}

public static class ClaudeAccountCard
{
    public static FrameworkElement Create(ClaudeAccountInfo info, bool compact = false)
    {
        var profile = ClaudeProfiles.Shared.Active;
        var nameRow = Ui.H(5, Ui.Text(info.Email ?? L.T("Claude_SignedIn", "Signed in"), compact ? 13 : 15, "text", FontWeights.Medium));
        if (ClaudeProfiles.Shared.Visible.Count > 1) nameRow.Children.Add(Ui.Chip(profile.Label, "muted"));
        var sub = Ui.H(5);
        if (info.OrgName is { } org) sub.Children.Add(Ui.Caption(org));
        if (info.Subscription is { } plan) sub.Children.Add(Ui.Chip(plan, "coral"));
        else if (info.Method == "console" || info.Provider != "firstParty") sub.Children.Add(Ui.Caption(info.Provider == "firstParty" ? "API" : info.Provider ?? "API"));
        var more = Ui.IconButton("", L.T("Common_More", "More"), () => { }, "text");
        var menu = ProfileMenu();
        menu.Items.Add(Ui.Separator());
        menu.Items.Add(Ui.MenuItem(L.T("Claude_SignOutThis", "Sign out of this account…"), () => ConfirmSignOut().Forget()));
        menu.Items.Add(Ui.Separator());
        menu.Items.Add(Ui.MenuItem(L.T("Claude_UsagePage", "Usage page"), () => LinkBrowser.Open("https://claude.ai/settings/usage")));
        menu.Items.Add(Ui.MenuItem(L.T("Claude_RefreshStatus", "Refresh status"), () => ClaudeAccountStore.Shared.Refresh().Forget()));
        more.Flyout = menu;
        var grid = Ui.Columns((ProfileBadge(profile, compact ? 26 : 34), Ui.Auto), (Ui.V(1, nameRow, sub), Ui.Star), (more, Ui.Auto));
        grid.ColumnSpacing = 10;
        return Ui.Card(grid, 10, "raised", compact ? 8 : 14);
    }

    private static async Task ConfirmSignOut()
    {
        var root = App.MainWindow?.Content?.XamlRoot;
        var active = ClaudeProfiles.Shared.Active;
        var message = active.IsDefault
            ? L.T("Claude_SignOutDefaultHelp", "This also signs out Claude Code in the terminal. You can sign in again afterwards, including with another account.")
            : L.F("Claude_SignOutProfileHelp", "Signs out only “{0}”. Other accounts are not affected.", active.Label);
        if (await Dialogs.Confirm(root, L.T("Claude_SignOutQ", "Sign out of Claude Code?"), L.T("Settings_SignOut", "Sign out"), true, message))
            await ClaudeAccountStore.Shared.Logout();
    }

    public static MenuFlyout ProfileMenu()
    {
        var app = AppViewModel.Shared;
        var profiles = ClaudeProfiles.Shared;
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = L.T("Claude_Accounts", "Claude accounts"), IsEnabled = false });
        foreach (var p in profiles.Visible)
        {
            var id = p.Id;
            menu.Items.Add(Ui.CheckItem(p.MenuTitle, id == profiles.ActiveId, () => app.SwitchClaudeProfile(id)));
        }
        menu.Items.Add(Ui.MenuItem(L.T("Claude_AddAccountMenu", "Add account…"), () => ClaudeDialogs.AddProfile(App.MainWindow?.Content?.XamlRoot).Forget()));
        if (!profiles.Active.IsDefault)
        {
            var active = profiles.Active;
            menu.Items.Add(Ui.MenuItem(L.F("Claude_RemoveAccount", "Remove “{0}”…", active.Label), () => ClaudeDialogs.RemoveProfile(App.MainWindow?.Content?.XamlRoot, active).Forget()));
        }
        return menu;
    }

    public static FrameworkElement Switcher()
    {
        var active = ClaudeProfiles.Shared.Active;
        var b = new DropDownButton { Content = Ui.H(6, ProfileBadge(active, 18), Ui.Text(active.Label, 13)), Flyout = ProfileMenu() };
        Ui.Tip(b, L.T("Claude_SwitchAccount", "Switch Claude account"));
        return b;
    }

    public static FrameworkElement ProfileBadge(ClaudeProfile profile, double size)
    {
        var color = profile.IsDefault ? "coral" : Palette.ProjectKey(profile.Id);
        var grid = new Grid { Width = size, Height = size };
        grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Fill = Palette.Brush(color, 0.18), Stroke = Palette.Brush(color, 0.35), StrokeThickness = 1 });
        var t = Ui.Text(profile.Initial, size * 0.48, color, FontWeights.Bold);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        grid.Children.Add(t);
        return grid;
    }
}

public static class ClaudeDialogs
{
    public static async Task AddProfile(XamlRoot? root)
    {
        if (root is null) return;
        var name = new TextBox { PlaceholderText = L.T("Claude_ProfileName", "Name, e.g. “Personal” or “Work”") };
        var ownsMain = ClaudeProfiles.Shared.OwnsMain;
        var share = new CheckBox { Content = L.T("Claude_ShareSettings", "Use my settings, CLAUDE.md, skills and plugins from the main account"), IsChecked = true, Visibility = ownsMain ? Visibility.Visible : Visibility.Collapsed };
        var error = Ui.Text("", 12, "red", wrap: true);
        var panel = Ui.V(10, Ui.Text(L.T("Claude_ProfileHelp", "The account gets its own sign-in, session history and limits. Sign-in opens right after."), 13, "muted", wrap: true), name, share, error);
        var d = Dialogs.Create(root, L.T("Claude_NewAccount", "New Claude account"), panel, L.T("Claude_CreateAndSignIn", "Create and sign in"));
        d.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                var p = ClaudeProfiles.Shared.Add(name.Text, ownsMain && share.IsChecked == true);
                var app = AppViewModel.Shared;
                app.SwitchClaudeProfile(p.Id);
                app.Section = Section.Claude;
            }
            catch (Exception e)
            {
                error.Text = e.Message;
                args.Cancel = true;
            }
        };
        await Dialogs.ShowAsync(d);
    }

    public static async Task RemoveProfile(XamlRoot? root, ClaudeProfile profile)
    {
        if (await Dialogs.Confirm(root, L.T("Claude_RemoveQ", "Remove account?"), L.F("Claude_RemoveButton", "Sign out and remove “{0}”", profile.Label), true,
                L.F("Claude_RemoveHelp", "The app signs out of this account and removes it from the list. Its history folder stays on disk: {0}", profile.ConfigDir ?? "")))
            AppViewModel.Shared.RemoveClaudeProfile(profile.Id);
    }
}
