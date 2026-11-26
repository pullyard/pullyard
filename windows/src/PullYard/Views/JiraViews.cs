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
    public static JiraConnections Connections { get; } = new(Settings.Shared, new CredentialVault());

    public const string TicketGlyph = "\uE8EC";

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
    private readonly JiraConnections store = JiraService.Connections;
    private readonly StackPanel body = Ui.V(12);
    private readonly TextBox ruleOrg = new() { PlaceholderText = L.T("Jira_RuleOrgPlaceholder", "GitHub organization"), MinWidth = 160 };
    private readonly ComboBox ruleTarget = new() { MinWidth = 140 };
    private string? editing;
    private bool reconnect;
    private bool adding;

    public JiraConnectForm()
    {
        Children.Add(body);
        Loaded += (_, _) =>
        {
            store.Changed -= OnChanged;
            store.Changed += OnChanged;
            Render();
        };
        Unloaded += (_, _) => store.Changed -= OnChanged;
        Render();
    }

    private void OnChanged() => DispatcherQueue.TryEnqueue(Render);

    private void Render()
    {
        body.Children.Clear();
        var list = store.Connections;
        if (list.Count == 0)
        {
            body.Children.Add(Ui.Text(L.T("Jira_ConnectHint", "Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in Windows Credential Manager."), 13, "muted", wrap: true));
            body.Children.Add(new JiraConnectionEditor(null, false, Render, null));
            return;
        }
        var rows = Ui.V(8);
        foreach (var c in list)
        {
            if (editing == c.Id) rows.Children.Add(Ui.Card(new JiraConnectionEditor(c, reconnect, Close, Close), 10, "sunken", 12));
            else rows.Children.Add(Row(c));
        }
        body.Children.Add(rows);
        if (adding) body.Children.Add(Ui.Card(new JiraConnectionEditor(null, false, Close, Close), 10, "sunken", 12));
        else
        {
            var add = Ui.Button(L.T("Jira_AddConnection", "Add Jira connection"), () =>
            {
                adding = true;
                editing = null;
                Render();
            }, glyph: "\uE710");
            add.HorizontalAlignment = HorizontalAlignment.Left;
            body.Children.Add(add);
        }
        var orgRules = store.OrgOverrides;
        var repoRules = store.RepoOverrides;
        if (list.Count > 1 || orgRules.Count > 0 || repoRules.Count > 0) body.Children.Add(Rules(list, orgRules, repoRules));
    }

    private void Close()
    {
        editing = null;
        adding = false;
        reconnect = false;
        Render();
    }

    private FrameworkElement Row(JiraConnection c)
    {
        var ok = c.DisplayName is not null && store.Token(c.Id) is { Length: > 0 };
        var icon = ok ? Ui.Glyph("\uE930", 16, "green") : Ui.Glyph("\uE7BA", 16, "amber");
        Ui.Tip(icon, ok ? L.T("Jira_Connected", "Connected") : L.T("Jira_NeedsToken", "Needs a new token"));
        var name = Ui.H(6, Ui.Text(c.Name, 13, "text", FontWeights.SemiBold));
        if (c.DisplayName is { } who) name.Children.Add(Ui.Text(who, 12.5, "muted"));
        var summary = Ui.Caption(c.ProjectSummary);
        summary.TextTrimming = TextTrimming.CharacterEllipsis;
        Ui.Tip(summary, c.ProjectKeys.Count > 0 ? string.Join(", ", c.ProjectKeys) : c.Host);
        var id = c.Id;
        var more = Ui.IconButton("\uE712", L.F("Jira_ConnectionMenu", "{0} options", c.Name), () => { }, "text");
        more.Flyout = Ui.Menu(
            Ui.MenuItem(L.T("Jira_Edit", "Edit…"), () => Edit(id, false), "\uE70F"),
            Ui.MenuItem(L.T("Jira_Reconnect", "Reconnect with a new token…"), () => Edit(id, true), "\uE8D7"),
            Ui.MenuItem(L.T("Jira_RefreshProjects", "Refresh projects"), () => store.RefreshProjects(id).Forget(), "\uE72C"),
            Ui.Separator(),
            Ui.MenuItem(L.T("Jira_Remove", "Remove…"), () => Remove(c).Forget(), "\uE74D"));
        var row = Ui.Columns((icon, Ui.Auto), (Ui.V(1, name, summary), Ui.Star), (more, Ui.Auto));
        row.ColumnSpacing = 10;
        return row;
    }

    private void Edit(string id, bool token)
    {
        editing = id;
        reconnect = token;
        adding = false;
        Render();
    }

    private async Task Remove(JiraConnection c)
    {
        if (await Dialogs.Confirm(XamlRoot, L.F("Jira_RemoveQ", "Remove “{0}”?", c.Name), L.T("Jira_RemoveButton", "Remove"), true,
                L.T("Jira_RemoveHelp", "Its API token is deleted from Windows Credential Manager, and rules that point to it go too.")))
            store.Remove(c.Id);
    }

    private FrameworkElement Rules(List<JiraConnection> list, Dictionary<string, string> orgRules, Dictionary<string, string> repoRules)
    {
        var panel = Ui.V(6, Ui.Text(L.T("Jira_Rules", "Rules"), 13, "text", FontWeights.SemiBold),
            Ui.Text(L.T("Jira_RulesHint", "Tickets go to the site that owns their project key. A rule sends every ticket of a repository or organization to one connection."), 12, "muted", wrap: true));
        string NameOf(string id) => list.FirstOrDefault(c => c.Id == id)?.Name ?? L.T("Jira_RemovedConnection", "removed connection");
        foreach (var (full, id) in repoRules.OrderBy(kv => kv.Key))
        {
            var key = full;
            panel.Children.Add(RuleRow("\uE8B7", full, NameOf(id), () => store.SetRepoOverride(null, key)));
        }
        foreach (var (org, id) in orgRules.OrderBy(kv => kv.Key))
        {
            var key = org;
            panel.Children.Add(RuleRow("\uE716", L.F("Jira_AllOf", "All of {0}", org), NameOf(id), () => store.SetOrgOverride(null, key)));
        }
        ruleTarget.Items.Clear();
        foreach (var c in list) ruleTarget.Items.Add(new ComboBoxItem { Content = c.Name, Tag = c.Id });
        ruleTarget.SelectedIndex = 0;
        if (ruleOrg.Parent is Panel oldOrg) oldOrg.Children.Remove(ruleOrg);
        if (ruleTarget.Parent is Panel oldTarget) oldTarget.Children.Remove(ruleTarget);
        var addRule = Ui.Button(L.T("Jira_AddRule", "Add rule"), () =>
        {
            var org = ruleOrg.Text.Trim().TrimStart('@');
            if (org.Length == 0 || (ruleTarget.SelectedItem as ComboBoxItem)?.Tag is not string id) return;
            ruleOrg.Text = "";
            store.SetOrgOverride(id, org);
        });
        panel.Children.Add(new WrapPanel(8, ruleOrg, ruleTarget, addRule) { VerticalSpacing = 8 });
        panel.Margin = new Thickness(0, 6, 0, 0);
        return panel;
    }

    private static FrameworkElement RuleRow(string glyph, string scope, string target, Action remove)
    {
        var left = Ui.H(6, Ui.Glyph(glyph, 12, "muted"), Ui.Text(scope, 13, "text", mono: true), Ui.Glyph("\uE72A", 10, "dim"), Ui.Text(target, 13, "sky"));
        var x = Ui.IconButton("\uE711", L.F("Jira_RemoveRule", "Remove rule for {0}", scope), remove);
        return Ui.Columns((left, Ui.Star), (x, Ui.Auto));
    }
}

