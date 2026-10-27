using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using PullYard.Core.Claude;
using PullYard.Services;
using PullYard.Views;
using Windows.Foundation;

namespace PullYard.Controls;

public sealed class SessionDot : Grid
{
    private static Windows.UI.Color Violet => LogoArt.Violet;
    private static Windows.UI.Color Sky => LogoArt.Sky;
    private static Windows.UI.Color HullTop => LogoArt.HullTop;
    private static Windows.UI.Color HullBottom => LogoArt.HullBottom;

    private SessionIndicator shown = (SessionIndicator)(-1);
    private Storyboard? story;
    private ClaudeTab? tab;
    private DispatcherTimer? expiry;
    private Func<SessionIndicator>? evaluate;

    public SessionDot(SessionIndicator indicator = SessionIndicator.None)
    {
        Width = 14;
        Height = 14;
        IsHitTestVisible = true;
        VerticalAlignment = VerticalAlignment.Center;
        Loaded += (_, _) =>
        {
            Attach();
            story?.Begin();
            if (!Motion.Enabled) story?.Pause();
        };
        Unloaded += (_, _) =>
        {
            story?.Stop();
            Detach();
        };
        Set(indicator);
    }

    public static SessionDot ForTab(ClaudeTab tab) => new(tab.Indicator) { tab = tab };

    public static SessionDot ForSession(ClaudeSessionInfo session, ClaudeWorkspace ws)
    {
        if (ws.TabForSession(session.Id) is { } open) return ForTab(open);
        var dot = new SessionDot(ws.Indicator(session)) { evaluate = () => ws.Indicator(session) };
        if (dot.shown == SessionIndicator.Working)
        {
            var left = SessionIndicators.RecentWrite - (DateTimeOffset.Now - session.Modified) + TimeSpan.FromMilliseconds(200);
            dot.expiry = new DispatcherTimer { Interval = left > TimeSpan.Zero ? left : TimeSpan.FromMilliseconds(200) };
            dot.expiry.Tick += (_, _) =>
            {
                dot.expiry?.Stop();
                if (dot.evaluate is { } e) dot.Set(e());
            };
        }
        return dot;
    }

    private void Attach()
    {
        if (tab is not null)
        {
            tab.PropertyChanged -= OnTab;
            tab.PropertyChanged += OnTab;
            Set(tab.Indicator);
        }
        expiry?.Start();
    }

    private void Detach()
    {
        if (tab is not null) tab.PropertyChanged -= OnTab;
        expiry?.Stop();
    }

