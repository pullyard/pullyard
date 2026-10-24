using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using Windows.System;

namespace PullYard.Views;

public sealed class StackTab : Grid
{
    private static WeakReference<StackTab>? last;

    public static StackTab? Last => last is not null && last.TryGetTarget(out var t) ? t : null;

    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly PRDetailViewModel model;
    private readonly StackNotes notes = StackNotes.Shared;
    private readonly SelectorBar modes = new();
    private readonly SelectorBarItem listItem;
    private readonly SelectorBarItem graphItem;
    private readonly TextBlock summary = Ui.Caption("");
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private readonly Grid body = new();
    private StackListPane? list;
    private StackGraphView? graph;
    private StackNotesPanel? notesPanel;
    private int? notesFor;
    private int? loading;
    private StackTree? shown;
    private Dictionary<int, ClaudeSessionInfo> sessions = new();
    private bool subscribed;
    private bool syncingMode;

    public StackTab(PRDetailViewModel model)
    {
        this.model = model;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        listItem = new SelectorBarItem { Text = L.T("Stack_List", "List"), Icon = new FontIcon { Glyph = "", FontFamily = Ui.Icons } };
        graphItem = new SelectorBarItem { Text = L.T("Stack_Graph", "Graph"), Icon = new FontIcon { Glyph = "", FontFamily = Ui.Icons } };
        modes.Items.Add(listItem);
        modes.Items.Add(graphItem);
        modes.SelectedItem = IsGraph ? graphItem : listItem;
        modes.SelectionChanged += (_, _) =>
        {
            if (syncingMode) return;
            SwitchMode(modes.SelectedItem == graphItem);
        };
        var bar = Ui.Columns((modes, Ui.Auto), (summary, Ui.Star));
        bar.Padding = new Thickness(12, 2, 12, 2);
        Children.Add(bar);
        var line = Ui.Line();
        SetRow(line, 1);
        Children.Add(line);
        body.Children.Add(host);
        SetRow(body, 2);
        Children.Add(body);

        var esc = new KeyboardAccelerator { Key = VirtualKey.Escape };
        esc.Invoked += (_, e) =>
        {
            if (notesFor is null) return;
            e.Handled = true;
            ShowNotes(null);
        };
        KeyboardAccelerators.Add(esc);
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;

        Loaded += (_, _) =>
        {
            last = new WeakReference<StackTab>(this);
            if (subscribed) return;
            subscribed = true;
            model.PropertyChanged += OnModel;
            notes.Changed += OnNotes;
            Render();
        };
        Unloaded += (_, _) =>
        {
            subscribed = false;
            model.PropertyChanged -= OnModel;
            notes.Changed -= OnNotes;
        };
        Render();
    }

    public int? CurrentNumber => Tree?.Current;

    public void SetGraph(bool on) => modes.SelectedItem = on ? graphItem : listItem;

    public void FitGraph() => graph?.Fit();

    public void FocusGraph() => graph?.FocusCurrent();

    private static bool IsGraph => Settings.Shared.GetString(Keys.StackView) == "graph";

