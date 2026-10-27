using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using VisualState = PullYard.Core.Api.VisualState;

namespace PullYard.Controls;

public abstract class CodeRow : ContentControl
{
    protected CodeRow()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        IsTabStop = false;
        DataContextChanged += (_, e) =>
        {
            Content = e.NewValue is null ? null : Build(e.NewValue);
            ApplyName();
        };
        Loaded += (_, _) =>
        {
            ApplyName();
            if (ticking) return;
            ticking = true;
            RelativeClock.Minute += Rebuild;
        };
        Unloaded += (_, _) =>
        {
            if (!ticking) return;
            ticking = false;
            RelativeClock.Minute -= Rebuild;
        };
    }

    private bool ticking;

    private void Rebuild()
    {
        if (DataContext is not { } item) return;
        Content = Build(item);
        ApplyName();
    }

    private void ApplyName()
    {
        var name = DataContext is { } item ? Spoken(item) ?? "" : "";
        AutomationProperties.SetName(this, name);
        DependencyObject? parent = this;
        while (parent is not null && parent is not SelectorItem) parent = VisualTreeHelper.GetParent(parent);
        if (parent is SelectorItem container) AutomationProperties.SetName(container, name);
    }

    protected abstract UIElement? Build(object item);

    protected virtual string? Spoken(object item) => null;
}

public static class RelativeClock
{
    private static DispatcherTimer? timer;
    private static Action? minute;

    public static event Action Minute
    {
        add
        {
            minute += value;
            if (timer is not null) return;
            timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
            timer.Tick += (_, _) => minute?.Invoke();
            timer.Start();
        }
        remove => minute -= value;
    }
}

public sealed class GroupHeaderItem
{
    public RepoGroup Group { get; init; } = new("", new());
    public bool Expanded { get; init; }
}

public sealed class FeedRow : CodeRow
{
    public static bool ShowRepoDefault { get; set; } = true;

    protected override UIElement? Build(object item) => item switch
    {
        SearchItem s => SearchRow(s, true),
        GroupedSearchItem g => SearchRow(g.Item, false),
        GroupHeaderItem h => GroupHeader(h),
        _ => null
    };

    protected override string? Spoken(object item) => item switch
    {
        SearchItem s => SpokenLabel(s),
        GroupedSearchItem g => SpokenLabel(g.Item),
        GroupHeaderItem h => $"{h.Group.Id}, {Fmt.Plural(h.Group.Items.Count, "item", "items")}, {(h.Expanded ? L.T("A11y_Expanded", "Expanded") : L.T("A11y_Collapsed", "Collapsed"))}",
        _ => null
    };

    private static string Prefix => AppViewModel.Shared.Forge is null ? "#" : AppViewModel.Shared.Provider.NumberPrefix();

    public static string SpokenLabel(SearchItem item)
    {
        var parts = new List<string> { item.Title, $"{item.Repository.NameWithOwner}{Prefix}{item.Number}" };
        if (item.Author?.Login is { Length: > 0 } login) parts.Add(L.F("A11y_ByAuthor", "by {0}", login));
        parts.Add(Ui.StateTitle(item.VisualState));
        if (item.IsPR)
        {
            if (Ui.CiTitle(item.CiState) is { } ci) parts.Add(ci);
            if (ReviewTitle(item.ReviewDecision) is { } review) parts.Add(review);
        }
        if (item.Comments.TotalCount > 0) parts.Add(Fmt.Plural(item.Comments.TotalCount, "comment", "comments"));
        parts.Add(L.F("A11y_Updated", "updated {0}", Fmt.Rel(item.UpdatedAt)));
        return string.Join(", ", parts);
    }

    private static string? ReviewTitle(string? decision) => decision switch
    {
        "APPROVED" => L.T("Review_Approved", "Approved"),
        "CHANGES_REQUESTED" => L.T("Review_ChangesRequested", "Changes requested"),
        "REVIEW_REQUIRED" => L.T("Review_Required", "Review required"),
        _ => null
    };

