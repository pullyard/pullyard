using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Html;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using VisualState = PullYard.Core.Api.VisualState;

namespace PullYard.Views;

public sealed class ClaudeInspector : Grid
{
    private readonly ClaudeTab tab;
    private readonly TabStrip tabs = new("changes");
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private ChangesPanel? changes;
    private TasksPanel? tasks;
    private LocalFilesPanel? files;
    private BranchPRPanel? prs;
    private readonly Button expandButton;
    private bool expanded;

    public Action? ToggleExpand { get; set; }

    public ClaudeInspector(ClaudeTab tab)
    {
        this.tab = tab;
        Background = ThemeService.IsBrand ? Palette.Brush("panel") : null;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        expandButton = Ui.IconButton("\uE740", L.T("Inspector_ExpandHint", "Expand over the chat"), () => ToggleExpand?.Invoke());
        expandButton.Margin = new Thickness(0, 0, 6, 0);
        expandButton.VerticalAlignment = VerticalAlignment.Center;
        SetExpanded(false);
        var top = Ui.V(0, Ui.Columns((tabs, Ui.Star), (expandButton, Ui.Auto)), Ui.Line());
        top.Margin = new Thickness(0, 4, 0, 0);
        Children.Add(top);
        SetRow(host, 1);
        Children.Add(host);
        tabs.SelectionChanged += _ => Show();
        tab.Git.PropertyChanged += OnGit;
        if (tab.Chat is { } chat) chat.ItemsChanged += OnItems;
        Unloaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            if (tab.Chat is { } c) c.ItemsChanged -= OnItems;
        };
        Loaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            tab.Git.PropertyChanged += OnGit;
            if (tab.Chat is { } c)
            {
                c.ItemsChanged -= OnItems;
                c.ItemsChanged += OnItems;
            }
        };
        RenderTabs();
        Show();
    }

    public void SetExpanded(bool on)
    {
        expanded = on;
        expandButton.Content = Ui.Glyph(on ? "\uE73F" : "\uE740", 14, "muted");
        var tip = on ? L.T("Inspector_CollapseHint", "Collapse (Esc)") : L.T("Inspector_ExpandHint", "Expand over the chat");
        ToolTipService.SetToolTip(expandButton, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expandButton, on ? L.T("Inspector_Collapse", "Collapse inspector") : L.T("Inspector_Expand", "Expand inspector"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(expandButton, tip);
    }

    public bool Expanded => expanded;

    public void FocusExpand() => expandButton.Focus(FocusState.Programmatic);

    private int shownRunning = -1;

    private int RunningTasks => tab.Chat?.Items.OfType<ToolItem>().Count(t => t.IsTask && t.TaskState == ChatTaskState.Running) ?? 0;

    private void OnItems()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (RunningTasks != shownRunning) RenderTabs();
        });
    }

    private void OnGit(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Core.Git.GitWorkingCopy.Changes)) RenderTabs();
    }

    private void RenderTabs()
    {
        var count = tab.Git.Changes.Count;
        shownRunning = RunningTasks;
        var specs = new List<TabSpec> { new("changes", L.T("Inspector_Changes", "Changes"), "", count > 0 ? count.ToString() : null, "amber") };
        if (tab.Chat is not null) specs.Add(new TabSpec("tasks", L.T("Inspector_Tasks", "Tasks"), "\uE756", shownRunning > 0 ? shownRunning.ToString() : null, "sky"));
        specs.Add(new TabSpec("files", L.T("Inspector_Files", "Files"), ""));
        specs.Add(new TabSpec("pr", L.T("Inspector_PR", "PR"), ""));
        tabs.SetTabs(specs);
    }

    private void Show()
    {
        host.Content = tabs.Selected switch
        {
            "files" => files ??= new LocalFilesPanel(tab.Folder),
            "pr" => prs ??= new BranchPRPanel(tab),
            "tasks" when tab.Chat is { } chat => tasks ??= new TasksPanel(chat),
            _ => changes ??= new ChangesPanel(tab)
        };
    }
}

public sealed class TasksPanel : Grid
{
    private readonly ChatSession chat;
    private readonly StackPanel list = Ui.V(2);
    private readonly ContentControl empty = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly HashSet<string> expanded = new();
    private bool showFinished = true;
    private DispatcherQueueTimer? pending;
    private DispatcherQueueTimer? clock;

    public TasksPanel(ChatSession chat)
    {
        this.chat = chat;
        list.Padding = new Thickness(8);
        Children.Add(new ScrollViewer { Content = list });
        Children.Add(empty);
        chat.ItemsChanged += Schedule;
        Unloaded += (_, _) =>
        {
            chat.ItemsChanged -= Schedule;
            clock?.Stop();
        };
        Loaded += (_, _) =>
        {
            chat.ItemsChanged -= Schedule;
            chat.ItemsChanged += Schedule;
            Render();
        };
        Render();
    }