    private void OnTab(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(ClaudeTab.Indicator) || tab is null) return;
        var t = tab;
        if (DispatcherQueue.HasThreadAccess) Set(t.Indicator);
        else DispatcherQueue.TryEnqueue(() => Set(t.Indicator));
    }

    public void Set(SessionIndicator indicator)
    {
        if (indicator == shown) return;
        shown = indicator;
        story?.Stop();
        story = null;
        Children.Clear();
        Ui.Tip(this, null);
        switch (indicator)
        {
            case SessionIndicator.Working:
                BuildSpinner();
                break;
            case SessionIndicator.Done:
                BuildDone();
                break;
            case SessionIndicator.Waiting:
                BuildWaiting();
                break;
        }
        var help = Help(indicator);
        ToolTipService.SetToolTip(this, help.Length > 0 ? help : null);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, help);
        if (story is not null && IsLoaded)
        {
            story.Begin();
            if (!Motion.Enabled) story.Pause();
        }
    }

    public static string Help(SessionIndicator indicator) => indicator switch
    {
        SessionIndicator.Working => L.T("Agents_IndicatorWorking", "Working"),
        SessionIndicator.Done => L.T("Agents_IndicatorDone", "Finished — not viewed yet"),
        SessionIndicator.Waiting => L.T("Agents_IndicatorWaiting", "Waiting for you"),
        _ => ""
    };

    private static LinearGradientBrush Gradient(Windows.UI.Color a, Windows.UI.Color b, Point start, Point end)
    {
        var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end };
        brush.GradientStops.Add(new GradientStop { Color = a, Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = b, Offset = 1 });
        return brush;
    }

    private void BuildSpinner()
    {
        var host = new Grid { Width = 10, Height = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        host.Children.Add(new Ellipse { Width = 10, Height = 10, Stroke = new SolidColorBrush(LogoArt.Alpha(Violet, 0.2)), StrokeThickness = 2 });
        const double r = 4;
        var sweep = 0.34 * 360 * Math.PI / 180;
        var startAngle = -Math.PI / 2;
        var figure = new PathFigure { StartPoint = new Point(5 + r * Math.Cos(startAngle), 5 + r * Math.Sin(startAngle)), IsClosed = false, IsFilled = false };
        figure.Segments.Add(new ArcSegment
        {
            Point = new Point(5 + r * Math.Cos(startAngle + sweep), 5 + r * Math.Sin(startAngle + sweep)),
            Size = new Size(r, r),
            SweepDirection = SweepDirection.Clockwise,
            IsLargeArc = false
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        var rotate = new RotateTransform { CenterX = 5, CenterY = 5 };
        var arc = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = geometry,
            Width = 10,
            Height = 10,
            Stroke = Gradient(Sky, Violet, new Point(0, 0.5), new Point(1, 0.5)),
            StrokeThickness = 2,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            RenderTransform = rotate
        };
        host.Children.Add(arc);
        Children.Add(host);
        var spin = new DoubleAnimation { From = 0, To = 360, Duration = new Duration(TimeSpan.FromSeconds(1)), RepeatBehavior = RepeatBehavior.Forever, EnableDependentAnimation = false };
        Storyboard.SetTarget(spin, rotate);
        Storyboard.SetTargetProperty(spin, "Angle");
        story = new Storyboard();
        story.Children.Add(spin);
    }

    private void BuildDone()
    {
        var host = new Grid { Width = 10, Height = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        host.Children.Add(new Ellipse { Width = 10, Height = 10, Stroke = Gradient(Violet, Sky, new Point(0, 0), new Point(1, 1)), StrokeThickness = 2 });
        host.Children.Add(new Ellipse { Width = 4, Height = 4, Fill = Gradient(Violet, Sky, new Point(0, 0), new Point(1, 1)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        Children.Add(host);
    }

    private void BuildWaiting()
    {
        var host = new Grid { Width = 12, Height = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var scale = new ScaleTransform { CenterX = 6, CenterY = 6 };
        var pulse = new Ellipse { Width = 12, Height = 12, Fill = new SolidColorBrush(LogoArt.Alpha(HullTop, 0.3)), RenderTransform = scale };
        host.Children.Add(pulse);
        host.Children.Add(new Ellipse { Width = 12, Height = 12, Fill = Gradient(HullTop, HullBottom, new Point(0.5, 0), new Point(0.5, 1)) });
        var mark = new TextBlock
        {
            Text = "?",
            FontSize = 8.5,
            FontWeight = FontWeights.Black,
            Foreground = new SolidColorBrush(LogoArt.Cabin),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextLineBounds = TextLineBounds.Tight,
            IsTextScaleFactorEnabled = false
        };
        host.Children.Add(mark);
        Children.Add(host);
        var duration = new Duration(TimeSpan.FromSeconds(1.4));
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        story = new Storyboard();
        foreach (var property in new[] { "ScaleX", "ScaleY" })
        {
            var grow = new DoubleAnimation { From = 1, To = 1.7, Duration = duration, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
            Storyboard.SetTarget(grow, scale);
            Storyboard.SetTargetProperty(grow, property);
            story.Children.Add(grow);
        }
        var fade = new DoubleAnimation { From = 1, To = 0, Duration = duration, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease };
        Storyboard.SetTarget(fade, pulse);
        Storyboard.SetTargetProperty(fade, "Opacity");
        story.Children.Add(fade);
    }
}