    public static UIElement SearchRow(SearchItem item, bool showRepo)
    {
        var prefix = Prefix;
        var title = Ui.Text(item.Title, 13.5, "text", FontWeights.Medium, maxLines: 2);
        Ui.Tip(title, item.Title);

        var meta = Ui.Text("", 12, "muted");
        meta.Inlines.Add(new Run { Text = showRepo ? $"{item.Repository.NameWithOwner}{prefix}{item.Number}" : $"{prefix}{item.Number}" });
        meta.Inlines.Add(new Run { Text = "  ·  ", Foreground = Palette.Brush("dim") });
        meta.Inlines.Add(new Run { Text = Fmt.Rel(item.UpdatedAt) });
        var stat = item.IsPR && item.Additions is { } add && item.Deletions is { } del ? Ui.DiffStat(add, del, 11.5) : null;
        var metaRow = Ui.Columns((meta, Ui.Star), (stat, Ui.Auto));

        var signals = Ui.H(8);
        if (item.IsPR)
        {
            if (Ui.CiIcon(item.CiState, 11) is { } ci) signals.Children.Add(ci);
            switch (item.ReviewDecision)
            {
                case "APPROVED":
                    signals.Children.Add(Ui.StatusGlyph("\uE8FB", 11, "green", L.T("Review_Approved", "Approved")));
                    break;
                case "CHANGES_REQUESTED":
                    signals.Children.Add(Ui.StatusGlyph("\uE7BA", 11, "red", L.T("Review_ChangesRequested", "Changes requested")));
                    break;
                case "REVIEW_REQUIRED":
                    signals.Children.Add(Ui.StatusGlyph("\uE7B3", 11, "muted", L.T("Review_Required", "Review required")));
                    break;
            }
        }
        if (item.Comments.TotalCount > 0)
        {
            var comments = Ui.H(3, Ui.Glyph("\uE8BD", 11), Ui.Caption(item.Comments.TotalCount.ToString(Fmt.Culture)));
            Ui.Tip(comments, Fmt.Plural(item.Comments.TotalCount, "comment", "comments"));
            signals.Children.Add(comments);
        }
        var login = Ui.Caption(item.Author?.Login ?? "");
        var who = Ui.Columns((Ui.Avatar(item.Author?.AvatarUrl, 18, ring: true), Ui.Auto), (login, Ui.Star), (signals.Children.Count > 0 ? signals : null, Ui.Auto));
        who.ColumnSpacing = 6;

        var body = Ui.V(4, title, metaRow, who);
        if (item.StackedOn is { } baseRef)
        {
            var s = Ui.H(4, Ui.Glyph("", 11, "indigo"), Ui.Text(L.F("Item_StackedOn", "stacked on {0}", baseRef), 12, "indigo"));
            Ui.Tip(s, baseRef);
            body.Children.Add(s);
        }
        if (item.Labels?.Items is { Count: > 0 } labels)
        {
            var row = Ui.H(4);
            foreach (var l in labels.Take(4)) row.Children.Add(Ui.LabelChip(l));
            body.Children.Add(row);
        }
        var grid = Ui.Columns((Ui.StateBadge(item.VisualState, true), Ui.Auto), (body, Ui.Star));
        grid.ColumnSpacing = 10;
        grid.Padding = new Thickness(0, 6, 0, 6);
        return grid;
    }

    private static UIElement GroupHeader(GroupHeaderItem h)
    {
        var color = Palette.ProjectKey(h.Group.Id);
        var count = new Border
        {
            Background = Palette.Brush(color, 0.14),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 0, 6, 1),
            Child = Ui.Text(h.Group.Items.Count.ToString(), 11, color, FontWeights.SemiBold),
            VerticalAlignment = VerticalAlignment.Center
        };
        var grid = Ui.Columns(
            (Ui.Glyph(h.Expanded ? "\uE70D" : "\uE76C", 10, "dim"), Ui.Auto),
            (Ui.IconTile("", color, 24), Ui.Auto),
            (Ui.V(0, Ui.Text(h.Group.Name, 13, "text", FontWeights.SemiBold), Ui.Text(h.Group.Owner, 11, "dim")), Ui.Star),
            (count, Ui.Auto));
        grid.Padding = new Thickness(0, 6, 0, 4);
        Ui.Tip(grid, h.Group.Id);
        return grid;
    }
}

public sealed record GroupedSearchItem(SearchItem Item);