public sealed class JiraConnectionEditor : StackPanel
{
    private readonly JiraConnections store = JiraService.Connections;
    private readonly JiraConnection? existing;
    private readonly Action done;
    private readonly TextBox name = new() { PlaceholderText = L.T("Jira_NamePlaceholder", "Name, e.g. Work") };
    private readonly TextBox site = new() { PlaceholderText = L.T("Jira_SitePlaceholder", "Jira address — acme.atlassian.net") };
    private readonly TextBox email = new() { PlaceholderText = L.T("Jira_EmailPlaceholder", "Atlassian account email (empty for a Data Center token)") };
    private readonly PasswordBox token = new();
    private readonly TextBlock error = Ui.Text("", 12, "red", wrap: true, select: true);
    private readonly Button save;
    private bool busy;

    public JiraConnectionEditor(JiraConnection? existing, bool focusToken, Action done, Action? cancel)
    {
        this.existing = existing;
        this.done = done;
        Spacing = 10;
        name.Text = existing?.Name ?? "";
        site.Text = existing?.Site ?? "";
        email.Text = existing?.Email ?? "";
        token.PlaceholderText = existing is null ? L.T("Jira_TokenPlaceholder", "API token") : L.T("Jira_TokenKeep", "API token (leave empty to keep the current one)");
        token.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Save().Forget();
        };
        save = Ui.Button(existing is null ? L.T("Jira_Connect", "Connect") : L.T("Common_Save", "Save"), () => Save().Forget(), accent: true);
        Children.Add(name);
        Children.Add(site);
        Children.Add(email);
        Children.Add(token);
        var actions = Ui.H(8, save);
        if (cancel is not null) actions.Children.Add(Ui.Button(L.T("Jira_Cancel", "Cancel"), cancel));
        Children.Add(Ui.Columns((actions, Ui.Star), (Ui.Link(L.T("Jira_CreateToken", "Create an API token at id.atlassian.com"), () => LinkBrowser.Open(JiraService.TokenUrl)), Ui.Auto)));
        error.Visibility = Visibility.Collapsed;
        Children.Add(error);
        if (focusToken) Loaded += (_, _) => token.Focus(FocusState.Programmatic);
    }

    private async Task Save()
    {
        if (busy || site.Text.Trim().Length == 0 || (existing is null && token.Password.Trim().Length == 0)) return;
        busy = true;
        error.Visibility = Visibility.Collapsed;
        save.IsEnabled = false;
        var label = save.Content;
        save.Content = Ui.Spinner(14);
        try
        {
            if (existing is null) await store.Add(name.Text, site.Text, email.Text, token.Password);
            else await store.Update(existing.Id, name.Text, site.Text, email.Text, token.Password);
            token.Password = "";
            busy = false;
            done();
            return;
        }
        catch (Exception e)
        {
            error.Text = e.Message;
            error.Visibility = Visibility.Visible;
        }
        busy = false;
        save.Content = label;
        save.IsEnabled = true;
    }
}