    private StackTree? Tree => model.StackTree;

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PRDetailViewModel.StackTree)) Render();
    }

    private void OnNotes(string key) => DispatcherQueue.TryEnqueue(() =>
    {
        if (Tree is not { } tree || !tree.Nodes.Keys.Any(n => NoteKey(n) == key)) return;
        list?.Show(tree, sessions, loading, NoteKey);
        graph?.Show(tree, sessions, NoteKey);
    });

    public string NoteKey(int number) => StackNotes.Key(model.CacheAccount, model.Api.Host, model.Ref.Repo, number);

    private void Render()
    {
        if (Tree is not { } tree)
        {
            summary.Text = "";
            list = null;
            graph = null;
            shown = null;
            host.Content = Ui.Loading();
            return;
        }
        if (!ReferenceEquals(shown, tree))
        {
            shown = tree;
            sessions = StackUi.MatchSessions(tree);
        }
        summary.Text = (tree.Count == 1 ? L.T("Stack_OnePR", "1 pull request") : L.F("Stack_ManyPRs", "{0} pull requests", tree.Count)) + " " + L.F("Stack_OnBase", "on {0}", tree.Base);
        syncingMode = true;
        modes.SelectedItem = IsGraph ? graphItem : listItem;
        syncingMode = false;
        if (IsGraph)
        {
            list = null;
            graph ??= new StackGraphView(this);
            if (host.Content != graph) host.Content = graph;
            graph.Show(tree, sessions, NoteKey);
        }
        else
        {
            graph = null;
            list ??= new StackListPane(this);
            if (host.Content != list) host.Content = list;
            list.Show(tree, sessions, loading, NoteKey);
        }
        if (notesFor is { } n && !tree.Nodes.ContainsKey(n)) ShowNotes(null);
    }

    private void SwitchMode(bool toGraph)
    {
        Settings.Shared.Set(Keys.StackView, toGraph ? "graph" : "list");
        Render();
        if (!toGraph || Settings.Shared.GetBool(Keys.StackSupportAsked, false)) return;
        Settings.Shared.Set(Keys.StackSupportAsked, true);
        AskSupport().Forget();
    }

    private async Task AskSupport()
    {
        await Task.Delay(600);
        if (XamlRoot is not { } root) return;
        var text = Ui.Text(L.T("Stack_SupportBody", "PullYard is free and built by one developer. If it saves you time, you can be part of it by buying a pizza that keeps it going. We only ask once."), 13, "text", wrap: true);
        var d = Dialogs.Create(root, L.T("Stack_SupportTitle", "Like the stack graph?"), text, L.T("Stack_SupportPizza", "Buy a Pizza 🍕"), close: L.T("Common_OK", "OK"));
        d.DefaultButton = ContentDialogButton.Close;
        if (await Dialogs.ShowAsync(d) == ContentDialogResult.Primary) LinkBrowser.OpenDonation();
    }

    public void ShowNotes(int? number)
    {
        if (notesPanel is not null)
        {
            notesPanel.Commit();
            body.Children.Remove(notesPanel);
            notesPanel = null;
        }
        notesFor = number;
        if (number is not { } n || Tree is not { } tree || !tree.Nodes.TryGetValue(n, out var node)) return;
        notesPanel = new StackNotesPanel(NoteKey(n), n, node.Title, notes, () => ShowNotes(null))
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(12)
        };
        body.Children.Add(notesPanel);
    }

    public void Resume(ClaudeSessionInfo session)
    {
        app.Section = Section.Claude;
        app.Claude.Resume(session);
    }

    public void Open(int number, bool inPlace)
    {
        if (loading is not null || Tree is not { } tree) return;
        if (number == tree.Current)
        {
            if (!inPlace) graph?.FocusCurrent();
            return;
        }
        var target = new ItemRef(model.Ref.Repo, number);
        if (app.PrModel(target) is not { } next)
        {
            app.OpenQuietly(Route.Pr(target));
            return;
        }
        next.Tab = PRTab.Stack;
        if (tree.Nodes.TryGetValue(number, out var node))
        {
            var nodes = StackStore.Shared.MemoryNodes(model.CacheAccount, model.Api.Host, model.Ref.Repo) ?? tree.Nodes.Values.ToList();
            next.SeedStack(node, nodes);
        }
        if (!inPlace || next.Pr is not null)
        {
            app.OpenQuietly(Route.Pr(target));
            return;
        }
        LoadInPlace(next, target).Forget();
    }

    private async Task LoadInPlace(PRDetailViewModel next, ItemRef target)
    {
        var here = Route.Pr(model.Ref);
        loading = target.Number;
        Render();
        try
        {
            await next.Load();
        }
        finally
        {
            loading = null;
        }
        if (app.DetailRoot != here || !IsLoaded)
        {
            Render();
            return;
        }
        list?.Remember();
        app.OpenQuietly(Route.Pr(target));
    }

    public static MenuFlyout CardMenu(StackTab owner, StackNode node, bool current, int noteCount)
    {
        return Ui.Menu(
            Ui.MenuItem(L.F("Stack_OpenN", "Open #{0}", node.Number), () => owner.Open(node.Number, false), enabled: !current),
            Ui.MenuItem(noteCount > 0 ? L.T("Stack_NotesMenu", "Notes…") : L.T("Stack_AddNoteMenu", "Add note…"), () => owner.ShowNotes(node.Number), ""),
            Ui.Separator(),
            Ui.MenuItem(L.T("PR_CopyBranch", "Copy branch name"), () => WindowInterop.Copy(node.HeadRefName)));
    }

    public static string NoteTip(int count) =>
        count == 0 ? L.T("Stack_AddNote", "Add a note") : count == 1 ? L.T("Stack_OneNoteOpen", "1 note — click to open") : L.F("Stack_NotesOpen", "{0} notes — click to open", count);
}