public sealed class NotificationRow : CodeRow
{
    protected override UIElement? Build(object item)
    {
        if (item is not NotificationThread n) return null;
        var (glyph, color) = n.Subject.Type switch
        {
            "PullRequest" => ("", "violet"),
            "Issue" => ("", "green"),
            "Release" => ("", "teal"),
            "Discussion" => ("", "indigo"),
            "CheckSuite" => ("", "red"),
            "Commit" => ("", "sky"),
            _ => ("", "amber")
        };
        var reasonColor = n.Reason switch
        {
            "review_requested" => "sky",
            "mention" or "team_mention" => "amber",
            "security_alert" => "red",
            _ => "muted"
        };
        var reason = n.Reason switch
        {
            "review_requested" => "review requested",
            "team_mention" => "team mention",
            "assign" => "assigned",
            "state_change" => "state change",
            "ci_activity" => "CI",
            "manual" => "subscribed",
            "security_alert" => "security alert",
            var r => r.Replace('_', ' ')
        };
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, Fill = n.Unread ? Palette.Brush("sky") : new SolidColorBrush(Microsoft.UI.Colors.Transparent), Margin = new Thickness(0, 7, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        var tile = Ui.IconTile(glyph, color, 22);
        tile.VerticalAlignment = VerticalAlignment.Top;
        var title = Ui.Text(n.Subject.Title, 13.5, n.Unread ? "text" : "muted", n.Unread ? FontWeights.SemiBold : FontWeights.Normal, maxLines: 2);
        Ui.Tip(title, n.Subject.Title);
        Ui.Tip(tile, TypeTitle(n.Subject.Type));
        var meta = Ui.H(5, Ui.Avatar(n.Repository.Owner?.AvatarUrl, 13, ring: true), Ui.Caption(n.Repository.FullName), Ui.Caption("·", "dim"), Ui.Caption(reason, reasonColor), Ui.Caption("·", "dim"), Ui.Caption(Fmt.Rel(n.UpdatedAt), "dim"));
        var grid = Ui.Columns((dot, Ui.Auto), (tile, Ui.Auto), (Ui.V(3, title, meta), Ui.Star));
        grid.Padding = new Thickness(0, 5, 0, 5);
        return grid;
    }

    protected override string? Spoken(object item)
    {
        if (item is not NotificationThread n) return null;
        var parts = new List<string>();
        if (n.Unread) parts.Add(L.T("A11y_Unread", "Unread"));
        parts.Add(TypeTitle(n.Subject.Type));
        parts.Add(n.Subject.Title);
        parts.Add(n.Repository.FullName);
        parts.Add(n.Reason.Replace('_', ' '));
        parts.Add(L.F("A11y_Updated", "updated {0}", Fmt.Rel(n.UpdatedAt)));
        return string.Join(", ", parts);
    }

    private static string TypeTitle(string type) => type switch
    {
        "PullRequest" => L.T("A11y_PullRequest", "Pull request"),
        "Issue" => L.T("A11y_Issue", "Issue"),
        "Release" => L.T("A11y_Release", "Release"),
        "Discussion" => L.T("A11y_Discussion", "Discussion"),
        "CheckSuite" => L.T("A11y_CheckSuite", "Check suite"),
        "Commit" => L.T("A11y_Commit", "Commit"),
        _ => L.T("A11y_Notification", "Notification")
    };
}

public sealed class RepoRow : CodeRow
{
    protected override UIElement? Build(object item)
    {
        if (item is not RepoSummary repo) return null;
        var tile = Ui.IconTile(repo.IsPrivate ? "" : "", repo.IsArchived ? "slate" : "teal", 22);
        tile.VerticalAlignment = VerticalAlignment.Top;
        var name = Ui.Text(repo.NameWithOwner, 13.5, "text", FontWeights.Medium);
        Ui.Tip(name, repo.NameWithOwner);
        var title = Ui.H(5, name);
        if (repo.IsArchived) title.Children.Add(Ui.Chip(L.T("Repo_Archived", "archived"), "amber"));
        if (repo.IsFork) title.Children.Add(Ui.StatusGlyph("", 10, "dim", L.T("A11y_Fork", "Fork")));
        var body = Ui.V(3, title);
        if (!string.IsNullOrEmpty(repo.Description)) body.Children.Add(Ui.Text(repo.Description, 12, "muted", maxLines: 2));
        var stats = Ui.H(10);
        if (repo.PrimaryLanguage is { } lang)
            stats.Children.Add(Ui.H(3, new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, Fill = Palette.HexBrush(lang.Color ?? "#888") }, Ui.Caption(lang.Name)));
        if (repo.PullRequests.TotalCount > 0) stats.Children.Add(Ui.H(3, Ui.Glyph("", 11, "violet"), Ui.Caption(repo.PullRequests.TotalCount.ToString(), "violet")));
        if (repo.Issues.TotalCount > 0) stats.Children.Add(Ui.H(3, Ui.Glyph("", 11, "green"), Ui.Caption(repo.Issues.TotalCount.ToString(), "green")));
        if (repo.StargazerCount > 0) stats.Children.Add(Ui.H(3, Ui.Glyph("", 11, "amber"), Ui.Caption(repo.StargazerCount.ToString(), "amber")));
        var line = Ui.Columns((stats, Ui.Star), (Ui.Caption(Fmt.Rel(repo.PushedAt), "dim"), Ui.Auto));
        body.Children.Add(line);
        var grid = Ui.Columns((tile, Ui.Auto), (body, Ui.Star));
        grid.Padding = new Thickness(0, 5, 0, 5);
        return grid;
    }

