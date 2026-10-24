using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using PullYard.Services;
using PullYard.Views;
using Windows.Foundation;
using Windows.UI;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace PullYard.Controls;

internal static class LogoArt
{
    public const double BoxX = 150;
    public const double BoxY = 370;
    public const double BoxWidth = 750;
    public const double BoxHeight = 500;

    public static readonly Color Violet = Color.FromArgb(255, 0xA7, 0x8B, 0xFA);
    public static readonly Color Sky = Color.FromArgb(255, 0x38, 0xBD, 0xF8);
    public static readonly Color Blue = Color.FromArgb(255, 0x6E, 0xA6, 0xFA);
    public static readonly Color HullTop = Color.FromArgb(255, 0xFB, 0x71, 0x85);
    public static readonly Color HullBottom = Color.FromArgb(255, 0xD6, 0x1F, 0x4E);
    public static readonly Color Deck = Color.FromArgb(255, 0xFE, 0xCD, 0xD3);
    public static readonly Color Cabin = Color.FromArgb(255, 0xF8, 0xFA, 0xFC);
    public static readonly Color CabinShade = Color.FromArgb(255, 0xE2, 0xE8, 0xF0);
    public static readonly Color Window = Color.FromArgb(255, 0x1E, 0x29, 0x3B);
    public static readonly Color Wave = Color.FromArgb(255, 0x7D, 0xD3, 0xFC);

    public static Color Alpha(Color c, double opacity) => Color.FromArgb((byte)Math.Round(255 * opacity), c.R, c.G, c.B);

    public static PathGeometry Circle(double cx, double cy, double r)
    {
        var figure = new PathFigure { StartPoint = new Point(cx + r, cy), IsClosed = true, IsFilled = false };
        figure.Segments.Add(new ArcSegment { Point = new Point(cx - r, cy), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise });
        figure.Segments.Add(new ArcSegment { Point = new Point(cx + r, cy), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise });
        var g = new PathGeometry();
        g.Figures.Add(figure);
        return g;
    }

    public static PathGeometry Curves(Point start, params (Point C1, Point C2, Point End)[] parts)
    {
        var figure = new PathFigure { StartPoint = start, IsFilled = false };
        foreach (var (c1, c2, end) in parts) figure.Segments.Add(new BezierSegment { Point1 = c1, Point2 = c2, Point3 = end });
        var g = new PathGeometry();
        g.Figures.Add(figure);
        return g;
    }

    public static PathGeometry Polygon(bool filled, params Point[] points)
    {
        var figure = new PathFigure { StartPoint = points[0], IsClosed = true, IsFilled = filled };
        foreach (var p in points.Skip(1)) figure.Segments.Add(new LineSegment { Point = p });
        var g = new PathGeometry();
        g.Figures.Add(figure);
        return g;
    }

    public static double CubicLength(Point start, params (Point C1, Point C2, Point End)[] parts)
    {
        var total = 0.0;
        var from = start;
        foreach (var (c1, c2, end) in parts)
        {
            var prev = from;
            for (var i = 1; i <= 48; i++)
            {
                var t = i / 48.0;
                var u = 1 - t;
                var x = u * u * u * from.X + 3 * u * u * t * c1.X + 3 * u * t * t * c2.X + t * t * t * end.X;
                var y = u * u * u * from.Y + 3 * u * u * t * c1.Y + 3 * u * t * t * c2.Y + t * t * t * end.Y;
                total += Math.Sqrt((x - prev.X) * (x - prev.X) + (y - prev.Y) * (y - prev.Y));
                prev = new Point(x, y);
            }
            from = end;
        }
        return total;
    }

    public static double PolygonLength(params Point[] points)
    {
        var total = 0.0;
        for (var i = 0; i < points.Length; i++)
        {
            var a = points[i];
            var b = points[(i + 1) % points.Length];
            total += Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
        }
        return total;
    }

    public static Rectangle Rect(double x, double y, double w, double h, double radius, Color fill)
    {
        var r = new Rectangle { Width = w, Height = h, RadiusX = radius, RadiusY = radius, Fill = new SolidColorBrush(fill) };
        Canvas.SetLeft(r, x);
        Canvas.SetTop(r, y);
        return r;
    }
}

