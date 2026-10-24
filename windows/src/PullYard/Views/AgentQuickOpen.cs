using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PullYard.Controls;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using Windows.System;

namespace PullYard.Views;

public enum QuickEntryKind { Tab, Session, Match, NewSession }

public sealed record QuickEntry(QuickEntryKind Kind, string Id) : IRowContent
{
    public ClaudeTab? Tab { get; init; }
    public ClaudeSessionInfo? Session { get; init; }
    public ClaudeProject? Project { get; init; }
    public string ProjectName { get; init; } = "";
    public string Snippet { get; init; } = "";

    public UIElement BuildRow()
    {
        var ws = AppViewModel.Shared.Claude;
        Grid grid;
        switch (Kind)
        {
            case QuickEntryKind.Tab when Tab is { } t:
                grid = Ui.Columns((SessionDot.ForTab(t), Ui.Auto), (Ui.Text(t.Title, 13.5), Ui.Star), (Ui.Caption(L.F("Agents_QuickOpenTab", "open · {0}", t.ProjectName), "dim"), Ui.Auto));
                break;
            case QuickEntryKind.Session when Session is { } s:
                grid = Ui.Columns((SessionDot.ForSession(s, ws), Ui.Auto), (Ui.Text(s.Title, 13.5), Ui.Star), (Ui.Caption(ProjectName + " · " + Fmt.Rel(s.Modified), "dim"), Ui.Auto));
                break;
            case QuickEntryKind.Match when Session is { } m:
                var head = Ui.Columns((Ui.Text(m.Title, 13.5), Ui.Star), (Ui.Caption(ProjectName + " · " + Fmt.Rel(m.Modified), "dim"), Ui.Auto));
                var snippet = Ui.Text(Snippet, 12, "muted");
                snippet.TextTrimming = TextTrimming.CharacterEllipsis;
                var glyph = Ui.Glyph("", 12, "violet");
                glyph.Width = 14;
                grid = Ui.Columns((glyph, Ui.Auto), (Ui.V(2, head, snippet), Ui.Star));
                break;
            case QuickEntryKind.NewSession when Project is { } p:
                var plus = Ui.Glyph("", 12, "violet");
                plus.Width = 14;
                grid = Ui.Columns((plus, Ui.Auto), (Ui.H(4, Ui.Text(L.T("Agents_NewSessionIn", "New session in"), 13.5, "muted"), Ui.Text(p.Name, 13.5, "text", FontWeights.Medium)), Ui.Star));
                break;
            default:
                grid = new Grid();
                break;
        }
        grid.ColumnSpacing = 10;
        grid.Padding = new Thickness(0, 7, 0, 7);
        return grid;
    }
}

public sealed class AgentQuickOpen
{
    private readonly AppViewModel app = AppViewModel.Shared;
    private ClaudeWorkspace Ws => app.Claude;
    private readonly TextBox box = new() { PlaceholderText = L.T("Agents_QuickOpenPlaceholder", "Go to a session, search conversations, or start one in a project…"), FontSize = 15 };
    private readonly ListView list = ListSupport.Create("GenericRowTemplate");
    private readonly ContentControl leading = new() { Width = 18, VerticalAlignment = VerticalAlignment.Center, IsTabStop = false };
    private readonly TextBlock empty = Ui.Text("", 13, "muted");
    private Dictionary<string, string> matches = new(StringComparer.OrdinalIgnoreCase);
    private List<QuickEntry> entries = new();
    private CancellationTokenSource? searchCts;
    private ContentDialog? dialog;
    private static bool showing;

    public static async Task Show(XamlRoot? root)
    {
        if (root is null || showing || !ClaudeAccountStore.Shared.IsLoggedIn) return;
        showing = true;
        try
        {
            await new AgentQuickOpen().Run(root);
        }
        finally
        {
            showing = false;
        }
    }