    protected override string? Spoken(object item)
    {
        if (item is not RepoSummary repo) return null;
        var parts = new List<string> { repo.NameWithOwner };
        if (repo.IsPrivate) parts.Add(L.T("A11y_Private", "private"));
        if (repo.IsArchived) parts.Add(L.T("Repo_Archived", "archived"));
        if (repo.IsFork) parts.Add(L.T("A11y_Fork", "Fork"));
        if (!string.IsNullOrEmpty(repo.Description)) parts.Add(repo.Description);
        if (repo.PullRequests.TotalCount > 0) parts.Add(Fmt.Plural(repo.PullRequests.TotalCount, "pull request", "pull requests"));
        if (repo.Issues.TotalCount > 0) parts.Add(Fmt.Plural(repo.Issues.TotalCount, "issue", "issues"));
        if (repo.StargazerCount > 0) parts.Add(Fmt.Plural(repo.StargazerCount, "star", "stars"));
        return string.Join(", ", parts);
    }
}

public sealed class ProjectRow : CodeRow
{
    protected override UIElement? Build(object item)
    {
        if (item is not ProjectSummary p) return null;
        var tile = Ui.IconTile("", p.Closed ? "slate" : "indigo", 22);
        tile.VerticalAlignment = VerticalAlignment.Top;
        var name = Ui.Text(p.Title, 13.5, "text", FontWeights.Medium);
        Ui.Tip(name, p.Title);
        var title = Ui.H(5, name);
        if (p.Closed) title.Children.Add(Ui.Chip(L.T("Project_Closed", "closed"), "slate"));
        var body = Ui.V(3, title);
        if (!string.IsNullOrEmpty(p.ShortDescription)) body.Children.Add(Ui.Text(p.ShortDescription, 12, "muted", maxLines: 2));
        var meta = Ui.H(6, Ui.Caption($"{p.Owner?.Login ?? ""} · #{p.Number}"), Ui.Caption("·", "dim"), Ui.Caption(Fmt.Plural(p.Items.TotalCount, "item", "items"), "indigo"));
        body.Children.Add(Ui.Columns((meta, Ui.Star), (Ui.Caption(Fmt.Rel(p.UpdatedAt), "dim"), Ui.Auto)));
        var grid = Ui.Columns((tile, Ui.Auto), (body, Ui.Star));
        grid.Padding = new Thickness(0, 5, 0, 5);
        return grid;
    }

    protected override string? Spoken(object item)
    {
        if (item is not ProjectSummary p) return null;
        var parts = new List<string> { p.Title };
        if (p.Closed) parts.Add(L.T("Project_Closed", "closed"));
        parts.Add(Fmt.Plural(p.Items.TotalCount, "item", "items"));
        parts.Add(L.F("A11y_Updated", "updated {0}", Fmt.Rel(p.UpdatedAt)));
        return string.Join(", ", parts);
    }
}