public sealed record StackBaseRow(string Base) : IRowContent
{
    public UIElement BuildRow()
    {
        var row = Ui.H(6, Ui.Text("⎇", 13, "muted"), Ui.Text(Base, 13, "muted", mono: true));
        row.Margin = new Thickness(0, 6, 0, 4);
        return row;
    }
}

public sealed record StackListRow(StackNode Node, int Depth, bool Current, bool OnPath, int NoteCount, bool HasSession, bool Opening, bool Dimmed, StackTab Owner) : IRowContent
{
    public UIElement BuildRow()
    {
        var n = Node;
        var marker = Ui.Text(Depth == 0 ? "●" : "↳", Depth == 0 ? 9 : 13, OnPath ? "indigo" : "dim");
        marker.Width = 14;
        marker.TextAlignment = TextAlignment.Center;
        var left = Ui.H(8, new Border { Width = Depth * 22 }, marker, Ui.StateBadge(n.VisualState, true), Ui.Text($"#{n.Number}", 13, "muted", FontWeights.SemiBold));
        ((FrameworkElement)left.Children[2]).VerticalAlignment = VerticalAlignment.Center;
        var title = Ui.Text(n.Title, 13, "text", Current ? FontWeights.SemiBold : FontWeights.Normal);
        var right = Ui.H(8);
        if (n.JiraKey is { } key && !n.HeadRefName.Contains(key, StringComparison.Ordinal)) right.Children.Add(Ui.Text(key, 12, "muted", mono: true));
        if (HasSession)
        {
            var s = Ui.Glyph("", 12, "coral");
            Ui.Tip(s, L.T("Stack_HasSession", "Has a Claude Code session"));
            right.Children.Add(s);
        }
        right.Children.Add(PRContent.BranchChip(n.HeadRefName, Current ? "violet" : "slate"));
        right.Children.Add(NoteButton(NoteCount, () => Owner.ShowNotes(n.Number), true));
        if (Opening) right.Children.Add(Ui.Spinner(14));
        right.Children.Add(StackUi.StatusPill(n.Status));
        var grid = Ui.Columns((left, Ui.Auto), (title, Ui.Star), (right, Ui.Auto));
        grid.ColumnSpacing = 8;
        var border = new Border
        {
            Child = grid,
            Padding = new Thickness(10, 7, 10, 7),
            Margin = new Thickness(0, 1, 0, 1),
            CornerRadius = new CornerRadius(7),
            Background = Current ? Palette.Brush("indigo", 0.12) : null,
            BorderBrush = Palette.Brush("indigo", Current || Opening ? 0.5 : 0),
            BorderThickness = new Thickness(1),
            Opacity = Dimmed ? 0.55 : 1
        };
        border.ContextRequested += (_, e) =>
        {
            e.Handled = true;
            StackTab.CardMenu(Owner, n, Current, NoteCount).ShowAt(border);
        };
        return border;
    }

    public static Button NoteButton(int count, Action onClick, bool zoomed)
    {
        UIElement content = count > 0
            ? Ui.H(3, zoomed ? Ui.Glyph("", 11, "amber") : StackUi.FixedGlyph("", 11, "amber"), zoomed ? Ui.Text(count.ToString(), 12, "amber", FontWeights.SemiBold) : StackUi.Fixed(count.ToString(), 12, "amber", FontWeights.SemiBold))
            : zoomed ? Ui.Glyph("", 11, "dim") : StackUi.FixedGlyph("", 11, "dim");
        var b = new Button
        {
            Content = content,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 2, 4, 2),
            MinWidth = 0,
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center
        };
        Ui.Tip(b, StackTab.NoteTip(count));
        b.Click += (_, _) => onClick();
        return b;
    }
}