    private async Task Run(XamlRoot root)
    {
        leading.Content = Ui.Glyph("", 14, "muted");
        var top = Ui.Columns((leading, Ui.Auto), (box, Ui.Star));
        top.ColumnSpacing = 10;
        list.Height = 340;
        list.Width = 580;
        list.SelectionMode = ListViewSelectionMode.Single;
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is QuickEntry entry) Open(entry);
        };
        empty.Margin = new Thickness(12);
        empty.Visibility = Visibility.Collapsed;
        var listArea = new Grid();
        listArea.Children.Add(list);
        listArea.Children.Add(empty);
        var hints = Ui.H(14, Hint("↑↓", L.T("Agents_HintSelect", "select")), Hint("↵", L.T("Agents_HintOpen", "open")), Hint("Esc", L.T("Agents_HintClose", "close")));
        var panel = Ui.V(8, top, Ui.Line(), listArea, Ui.Line(), hints);
        dialog = Dialogs.Create(root, L.T("Agents_QuickOpenTitle", "Go to session"), panel, close: L.T("Common_Close", "Close"), maxWidth: 680);
        box.TextChanged += (_, _) =>
        {
            Rebuild(true);
            SearchContent();
        };
        box.PreviewKeyDown += OnKey;
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        dialog.Closed += (_, _) => searchCts?.Cancel();
        Rebuild(true);
        await Dialogs.ShowAsync(dialog);
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
                if (list.SelectedItem is QuickEntry entry) Open(entry);
                e.Handled = true;
                break;
        }
    }

    private void Move(int delta)
    {
        if (entries.Count == 0) return;
        var i = list.SelectedIndex < 0 ? 0 : list.SelectedIndex;
        list.SelectedIndex = ((i + delta) % entries.Count + entries.Count) % entries.Count;
        list.ScrollIntoView(list.SelectedItem);
    }

    private static bool Hit(string q, params string?[] parts) => q.Length == 0 || parts.Any(p => p?.Contains(q, StringComparison.OrdinalIgnoreCase) == true);

    private void Rebuild(bool resetSelection)
    {
        var q = box.Text.Trim();
        var prefs = AgentSessionPrefs.Shared;
        var result = new List<QuickEntry>();
        var openIds = new HashSet<string>(Ws.Tabs.Select(t => t.SessionId).Where(id => id.Length > 0));
        foreach (var t in Ws.Tabs.Where(t => Hit(q, t.Title, t.ProjectName)))
            result.Add(new QuickEntry(QuickEntryKind.Tab, "t" + t.Id) { Tab = t, ProjectName = t.ProjectName });
        var sessions = Ws.Projects
            .SelectMany(p => p.Sessions.Where(s => !prefs.IsArchived(s) && !openIds.Contains(s.Id)).Select(s => (Session: prefs.Apply(s), Project: p.Name)))
            .Where(x => Hit(q, x.Session.Title, x.Project, x.Session.Branch))
            .OrderByDescending(x => x.Session.Modified)
            .Take(q.Length == 0 ? 12 : 40)
            .ToList();
        foreach (var (s, project) in sessions)
            result.Add(new QuickEntry(QuickEntryKind.Session, "s" + s.Id) { Session = s, ProjectName = project });
        if (q.Length >= 3 && matches.Count > 0)
        {
            var shown = new HashSet<string>(sessions.Select(x => x.Session.Id));
            var found = Ws.Projects
                .SelectMany(p => p.Sessions.Where(s => !shown.Contains(s.Id) && matches.ContainsKey(s.File)).Select(s => (Session: prefs.Apply(s), Project: p.Name)))
                .OrderByDescending(x => x.Session.Modified)
                .Take(30);
            foreach (var (s, project) in found)
                result.Add(new QuickEntry(QuickEntryKind.Match, "m" + s.Id) { Session = s, ProjectName = project, Snippet = matches[s.File] });
        }
        foreach (var p in Ws.Projects.Where(p => p.Exists && Hit(q, p.Name, "new")).Take(q.Length == 0 ? 4 : 8))
            result.Add(new QuickEntry(QuickEntryKind.NewSession, "n" + p.Id) { Project = p, ProjectName = p.Name });
        var selectedId = resetSelection ? null : (list.SelectedItem as QuickEntry)?.Id;
        entries = result;
        list.ItemsSource = entries;
        var index = selectedId is null ? 0 : Math.Max(0, entries.FindIndex(e => e.Id == selectedId));
        if (entries.Count > 0) list.SelectedIndex = index;
        empty.Text = L.F("Agents_QuickOpenEmpty", "Nothing matches “{0}”", q);
        empty.Visibility = entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SearchContent()
    {
        searchCts?.Cancel();
        var q = box.Text.Trim();
        if (q.Length < 3)
        {
            if (matches.Count > 0)
            {
                matches = new(StringComparer.OrdinalIgnoreCase);
                Rebuild(false);
            }
            SetSearching(false);
            return;
        }
        var cts = new CancellationTokenSource();
        searchCts = cts;
        var files = Ws.SessionFiles();
        Search().Forget();

        async Task Search()
        {
            try
            {
                await Task.Delay(250, cts.Token);
                SetSearching(true);
                var found = await Task.Run(() => SessionIndex.Shared.Search(q, files, cts.Token), cts.Token);
                if (cts.IsCancellationRequested) return;
                matches = found;
                Rebuild(false);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "conversation search failed");
            }
            finally
            {
                if (searchCts == cts) SetSearching(false);
            }
        }
    }

    private void SetSearching(bool on) => leading.Content = on ? Ui.Spinner(14) : Ui.Glyph("", 14, "muted");

    private void Open(QuickEntry entry)
    {
        app.Section = Section.Claude;
        switch (entry.Kind)
        {
            case QuickEntryKind.Tab when entry.Tab is { } t:
                Ws.SelectedTab = t;
                break;
            case QuickEntryKind.Session or QuickEntryKind.Match when entry.Session is { } s:
                Ws.Resume(s);
                break;
            case QuickEntryKind.NewSession when entry.Project is { } p:
                Ws.NewSession(p.Path);
                break;
        }
        dialog?.Hide();
    }
}
