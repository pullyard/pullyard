using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Jira;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public static class JiraService
{
    public static JiraAccount Account { get; } = new(Settings.Shared, new CredentialVault());

    public const string TokenUrl = "https://id.atlassian.com/manage-profile/security/api-tokens";

    public static string StatusColor(string category) => category switch
    {
        "done" => "green",
        "indeterminate" => "sky",
        _ => "muted"
    };

    public static string PriorityColor(string? priority) => (priority ?? "").ToLowerInvariant() switch
    {
        "highest" or "blocker" or "critical" => "red",
        "high" or "major" => "coral",
        "medium" => "amber",
        _ => "muted"
    };

    public static (string Glyph, string Color) TypeIcon(string? type)
    {
        var t = type?.ToLowerInvariant() ?? "";
        if (t.Contains("bug")) return ("", "red");
        if (t.Contains("epic")) return ("", "violet");
        if (t.Contains("story")) return ("", "green");
        if (t.Contains("sub")) return ("", "sky");
        return ("", "sky");
    }
}

public sealed class JiraConnectForm : Grid
{
    private readonly JiraAccount account = JiraService.Account;
    private readonly TextBox site = new() { PlaceholderText = L.T("Jira_SitePlaceholder", "Jira address — acme.atlassian.net") };
    private readonly TextBox email = new() { PlaceholderText = L.T("Jira_EmailPlaceholder", "Atlassian account email (empty for a Data Center token)") };
    private readonly PasswordBox token = new() { PlaceholderText = L.T("Jira_TokenPlaceholder", "API token") };
    private readonly TextBlock error = Ui.Text("", 12, "red", wrap: true, select: true);
    private readonly StackPanel body = Ui.V(10);
    private bool busy;

    public JiraConnectForm()
    {
        site.Text = account.Site;
        email.Text = account.Email;
        token.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Connect();
        };
        Children.Add(body);
        Loaded += (_, _) =>
        {
            account.Changed -= OnChanged;
            account.Changed += OnChanged;
            Render();
        };
        Unloaded += (_, _) => account.Changed -= OnChanged;
        Render();
    }

    private void OnChanged() => DispatcherQueue.TryEnqueue(Render);

    private void Render()
    {
        body.Children.Clear();
        if (account.IsConfigured)
        {
            var info = Ui.V(1, Ui.Text(account.DisplayName ?? L.T("Jira_Connected", "Connected"), 13, "text"), Ui.Caption(account.BaseUrl?.Host ?? ""));
            var row = Ui.Columns((Ui.Glyph("", 16, "green"), Ui.Auto), (info, Ui.Star), (Ui.Button(L.T("Jira_Disconnect", "Disconnect"), account.Disconnect), Ui.Auto));
            row.ColumnSpacing = 10;
            body.Children.Add(row);
            return;
        }
        body.Children.Add(Ui.Text(L.T("Jira_ConnectHint", "Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in Windows Credential Manager."), 13, "muted", wrap: true));
        body.Children.Add(site);
        body.Children.Add(email);
        var connect = Ui.Button(L.T("Jira_Connect", "Connect"), Connect, accent: true);
        if (busy)
        {
            connect.Content = Ui.Spinner(14);
            connect.IsEnabled = false;
        }
        if (token.Parent is Panel old) old.Children.Remove(token);
        var row2 = Ui.Columns((token, Ui.Star), (connect, Ui.Auto));
        body.Children.Add(row2);
        body.Children.Add(Ui.Link(L.T("Jira_CreateToken", "Create an API token at id.atlassian.com"), () => LinkBrowser.Open(JiraService.TokenUrl)));
        error.Visibility = error.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        body.Children.Add(error);
    }

    private async void Connect()
    {
        if (busy || site.Text.Trim().Length == 0 || token.Password.Trim().Length == 0) return;
        busy = true;
        error.Text = "";
        Render();
        try
        {
            await account.Connect(site.Text, email.Text, token.Password);
            token.Password = "";
        }
        catch (Exception e)
        {
            error.Text = e.Message;
        }
        busy = false;
        Render();
    }
}

public static class JiraUi
{
    public static SolidColorBrush LineBrush() => Palette.Brush("text", ThemeService.IsDark ? 0.10 : 0.08);