    private void Schedule()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (pending is not null) return;
            pending = DispatcherQueue.CreateTimer();
            pending.Interval = TimeSpan.FromMilliseconds(250);
            pending.IsRepeating = false;
            pending.Tick += (_, _) =>
            {
                pending = null;
                Render();
            };
            pending.Start();
        });
    }

    private void Render()
    {
        var calls = chat.Items.OfType<ToolItem>().Where(t => t.IsTask).Reverse().ToList();
        var running = calls.Where(t => t.TaskState == ChatTaskState.Running).ToList();
        var finished = calls.Where(t => t.TaskState != ChatTaskState.Running).ToList();
        list.Children.Clear();
        empty.Content = calls.Count == 0 ? Ui.Empty("", "dim", L.T("Tasks_Empty", "Commands and agents Claude runs will show up here")) : null;
        empty.Visibility = calls.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (running.Count > 0)
        {
            list.Children.Add(Header(L.T("Tasks_Running", "Running") + $" {running.Count}", false));
            foreach (var t in running) list.Children.Add(Row(t));
        }
        if (finished.Count > 0)
        {
            list.Children.Add(Header(L.T("Tasks_Finished", "Finished") + $" {finished.Count}", true));
            if (showFinished)
                foreach (var t in finished) list.Children.Add(Row(t));
        }
        if (running.Count > 0)
        {
            if (clock is null)
            {
                clock = DispatcherQueue.CreateTimer();
                clock.Interval = TimeSpan.FromSeconds(1);
                clock.Tick += (_, _) => Render();
            }
            if (!clock.IsRunning) clock.Start();
        }
        else clock?.Stop();
    }

    private UIElement Header(string title, bool collapsible)
    {
        var row = Ui.H(4, Ui.Text(title, 12, "muted", FontWeights.SemiBold), collapsible ? Ui.Glyph(showFinished ? "" : "", 9, "dim") : null);
        row.Margin = new Thickness(6, 8, 6, 4);
        if (!collapsible) return row;
        var b = new Button { Content = row, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        Ui.Expandable(b, title, showFinished);
        b.Click += (_, _) =>
        {
            showFinished = !showFinished;
            Render();
        };
        return b;
    }

    private static string Title(ToolItem t)
    {
        if (t.Str("description") is { Length: > 0 } d) return d;
        if (t.Str("command") is { Length: > 0 } c) return c.Split('\n')[0];
        if (t.Str("prompt") is { Length: > 0 } p) return p.Length > 80 ? p[..80] : p;
        return t.Name;
    }

    private static string? Subtitle(ToolItem t)
    {
        if (t.Name == "Bash") return t.Backgrounded ? L.T("Tasks_Background", "Background") : null;
        var parts = new List<string>();
        if (t.Str("subagent_type") is { Length: > 0 } type) parts.Add(type);
        if (t.TaskTokens is { } n) parts.Add((n >= 1000 ? (n / 1000.0).ToString("0.0") + "k" : n.ToString()) + " tokens");
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static string? Output(ToolItem t)
    {
        if (t.Structured is { } s)
        {
            var joined = string.Join("\n", new[] { s.Str("stdout"), s.Str("stderr") }.Where(x => !string.IsNullOrEmpty(x)));
            if (joined.Length > 0) return joined;
        }
        return t.TaskSummary ?? t.ResultText;
    }

    public static string Duration(TimeSpan span)
    {
        var s = Math.Max(0, (int)Math.Round(span.TotalSeconds));
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m {s % 60}s";
        return $"{s / 3600}h {s % 3600 / 60}m";
    }

    private static UIElement Trailing(ToolItem t) => t.TaskState switch
    {
        ChatTaskState.Running => Ui.H(6, t.StartedAt is { } start ? Ui.Caption(Duration(DateTime.Now - start)) : null, Ui.Spinner(12)),
        ChatTaskState.Failed => Ui.Text(L.T("Tasks_Failed", "Failed"), 12, "red", FontWeights.Medium),
        ChatTaskState.Stopped => Ui.Caption(L.T("Tasks_Stopped", "Stopped")),
        _ => Ui.Caption(t.StartedAt is { } a && t.FinishedAt is { } b ? Duration(b - a) : "")
    };

    private UIElement Row(ToolItem t)
    {
        var open = expanded.Contains(t.ToolId);
        var titles = Ui.V(2, Ui.Text(Title(t), 13, "text", maxLines: 1), Subtitle(t) is { } sub ? Ui.Caption(sub) : null);
        var line = Ui.Columns(
            (Ui.Glyph(t.Name == "Bash" ? "" : "", 12, "dim"), Ui.Auto),
            (titles, Ui.Star),
            (Trailing(t), Ui.Auto),
            (Ui.Glyph(open ? "" : "", 9, "dim"), Ui.Auto));
        var button = new Button
        {
            Content = line,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        Ui.Expandable(button, Title(t), open);
        button.Click += (_, _) =>
        {
            if (!expanded.Remove(t.ToolId)) expanded.Add(t.ToolId);
            Render();
        };
        var command = t.Str("command");
        var output = Output(t);
        button.ContextFlyout = Ui.Menu(
            string.IsNullOrEmpty(command) ? null : Ui.MenuItem(L.T("Tasks_CopyCommand", "Copy Command"), () => WindowInterop.Copy(command)),
            string.IsNullOrEmpty(output) ? null : Ui.MenuItem(L.T("Tasks_CopyOutput", "Copy Output"), () => WindowInterop.Copy(output)));
        var box = Ui.V(6, button);
        if (open)
        {
            var details = Ui.V(6);
            details.Margin = new Thickness(6, 0, 6, 8);
            if (!string.IsNullOrEmpty(command))
                details.Children.Add(new Border
                {
                    Child = Ui.Text("$ " + command, 12, "text", wrap: true, mono: true, select: true),
                    Background = Palette.Brush("sunken"),
                    BorderBrush = Palette.Brush("text", 0.1),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8)
                });
            if (!string.IsNullOrEmpty(output))
                details.Children.Add(new Border
                {
                    Child = new ScrollViewer { Content = Ui.Text(output.Length > 8000 ? output[^8000..] : output, 12, t.TaskState == ChatTaskState.Failed ? "red" : "muted", wrap: true, mono: true, select: true), MaxHeight = 180 },
                    Background = Palette.Brush("text", 0.06),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8)
                });
            box.Children.Add(details);
        }
        return new Border { Child = box, CornerRadius = new CornerRadius(8), Background = open ? Palette.Brush("text", 0.05) : null };
    }
}