public sealed class LogoLoader : Grid
{
    private const double Draw = 1.7;
    private const double Hold = 0.5;
    private const double Erase = 0.55;
    private const double DashPad = 0.6;

    private readonly bool once;
    private readonly double drawSeconds;
    private readonly Storyboard? board;
    private readonly List<Action> finalState = new();
    private bool running;

    public event Action? Drawn;

    public LogoLoader(double size = 56, bool once = false, double? drawSeconds = null)
    {
        this.once = once;
        this.drawSeconds = drawSeconds ?? Draw;
        Width = size;
        Height = size * LogoArt.BoxHeight / LogoArt.BoxWidth;
        IsHitTestVisible = false;
        AutomationProperties.SetName(this, L.T("Loader_Loading", "Loading"));

        var art = new Canvas { RenderTransform = new TranslateTransform { X = -LogoArt.BoxX, Y = -LogoArt.BoxY } };
        Children.Add(new Viewbox { Stretch = Stretch.Uniform, Child = new Canvas { Width = LogoArt.BoxWidth, Height = LogoArt.BoxHeight, Children = { art } } });

        var animate = Motion.Enabled;
        board = animate ? new Storyboard() : null;
        if (board is not null && !once)
        {
            board.Duration = new Duration(TimeSpan.FromSeconds(Cycle));
            board.RepeatBehavior = RepeatBehavior.Forever;
        }

        var curveA = (Start: new Point(240, 500), Parts: new[] { (new Point(392, 500), new Point(420, 636), new Point(520, 636)) });
        var curveB = (Start: new Point(240, 772), Parts: new[] { (new Point(392, 772), new Point(420, 636), new Point(520, 636)) });
        var hull = new[] { new Point(470, 566), new Point(866, 566), new Point(800, 728), new Point(540, 728) };
        var wave1 = (Start: new Point(560, 786), Parts: new[] { (new Point(620, 770), new Point(660, 802), new Point(720, 786)), (new Point(780, 770), new Point(820, 770), new Point(870, 786)) });
        var wave2 = (Start: new Point(600, 836), Parts: new[] { (new Point(650, 822), new Point(690, 848), new Point(740, 836)), (new Point(790, 824), new Point(820, 822), new Point(850, 836)) });

        art.Children.Add(Stroke(LogoArt.Circle(206, 500, 34), 2 * Math.PI * 34, 18, LogoArt.Violet, 0.00, 0.22));
        art.Children.Add(Stroke(LogoArt.Circle(206, 772, 34), 2 * Math.PI * 34, 18, LogoArt.Sky, 0.00, 0.22));
        art.Children.Add(Stroke(LogoArt.Curves(curveA.Start, curveA.Parts), LogoArt.CubicLength(curveA.Start, curveA.Parts), 24, LogoArt.Violet, 0.14, 0.48));
        art.Children.Add(Stroke(LogoArt.Curves(curveB.Start, curveB.Parts), LogoArt.CubicLength(curveB.Start, curveB.Parts), 24, LogoArt.Sky, 0.14, 0.48));

        var fill = new Canvas();
        var gradient = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        gradient.GradientStops.Add(new GradientStop { Color = LogoArt.HullTop, Offset = 0 });
        gradient.GradientStops.Add(new GradientStop { Color = LogoArt.HullBottom, Offset = 1 });
        fill.Children.Add(new Path { Data = LogoArt.Polygon(true, hull), Fill = gradient });
        fill.Children.Add(new Path { Data = LogoArt.Polygon(true, new Point(470, 566), new Point(866, 566), new Point(857, 590), new Point(480, 590)), Fill = new SolidColorBrush(LogoArt.Deck) });
        var porthole = new Ellipse { Width = 30, Height = 30, Fill = new SolidColorBrush(LogoArt.Deck) };
        Canvas.SetLeft(porthole, 755);
        Canvas.SetTop(porthole, 627);
        fill.Children.Add(porthole);
        Fade(fill, 0.58, 0.78, 0, 1, true);
        art.Children.Add(fill);

        var hullLine = Stroke(LogoArt.Polygon(false, hull), LogoArt.PolygonLength(hull), 14, LogoArt.HullTop, 0.40, 0.68);
        hullLine.StrokeLineJoin = PenLineJoin.Round;
        Fade(hullLine, 0.58, 0.78, 1, 0.15, false);
        art.Children.Add(hullLine);

        var scale = new ScaleTransform { CenterX = LogoArt.BoxX + LogoArt.BoxWidth / 2, CenterY = 566, ScaleY = 0.6 };
        var cabin = new Canvas { RenderTransform = scale };
        cabin.Children.Add(LogoArt.Rect(702, 392, 40, 86, 8, LogoArt.CabinShade));
        cabin.Children.Add(LogoArt.Rect(702, 392, 40, 20, 6, LogoArt.HullTop));
        cabin.Children.Add(LogoArt.Rect(584, 462, 176, 104, 16, LogoArt.Cabin));
        cabin.Children.Add(LogoArt.Rect(584, 540, 176, 26, 0, LogoArt.CabinShade));
        cabin.Children.Add(LogoArt.Rect(610, 488, 38, 34, 8, LogoArt.Window));
        cabin.Children.Add(LogoArt.Rect(664, 488, 38, 34, 8, LogoArt.Window));
        Fade(cabin, 0.66, 0.86, 0, 1, true);
        Grow(scale, 0.66, 0.86);
        art.Children.Add(cabin);

        art.Children.Add(Stroke(LogoArt.Curves(wave1.Start, wave1.Parts), LogoArt.CubicLength(wave1.Start, wave1.Parts), 12, LogoArt.Alpha(LogoArt.Wave, 0.55), 0.74, 1.00));
        art.Children.Add(Stroke(LogoArt.Curves(wave2.Start, wave2.Parts), LogoArt.CubicLength(wave2.Start, wave2.Parts), 10, LogoArt.Alpha(LogoArt.Wave, 0.32), 0.78, 1.00));

        if (board is null)
        {
            foreach (var apply in finalState) apply();
            Opacity = once ? 1 : 0.8;
            return;
        }
        if (once) board.Completed += (_, _) => Drawn?.Invoke();
        Loaded += (_, _) => Sync();
        Unloaded += (_, _) => Stop();
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => Sync());
    }

    internal void Freeze(double seconds)
    {
        if (board is null) return;
        running = true;
        board.Begin();
        board.Pause();
        board.SeekAlignedToLastTick(TimeSpan.FromSeconds(seconds));
    }

    private double Cycle => drawSeconds + Hold + Erase;

    private TimeSpan At(double progress) => TimeSpan.FromSeconds(progress * drawSeconds);

    private static KeyTime Key(TimeSpan t) => KeyTime.FromTimeSpan(t);

    private void Sync()
    {
        if (board is null) return;
        if (IsLoaded && Visibility == Visibility.Visible)
        {
            if (running) return;
            running = true;
            board.Begin();
        }
        else Stop();
    }

    private void Stop()
    {
        if (board is null || !running) return;
        running = false;
        if (once) board.SkipToFill();
        else board.Stop();
    }

    private Path Stroke(Geometry geometry, double length, double thickness, Color color, double from, double to)
    {
        var dash = length / thickness;
        var hidden = dash + DashPad;
        var path = new Path
        {
            Data = geometry,
            Stroke = new SolidColorBrush(color),
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeDashCap = PenLineCap.Round,
            StrokeDashArray = new DoubleCollection { dash, dash + 2 * DashPad + 1 },
            StrokeDashOffset = board is null ? 0 : hidden
        };
        finalState.Add(() => path.StrokeDashOffset = 0);
        if (board is null) return path;
        var anim = new DoubleAnimationUsingKeyFrames { EnableDependentAnimation = true };
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.Zero), Value = hidden });
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(At(from)), Value = hidden });
        anim.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = Key(At(to)), Value = 0, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });
        if (!once)
        {
            anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.FromSeconds(drawSeconds + Hold)), Value = 0 });
            anim.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = Key(TimeSpan.FromSeconds(Cycle)), Value = -hidden, EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut } });
        }
        Storyboard.SetTarget(anim, path);
        Storyboard.SetTargetProperty(anim, "StrokeDashOffset");
        board.Children.Add(anim);
        return path;
    }

    private void Fade(UIElement target, double from, double to, double start, double end, bool eraseOut)
    {
        finalState.Add(() => target.Opacity = end);
        target.Opacity = board is null ? end : start;
        if (board is null) return;
        var anim = new DoubleAnimationUsingKeyFrames();
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.Zero), Value = start });
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(At(from)), Value = start });
        anim.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = Key(At(to)), Value = end, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });
        if (!once)
        {
            anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.FromSeconds(drawSeconds + Hold)), Value = end });
            anim.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = Key(TimeSpan.FromSeconds(Cycle)), Value = eraseOut ? 0 : end, EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut } });
        }
        Storyboard.SetTarget(anim, target);
        Storyboard.SetTargetProperty(anim, "Opacity");
        board.Children.Add(anim);
    }

    private void Grow(ScaleTransform scale, double from, double to)
    {
        finalState.Add(() => scale.ScaleY = 1);
        if (board is null) return;
        var anim = new DoubleAnimationUsingKeyFrames();
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.Zero), Value = 0.6 });
        anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(At(from)), Value = 0.6 });
        anim.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = Key(At(to)), Value = 1, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });
        if (!once) anim.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = Key(TimeSpan.FromSeconds(Cycle)), Value = 1 });
        Storyboard.SetTarget(anim, scale);
        Storyboard.SetTargetProperty(anim, "ScaleY");
        board.Children.Add(anim);
    }
}