    public static Border Panel(UIElement child, double radius = 12, double padding = 16) => new()
    {
        Background = Palette.Brush("raised"),
        BorderBrush = LineBrush(),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(radius),
        Padding = new Thickness(padding),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = child
    };

    public static Border StatusPill(string status, string category, bool chevron = false, bool busy = false)
    {
        var color = JiraService.StatusColor(category);
        var dot = busy
            ? (UIElement)Ui.Spinner(10)
            : new Border { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = Palette.Brush(color), VerticalAlignment = VerticalAlignment.Center };
        var row = Ui.H(5, dot, Ui.Text(status.ToUpperInvariant(), 11.5, color, FontWeights.Bold), chevron ? Ui.Glyph("", 8, color) : null);
        return new Border
        {
            Background = Palette.Brush(color, 0.14),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(10, 3, 10, 4),
            Child = row,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static Button Plain(UIElement content, Action onClick, string? tooltip = null)
    {
        var b = new Button
        {
            Content = content,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Left
        };
        b.Click += (_, _) => onClick();
        Ui.Tip(b, tooltip);
        return b;
    }

    public static Button Small(string text, string glyph, Action onClick, bool accent = false, string? tooltip = null)
    {
        var b = Ui.Button(text, onClick, accent, glyph, tooltip);
        b.Padding = new Thickness(10, 4, 10, 5);
        return b;
    }
}

public sealed class JiraTab : Grid
{
    private readonly PRDetailViewModel model;
    private readonly JiraAccount account = JiraService.Account;
    private readonly StackPanel content = Ui.V(16);
    private readonly Dictionary<string, JiraIssue> issues = new();
    private readonly Dictionary<string, string> errors = new();
    private readonly HashSet<string> pending = new();
    private readonly HashSet<string> open = new();
    private readonly Dictionary<string, (JiraIssue Issue, bool Manual, bool Primary, JiraIssueCard Card)> cards = new();
    private readonly TextBox manual = new() { PlaceholderText = L.T("Jira_KeyPlaceholder", "Ticket key, e.g. ABC-123"), MaxWidth = 220, MinWidth = 180 };
    private readonly Button linkButton;
    private string loadedFor = "";
    private bool linking;
    private bool subscribed;

    public JiraTab(PRDetailViewModel model)
    {
        this.model = model;
        content.MaxWidth = 860;
        content.Padding = new Thickness(20);
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        linkButton = Ui.Button(L.T("Jira_Link", "Link"), Link, accent: true);
        linkButton.IsEnabled = false;
        manual.TextChanged += (_, _) => linkButton.IsEnabled = JiraKeys.Normalize(manual.Text) is not null;
        manual.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Link();
            else if (e.Key == Windows.System.VirtualKey.Escape) SetLinking(false);
        };
        Loaded += (_, _) =>
        {
            if (subscribed) return;
            subscribed = true;
            account.Changed += OnAccount;
            model.PropertyChanged += OnModel;
            Render();
        };
        Unloaded += (_, _) =>
        {
            subscribed = false;
            account.Changed -= OnAccount;
            model.PropertyChanged -= OnModel;
        };
        Render();
    }

    private void OnAccount() => DispatcherQueue.TryEnqueue(Render);

    private void OnModel(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PRDetailViewModel.Pr)) Render();
    }

    private void Render()
    {
        if (model.Pr is not { } pr) return;
        var keys = account.Keys(pr);
        var linked = account.LinkedKeys(pr.Url);
        content.Children.Clear();
        if (!account.IsConfigured)
        {
            content.Children.Add(JiraUi.Panel(Ui.V(10, Ui.H(8, Ui.IconTile("", "sky", 22), Ui.Text(L.T("Jira_Title", "Jira"), 14, "text", FontWeights.SemiBold)), new JiraConnectForm())));
            return;
        }
        content.Children.Add(Header(keys.Count));
        if (linking) content.Children.Add(LinkField());
        if (keys.Count == 0) content.Children.Add(EmptyState());
        for (var i = 0; i < keys.Count; i++) content.Children.Add(Entry(keys[i], i == 0, linked.Contains(keys[i])));
        foreach (var stale in cards.Keys.Where(k => !keys.Contains(k)).ToList()) cards.Remove(stale);
        var signature = $"{account.IsConfigured}|{string.Join(",", keys)}";
        if (signature != loadedFor)
        {
            loadedFor = signature;
            Load(keys).Forget();
        }
    }

    private FrameworkElement Header(int count)
    {
        var title = Ui.Text(count == 1 ? L.T("Jira_LinkedOne", "1 linked ticket") : L.F("Jira_LinkedMany", "{0} linked tickets", count), 14, "text", FontWeights.SemiBold);
        var info = Ui.V(1, title, Ui.Caption(account.BaseUrl?.Host ?? ""));
        var toggle = JiraUi.Small(L.T("Jira_LinkTicket", "Link ticket"), linking ? "" : "", () => SetLinking(!linking));
        var refresh = Ui.IconButton("", L.T("Jira_Reload", "Reload from Jira"), Reload, "text");
        var actions = Ui.H(8, pending.Count > 0 ? Ui.Spinner(14) : null, toggle, refresh);
        var row = Ui.Columns((Ui.IconTile("", "sky", 26), Ui.Auto), (info, Ui.Star), (actions, Ui.Auto));
        row.ColumnSpacing = 10;
        return row;
    }

    private FrameworkElement LinkField()
    {
        if (manual.Parent is Panel old) old.Children.Remove(manual);
        if (linkButton.Parent is Panel oldButton) oldButton.Children.Remove(linkButton);
        var row = new WrapPanel(8, Ui.Glyph("", 13, "muted"), manual, linkButton, Ui.Caption(L.T("Jira_LinkSaved", "Saved for this pull request on this PC."), "dim")) { VerticalSpacing = 8 };
        return new Border
        {
            Background = Palette.Brush("text", 0.04),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Child = row
        };
    }

    private FrameworkElement EmptyState()
    {
        var hint = Ui.Text(L.T("Jira_NoTicketHint", "PullYard looks for keys like ABC-123 in the title, branch name and description."), 13, "muted", wrap: true);
        hint.TextAlignment = TextAlignment.Center;
        var title = Ui.Text(L.T("Jira_NoTicket", "No Jira ticket on this pull request"), 14, "text", FontWeights.SemiBold);
        var icon = Ui.Glyph("", 30, "dim");
        var panel = Ui.V(10, icon, title, hint);
        foreach (var c in panel.Children) ((FrameworkElement)c).HorizontalAlignment = HorizontalAlignment.Center;
        if (!linking)
        {
            var b = JiraUi.Small(L.T("Jira_LinkATicket", "Link a ticket"), "", () => SetLinking(true));
            b.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(b);
        }
        panel.HorizontalAlignment = HorizontalAlignment.Stretch;
        panel.MaxWidth = 460;
        panel.Margin = new Thickness(0, 36, 0, 36);
        return panel;
    }

    private UIElement Entry(string key, bool primary, bool isManual)
    {
        if (issues.TryGetValue(key, out var issue))
        {
            if (primary || open.Contains(key)) return Card(key, issue, primary, isManual);
            return new JiraIssueRow(issue, () =>
            {
                open.Add(key);
                Render();
            });
        }
        if (errors.TryGetValue(key, out var err))
        {
            var message = Ui.Text(err, 13, "muted", maxLines: 2, select: true);
            var left = Ui.H(8, Ui.Glyph("", 13, "amber"), Ui.Text(key, 13, "text", FontWeights.SemiBold, mono: true));
            var row = Ui.Columns((left, Ui.Auto), (message, Ui.Star), (isManual ? JiraUi.Small(L.T("Jira_Unlink", "Unlink"), "", () => Unlink(key)) : null, Ui.Auto));
            return JiraUi.Panel(row);
        }
        return JiraUi.Panel(Ui.H(10, Ui.Spinner(16), Ui.Text(key, 13, "muted", mono: true)));
    }

    private JiraIssueCard Card(string key, JiraIssue issue, bool primary, bool isManual)
    {
        if (cards.TryGetValue(key, out var hit) && ReferenceEquals(hit.Issue, issue) && hit.Manual == isManual && hit.Primary == primary) return hit.Card;
        Action? collapse = primary ? null : () =>
        {
            open.Remove(key);
            Render();
        };
        var card = new JiraIssueCard(issue, isManual, () => Unlink(key), collapse, updated =>
        {
            account.Remember(updated);
            issues[updated.Key] = updated;
            Render();
        });
        cards[key] = (issue, isManual, primary, card);
        return card;
    }

    private void SetLinking(bool on)
    {
        linking = on;
        if (!on) manual.Text = "";
        Render();
        if (on) DispatcherQueue.TryEnqueue(() => manual.Focus(FocusState.Programmatic));
    }

    private void Reload()
    {
        issues.Clear();
        errors.Clear();
        cards.Clear();
        account.ClearCache();
        loadedFor = "";
        Render();
    }

    private void Link()
    {
        if (model.Pr is not { } pr) return;
        if (account.Link(pr.Url, manual.Text) is null) return;
        manual.Text = "";
        linking = false;
        Render();
    }

    private void Unlink(string key)
    {
        if (model.Pr is not { } pr) return;
        issues.Remove(key);
        errors.Remove(key);
        open.Remove(key);
        cards.Remove(key);
        account.Unlink(pr.Url, key);
    }

    private async Task Load(List<string> keys)
    {
        foreach (var key in keys)
            if (!issues.ContainsKey(key) && account.CachedIssue(key) is { } hit) issues[key] = hit;
        var todo = keys.Where(k => !issues.ContainsKey(k) && !errors.ContainsKey(k) && pending.Add(k)).ToList();
        RenderIfLoaded();
        if (todo.Count == 0) return;
        var tasks = todo.Select(async key =>
        {
            try
            {
                var issue = await account.Load(key);
                issues[key] = issue;
                errors.Remove(key);
            }
            catch (Exception e)
            {
                errors[key] = e.Message;
            }
            finally
            {
                pending.Remove(key);
            }
            RenderIfLoaded();
        });
        await Task.WhenAll(tasks);
    }

    private void RenderIfLoaded()
    {
        if (IsLoaded) Render();
    }
}