public sealed class StackListPane : Grid
{
    private static readonly Dictionary<string, double> Offsets = new();

    private readonly StackTab owner;
    private readonly ListView list;
    private ObservableCollection<object> items = new();
    private ScrollViewer? scroller;
    private string? key;
    private int? current;
    private bool restored;

    public StackListPane(StackTab owner)
    {
        this.owner = owner;
        list = ListSupport.Create("GenericRowTemplate", ListViewSelectionMode.None);
        list.Padding = new Thickness(12, 6, 12, 12);
        list.ItemsSource = items;
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is StackListRow r && !r.Dimmed) owner.Open(r.Node.Number, true);
        };
        Children.Add(list);
        list.Loaded += (_, _) => Restore();
    }

    public void Show(StackTree tree, IReadOnlyDictionary<int, ClaudeSessionInfo> sessions, int? busy, Func<int, string> noteKey)
    {
        var nextKey = $"{tree.Root}|{tree.Base}";
        if (key != nextKey)
        {
            key = nextKey;
            restored = false;
        }
        current = tree.Current;
        var path = tree.PathSet;
        var rows = new List<object> { new StackBaseRow(tree.Base) };
        foreach (var (node, depth) in StackRows.Ordered(tree))
        {
            rows.Add(new StackListRow(node, depth, node.Number == tree.Current, path.Contains(node.Number), StackNotes.Shared.Count(noteKey(node.Number)),
                sessions.ContainsKey(node.Number), busy == node.Number, busy is not null && busy != node.Number, owner));
        }
        if (rows.Count == items.Count)
        {
            for (var i = 0; i < rows.Count; i++)
                if (!Equals(rows[i], items[i])) items[i] = rows[i];
        }
        else
        {
            var offset = scroller?.VerticalOffset;
            items = new ObservableCollection<object>(rows);
            list.ItemsSource = items;
            if (offset is { } o && restored) DispatcherQueue.TryEnqueue(() => scroller?.ChangeView(null, o, null, true));
        }
        Restore();
    }

    public void Remember()
    {
        if (key is not null && scroller is not null) Offsets[key] = scroller.VerticalOffset;
    }

    private void Restore()
    {
        if (restored || key is null || !list.IsLoaded) return;
        scroller ??= Find<ScrollViewer>(list);
        if (scroller is null) return;
        restored = true;
        scroller.ViewChanged -= OnViewChanged;
        scroller.ViewChanged += OnViewChanged;
        if (Offsets.TryGetValue(key, out var offset))
        {
            list.UpdateLayout();
            scroller.ChangeView(null, offset, null, true);
        }
        else if (items.OfType<StackListRow>().FirstOrDefault(r => r.Node.Number == current) is { } row)
        {
            list.ScrollIntoView(row, ScrollIntoViewAlignment.Default);
        }
    }

    private void OnViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (!e.IsIntermediate) Remember();
    }

    private static T? Find<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T t) return t;
            if (Find<T>(child) is { } found) return found;
        }
        return null;
    }
}

public sealed class StackNotesPanel : Grid
{
    private readonly string key;
    private readonly StackNotes store;
    private readonly List<StackNote> drafts;
    private readonly StackPanel rows = Ui.V(12);
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private bool committed = true;