public static class JiraRepo
{
    public static string? RoutedName(RepoRef repo) =>
        JiraService.Connections.ConnectionForRepo(repo) is { } id ? JiraService.Connections.Connection(id)?.Name : null;

    public static FrameworkElement? Badge(string full)
    {
        var store = JiraService.Connections;
        if (!store.HasSeveral || RepoRef.Parse(full) is not { } repo || RoutedName(repo) is not { } name) return null;
        var badge = Ui.H(3, Ui.Glyph(JiraService.TicketGlyph, 10, "sky"), Ui.Text(name, 11, "sky"));
        Ui.Tip(badge, L.F("Jira_RepoUses", "Jira: {0}", name));
        return badge;
    }

    public static FrameworkElement? Chip(RepoRef repo)
    {
        var store = JiraService.Connections;
        if (!store.IsConfigured) return null;
        var label = RoutedName(repo) is { } name ? name : L.T("Jira_ByKey", "Jira: by key");
        var content = Ui.H(5, Ui.Glyph(JiraService.TicketGlyph, 11, "sky"), Ui.Text(label, 12, "sky", FontWeights.Medium));
        var button = new DropDownButton
        {
            Content = content,
            Padding = new Thickness(8, 2, 6, 3),
            MinHeight = 0,
            CornerRadius = new CornerRadius(11),
            Background = Palette.Brush("sky", 0.12),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center
        };
        Ui.Tip(button, L.T("Jira_RepoChipTip", "Which Jira this repository uses"));
        Ui.Named(button, L.F("Jira_RepoUses", "Jira: {0}", label));
        button.Flyout = Menu(repo);
        return button;
    }

    private static MenuFlyout Menu(RepoRef repo)
    {
        var store = JiraService.Connections;
        var list = store.Connections;
        var (repoRule, orgRule) = store.Override(repo);
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = L.F("Jira_ForRepo", "Jira for {0}", repo.Full), IsEnabled = false });
        var ownerName = orgRule is not null ? list.FirstOrDefault(c => c.Id == orgRule)?.Name : null;
        var automatic = ownerName is not null ? L.F("Jira_SameAsOwner", "Same as owner ({0})", ownerName) : L.T("Jira_Automatic", "Automatic");
        menu.Items.Add(Ui.CheckItem(automatic, repoRule is null, () => store.SetRepoOverride(null, repo)));
        foreach (var c in list)
        {
            var id = c.Id;
            menu.Items.Add(Ui.CheckItem(c.Name, repoRule == id, () => store.SetRepoOverride(id, repo)));
        }
        if (list.Count > 1)
        {
            menu.Items.Add(Ui.Separator());
            menu.Items.Add(new MenuFlyoutItem { Text = L.F("Jira_AllOfOwner", "All of {0}", repo.Owner), IsEnabled = false });
            menu.Items.Add(Ui.CheckItem(L.T("Jira_ByProjectKey", "By project key"), orgRule is null, () => store.SetOrgOverride(null, repo.Owner)));
            foreach (var c in list)
            {
                var id = c.Id;
                menu.Items.Add(Ui.CheckItem(c.Name, orgRule == id, () => store.SetOrgOverride(id, repo.Owner)));
            }
        }
        return menu;
    }
}