public sealed class SessionRow : CodeRow
{
    protected override UIElement? Build(object item)
    {
        return item switch
        {
            SessionListItem s => Session(s),
            ProjectHeaderItem p => ProjectHeader(p),
            OpenTabItem t => OpenTab(t),
            SectionLabelItem l => SectionLabel(l),
            ArchivedToggleItem a => ArchivedToggle(a),
            _ => null
        };
    }

    protected override string? Spoken(object item) => item switch
    {
        SessionListItem s => string.Join(", ", new[]
        {
            s.Session.Title,
            s.Open ? L.T("A11y_OpenTab", "open") : null,
            s.Session.PrNumber is { } n ? $"PR #{n}" : null,
            s.ChildCount > 0 ? Fmt.Plural(s.ChildCount, "sub-session", "sub-sessions") + ", " + (s.Collapsed ? L.T("A11y_Collapsed", "Collapsed") : L.T("A11y_Expanded", "Expanded")) : null,
            L.F("Agents_Updated", "Updated {0}", Fmt.Rel(s.Session.Modified))
        }.Where(x => x is not null)),
        ProjectHeaderItem p => $"{p.Project.Name}, {Fmt.Plural(p.Count, "session", "sessions")}, {(p.Expanded ? L.T("A11y_Expanded", "Expanded") : L.T("A11y_Collapsed", "Collapsed"))}",
        OpenTabItem t => $"{t.Tab.Title}, {t.Tab.ProjectName}, {t.Tab.State.Help()}",
        SectionLabelItem l => l.Text,
        ArchivedToggleItem a => a.Showing ? L.T("Agents_HideArchived", "Hide archived sessions") : L.T("Agents_ShowArchived", "Show archived sessions"),
        _ => null
    };

    private static UIElement SectionLabel(SectionLabelItem item)
    {
        var label = Ui.H(5);
        if (item.Glyph is { } g) label.Children.Add(Ui.Glyph(g, 10, "muted"));
        label.Children.Add(Ui.Text(item.Text, 11.5, "muted", FontWeights.SemiBold));
        var grid = Ui.Columns((label, Ui.Star), (item.OnAction is { } act && item.ActionText is { } text ? Ui.Link(text, act, 11.5) : null, Ui.Auto));
        grid.Padding = new Thickness(0, 12, 0, 4);
        return grid;
    }

    private static UIElement ArchivedToggle(ArchivedToggleItem item)
    {
        var t = Ui.Text(item.Showing ? L.T("Agents_HideArchived", "Hide archived sessions") : L.T("Agents_ShowArchived", "Show archived sessions"), 12, "accent");
        t.Margin = new Thickness(0, 10, 0, 12);
        return t;
    }

    private static UIElement Session(SessionListItem item)
    {
        var s = item.Session;
        var ws = AppViewModel.Shared.Claude;
        var cols = new List<(UIElement? Element, GridLength Width)>();
        if (item.Depth > 0) cols.Add((TreeGuide(item.Last), Ui.Auto));
        if (item.ChildCount > 0)
        {
            var chevron = new Button
            {
                Content = Ui.Glyph(item.Collapsed ? "\uE76C" : "\uE70D", 9, "dim"),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(3),
                MinWidth = 0,
                MinHeight = 0,
                VerticalAlignment = VerticalAlignment.Center
            };
            chevron.Click += (_, _) => item.OnToggle?.Invoke();
            Ui.Tip(chevron, item.Collapsed ? L.T("Agents_ShowSubsessions", "Show sub-sessions") : L.T("Agents_HideSubsessions", "Hide sub-sessions"));
            Ui.Expandable(chevron, item.Collapsed ? L.T("Agents_ShowSubsessions", "Show sub-sessions") : L.T("Agents_HideSubsessions", "Hide sub-sessions"), !item.Collapsed);
            cols.Add((chevron, Ui.Auto));
        }
        else if (item.Depth == 0)
        {
            cols.Add((new Border { Width = 0 }, Ui.Auto));
        }
        var title = Ui.Text(s.Title, 13, item.Depth > 0 ? "muted" : "text", item.Open ? FontWeights.SemiBold : FontWeights.Normal);
        cols.Add((title, Ui.Star));
        if (s.PrNumber is not null) cols.Add((Ui.StatusGlyph("", 11, "violet", L.T("A11y_PullRequest", "Pull request")), Ui.Auto));
        if (item.ChildCount > 0) cols.Add((Ui.Text(item.ChildCount.ToString(Fmt.Culture), 11.5, "dim"), Ui.Auto));
        cols.Add((Ui.Text(Fmt.Rel(s.Modified), 11.5, "dim"), Ui.Auto));
        cols.Add((SessionDot.ForSession(s, ws), Ui.Auto));
        var grid = Ui.Columns(cols.ToArray());
        grid.ColumnSpacing = 6;
        grid.MinHeight = 34;
        grid.Padding = new Thickness(2, 7, 0, 7);
        Ui.Tip(grid, Details(s));
        return grid;
    }