    public StackNotesPanel(string key, int number, string title, StackNotes store, Action onClose)
    {
        this.key = key;
        this.store = store;
        drafts = store.Notes(key);
        if (drafts.Count == 0) drafts.Add(StackNote.Blank());
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(700);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Commit();

        var titleText = Ui.Caption(title);
        var head = Ui.Columns(
            (Ui.Glyph("", 14, "amber"), Ui.Auto),
            (Ui.V(2, Ui.Text(L.F("Notes_Title", "Notes on #{0}", number), 15, "text", FontWeights.SemiBold), titleText), Ui.Star),
            (Ui.IconButton("", L.T("Notes_Close", "Close (Esc)"), onClose, "text"), Ui.Auto));
        foreach (var d in drafts) rows.Children.Add(Row(d));
        var scroll = new ScrollViewer { Content = rows, MaxHeight = 360, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 4, 0) };
        var add = Ui.Button(L.T("Notes_Add", "Add note"), () =>
        {
            var n = StackNote.Blank();
            drafts.Add(n);
            var row = Row(n);
            rows.Children.Add(row);
            row.Loaded += (_, _) => (row.Tag as TextBox)?.Focus(FocusState.Programmatic);
        }, glyph: "");
        add.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        add.BorderThickness = new Thickness(0);
        var foot = Ui.Columns((add, Ui.Auto), (Ui.Caption(L.T("Notes_Local", "Only on this PC"), "dim"), Ui.Auto));
        ((FrameworkElement)foot.Children[1]).HorizontalAlignment = HorizontalAlignment.Right;
        foot.ColumnDefinitions[1].Width = Ui.Star;

        Children.Add(Ui.V(10, head, scroll, foot));
        Width = 340;
        Padding = new Thickness(14);
        CornerRadius = new CornerRadius(10);
        Background = Palette.Brush("raised");
        BorderBrush = Palette.Brush("text", 0.16);
        BorderThickness = new Thickness(1);
        Shadow = new ThemeShadow();
        Translation = new System.Numerics.Vector3(0, 0, 24);
        store.Changed += OnStoreChanged;
        Unloaded += (_, _) =>
        {
            store.Changed -= OnStoreChanged;
            Commit();
            store.Flush().Forget();
        };
    }

    private FrameworkElement Row(StackNote note)
    {
        var id = note.Id;
        var kinds = new SelectorBar();
        foreach (var k in Enum.GetValues<StackNoteKind>())
        {
            var item = new SelectorBarItem { Text = k.Title(), Tag = k };
            kinds.Items.Add(item);
            if (k == note.Kind) kinds.SelectedItem = item;
        }
        kinds.SelectionChanged += (s, _) =>
        {
            if (s.SelectedItem?.Tag is StackNoteKind k) Update(id, d => d with { Kind = k });
        };
        var box = new TextBox
        {
            Text = note.Text,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 64,
            Background = Palette.Brush("amber", 0.10),
            PlaceholderText = L.T("Notes_Placeholder", "Write a note")
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        box.TextChanged += (_, _) => Update(id, d => d with { Text = box.Text });
        FrameworkElement? row = null;
        var delete = Ui.IconButton("", L.T("Notes_Delete", "Delete note"), () =>
        {
            drafts.RemoveAll(d => d.Id == id);
            if (row is not null) rows.Children.Remove(row);
            Commit(force: true);
        });
        var top = note.Source is { } source
            ? Ui.Columns((kinds, Ui.Star), (AgentChip(source), Ui.Auto), (delete, Ui.Auto))
            : Ui.Columns((kinds, Ui.Star), (delete, Ui.Auto));
        row = Ui.V(6, top, box);
        row.Tag = box;
        return row;
    }

    public static FrameworkElement AgentChip(string source)
    {
        var chip = Ui.Chip(source, "coral", "\uE756");
        Ui.Tip(chip, L.F("Notes_AddedBy", "Added by {0}", source));
        return chip;
    }

    private void OnStoreChanged(string changed)
    {
        if (changed != key) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!committed) return;
            var known = drafts.Select(d => d.Id).ToHashSet();
            var arrived = store.Notes(key).Where(n => !known.Contains(n.Id)).ToList();
            if (arrived.Count == 0) return;
            if (drafts.Count == 1 && drafts[0].IsEmpty && rows.Children.Count == 1)
            {
                drafts.Clear();
                rows.Children.Clear();
            }
            foreach (var n in arrived)
            {
                drafts.Add(n);
                rows.Children.Add(Row(n));
            }
        });
    }

    private void Update(Guid id, Func<StackNote, StackNote> change)
    {
        var i = drafts.FindIndex(d => d.Id == id);
        if (i < 0) return;
        drafts[i] = change(drafts[i]);
        committed = false;
        timer.Stop();
        timer.Start();
    }

    public void Commit(bool force = false)
    {
        timer.Stop();
        if (committed && !force) return;
        committed = true;
        store.Replace(key, drafts);
    }
}