public sealed class ChangesPanel : Grid
{
    private readonly ClaudeTab tab;
    private readonly StackPanel header = Ui.V(4);
    private readonly HtmlView html = new();
    private readonly ContentControl empty = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly HashSet<string> collapsed = new();

    public ChangesPanel(ClaudeTab tab)
    {
        this.tab = tab;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        header.Padding = new Thickness(10, 6, 6, 6);
        Children.Add(header);
        var area = new Grid();
        area.Children.Add(html);
        area.Children.Add(empty);
        SetRow(area, 1);
        Children.Add(area);
        html.ActionInvoked += (type, id) =>
        {
            switch (type)
            {
                case "open":
                    PathGuard.OpenWithinWorkspace(tab.Folder, id.Replace('/', Path.DirectorySeparatorChar));
                    break;
                case "copy":
                    WindowInterop.Copy(id);
                    break;
                case "collapse":
                    collapsed.Add(id);
                    break;
                case "expand":
                    collapsed.Remove(id);
                    if (tab.Git.Changes.FirstOrDefault(f => f.Id == id) is { } file)
                        html.Send(new System.Text.Json.Nodes.JsonObject { ["op"] = "fileBody", ["path"] = id, ["html"] = DiffHtml.Body(file, new DiffRenderOptions { Wrap = Wrap }) });
                    break;
            }
        };
        tab.Git.PropertyChanged += OnGit;
        Settings.Shared.Changed += OnSettings;
        Unloaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            Settings.Shared.Changed -= OnSettings;
        };
        Loaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            tab.Git.PropertyChanged += OnGit;
            Settings.Shared.Changed -= OnSettings;
            Settings.Shared.Changed += OnSettings;
            tab.Git.Refresh().Forget();
        };
        Render();
    }

    private static bool Wrap => Settings.Shared.GetBool(DiffPrefs.WrapKey, true);

    private void OnSettings(string key)
    {
        if (key == DiffPrefs.WrapKey) DispatcherQueue.TryEnqueue(Render);
    }

    private CheckBox WrapToggle()
    {
        var box = new CheckBox { Content = L.T("Files_WrapLines", "Wrap lines"), IsChecked = Wrap, MinWidth = 0, Padding = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(box, L.T("Changes_WrapTip", "Wrap long lines"));
        box.Click += (_, _) => Settings.Shared.Set(DiffPrefs.WrapKey, box.IsChecked == true);
        return box;
    }

    private void OnGit(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(Core.Git.GitWorkingCopy.Changes) or nameof(Core.Git.GitWorkingCopy.Unpushed) or nameof(Core.Git.GitWorkingCopy.Loading)) Render();
    }

    private void Render()
    {
        var git = tab.Git;
        header.Children.Clear();
        var summary = Ui.H(8);
        if (git.Loading) summary.Children.Add(Ui.Spinner(12));
        summary.Children.Add(Ui.Caption(git.Changes.Count == 0 ? L.T("Changes_None", "No uncommitted changes") : Fmt.Plural(git.Changes.Count, "file changed", "files changed")));
        if (git.Changes.Count > 0) summary.Children.Add(Ui.DiffStat(git.TotalAdditions, git.TotalDeletions));
        header.Children.Add(Ui.Columns((summary, Ui.Star), (git.Changes.Count > 0 ? WrapToggle() : null, Ui.Auto), (Ui.IconButton("", L.T("Common_Refresh", "Refresh"), () => git.Refresh().Forget()), Ui.Auto)));
        if (git.Unpushed.Count > 0)
        {
            header.Children.Add(Ui.Text(L.F("Changes_Unpushed", "Unpushed commits · {0}", git.Unpushed.Count), 12, "muted", FontWeights.SemiBold));
            foreach (var c in git.Unpushed.Take(6)) header.Children.Add(Ui.H(6, Ui.Text(c.Short, 12, "muted", mono: true), Ui.Text(c.Subject, 12)));
        }
        if (git.Changes.Count == 0)
        {
            empty.Content = Ui.Empty("", "green", L.T("Changes_Help", "Changes Claude makes will show up here automatically"));
            empty.Visibility = Visibility.Visible;
            html.Visibility = Visibility.Collapsed;
            return;
        }
        empty.Visibility = Visibility.Collapsed;
        html.Visibility = Visibility.Visible;
        foreach (var f in git.Changes.Where(f => f.Lines.Count > 1500)) collapsed.Add(f.Id);
        html.Render(DiffHtml.Render(git.Changes, new DiffRenderOptions { ShowOpen = true, Collapsed = collapsed, Wrap = Wrap }), "diff", null, "flush");
    }
}