    private static string Details(ClaudeSessionInfo s)
    {
        var parts = new List<string> { s.Title, L.F("Agents_Updated", "Updated {0}", Fmt.Rel(s.Modified)) };
        if (s.Branch is { } b) parts.Add(L.F("Agents_BranchDetail", "Branch: {0}", b));
        if (s.WorktreeName is { } w) parts.Add(L.F("Agents_WorktreeDetail", "Worktree: {0}", w));
        if (s.PrNumber is { } n) parts.Add($"PR #{n}");
        if (s.HasDiff) parts.Add($"+{s.LinesAdded ?? 0} −{s.LinesRemoved ?? 0}");
        return string.Join("\n", parts);
    }

    private static FrameworkElement TreeGuide(bool last)
    {
        var brush = Palette.Brush("text", ThemeService.IsDark ? 0.22 : 0.18);
        var g = new Grid { Width = 12, Margin = new Thickness(8, 0, 0, 0) };
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        if (last)
        {
            var elbow = new Border { BorderBrush = brush, BorderThickness = new Thickness(1, 0, 0, 1), CornerRadius = new CornerRadius(0, 0, 0, 6), Margin = new Thickness(0, -7, 0, 0) };
            g.Children.Add(elbow);
        }
        else
        {
            var line = new Border { BorderBrush = brush, BorderThickness = new Thickness(1, 0, 0, 0), Margin = new Thickness(0, -7, 0, -7) };
            Grid.SetRowSpan(line, 2);
            g.Children.Add(line);
            var tick = new Border { BorderBrush = brush, BorderThickness = new Thickness(0, 0, 0, 1) };
            g.Children.Add(tick);
        }
        return g;
    }

    public static Border BranchTag(string name)
    {
        var c = Palette.BranchKey(name);
        return Ui.Chip(name, c, "");
    }

