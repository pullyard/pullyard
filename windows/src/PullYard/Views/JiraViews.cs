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

public sealed class JiraTab : Grid
{
    private readonly PRDetailViewModel model;
    private readonly JiraAccount account = JiraService.Account;
    private readonly StackPanel content = Ui.V(14);
    private readonly Dictionary<string, JiraIssue> issues = new();
    private readonly Dictionary<string, string> errors = new();
    private readonly HashSet<string> pending = new();
    private readonly TextBox manual = new() { PlaceholderText = "ABC-123", Width = 140 };
    private string loadedFor = "";
    private bool subscribed;

    public JiraTab(PRDetailViewModel model)
    {
        this.model = model;
        content.MaxWidth = 820;
        content.Padding = new Thickness(20);
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        manual.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Link();
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

    private static Border Card(params UIElement?[] children)
    {
        var card = Ui.Card(Ui.V(10, children), 12, "raised", 16);
        card.HorizontalAlignment = HorizontalAlignment.Stretch;
        return card;
    }

    private void Render()
    {
        if (model.Pr is not { } pr) return;
        var keys = account.Keys(pr);
        var linked = account.LinkedKeys(pr.Url);
        content.Children.Clear();
        if (!account.IsConfigured)
        {
            content.Children.Add(Card(Ui.H(8, Ui.IconTile("", "sky", 22), Ui.Text(L.T("Jira_Title", "Jira"), 14, "text", FontWeights.SemiBold)), new JiraConnectForm()));
            return;
        }
        if (keys.Count == 0)
        {
            content.Children.Add(Card(
                Ui.H(8, Ui.Glyph("", 14, "text"), Ui.Text(L.T("Jira_NoTicket", "No Jira ticket found"), 15, "text", FontWeights.SemiBold)),
                Ui.Text(L.T("Jira_NoTicketHint", "PullYard looks for keys like ABC-123 in the title, branch and description. Link one by hand:"), 13, "muted", wrap: true),
                LinkField()));
            return;
        }
        foreach (var key in keys)
        {
            var isManual = linked.Contains(key);
            if (issues.TryGetValue(key, out var issue))
            {
                content.Children.Add(new JiraIssueCard(issue, isManual, () => Unlink(key), updated =>
                {
                    account.Remember(updated);
                    issues[updated.Key] = updated;
                    Render();
                }));
            }
            else if (errors.TryGetValue(key, out var err))
            {
                var row = Ui.H(8, Ui.Glyph("", 13, "amber"), Ui.Text($"{key}: {err}", 13, "amber", wrap: true, select: true));
                content.Children.Add(Card(row, isManual ? Ui.Button(L.T("Jira_Unlink", "Unlink"), () => Unlink(key)) : null));
            }
            else
            {
                content.Children.Add(Card(Ui.H(10, Ui.Spinner(16), Ui.Text(key, 13, "muted", mono: true))));
            }
        }
        content.Children.Add(LinkField());
        var signature = $"{account.IsConfigured}|{string.Join(",", keys)}";
        if (signature != loadedFor)
        {
            loadedFor = signature;
            Load(keys).Forget();
        }
    }

    private FrameworkElement LinkField()
    {
        if (manual.Parent is Panel old) old.Children.Remove(manual);
        var button = Ui.Button(L.T("Jira_LinkTicket", "Link ticket"), Link);
        return Ui.H(8, manual, button);
    }

    private void Link()
    {
        if (model.Pr is not { } pr) return;
        if (account.Link(pr.Url, manual.Text) is null) return;
        manual.Text = "";
    }

    private void Unlink(string key)
    {
        if (model.Pr is not { } pr) return;
        issues.Remove(key);
        errors.Remove(key);
        account.Unlink(pr.Url, key);
    }

    private async Task Load(List<string> keys)
    {
        foreach (var key in keys)
            if (!issues.ContainsKey(key) && account.CachedIssue(key) is { } hit) issues[key] = hit;
        var todo = keys.Where(k => !issues.ContainsKey(k) && !errors.ContainsKey(k) && pending.Add(k)).ToList();
        if (todo.Count == 0)
        {
            RenderIfChanged();
            return;
        }
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
            RenderIfChanged();
        });
        await Task.WhenAll(tasks);
    }

    private void RenderIfChanged()
    {
        if (IsLoaded) Render();
    }
}

public sealed class JiraIssueCard : Grid
{
    private readonly JiraIssue issue;
    private readonly Action<JiraIssue> onChange;
    private readonly StackPanel transitionsPanel = Ui.V(2);
    private readonly TextBlock errorText = Ui.Text("", 12, "red", wrap: true, select: true);
    private readonly Button statusButton = new();
    private List<JiraTransition>? transitions;
    private bool loadingTransitions;
    private bool moving;
    private bool expanded;
    private readonly TextBlock description;
    private readonly HyperlinkButton? more;