public sealed class LocalFilesPanel : Grid
{
    private readonly string root;
    private string dir = "";
    private string? file;
    private readonly TextBlock pathText = Ui.Text("", 12, "muted", mono: true);
    private readonly ListView list = ListSupport.Create("GenericRowTemplate");
    private readonly HtmlView html = new();
    private readonly ContentControl preview = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };

    public LocalFilesPanel(string root)
    {
        this.root = root;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 140 });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1.2, GridUnitType.Star), MinHeight = 160 });
        var back = Ui.IconButton("", L.T("Common_Back", "Back"), () =>
        {
            if (dir.Length == 0) return;
            dir = dir.Contains('/') ? dir[..dir.LastIndexOf('/')] : "";
            Load();
        });
        var top = Ui.Columns((back, Ui.Auto), (pathText, Ui.Star));
        top.Padding = new Thickness(6, 4, 6, 4);
        Children.Add(top);
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is not EntryItem item) return;
            if (item.Entry.IsDir)
            {
                dir = item.Entry.Path;
                Load();
            }
            else
            {
                file = item.Entry.Path;
                ShowFile().Forget();
            }
        };
        SetRow(list, 1);
        Children.Add(list);
        var line = Ui.Line();
        SetRow(line, 2);
        Children.Add(line);
        SetRow(preview, 3);
        Children.Add(preview);
        preview.Content = Ui.Empty("", "slate", L.T("Files_Pick", "Pick a file"));
        Load();
    }

    private void Load()
    {
        pathText.Text = dir.Length == 0 ? Path.GetFileName(root.TrimEnd('\\', '/')) : dir;
        var basePath = dir.Length == 0 ? root : Path.Combine(root, dir.Replace('/', Path.DirectorySeparatorChar));
        var entries = new List<TreeEntry>();
        try
        {
            foreach (var d in Directory.GetDirectories(basePath))
            {
                var name = Path.GetFileName(d);
                if (name is ".git") continue;
                entries.Add(new TreeEntry { Name = name, Path = dir.Length == 0 ? name : $"{dir}/{name}", Type = "tree" });
            }
            foreach (var f in Directory.GetFiles(basePath))
            {
                var name = Path.GetFileName(f);
                if (name is "desktop.ini" or "Thumbs.db" or ".DS_Store") continue;
                long size = 0;
                try
                {
                    size = new FileInfo(f).Length;
                }
                catch
                {
                }
                entries.Add(new TreeEntry { Name = name, Path = dir.Length == 0 ? name : $"{dir}/{name}", Type = "blob", Object = new BlobMeta { ByteSize = (int)Math.Min(size, int.MaxValue) } });
            }
        }
        catch
        {
        }
        list.ItemsSource = entries.OrderBy(e => e.IsDir ? 0 : 1).ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase).Select(e => new EntryItem(e)).ToList();
    }

    private async Task ShowFile()
    {
        if (file is not { } path) return;
        var full = Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
        var text = await Task.Run(() =>
        {
            try
            {
                var info = new FileInfo(full);
                if (!info.Exists || info.Length > 2_000_000) return null;
                var content = File.ReadAllText(full);
                return content.Contains('\0') ? null : content;
            }
            catch
            {
                return null;
            }
        });
        if (file != path) return;
        if (text is null)
        {
            preview.Content = Ui.Empty("", "slate", L.T("Files_Binary", "Binary or large file"));
            return;
        }
        html.Render(CodeHtml.Render(text, RepoCodeViewModel.Extension(path), false), "code", "top", "flush code-body");
        preview.Content = html;
    }
}