public static class JiraUi
{
    public static SolidColorBrush LineBrush() => Palette.Brush("line");

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
        if (tooltip is not null) Ui.Named(b, Ui.SpokenName(tooltip));
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
    private readonly JiraConnections account = JiraService.Connections;
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
        var hiddenCount = account.HiddenKeys(pr.Url).Count;
        if (hiddenCount > 0)
            content.Children.Add(Ui.Link(hiddenCount == 1 ? L.T("Jira_ShowHiddenOne", "Show 1 hidden ticket") : L.F("Jira_ShowHiddenMany", "Show {0} hidden tickets", hiddenCount), ShowHidden));
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
        var info = Ui.V(1, title, Ui.Caption(account.Names(issues.Values)));
        Button toggle;
        if (linking)
        {
            toggle = Ui.Button(L.T("Jira_Cancel", "Cancel"), () => SetLinking(false));
            toggle.Padding = new Thickness(10, 4, 10, 5);
            var escape = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
            escape.Invoked += (_, e) =>
            {
                e.Handled = true;
                SetLinking(false);
            };
            toggle.KeyboardAccelerators.Add(escape);
            toggle.KeyboardAcceleratorPlacementMode = Microsoft.UI.Xaml.Input.KeyboardAcceleratorPlacementMode.Hidden;
        }
        else toggle = JiraUi.Small(L.T("Jira_LinkTicket", "Link ticket"), "", () => SetLinking(true));
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
            return new JiraIssueRow(issue, isManual ? null : () => Hide(key), () =>
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
        var card = new JiraIssueCard(issue, isManual, () => Unlink(key), isManual ? null : () => Hide(key), collapse, updated =>
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

    private void Hide(string key)
    {
        if (model.Pr is not { } pr) return;
        issues.Remove(key);
        errors.Remove(key);
        open.Remove(key);
        cards.Remove(key);
        account.Hide(pr.Url, key);
    }

    private void ShowHidden()
    {
        if (model.Pr is not { } pr) return;
        account.ShowHidden(pr.Url);
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
            if (!issues.ContainsKey(key) && account.CachedIssue(key, model.Ref.Repo) is { } hit) issues[key] = hit;
        var todo = keys.Where(k => !issues.ContainsKey(k) && !errors.ContainsKey(k) && pending.Add(k)).ToList();
        RenderIfLoaded();
        if (todo.Count == 0) return;
        var tasks = todo.Select(async key =>
        {
            try
            {
                var issue = await account.FetchIssue(key, model.Ref.Repo);
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
    public JiraIssueRow(JiraIssue issue, Action? onHide, Action onOpen)
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
        ContextFlyout = Ui.Menu(
            Ui.MenuItem(L.T("Jira_Open", "Open in Jira"), () => LinkBrowser.Open(issue.Url), ""),
            onHide is not null ? Ui.MenuItem(L.T("Jira_HideOnPr", "Hide on this pull request"), onHide, "") : null);
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

    public JiraIssueCard(JiraIssue issue, bool manual, Action onUnlink, Action? onHide, Action? onCollapse, Action<JiraIssue> onChange)
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
                LinkBrowser.Open(issue.SiteBase + "/browse/" + parentKey);
            }, L.T("Jira_ParentTip", "Parent ticket — open in Jira")));
        }

        var (glyph, color) = JiraService.TypeIcon(issue.Type);
        var left = Ui.H(10, Ui.IconTile(glyph, color, 24), Ui.Text(issue.Key, 13, "text", FontWeights.SemiBold, mono: true), issue.Type is { } type ? Ui.Caption(type) : null);
        if (JiraService.Connections.HasSeveral && JiraService.Connections.Connection(issue.ConnectionId) is { } owner)
        {
            var site = Ui.Chip(owner.Name, "sky", JiraService.TicketGlyph);
            Ui.Tip(site, owner.Host);
            left.Children.Add(site);
        }
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
        else if (onHide is not null)
        {
            var b = JiraUi.Plain(Ui.H(6, Ui.Glyph("", 12, "muted"), Ui.Text(L.T("Jira_Hide", "Hide"), 13, "muted")), onHide, L.T("Jira_HideTip", "Hide this ticket on this pull request"));
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
        if (JiraService.Connections.Client(issue.ConnectionId) is not { } client)
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
        if (JiraService.Connections.Client(issue.ConnectionId) is not { } client) return;
        moving = true;
        errorText.Visibility = Visibility.Collapsed;
        RenderStatus();
        try
        {
            await client.Transition(issue.Key, t.Id);
            transitions = null;
            onChange((await client.Issue(issue.Key)) with { ConnectionId = issue.ConnectionId });
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

public sealed class JiraMergeFollowUp : Grid
{
    private readonly PullRequestDetail pr;
    private readonly JiraAccount account = JiraService.Account;
    private readonly StackPanel body = Ui.V(6);
    private List<JiraIssue> issues = new();
    private readonly Dictionary<string, JiraTransition> moves = new();
    private string? working;
    private string? error;
    private bool dismissed;

    public JiraMergeFollowUp(PullRequestDetail pr)
    {
        this.pr = pr;
        Children.Add(new Border
        {
            Background = Palette.Brush("sky", 0.07),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(10, 6, 10, 6),
            Child = body
        });
        Visibility = Visibility.Collapsed;
        Load().Forget();
    }

    private async Task Load()
    {
        dismissed = JiraFollowUp.IsDismissed(Settings.Shared, pr.Url);
        if (!pr.Merged || dismissed || !account.IsConfigured || account.Client() is not { } client) return;
        var found = new List<JiraIssue>();
        foreach (var key in account.Keys(pr).Take(5))
        {
            if (account.CachedIssue(key) is { } hit)
            {
                found.Add(hit);
                continue;
            }
            try
            {
                var fresh = await client.Issue(key);
                account.Remember(fresh);
                found.Add(fresh);
            }
            catch (Exception)
            {
            }
        }
        foreach (var issue in JiraFollowUp.Open(found))
        {
            try
            {
                if (JiraFollowUp.DoneTransition(await client.Transitions(issue.Key)) is { } t) moves[issue.Key] = t;
            }
            catch (Exception)
            {
            }
        }
        issues = found;
        Render();
    }

    private void Render()
    {
        var pending = JiraFollowUp.Open(issues);
        body.Children.Clear();
        if (!pr.Merged || dismissed || pending.Count == 0)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        foreach (var issue in pending)
        {
            var buttons = Ui.H(8);
            if (moves.TryGetValue(issue.Key, out var t))
            {
                var move = Ui.Button(working == issue.Key ? L.T("Jira_FollowUpMoving", "Moving…") : L.F("Jira_FollowUpMove", "Move to {0}", t.To), () => Move(issue, t).Forget(), accent: true);
                move.Padding = new Thickness(10, 4, 10, 5);
                move.IsEnabled = working is null;
                buttons.Children.Add(move);
            }
            buttons.Children.Add(JiraUi.Small(L.T("Jira_Open", "Open in Jira"), "", () => LinkBrowser.Open(issue.Url)));
            var status = Ui.Text(L.F("Jira_FollowUpStill", "is still {0}", issue.Status), 13, "muted", maxLines: 1);
            var row = Ui.Columns((Ui.Glyph("", 13, "sky"), Ui.Auto), (Ui.Text(issue.Key, 13, "text", FontWeights.SemiBold, mono: true), Ui.Auto), (status, Ui.Star), (buttons, Ui.Auto));
            row.ColumnSpacing = 8;
            body.Children.Add(row);
        }
        var errorText = error is null ? null : Ui.Text(error, 12, "red", wrap: true, select: true);
        var notNow = Ui.Link(L.T("Jira_FollowUpNotNow", "Not now"), Dismiss);
        body.Children.Add(Ui.Columns((errorText, Ui.Star), (notNow, Ui.Auto)));
    }

    private void Dismiss()
    {
        JiraFollowUp.Dismiss(Settings.Shared, pr.Url);
        dismissed = true;
        Render();
    }

    private async Task Move(JiraIssue issue, JiraTransition t)
    {
        if (working is not null || account.Client() is not { } client) return;
        working = issue.Key;
        error = null;
        Render();
        try
        {
            await client.Transition(issue.Key, t.Id);
            try
            {
                var fresh = await client.Issue(issue.Key);
                account.Remember(fresh);
                issues = issues.Select(i => i.Key == fresh.Key ? fresh : i).ToList();
            }
            catch (Exception)
            {
            }
            ShellView.Toast(L.F("Jira_FollowUpMoved", "{0} moved to {1}", issue.Key, t.To));
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        working = null;
        Render();
    }
}