public sealed class JiraIssueRow : Button
{
    public JiraIssueRow(JiraIssue issue, Action onOpen)
    {
        var (glyph, color) = JiraService.TypeIcon(issue.Type);
        var summary = Ui.Text(issue.Summary, 13, "muted");
        var row = Ui.Columns(
            (Ui.Glyph(glyph, 13, color), Ui.Auto),
            (Ui.Text(issue.Key, 13, "text", FontWeights.SemiBold, mono: true), Ui.Auto),
            (summary, Ui.Star),
            (JiraUi.StatusPill(issue.Status, issue.StatusCategory), Ui.Auto),
            (Ui.Glyph("", 10, "dim"), Ui.Auto));
        row.ColumnSpacing = 10;
        var rest = Palette.Brush("text", 0.03);
        var hover = Palette.Brush("text", 0.06);
        Content = row;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Padding = new Thickness(14, 10, 14, 10);
        CornerRadius = new CornerRadius(10);
        Background = rest;
        BorderBrush = JiraUi.LineBrush();
        BorderThickness = new Thickness(1);
        Resources["ButtonBackgroundPointerOver"] = hover;
        Resources["ButtonBackgroundPressed"] = Palette.Brush("text", 0.09);
        Resources["ButtonBorderBrushPointerOver"] = JiraUi.LineBrush();
        Resources["ButtonBorderBrushPressed"] = JiraUi.LineBrush();
        Ui.Tip(this, L.T("Jira_ShowDetails", "Show details"));
        Click += (_, _) => onOpen();
    }
}

