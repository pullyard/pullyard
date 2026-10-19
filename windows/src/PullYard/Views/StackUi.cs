using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public static class StackUi
{
    public const string StackGlyph = "";

    public static string Title(this StackStatus s) => s switch
    {
        StackStatus.Merged => L.T("Stack_StatusMerged", "Merged"),
        StackStatus.Closed => L.T("Stack_StatusClosed", "Closed"),
        StackStatus.Draft => L.T("Stack_StatusDraft", "Draft"),
        StackStatus.CiFailed => L.T("Stack_StatusCiFailed", "CI failed"),
        StackStatus.ChangesRequested => L.T("Stack_StatusChanges", "Changes requested"),
        StackStatus.Ready => L.T("Stack_StatusReady", "Ready"),
        StackStatus.Checking => L.T("Stack_StatusChecking", "Checks running"),
        _ => L.T("Stack_StatusReview", "In review")
    };

    public static string Title(this StackNoteKind k) => k switch
    {
        StackNoteKind.Question => L.T("Notes_Question", "Question"),
        StackNoteKind.Decision => L.T("Notes_Decision", "Decision"),
        _ => L.T("Notes_Note", "Note")
    };

    public static Border StatusPill(StackStatus status, bool zoomed = true)
    {
        var key = status.ColorKey();
        var text = zoomed ? Ui.Text(status.Title(), 11, key, FontWeights.SemiBold) : Fixed(status.Title(), 11, key, FontWeights.SemiBold);
        return new Border
        {
            Background = Palette.Brush(key, 0.14),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 1, 7, 2),
            Child = text,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static TextBlock Fixed(string? text, double size, string color = "text", Windows.UI.Text.FontWeight? weight = null, bool mono = false)
    {
        var t = new TextBlock
        {
            Text = text ?? "",
            FontSize = size,
            Foreground = Palette.Brush(color),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            VerticalAlignment = VerticalAlignment.Center
        };
        if (weight is { } w) t.FontWeight = w;
        if (mono) t.FontFamily = Ui.Mono;
        return t;
    }

    public static FontIcon FixedGlyph(string glyph, double size, string color) => new()
    {
        Glyph = glyph,
        FontFamily = Ui.Icons,
        FontSize = size,
        Foreground = Palette.Brush(color),
        VerticalAlignment = VerticalAlignment.Center
    };

    public static Border Dots(IEnumerable<(string Color, double Opacity, double Width)> dots)
    {
        var row = Ui.H(3);
        foreach (var (color, opacity, width) in dots)
            row.Children.Add(new Border { Width = width, Height = 5, CornerRadius = new CornerRadius(2.5), Background = Palette.Brush(color, opacity), VerticalAlignment = VerticalAlignment.Center });
        return new Border { Child = row, VerticalAlignment = VerticalAlignment.Center };
    }

    private static Button Plain(UIElement content, string? tip, Action onClick)
    {
        var b = new Button
        {
            Content = content,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 2, 6, 2),
            VerticalAlignment = VerticalAlignment.Center
        };
        Ui.Tip(b, tip);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static FrameworkElement Strip(StackTree tree, RepoRef repo, Action onShow)
    {
        var app = AppViewModel.Shared;
        var line = tree.Line;
        var index = Math.Max(0, line.FindIndex(s => s.Number == tree.Current));
        var ups = tree.ChildrenOf(tree.Current).Where(tree.Nodes.ContainsKey).Select(n => tree.Nodes[n]).ToList();
        void Go(int number) => app.Open(Route.Pr(new ItemRef(repo, number)));

        var summary = Ui.H(8,
            Ui.Glyph(StackGlyph, 13, "indigo"),
            Ui.Text(L.T("PR_Stack", "Stack"), 13, "text", FontWeights.SemiBold),
            Ui.Caption(L.F("PR_StackPosition", "{0} of {1}", index + 1, line.Count)),
            Dots(line.Select(s => (s.Number == tree.Current ? "indigo" : Palette.StateKey(s.VisualState), s.Number == tree.Current ? 1.0 : 0.55, s.Number == tree.Current ? 18.0 : 10.0))));
        if (tree.Count > line.Count)
        {
            var more = Ui.Caption($"+{tree.Count - line.Count}");
            var hidden = tree.Count - line.Count;
            Ui.Tip(more, hidden == 1 ? L.T("Stack_MoreOne", "1 more pull request on another branch of the stack") : L.F("Stack_MoreMany", "{0} more pull requests on other branches of the stack", hidden));
            summary.Children.Add(more);
        }
        var show = Plain(summary, L.T("Stack_ShowWhole", "Show the whole stack"), onShow);
        show.HorizontalAlignment = HorizontalAlignment.Stretch;
        show.HorizontalContentAlignment = HorizontalAlignment.Left;

        var nav = Ui.H(2);
        if (tree.ParentNode(tree.Current) is { } down)
            nav.Children.Add(Plain(Ui.H(4, Ui.Glyph("", 10), Ui.Text($"#{down.Number}", 12, "text", FontWeights.Medium)), $"{L.T("PR_DownStack", "Down the stack")}: #{down.Number} {down.Title}", () => Go(down.Number)));
        if (ups.Count == 1)
        {
            var up = ups[0];
            nav.Children.Add(Plain(Ui.H(4, Ui.Glyph("", 10), Ui.Text($"#{up.Number}", 12, "text", FontWeights.Medium)), $"{L.T("PR_UpStack", "Up the stack")}: #{up.Number} {up.Title}", () => Go(up.Number)));
        }
        else if (ups.Count > 1)
        {
            var menu = new MenuFlyout();
            foreach (var s in ups)
            {
                var number = s.Number;
                menu.Items.Add(Ui.MenuItem($"#{s.Number} {s.Title}", () => Go(number)));
            }
            var drop = new DropDownButton
            {
                Content = Ui.H(4, Ui.Glyph("", 10), Ui.Text(ups.Count.ToString(), 12, "text", FontWeights.Medium)),
                Flyout = menu,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(6, 2, 6, 2),
                VerticalAlignment = VerticalAlignment.Center
            };
            Ui.Tip(drop, L.F("Stack_UpMany", "Up the stack: {0} pull requests are stacked on this one", ups.Count));
            nav.Children.Add(drop);
        }
        nav.Children.Add(Plain(Ui.Glyph("", 10, "dim"), L.T("Stack_ShowWhole", "Show the whole stack"), onShow));
        var grid = Ui.Columns((show, Ui.Star), (nav, Ui.Auto));
        grid.ColumnSpacing = 4;
        return new Border { Background = Palette.Brush("indigo", 0.06), CornerRadius = new CornerRadius(9), Padding = new Thickness(4, 2, 4, 2), Child = grid };
    }

    public static Border Shimmer(double width = double.NaN, double height = 12, double radius = 6)
    {
        var bar = new Border { Width = width, Height = height, CornerRadius = new CornerRadius(radius), Background = Palette.Brush("text", 0.08), HorizontalAlignment = double.IsNaN(width) ? HorizontalAlignment.Stretch : HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        var animation = new DoubleAnimation { From = 1, To = 0.4, Duration = new Duration(TimeSpan.FromMilliseconds(800)), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EnableDependentAnimation = false };
        Storyboard.SetTarget(animation, bar);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var story = new Storyboard();
        story.Children.Add(animation);
        bar.Loaded += (_, _) =>
        {
            if (Motion.Enabled) story.Begin();
        };
        bar.Unloaded += (_, _) => story.Stop();
        return bar;
    }

    public static Dictionary<int, Core.Claude.ClaudeSessionInfo> MatchSessions(StackTree tree)
    {
        var byPR = new Dictionary<int, Core.Claude.ClaudeSessionInfo>();
        var byBranch = new Dictionary<string, Core.Claude.ClaudeSessionInfo>();
        IEnumerable<Core.Claude.ClaudeSessionInfo> all;
        try
        {
            all = AppViewModel.Shared.Claude.AllSessions.ToList();
        }
        catch
        {
            return new();
        }
        foreach (var s in all)
        {
            if (s.PrNumber is { } n) byPR.TryAdd(n, s);
            if (s.Branch is { Length: > 0 } b) byBranch.TryAdd(b, s);
        }
        var output = new Dictionary<int, Core.Claude.ClaudeSessionInfo>();
        foreach (var node in tree.Nodes.Values)
        {
            if (byPR.TryGetValue(node.Number, out var s) || byBranch.TryGetValue(node.HeadRefName, out s)) output[node.Number] = s;
        }
        return output;
    }
}

public static class Motion
{
    private static Windows.UI.ViewManagement.UISettings? settings;

    public static bool Enabled
    {
        get
        {
            try
            {
                settings ??= new Windows.UI.ViewManagement.UISettings();
                return settings.AnimationsEnabled;
            }
            catch
            {
                return true;
            }
        }
    }
}

public sealed class StackPreviewContent : Grid
{
    public StackPreviewContent(PRDetailViewModel model, StackNode node)
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var title = Ui.Text("", 20, "text", FontWeights.Bold);
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = node.Title + "  " });
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"#{node.Number}", Foreground = Palette.Brush("dim"), FontWeight = FontWeights.Normal });
        var head = Ui.Columns((title, Ui.Star), (Ui.Spinner(16), Ui.Auto));
        var meta = new WrapPanel(8, Ui.StateBadge(node.VisualState), Ui.Text(node.Author ?? "", 13, "text", FontWeights.SemiBold),
            PRContent.BranchChip(node.BaseRefName, "sky"), Ui.Glyph("", 11, "dim"), PRContent.BranchChip(node.HeadRefName, "violet"), StackUi.Shimmer(70));
        var header = Ui.V(8, head, meta);
        if (model.StackTree is { } tree) header.Children.Add(StackUi.Strip(tree, model.Ref.Repo, () => { }));
        header.Children.Add(StackUi.Shimmer(height: 30, radius: 9));
        header.Children.Add(StackUi.Shimmer(height: 30, radius: 9));
        header.Padding = new Thickness(16, 12, 16, 0);
        Children.Add(header);

        var tabs = Ui.H(14);
        foreach (var w in new[] { 96.0, 80, 70, 110 }) tabs.Children.Add(StackUi.Shimmer(w, 14));
        tabs.Children.Add(Ui.H(6, Ui.Glyph(StackUi.StackGlyph, 12, "text"), Ui.Text(L.T("PR_TabStack", "Stack"), 13, "text", FontWeights.SemiBold)));
        tabs.Padding = new Thickness(20, 10, 20, 10);
        var tabRow = Ui.V(0, tabs, Ui.Line());
        tabRow.Margin = new Thickness(0, 6, 0, 0);
        SetRow(tabRow, 1);
        Children.Add(tabRow);

        var stack = new StackTab(model);
        SetRow(stack, 2);
        Children.Add(stack);
        App.MainWindow?.SetSubtitle(node.Title);
    }
}
