using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using PullYard.Views;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace PullYard.Controls;

public static class Brand
{
    public static FontFamily Serif { get; } = new("Sitka Display, Sitka Text, Georgia");

    public static TextBlock Display(string text, double size = 28)
    {
        var t = Ui.Text(text, size, "text", FontWeights.SemiBold, wrap: true);
        t.FontFamily = Serif;
        t.TextAlignment = TextAlignment.Center;
        t.HorizontalAlignment = HorizontalAlignment.Center;
        return t;
    }

    public static Border Keycap(string key)
    {
        var t = Ui.Text(key, 11, "text", FontWeights.Medium, mono: true);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        return new Border
        {
            MinWidth = 22,
            MinHeight = 20,
            Padding = new Thickness(6, 1, 6, 1),
            CornerRadius = new CornerRadius(4),
            Background = Palette.Brush("raised"),
            BorderBrush = Palette.Brush("lineStrong"),
            BorderThickness = new Thickness(1),
            Child = t,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static FrameworkElement Shortcut(string key, string label)
    {
        var row = Ui.H(6, Keycap(key), Ui.Caption(label));
        AutomationProperties.SetName(row, $"{label}, {key}");
        return row;
    }

    public static Canvas HarborWaves(double width = 200, double height = 22)
    {
        var canvas = new Canvas { Width = width, Height = height, IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        foreach (var (y, inset, opacity) in new[] { (height * 0.35, 0.0, 1.0), (height * 0.8, width * 0.12, 0.6) })
        {
            var w = width - inset * 2;
            var figure = new PathFigure { StartPoint = new Point(inset, y), IsFilled = false };
            for (var s = 0; s < 4; s++)
            {
                var x0 = inset + w * s / 4;
                var x1 = inset + w * (s + 1) / 4;
                var dip = s % 2 == 0 ? -4 : 4;
                figure.Segments.Add(new QuadraticBezierSegment { Point1 = new Point((x0 + x1) / 2, y + dip), Point2 = new Point(x1, y) });
            }
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            canvas.Children.Add(new Path
            {
                Data = geometry,
                Stroke = Palette.Brush("harborLine"),
                StrokeThickness = 2,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                Opacity = opacity
            });
        }
        return canvas;
    }

    public static Grid Aurora()
    {
        var grid = new Grid { IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(grid, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (!ThemeService.IsBrand) return grid;
        void Blob(string key, double opacity, double size, double x, double y)
        {
            var color = Palette.Get(key);
            var brush = new RadialGradientBrush();
            brush.GradientStops.Add(new GradientStop { Color = LogoArt.Alpha(color, opacity), Offset = 0 });
            brush.GradientStops.Add(new GradientStop { Color = LogoArt.Alpha(color, opacity * 0.5), Offset = 0.45 });
            brush.GradientStops.Add(new GradientStop { Color = LogoArt.Alpha(color, 0), Offset = 1 });
            grid.Children.Add(new Ellipse
            {
                Width = size * 1.6,
                Height = size * 1.6,
                Fill = brush,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                RenderTransform = new TranslateTransform { X = x, Y = y }
            });
        }
        Blob("violet", 0.08, 320, -160, -90);
        Blob("accent", 0.08, 300, 170, -40);
        Blob("coral", 0.06, 260, 20, 140);
        return grid;
    }

    public static FrameworkElement HeroMark(string key, double size = 96)
    {
        var host = new Grid { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 14) };
        var waves = HarborWaves();
        waves.HorizontalAlignment = HorizontalAlignment.Center;
        waves.VerticalAlignment = VerticalAlignment.Bottom;
        waves.RenderTransform = new TranslateTransform { Y = 16 };
        host.Children.Add(waves);
        var lift = new TranslateTransform();
        var mark = new DrawnLogoMark(key, size) { HorizontalAlignment = HorizontalAlignment.Center, RenderTransform = lift };
        host.Children.Add(mark);
        if (!Motion.Enabled) return host;
        var bob = new DoubleAnimation
        {
            From = 0,
            To = -4,
            Duration = new Duration(TimeSpan.FromSeconds(2.3)),
            AutoReverse = true,
            RepeatBehavior = new RepeatBehavior(2),
            BeginTime = TimeSpan.FromSeconds(1.4),
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
        };
        var board = new Storyboard();
        Storyboard.SetTarget(bob, lift);
        Storyboard.SetTargetProperty(bob, "Y");
        board.Children.Add(bob);
        host.Loaded += (_, _) => board.Begin();
        host.Unloaded += (_, _) => board.Stop();
        return host;
    }
}

public sealed class EmptyHarbor : Grid
{
    public EmptyHarbor(string key, string title, string message, IEnumerable<(string Key, string Label)>? shortcuts = null, bool aurora = true, bool nextUp = false)
    {
        if (aurora) Children.Add(Brand.Aurora());
        var stack = Ui.V(14);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        stack.Padding = new Thickness(32);
        stack.Children.Add(Brand.HeroMark(key));
        stack.Children.Add(Brand.Display(title));
        var line = Ui.Text(message, 13, "muted", wrap: true);
        line.TextAlignment = TextAlignment.Center;
        line.HorizontalAlignment = HorizontalAlignment.Center;
        line.MaxWidth = 360;
        stack.Children.Add(line);
        if (shortcuts?.ToList() is { Count: > 0 } keys)
        {
            var row = new WrapPanel(16);
            row.HorizontalAlignment = HorizontalAlignment.Center;
            row.Margin = new Thickness(0, 6, 0, 0);
            foreach (var (k, label) in keys) row.Children.Add(Brand.Shortcut(k, label));
            stack.Children.Add(row);
        }
        if (nextUp)
        {
            var cards = NextUp.Panel();
            if (cards is not null)
            {
                cards.Margin = new Thickness(0, 18, 0, 0);
                stack.Children.Add(cards);
            }
            if (NextUp.Checklist() is { } checklist) stack.Children.Add(checklist);
        }
        var scroll = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Children.Add(scroll);
    }
}

public static class NextUp
{
    public const string ChecklistDismissedKey = "onboarding.checklistDismissed";

    public static FrameworkElement? Panel()
    {
        var app = AppViewModel.Shared;
        var reviews = app.ReviewRequests.Take(3).ToList();
        var attention = app.MyPRs.Where(i => i.CiState is "FAILURE" or "ERROR" || i.ReviewDecision == "CHANGES_REQUESTED").Take(3).ToList();
        var shown = reviews.Concat(attention).Select(i => i.Ref).ToHashSet();
        var recent = app.RecentRoutes.Where(r => r.Kind == RouteKind.PullRequest && r.Item is not null && !shown.Contains(r.Item)).Select(r => r.Item!).Distinct().Take(3).ToList();
        if (reviews.Count == 0 && attention.Count == 0 && recent.Count == 0) return null;
        var row = new WrapPanel(12) { HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 760 };
        if (reviews.Count > 0) row.Children.Add(Card(L.T("NextUp_YourTurn", "Your turn"), "", "link", reviews.Select(ItemRow)));
        if (attention.Count > 0) row.Children.Add(Card(L.T("NextUp_Attention", "Needs attention"), "", "amberInk", attention.Select(ItemRow)));
        if (recent.Count > 0) row.Children.Add(Card(L.T("NextUp_Recent", "Recent"), "", "muted", recent.Select(RecentRow)));
        return row;
    }

    private static FrameworkElement Card(string title, string glyph, string tint, IEnumerable<UIElement> rows)
    {
        var header = Ui.H(5, Ui.Glyph(glyph, 10, tint), Ui.Text(title.ToUpperInvariant(), 10, tint, FontWeights.SemiBold));
        header.Margin = new Thickness(0, 0, 0, 2);
        var stack = Ui.V(2, header);
        foreach (var r in rows) stack.Children.Add(r);
        var card = Ui.Card(stack, 10, "raised", 12);
        card.Width = 240;
        card.BorderBrush = Palette.Brush("line");
        AutomationProperties.SetName(card, title);
        return card;
    }

    private static Button Plain(UIElement content, Action click, string tip)
    {
        var b = new Button
        {
            Content = content,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 3, 4, 3)
        };
        b.Click += (_, _) => click();
        Ui.Tip(b, tip);
        AutomationProperties.SetName(b, tip);
        return b;
    }

    private static UIElement ItemRow(SearchItem item)
    {
        var key = Palette.StateKey(item.VisualState);
        var words = Ui.V(1, Ui.Text(item.Title, 13, "text", maxLines: 2), Ui.Text($"{item.Repository.NameWithOwner}#{item.Number}", 11, "muted", mono: true));
        var grid = Ui.Columns((Ui.Glyph(item.VisualState.Glyph(), 9, key), Ui.Auto), (words, Ui.Star));
        grid.ColumnSpacing = 6;
        return Plain(grid, () => AppViewModel.Shared.Open(item.Route), item.Title);
    }

    private static UIElement RecentRow(ItemRef r)
    {
        var text = ShortLink.Of(r);
        var t = Ui.Text(text, 13, "text", mono: true);
        t.TextTrimming = TextTrimming.CharacterEllipsis;
        return Plain(t, () => AppViewModel.Shared.Open(Route.Pr(r)), text);
    }

    private static bool NotificationsOn()
    {
        try
        {
            return Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Setting == Microsoft.Windows.AppNotifications.AppNotificationSetting.Enabled;
        }
        catch
        {
            return true;
        }
    }

    public static FrameworkElement? Checklist()
    {
        if (Settings.Shared.GetBool(ChecklistDismissedKey, false)) return null;
        var notifications = NotificationsOn();
        var agents = ClaudeAccountStore.Shared.IsLoggedIn;
        var jira = JiraService.Connections.IsConfigured;
        if (notifications && agents && jira) return null;
        var app = AppViewModel.Shared;
        var panel = Ui.V(8);
        Border? card = null;
        var close = Ui.IconButton("", L.T("Checklist_Hide", "Hide this checklist"), () =>
        {
            Settings.Shared.Set(ChecklistDismissedKey, true);
            if (card is not null) card.Visibility = Visibility.Collapsed;
        });
        close.Padding = new Thickness(4);
        panel.Children.Add(Ui.Columns((Ui.Text(L.T("Checklist_Title", "Get set up").ToUpperInvariant(), 10, "coralInk", FontWeights.SemiBold), Ui.Star), (close, Ui.Auto)));
        panel.Children.Add(Step(L.T("Checklist_Notifications", "Turn on notifications"), L.T("Checklist_NotificationsDetail", "Review requests and agent results, even when PullYard is in the background"), notifications,
            () => Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications")).AsTask().Forget()));
        panel.Children.Add(Step(L.T("Checklist_Agents", "Connect Agents"), L.T("Checklist_AgentsDetail", "Fix review comments and failing checks with an agent"), agents, () => app.Section = Section.Claude));
        panel.Children.Add(Step(L.T("Checklist_Jira", "Link Jira"), L.T("Checklist_JiraDetail", "Optional · see tickets next to the pull request"), jira, app.RequestSettings));
        card = Ui.Card(panel, 10, "raised", 14);
        card.Width = 420;
        card.BorderBrush = Palette.Brush("line");
        card.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetName(card, L.T("Checklist_Title", "Get set up"));
        return card;
    }

    private static FrameworkElement Step(string title, string detail, bool done, Action action)
    {
        var words = Ui.V(1, Ui.Text(title, 13, done ? "muted" : "text", FontWeights.Medium), Ui.Text(detail, 12, "muted", wrap: true));
        if (done) ((TextBlock)words.Children[0]).TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        var button = done ? null : Ui.Button(L.T("Checklist_SetUp", "Set up"), action);
        var row = Ui.Columns((Ui.Glyph(done ? "" : "", 13, done ? "green" : "dim"), Ui.Auto), (words, Ui.Star), (button, Ui.Auto));
        row.ColumnSpacing = 10;
        AutomationProperties.SetName(row, done ? $"{title}, {L.T("Checklist_Done", "done")}" : title);
        return row;
    }
}