    public JiraIssueCard(JiraIssue issue, bool manual, Action onUnlink, Action<JiraIssue> onChange)
    {
        this.issue = issue;
        this.onChange = onChange;
        Background = Palette.Brush("raised");
        CornerRadius = new CornerRadius(12);
        Padding = new Thickness(16);
        HorizontalAlignment = HorizontalAlignment.Stretch;

        var (glyph, color) = JiraService.TypeIcon(issue.Type);
        var key = new HyperlinkButton { Content = Ui.Text(issue.Key, 13, "accent", FontWeights.SemiBold, mono: true), Padding = new Thickness(0) };
        key.Click += (_, _) => LinkBrowser.Open(issue.Url);
        var left = Ui.H(8, Ui.Glyph(glyph, 13, color), key, issue.Type is { } type ? Ui.Caption(type) : null);
        RenderStatus();
        var flyout = new Flyout { Content = transitionsPanel, Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        flyout.Opening += (_, _) => LoadTransitions().Forget();
        statusButton.Flyout = flyout;
        statusButton.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        statusButton.BorderThickness = new Thickness(0);
        statusButton.Padding = new Thickness(0);
        Ui.Tip(statusButton, L.T("Jira_ChangeStatus", "Change status"));
        var head = Ui.Columns((left, Ui.Star), (statusButton, Ui.Auto));

        var summary = Ui.Text(issue.Summary, 16, "text", FontWeights.SemiBold, wrap: true, select: true);

        var meta = new WrapPanel(16);
        meta.Children.Add(issue.Assignee is { } a
            ? Ui.H(6, Ui.Avatar(issue.AssigneeAvatar, 18), Ui.Caption(a))
            : Ui.H(5, Ui.Glyph("", 11, "muted"), Ui.Caption(L.T("Jira_Unassigned", "Unassigned"))));
        if (issue.Priority is { } p) meta.Children.Add(Ui.H(5, Ui.Glyph("", 11, "muted"), Ui.Caption(p)));
        if (issue.Reporter is { } r) meta.Children.Add(Ui.H(5, Ui.Glyph("", 11, "muted"), Ui.Caption(L.F("Jira_ReportedBy", "Reported by {0}", r))));
        if (issue.Updated is { } u) meta.Children.Add(Ui.Caption(L.F("Jira_Updated", "Updated {0}", Fmt.Rel(u))));

        var stack = Ui.V(12, head, summary, meta);
        description = Ui.Text(issue.Description, 13, "text", wrap: true, select: true);
        description.Opacity = 0.9;
        description.TextTrimming = TextTrimming.CharacterEllipsis;
        description.MaxLines = 8;
        if (issue.Description.Length > 0)
        {
            var block = Ui.V(6, description);
            if (issue.Description.Length > 500)
            {
                more = Ui.Link(L.T("Jira_ShowMore", "Show more"), ToggleMore);
                block.Children.Add(more);
            }
            stack.Children.Add(block);
        }
        errorText.Visibility = Visibility.Collapsed;
        stack.Children.Add(errorText);
        var buttons = Ui.H(8, Ui.Button(L.T("Jira_Open", "Open in Jira"), () => LinkBrowser.Open(issue.Url)), manual ? Ui.Button(L.T("Jira_Unlink", "Unlink"), onUnlink) : null);
        stack.Children.Add(buttons);
        Children.Add(stack);
    }

    private void ToggleMore()
    {
        expanded = !expanded;
        description.MaxLines = expanded ? 0 : 8;
        if (more is not null) more.Content = expanded ? L.T("Jira_ShowLess", "Show less") : L.T("Jira_ShowMore", "Show more");
    }

    private void RenderStatus()
    {
        var color = JiraService.StatusColor(issue.StatusCategory);
        var row = Ui.H(5, moving ? Ui.Spinner(12) : null, Ui.Text(issue.Status.ToUpperInvariant(), 11.5, color, FontWeights.Bold), Ui.Glyph("", 9, color));
        statusButton.Content = new Border { Background = Palette.Brush(color, 0.14), CornerRadius = new CornerRadius(11), Padding = new Thickness(9, 4, 9, 4), Child = row };
        statusButton.IsEnabled = !moving;
    }

    private void RenderTransitions()
    {
        transitionsPanel.Children.Clear();
        if (transitions is not { Count: > 0 } list)
        {
            transitionsPanel.Children.Add(Ui.Text(loadingTransitions ? L.T("Jira_Loading", "Loading…") : L.T("Jira_NoTransitions", "No transitions available"), 13, "muted"));
            return;
        }
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
        if (JiraService.Account.Client() is not { } client) return;
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