    private static UIElement ProjectHeader(ProjectHeaderItem item)
    {
        var p = item.Project;
        var color = Palette.ProjectKey(p.Path);
        var count = new Border
        {
            Background = Palette.Brush(color, 0.14),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 0, 6, 1),
            Child = Ui.Text(item.Count.ToString(Fmt.Culture), 11, color, FontWeights.SemiBold),
            VerticalAlignment = VerticalAlignment.Center
        };
        var plus = Ui.IconButton("", L.T("Claude_NewSession", "New session"), () => item.OnNew?.Invoke(), "coral");
        plus.IsEnabled = p.Exists;
        var grid = Ui.Columns(
            (Ui.Glyph(item.Expanded ? "" : "", 10, "dim"), Ui.Auto),
            (Ui.IconTile(p.Exists ? "" : "", p.Exists ? color : "slate", 24), Ui.Auto),
            (Ui.V(0, Ui.Text(p.Name, 13, "text", FontWeights.SemiBold), Ui.Text(Fmt.HomeRelative(p.Path), 11, "dim")), Ui.Star),
            (count, Ui.Auto),
            (plus, Ui.Auto));
        grid.Opacity = p.Exists ? 1 : 0.6;
        grid.Padding = new Thickness(0, 8, 0, 4);
        return grid;
    }

    private static UIElement OpenTab(OpenTabItem item)
    {
        var tab = item.Tab;
        var bar = new Border { Width = 3, Height = 14, CornerRadius = new CornerRadius(1.5), Background = Palette.Brush(Palette.ProjectKey(tab.Folder)), VerticalAlignment = VerticalAlignment.Center };
        var title = Ui.Text(tab.Title, 13, "text", item.Selected ? FontWeights.SemiBold : FontWeights.Normal);
        var project = Ui.Text(tab.ProjectName, 12, "dim");
        project.MaxWidth = 120;
        var grid = Ui.Columns((bar, Ui.Auto), (title, Ui.Star), (project, Ui.Auto), (SessionDot.ForTab(tab), Ui.Auto));
        grid.ColumnSpacing = 8;
        grid.MinHeight = 34;
        grid.Padding = new Thickness(6, 7, 4, 7);
        grid.CornerRadius = new CornerRadius(7);
        if (item.Selected) grid.Background = Palette.Brush("accent", 0.12);
        var memory = tab.MemoryBytes;
        Ui.Tip(grid, tab.State.Help() + (memory > 0 ? " — " + Fmt.Memory(memory) : ""));
        return grid;
    }

    public static FrameworkElement StateBadge(ClaudeTabState state, long memory, bool compact = false)
    {
        var color = state.ColorKey();
        var glyph = state switch
        {
            ClaudeTabState.Working => "",
            ClaudeTabState.Waiting => "",
            ClaudeTabState.Active => "",
            ClaudeTabState.Sleeping => "",
            _ => ""
        };
        var p = Ui.H(4, Ui.Glyph(glyph, state == ClaudeTabState.Active ? 7 : 10, color));
        if (!compact)
        {
            p.Children.Add(Ui.Text(state.Title(), 12, color));
            if (memory > 0 && state != ClaudeTabState.Sleeping) p.Children.Add(Ui.Text("· " + Fmt.Memory(memory), 12, "muted"));
        }
        Ui.Tip(p, state.Help() + (memory > 0 ? " — " + Fmt.Memory(memory) : ""));
        if (compact) Ui.Named(p, state.Title(), state.Help());
        return p;
    }
}

public sealed record SessionListItem(ClaudeSessionInfo Session, bool Open)
{
    public int Depth { get; init; }
    public bool Last { get; init; }
    public int ChildCount { get; init; }
    public bool Collapsed { get; init; }
    public Action? OnToggle { get; init; }
}

public sealed record ProjectHeaderItem(ClaudeProject Project, bool Expanded)
{
    public Action? OnNew { get; init; }
    public int Count { get; init; }
}

public sealed record OpenTabItem(ClaudeTab Tab, bool Selected);

public sealed record SectionLabelItem(string Text)
{
    public string? Glyph { get; init; }
    public string? ActionText { get; init; }
    public Action? OnAction { get; init; }
}

public sealed record ArchivedToggleItem(bool Showing);

public interface IRowContent
{
    UIElement BuildRow();

    string? SpokenName => null;
}

public sealed class GenericRow : CodeRow
{
    protected override UIElement? Build(object item) => item is IRowContent c ? c.BuildRow() : null;

    protected override string? Spoken(object item) => (item as IRowContent)?.SpokenName;
}

public static class ListSupport
{
    private static Style? stretch;

    public static DataTemplate Template(string key)
    {
        if (Application.Current.Resources.TryGetValue(key, out var v) && v is DataTemplate t) return t;
        foreach (var d in Application.Current.Resources.MergedDictionaries)
            if (d.TryGetValue(key, out var x) && x is DataTemplate dt) return dt;
        throw new InvalidOperationException($"Missing template {key}");
    }

    public static Style StretchItem
    {
        get
        {
            if (stretch is not null) return stretch;
            var s = new Style(typeof(ListViewItem));
            if (Application.Current.Resources.TryGetValue("DefaultListViewItemStyle", out var b) && b is Style basedOn) s.BasedOn = basedOn;
            s.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
            s.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(12, 0, 12, 0)));
            s.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0d));
            s.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(7)));
            stretch = s;
            return s;
        }
    }

    public static ListView Create(string template, ListViewSelectionMode mode = ListViewSelectionMode.Single)
    {
        var list = new ListView
        {
            ItemTemplate = Template(template),
            ItemContainerStyle = StretchItem,
            SelectionMode = mode,
            IsItemClickEnabled = true,
            Padding = new Thickness(0, 4, 0, 4)
        };
        return list;
    }
}