public sealed class BranchPRPanel : Grid
{
    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly ClaudeTab tab;
    private List<SearchItem> branchPRs = new();
    private SearchItem? linked;
    private List<SearchItem> list = new();
    private string scope = "open";
    private bool branchLoading;
    private bool listLoading;
    private string? branchError;
    private string? error;
    private DateTimeOffset? lastUpdated;
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly ListView listView = ListSupport.Create("GenericRowTemplate", ListViewSelectionMode.None);
    private readonly RefreshFooter status = new(compact: true);
    private ItemRef? selected;
    private string loadedKey = "";
    private readonly LiveRefresh live;

    public BranchPRPanel(ClaudeTab tab)
    {
        this.tab = tab;
        live = new LiveRefresh(this, OnLive);
        Children.Add(host);
        listView.ItemClick += (_, e) =>
        {
            switch (e.ClickedItem)
            {
                case PRRowItem p:
                    selected = p.Item.Ref;
                    Render();
                    break;
                case ActionRowItem a:
                    a.Action();
                    break;
            }
        };
        listView.ContextRequested += (_, args) =>
        {
            if ((args.OriginalSource as FrameworkElement)?.DataContext is not PRRowItem p) return;
            args.Handled = true;
            Ui.Menu(
                Ui.MenuItem(L.T("Inspector_OpenInPRs", "Open in PR section"), () => { app.Section = Section.Prs(PRFilter.Mine); app.Open(p.Item.Route); }),
                Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(p.Item.Url)),
                Ui.MenuItem(L.T("Menu_CopyLink", "Copy Link"), () => WindowInterop.Copy(p.Item.Url)),
                Ui.MenuItem(L.T("Menu_CopyShortLink", "Copy Short Link"), () => ShellView.CopyShortLink(ShortLink.Of(p.Item.Repository.NameWithOwner, p.Item.Number)))).ShowAt((FrameworkElement)args.OriginalSource);
        };
        status.Retry = () => Load().Forget();
        Loaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            tab.Git.PropertyChanged += OnGit;
            tab.PropertyChanged -= OnTab;
            tab.PropertyChanged += OnTab;
            app.LiveTick -= live.Tick;
            app.LiveTick += live.Tick;
            app.RefreshRequested -= OnLive;
            app.RefreshRequested += OnLive;
            Load().Forget();
        };
        Unloaded += (_, _) =>
        {
            tab.Git.PropertyChanged -= OnGit;
            tab.PropertyChanged -= OnTab;
            app.LiveTick -= live.Tick;
            app.RefreshRequested -= OnLive;
        };
        Render();
    }

    private RepoRef? Repo => tab.Git.Repo;

    private void OnLive()
    {
        if (selected is null) Load().Forget();
    }

    private void OnGit(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Core.Git.GitWorkingCopy.Changes) && selected is null)
        {
            Render();
            return;
        }
        if (e.PropertyName is nameof(Core.Git.GitWorkingCopy.Repo) or nameof(Core.Git.GitWorkingCopy.Branch) or nameof(Core.Git.GitWorkingCopy.Ahead))
        {
            var key = $"{Repo?.Full}|{tab.Git.Branch}|{tab.Git.Ahead}";
            if (key == loadedKey) return;
            Load().Forget();
        }
    }

    private void OnTab(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ClaudeTab.State) && !tab.Busy && selected is null) LoadBranch().Forget();
    }

    private async Task Load()
    {
        loadedKey = $"{Repo?.Full}|{tab.Git.Branch}|{tab.Git.Ahead}";
        var b = LoadBranch();
        var l = LoadList();
        await Task.WhenAll(b, l);
    }

    private async Task LoadBranch()
    {
        if (app.Api is not { } api || Repo is not { } repo) return;
        var branch = tab.Git.Branch;
        branchLoading = true;
        Render();
        try
        {
            var found = new List<SearchItem>();
            if (branch is not null && branch != "HEAD") found = await api.RepoPullRequests(repo, branch, new[] { "OPEN", "MERGED", "CLOSED" }, 5);
            SearchItem? linkedItem = null;
            if (app.Claude.AllSessions.FirstOrDefault(s => s.Id == tab.SessionId)?.PrNumber is { } number && !found.Any(f => f.Number == number))
            {
                try
                {
                    linkedItem = await api.PullRequestItem(new ItemRef(repo, number));
                }
                catch
                {
                }
            }
            if (branch != tab.Git.Branch || repo != Repo) return;
            branchPRs = found;
            linked = linkedItem;
            branchError = null;
            lastUpdated = DateTimeOffset.Now;
        }
        catch (Exception e)
        {
            branchError = e.Message;
        }
        finally
        {
            branchLoading = false;
            Render();
        }
    }

    private async Task LoadList()
    {
        if (app.Api is not { } api || Repo is not { } repo) return;
        var s = scope;
        listLoading = true;
        Render();
        try
        {
            var items = s switch
            {
                "merged" => await api.RepoPullRequests(repo, states: new[] { "MERGED" }),
                "mine" => (await api.Search($"repo:{repo.Full} is:pr author:@me sort:updated-desc")).Nodes,
                _ => await api.RepoPullRequests(repo, states: new[] { "OPEN" })
            };
            if (s != scope || repo != Repo) return;
            list = items;
            error = null;
            lastUpdated = DateTimeOffset.Now;
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        finally
        {
            listLoading = false;
            Render();
        }
    }

    private void Render()
    {
        if (selected is { } r)
        {
            if (host.Content is not InspectorPRDetail d || d.Ref != r)
                host.Content = new InspectorPRDetail(tab, r, () =>
                {
                    selected = null;
                    Render();
                });
            return;
        }
        if (Repo is null)
        {
            host.Content = Ui.Empty("", "slate", L.T("Inspector_NoRepo", "Folder isn't linked to a GitHub repository"));
            return;
        }
        var items = new List<object>();
        var branchName = tab.Git.Branch ?? "?";
        items.Add(new HeaderRowItem(L.T("Inspector_ThisBranch", "This branch"), branchName));
        if (branchError is { } be && branchPRs.Count == 0) items.Add(new TextRowItem(be));
        else if (branchPRs.Count == 0 && linked is null && !branchLoading)
        {
            items.Add(new TextRowItem(L.F("Inspector_NoPR", "No PR for branch {0}", branchName)));
            if (tab.Git.Branch is { } b && b != "HEAD" && Repo is { } repo)
            {
                items.Add(new ActionRowItem(L.T("Inspector_OpenPRAgent", "Open PR with agent"), () => app.Claude.Send(AgentShip.OpenPRPrompt(b, null, tab.Git.Changes.Count > 0, tab.Git.Ahead), tab, submit: true), "\uE8F2"));
                items.Add(new ActionRowItem(L.T("Inspector_CreatePR", "Create PR in browser"), () => LinkBrowser.Open($"https://github.com/{repo.Full}/pull/new/{b}")));
            }
        }
        if (branchPRs.FirstOrDefault(p => p.PrState == "OPEN") is { } open && tab.Git.Changes.Count > 0)
            items.Add(new ActionRowItem(L.F("Inspector_CommitAgent", "Commit and push to #{0} with agent", open.Number), () => app.Claude.Send(AgentShip.CommitPrompt(open.Number), tab, submit: true), "\uE898"));
        items.AddRange(branchPRs.Select(p => new PRRowItem(p, null)));
        if (linked is { } l && !branchPRs.Any(p => p.Number == l.Number)) items.Add(new PRRowItem(l, L.T("Inspector_FromSession", "from this session")));
        var bar = new SelectorBar();
        foreach (var (id, title) in new[] { ("open", L.T("State_Open", "Open")), ("merged", L.T("State_Merged", "Merged")), ("mine", L.T("Inspector_Mine", "Mine")) })
        {
            var item = new SelectorBarItem { Text = title, Tag = id };
            bar.Items.Add(item);
            if (id == scope) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (s, _) =>
        {
            if (s.SelectedItem?.Tag is string id && id != scope)
            {
                scope = id;
                LoadList().Forget();
            }
        };
        if (error is { } err) items.Add(new TextRowItem(err));
        if (list.Count == 0 && !listLoading && error is null) items.Add(new TextRowItem(scope switch
        {
            "mine" => L.T("Inspector_NoPRsByYou", "No pull requests by you"),
            "merged" => L.T("Inspector_NoMergedPRs", "No merged pull requests"),
            _ => L.T("Inspector_NoOpenPRs", "No open pull requests")
        }));
        items.AddRange(list.Select(p => new PRRowItem(p, null)));
        listView.ItemsSource = items;
        status.Update(lastUpdated, branchLoading || listLoading, branchError ?? error);
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var top = Ui.V(4, Ui.Columns((Ui.Text(Repo.Full, 12, "muted", FontWeights.SemiBold), Ui.Star), (status, Ui.Auto)), bar);
        top.Padding = new Thickness(10, 6, 10, 4);
        grid.Children.Add(top);
        if (listView.Parent is Panel p) p.Children.Remove(listView);
        SetRow(listView, 1);
        grid.Children.Add(listView);
        host.Content = grid;
    }
}

public sealed record HeaderRowItem(string Title, string Branch) : IRowContent
{
    public UIElement BuildRow()
    {
        var p = Ui.H(6, Ui.Text(Title, 12, "muted", FontWeights.SemiBold), SessionRow.BranchTag(Branch));
        p.Margin = new Thickness(0, 6, 0, 2);
        return p;
    }
}

public sealed record PRRowItem(SearchItem Item, string? Note) : IRowContent
{
    public UIElement BuildRow()
    {
        var i = Item;
        var meta = Ui.H(6, Ui.Caption($"#{i.Number}"), Ui.Caption(i.Author?.Login ?? ""));
        if (Ui.CiIcon(i.CiState, 11) is { } ci) meta.Children.Add(ci);
        if (i.Additions is { } a && i.Deletions is { } d) meta.Children.Add(Ui.DiffStat(a, d, 11.5));
        if (Note is { } n) meta.Children.Add(Ui.Caption(n, "violet"));
        var grid = Ui.Columns((Ui.StateBadge(i.VisualState, true), Ui.Auto), (Ui.V(3, Ui.Text(i.Title, 13, "text", FontWeights.Medium, maxLines: 2), Ui.Columns((meta, Ui.Star), (Ui.Caption(Fmt.Rel(i.UpdatedAt), "dim"), Ui.Auto))), Ui.Star));
        grid.Padding = new Thickness(0, 4, 0, 4);
        return grid;
    }
}

public sealed class InspectorPRDetail : Grid
{
    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly ClaudeTab tab;
    public ItemRef Ref { get; }
    private readonly Action onBack;
    private PRDetailViewModel? model;
    private readonly StackPanel body = Ui.V(12);
    private readonly RefreshFooter status = new(compact: true);
    private readonly LiveRefresh live;
    private bool showFiles;

    public InspectorPRDetail(ClaudeTab tab, ItemRef r, Action onBack)
    {
        this.tab = tab;
        live = new LiveRefresh(this, OnLive);
        Ref = r;
        this.onBack = onBack;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var back = Ui.Button(L.T("Common_Back", "Back"), onBack, glyph: "");
        var openFull = Ui.Button(L.T("Inspector_OpenFull", "Open full"), () => { app.Section = Section.Prs(PRFilter.Mine); app.Open(Route.Pr(r)); });
        var top = Ui.Columns((back, Ui.Auto), (new Grid(), Ui.Star), (status, Ui.Auto), (Ui.IconButton("", L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open($"https://github.com/{r.Repo.Full}/pull/{r.Number}")), Ui.Auto), (openFull, Ui.Auto));
        top.Padding = new Thickness(8);
        Children.Add(top);
        body.Padding = new Thickness(12);
        var scroll = new ScrollViewer { Content = body };
        SetRow(scroll, 1);
        Children.Add(scroll);
        body.Children.Add(Ui.Loading());
        Loaded += (_, _) =>
        {
            model ??= app.PrModel(r);
            if (model is null) return;
            model.PropertyChanged -= OnModel;
            model.PropertyChanged += OnModel;
            app.LiveTick -= live.Tick;
            app.LiveTick += live.Tick;
            model.FilesInInspector = showFiles;
            status.Retry = () => model.Load(true).Forget();
            model.Open().Forget();
            Render();
        };
        Unloaded += (_, _) =>
        {
            if (model is not null)
            {
                model.PropertyChanged -= OnModel;
                model.FilesInInspector = false;
            }
            app.LiveTick -= live.Tick;
        };
    }

    private void OnLive() => model?.Load(live: true).Forget();

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (model is null) return;
        switch (e.PropertyName)
        {
            case nameof(PRDetailViewModel.Pr):
            case nameof(PRDetailViewModel.Files):
            case nameof(PRDetailViewModel.FilesLoaded):
            case nameof(PRDetailViewModel.FilesError):
            case nameof(PRDetailViewModel.Error):
                Render();
                break;
            case nameof(PRDetailViewModel.Loading):
            case nameof(PRDetailViewModel.LastUpdated):
            case nameof(PRDetailViewModel.RefreshError):
                status.Update(model.LastUpdated, model.Loading, model.RefreshError);
                break;
            case nameof(PRDetailViewModel.ActionError):
                if (model.ActionError is { } err)
                {
                    model.ActionError = null;
                    Dialogs.Alert(XamlRoot, L.T("Common_Error", "Error"), err).Forget();
                }
                break;
        }
    }

    private void Render()
    {
        if (model is null) return;
        body.Children.Clear();
        if (model.Pr is not { } pr)
        {
            body.Children.Add(model.Error is { } e ? Ui.Error(e, () => model.Load().Forget()) : Ui.Loading());
            return;
        }
        var unresolved = pr.ReviewThreads.Items.Where(t => !t.IsResolved).ToList();
        var fix = FixPromptExtractor.Latest(pr);
        body.Children.Add(Ui.V(6,
            Ui.Text(pr.Title, 15, "text", FontWeights.SemiBold, wrap: true, select: true),
            Ui.H(6, Ui.StateBadge(pr.VisualState), Ui.Caption($"#{pr.Number}"), Ui.DiffStat(pr.Additions, pr.Deletions)),
            Ui.H(4, SessionRow.BranchTag(pr.BaseRefName), Ui.Glyph("", 10), SessionRow.BranchTag(pr.HeadRefName))));
        if (pr.IsOpen)
        {
            if (PRContent.MergeStatusBar(model, app, () => { app.Section = Section.Prs(PRFilter.Mine); app.Open(Route.Pr(Ref)); }) is { } bar) body.Children.Add(bar);
            if (PRContent.ReReviewBanner(model, () => { app.Section = Section.Prs(PRFilter.Mine); app.Open(Route.Pr(Ref)); }) is { } rr) body.Children.Add(rr);
        }
        var checks = pr.Checks;
        var stats = Ui.H(14,
            Ui.H(4, Ui.Glyph("", 12, checks.Any(c => c.Outcome == CheckOutcome.Failure) ? "red" : "muted"), Ui.Caption($"{checks.Count(c => c.Outcome == CheckOutcome.Success)}/{checks.Count}")),
            Ui.H(4, Ui.Glyph("", 12, unresolved.Count == 0 ? "muted" : "amber"), Ui.Caption(unresolved.Count.ToString(), unresolved.Count == 0 ? "muted" : "amber")));
        foreach (var r in model.Reviewers) stats.Children.Add(PRContent.ReviewerBadge(r));
        body.Children.Add(stats);
        if (tab.Chat is not null || tab.Running)
        {
            var send = Ui.V(6, Ui.Text(L.T("Inspector_SendToSession", "Send to this session"), 12, "muted", FontWeights.SemiBold));
            if (fix is not null)
                send.Children.Add(Wide(Ui.Button(L.F("Fix_PromptBy", "Fix prompt by @{0}", fix.Author), () => app.Claude.Send(FixPromptExtractor.Wrap(fix, pr, new FixOptions()), tab), glyph: "")));
            var comments = Ui.Button(L.F("Inspector_Unresolved", "Unresolved comments ({0})", unresolved.Count), () =>
                app.Claude.Send(FixPrompt.Build(pr, Ref.Repo, unresolved, FixPrompt.GeneralFeedback(pr), new FixOptions()), tab), glyph: "");
            comments.IsEnabled = unresolved.Count > 0;
            send.Children.Add(Wide(comments));
            send.Children.Add(Wide(Ui.Button(L.T("Inspector_AskReview", "Ask Claude to review this PR"), () =>
                app.Claude.Send($"Review PR #{pr.Number} ({pr.Url}) and briefly summarize what it does and any problems.", tab), glyph: "")));
            body.Children.Add(send);
        }
        if (unresolved.Count > 0)
        {
            var list = Ui.V(8, Ui.Text(L.T("Fix_Unresolved", "Unresolved comments"), 12, "muted", FontWeights.SemiBold));
            foreach (var th in unresolved)
            {
                var item = Ui.V(3, Ui.Text(th.Location, 12, "muted", mono: true));
                if (th.Comments.Items.FirstOrDefault() is { } c)
                {
                    var text = Ui.Text(c.Body, 13, "text", wrap: true, maxLines: 4);
                    item.Children.Add(Ui.Columns((Ui.Avatar(c.Author?.AvatarUrl, 14), Ui.Auto), (text, Ui.Star)));
                }
                list.Children.Add(Ui.Card(item, 8, "sunken", 8));
            }
            body.Children.Add(list);
        }
        var filesHeader = new Expander
        {
            Header = L.F("Inspector_FilesChanged", "Files changed · {0}", pr.ChangedFiles),
            IsExpanded = showFiles,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        var filesPanel = Ui.V(3);
        if (showFiles && model.FilesError is null) model.LoadFiles().Forget();
        if (model.FilesLoaded)
        {
            foreach (var f in model.Files)
                filesPanel.Children.Add(Ui.Columns((Ui.Text(f.StatusLetter, 11, "muted", FontWeights.Bold, mono: true), Ui.Auto), (Ui.Text(f.Id, 12, "text", mono: true), Ui.Star), (Ui.DiffStat(f.Additions, f.Deletions, 11), Ui.Auto)));
        }
        else if (model.FilesError is { } filesError && !model.FilesLoading)
        {
            filesPanel.Children.Add(Ui.Error(filesError, () => model.LoadFiles().Forget()));
        }
        else
        {
            filesPanel.Children.Add(Ui.Loading(28));
        }
        filesHeader.Content = filesPanel;
        filesHeader.Expanding += (_, _) =>
        {
            showFiles = true;
            model.FilesInInspector = true;
            model.LoadFiles().Forget();
        };
        filesHeader.Collapsed += (_, _) =>
        {
            showFiles = false;
            model.FilesInInspector = false;
        };
        body.Children.Add(filesHeader);
        status.Update(model.LastUpdated, model.Loading, model.RefreshError);
    }

    private static Button Wide(Button b)
    {
        b.HorizontalAlignment = HorizontalAlignment.Stretch;
        b.HorizontalContentAlignment = HorizontalAlignment.Left;
        return b;
    }
}