public sealed class JiraIssueCard : Grid
{
    private const int CollapsedLines = 6;
    private readonly JiraIssue issue;
    private readonly Action<JiraIssue> onChange;
    private readonly StackPanel transitionsPanel = Ui.V(2);
    private readonly TextBlock errorText = Ui.Text("", 12, "red", wrap: true, select: true);
    private readonly Button statusButton = new();
    private readonly Button copyButton;
    private List<JiraTransition>? transitions;
    private bool loadingTransitions;
    private bool moving;
    private bool expanded;
    private readonly TextBlock? description;
    private readonly HyperlinkButton? more;

    public JiraIssueCard(JiraIssue issue, bool manual, Action onUnlink, Action? onCollapse, Action<JiraIssue> onChange)
    {
        this.issue = issue;
        this.onChange = onChange;
        Background = Palette.Brush("raised");
        BorderBrush = JiraUi.LineBrush();
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(14);
        Padding = new Thickness(18);
        HorizontalAlignment = HorizontalAlignment.Stretch;

        var stack = Ui.V(14);

        if (issue.ParentKey is { } parentKey)
        {
            var parentSummary = issue.ParentSummary is { } ps ? Ui.Text(ps, 12, "muted") : null;
            var parentRow = Ui.H(5, Ui.Glyph("", 10, "muted"), Ui.Text(parentKey, 12, "muted", FontWeights.SemiBold, mono: true), parentSummary);
            stack.Children.Add(JiraUi.Plain(parentRow, () =>
            {
                if (JiraService.Account.BaseUrl is { } b) LinkBrowser.Open(JiraAuth.BaseString(b) + "/browse/" + parentKey);
            }, L.T("Jira_ParentTip", "Parent ticket — open in Jira")));
        }

        var (glyph, color) = JiraService.TypeIcon(issue.Type);
        var left = Ui.H(10, Ui.IconTile(glyph, color, 24), Ui.Text(issue.Key, 13, "text", FontWeights.SemiBold, mono: true), issue.Type is { } type ? Ui.Caption(type) : null);
        RenderStatus();
        var flyout = new Flyout { Content = transitionsPanel, Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        flyout.Opening += (_, _) =>
        {
            RenderTransitions();
            LoadTransitions().Forget();
        };
        statusButton.Flyout = flyout;
        statusButton.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        statusButton.BorderThickness = new Thickness(0);
        statusButton.Padding = new Thickness(0);
        Ui.Tip(statusButton, L.T("Jira_ChangeStatus", "Change status"));
        var right = Ui.H(4, statusButton, onCollapse is not null ? Ui.IconButton("", L.T("Jira_Collapse", "Collapse"), onCollapse) : null);
        stack.Children.Add(Ui.Columns((left, Ui.Star), (right, Ui.Auto)));

        stack.Children.Add(Ui.Text(issue.Summary, 17, "text", FontWeights.SemiBold, wrap: true, select: true));
        stack.Children.Add(Meta());

        if (issue.Description.Length > 0)
        {
            description = Ui.Text(issue.Description, 13, "text", wrap: true, select: true);
            description.Opacity = 0.9;
            description.TextWrapping = TextWrapping.Wrap;
            description.MaxLines = CollapsedLines;
            var block = Ui.V(6, Ui.Text(L.T("Jira_Description", "Description"), 12, "dim", FontWeights.SemiBold), description);
            if (issue.Description.Length > 320 || issue.Description.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length > CollapsedLines)
            {
                more = Ui.Link(L.T("Jira_ShowMore", "Show more"), ToggleMore);
                block.Children.Add(more);
            }
            stack.Children.Add(new Border { Background = Palette.Brush("sunken"), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Child = block });
        }

        errorText.Visibility = Visibility.Collapsed;
        stack.Children.Add(errorText);
        stack.Children.Add(Ui.Line());

        copyButton = JiraUi.Small(L.T("Jira_CopyLink", "Copy link"), "", () => Copy().Forget());
        var actions = Ui.H(8, JiraUi.Small(L.T("Jira_Open", "Open in Jira"), "", () => LinkBrowser.Open(issue.Url)), copyButton);
        UIElement? unlink = null;
        if (manual)
        {
            var b = JiraUi.Plain(Ui.H(6, Ui.Glyph("", 12, "red"), Ui.Text(L.T("Jira_Unlink", "Unlink"), 13, "red")), onUnlink);
            b.Padding = new Thickness(8, 4, 8, 5);
            unlink = b;
        }
        stack.Children.Add(Ui.Columns((actions, Ui.Star), (unlink, Ui.Auto)));
        Children.Add(stack);
    }

    private static Border Chip(string? tooltip, params UIElement?[] children)
    {
        var chip = new Border
        {
            Background = Palette.Brush("text", 0.05),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(8, 3, 9, 4),
            Child = Ui.H(5, children),
            VerticalAlignment = VerticalAlignment.Center
        };
        Ui.Tip(chip, tooltip);
        return chip;
    }

    private static TextBlock ChipText(string text)
    {
        var t = Ui.Text(text, 12, "muted");
        t.MaxWidth = 220;
        return t;
    }

    private WrapPanel Meta()
    {
        var meta = new WrapPanel(8) { VerticalSpacing = 6 };
        meta.Children.Add(issue.Assignee is { } a
            ? Chip(L.T("Jira_Assignee", "Assignee"), Ui.Avatar(issue.AssigneeAvatar, 16), ChipText(a))
            : Chip(L.T("Jira_Assignee", "Assignee"), Ui.Glyph("", 11, "muted"), ChipText(L.T("Jira_Unassigned", "Unassigned"))));
        if (issue.Priority is { } p)
            meta.Children.Add(Chip(L.T("Jira_Priority", "Priority"), Ui.Glyph("", 11, JiraService.PriorityColor(p)), ChipText(p)));
        if (issue.Reporter is { } r && r != issue.Assignee)
            meta.Children.Add(Chip(L.T("Jira_Reporter", "Reporter"), Ui.Glyph("", 11, "muted"), ChipText(r)));
        if (issue.Updated is { } u)
            meta.Children.Add(Chip(L.T("Jira_UpdatedTip", "Updated"), Ui.Glyph("", 11, "muted"), ChipText(Fmt.Rel(u))));
        return meta;
    }

    private async Task Copy()
    {
        WindowInterop.Copy(issue.Url);
        copyButton.Content = Ui.H(6, Ui.Glyph("", 12, "green"), new TextBlock { Text = L.T("Jira_Copied", "Copied") });
        await Task.Delay(1200);
        copyButton.Content = Ui.H(6, Ui.Glyph("", 12, "text"), new TextBlock { Text = L.T("Jira_CopyLink", "Copy link") });
    }

    private void ToggleMore()
    {
        if (description is null) return;
        expanded = !expanded;
        description.MaxLines = expanded ? 0 : CollapsedLines;
        if (more is not null) more.Content = expanded ? L.T("Jira_ShowLess", "Show less") : L.T("Jira_ShowMore", "Show more");
    }

    private void RenderStatus()
    {
        statusButton.Content = JiraUi.StatusPill(issue.Status, issue.StatusCategory, chevron: true, busy: moving);
        statusButton.IsEnabled = !moving;
    }

    private void RenderTransitions()
    {
        transitionsPanel.Children.Clear();
        if (transitions is not { Count: > 0 } list)
        {
            transitionsPanel.Children.Add(Ui.Text(loadingTransitions || transitions is null ? L.T("Jira_Loading", "Loading…") : L.T("Jira_NoTransitions", "No transitions available"), 13, "muted"));
            return;
        }
        var header = Ui.Text(L.T("Jira_MoveTo", "Move to"), 12, "dim", FontWeights.SemiBold);
        header.Margin = new Thickness(10, 0, 0, 4);
        transitionsPanel.Children.Add(header);
        foreach (var t in list)
        {
            var item = new Button
            {
                Content = Ui.H(8, new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = Palette.Brush(JiraService.StatusColor(t.ToCategory)), VerticalAlignment = VerticalAlignment.Center }, Ui.Text(t.Title, 13)),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                MinWidth = 180
            };
            var target = t;
            item.Click += (_, _) =>
            {
                statusButton.Flyout?.Hide();
                Move(target).Forget();
            };
            transitionsPanel.Children.Add(item);
        }
    }

    private async Task LoadTransitions()
    {
        if (loadingTransitions || transitions is { Count: > 0 }) return;
        if (JiraService.Account.Client() is not { } client)
        {
            transitions = new();
            RenderTransitions();
            return;
        }
        loadingTransitions = true;
        RenderTransitions();
        try
        {
            transitions = await client.Transitions(issue.Key);
        }
        catch
        {
            transitions = new();
        }
        loadingTransitions = false;
        RenderTransitions();
    }

    private async Task Move(JiraTransition t)
    {
        if (JiraService.Account.Client() is not { } client) return;
        moving = true;
        errorText.Visibility = Visibility.Collapsed;
        RenderStatus();
        try
        {
            await client.Transition(issue.Key, t.Id);
            transitions = null;
            onChange(await client.Issue(issue.Key));
        }
        catch (Exception e)
        {
            errorText.Text = e.Message;
            errorText.Visibility = Visibility.Visible;
        }
        moving = false;
        RenderStatus();
    }
}