public sealed class WakeLoader : Grid
{
    private const double Period = 1 / 1.6;
    private const int Samples = 16;
    private readonly Storyboard? board;
    private bool running;

    internal void Freeze(double seconds)
    {
        if (board is null) return;
        running = true;
        board.Begin();
        board.Pause();
        board.SeekAlignedToLastTick(TimeSpan.FromSeconds(seconds));
    }

    public WakeLoader(double size = 16)
    {
        var scale = size / 16;
        Width = 20 * scale;
        Height = 12 * scale;
        IsHitTestVisible = false;
        VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(this, L.T("Loader_Running", "Running"));
        var canvas = new Canvas { Width = 20, Height = 12 };
        Children.Add(new Viewbox { Stretch = Stretch.Uniform, Child = canvas });
        board = Motion.Enabled ? new Storyboard { RepeatBehavior = RepeatBehavior.Forever, Duration = new Duration(TimeSpan.FromSeconds(Period)) } : null;
        var colors = new[] { LogoArt.Sky, LogoArt.Blue, LogoArt.Violet };
        for (var i = 0; i < 3; i++)
        {
            var x = 20 * (0.12 + 0.3 * i);
            const double y = 12 * 0.62;
            var figure = new PathFigure { StartPoint = new Point(x - 3, y), IsFilled = false };
            figure.Segments.Add(new QuadraticBezierSegment { Point1 = new Point(x, y - 3), Point2 = new Point(x + 3, y) });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            var shift = new TranslateTransform();
            var wave = new Path
            {
                Data = geometry,
                Stroke = new SolidColorBrush(colors[i]),
                StrokeThickness = 2,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                RenderTransform = shift
            };
            canvas.Children.Add(wave);
            if (board is null)
            {
                shift.Y = -12 * 0.28;
                continue;
            }
            var lift = new DoubleAnimationUsingKeyFrames();
            var fade = new DoubleAnimationUsingKeyFrames();
            for (var k = 0; k <= Samples; k++)
            {
                var t = (double)k / Samples;
                var p = t - i * 0.22;
                p -= Math.Floor(p);
                var s = Math.Sin(p * Math.PI);
                var time = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t * Period));
                lift.KeyFrames.Add(new LinearDoubleKeyFrame { KeyTime = time, Value = -s * 12 * 0.28 });
                fade.KeyFrames.Add(new LinearDoubleKeyFrame { KeyTime = time, Value = 0.45 + 0.55 * s });
            }
            Storyboard.SetTarget(lift, shift);
            Storyboard.SetTargetProperty(lift, "Y");
            Storyboard.SetTarget(fade, wave);
            Storyboard.SetTargetProperty(fade, "Opacity");
            board.Children.Add(lift);
            board.Children.Add(fade);
        }
        if (board is null) return;
        Loaded += (_, _) => Sync();
        Unloaded += (_, _) => Sync();
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => Sync());
    }

    private void Sync()
    {
        if (board is null) return;
        var show = IsLoaded && Visibility == Visibility.Visible;
        if (show == running) return;
        running = show;
        if (show) board.Begin();
        else board.Stop();
    }
}
