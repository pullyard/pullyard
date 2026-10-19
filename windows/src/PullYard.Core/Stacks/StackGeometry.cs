namespace PullYard.Core.Stacks;

public readonly record struct StackPoint(double X, double Y);

public readonly record struct StackSize(double Width, double Height);

public readonly record struct StackRect(double X, double Y, double Width, double Height)
{
    public bool Intersects(StackRect o) => X < o.X + o.Width && o.X < X + Width && Y < o.Y + o.Height && o.Y < Y + Height;

    public bool Contains(StackPoint p) => p.X >= X && p.X <= X + Width && p.Y >= Y && p.Y <= Y + Height;

    public StackRect Inflate(double dx, double dy) => new(X - dx, Y - dy, Width + dx * 2, Height + dy * 2);
}

public static class StackMetrics
{
    public const double Pad = 28;
    public const double CardWidth = 256;
    public const double CardHeight = 120;
    public const double GapX = 28;
    public const double GapY = 58;
    public const double PillHeight = 30;
    public const double PillWidth = 150;
    public const double NoteGap = 8;
    public const double NoteHeight = 76;
    public const double CullMargin = 60;
    public const double CompactBelow = 0.45;
    public const double LabelsFrom = 0.5;
}

public sealed class StackGeometry
{
    public StackLayout Layout { get; }
    public IReadOnlySet<int> Noted { get; }
    public StackSize Size { get; }
    private readonly Dictionary<int, double> tops = new();

    public StackGeometry(StackLayout layout, IReadOnlySet<int> noted)
    {
        Layout = layout;
        Noted = noted;
        var notedLevels = noted.Where(layout.Slots.ContainsKey).Select(n => layout.Slots[n].Level).ToHashSet();
        var y = StackMetrics.Pad + StackMetrics.PillHeight + StackMetrics.GapY;
        for (var level = 1; level <= Math.Max(layout.Levels, 1); level++)
        {
            tops[level] = y;
            y += StackMetrics.CardHeight + (notedLevels.Contains(level) ? StackMetrics.NoteGap + StackMetrics.NoteHeight : 0) + StackMetrics.GapY;
        }
        Size = new StackSize(StackMetrics.Pad * 2 + layout.Columns * (StackMetrics.CardWidth + StackMetrics.GapX) - StackMetrics.GapX, y - StackMetrics.GapY + StackMetrics.Pad);
    }

    public StackPoint? Origin(int number)
    {
        if (!Layout.Slots.TryGetValue(number, out var slot)) return null;
        return new StackPoint(StackMetrics.Pad + slot.Column * (StackMetrics.CardWidth + StackMetrics.GapX), tops.TryGetValue(slot.Level, out var t) ? t : 0);
    }

    public double? Bottom(int number)
    {
        if (Origin(number) is not { } o) return null;
        return o.Y + StackMetrics.CardHeight + (Noted.Contains(number) ? StackMetrics.NoteGap + StackMetrics.NoteHeight : 0);
    }

    public StackPoint? Center(int number) => Origin(number) is { } o ? new StackPoint(o.X + StackMetrics.CardWidth / 2, o.Y + StackMetrics.CardHeight / 2) : null;

    public HashSet<int> Visible(IEnumerable<int> numbers, StackViewport vp, StackSize viewport)
    {
        var margin = StackMetrics.CullMargin / Math.Max(vp.Zoom, 0.25);
        var rect = new StackRect(-vp.PanX / vp.Zoom, -vp.PanY / vp.Zoom, viewport.Width / vp.Zoom, viewport.Height / vp.Zoom).Inflate(margin, margin);
        var output = new HashSet<int>();
        foreach (var n in numbers)
        {
            if (Origin(n) is not { } o || Bottom(n) is not { } bottom) continue;
            if (rect.Intersects(new StackRect(o.X, o.Y, StackMetrics.CardWidth, bottom - o.Y))) output.Add(n);
        }
        return output;
    }
}

public readonly record struct StackViewport(double Zoom, double PanX, double PanY)
{
    public const double MinZoom = 0.12;
    public const double MaxZoom = 1.6;
    public const double Margin = 80;

    public static StackViewport Identity => new(1, 0, 0);

    public static StackViewport Centered(StackPoint point, double zoom, StackSize content, StackSize viewport) =>
        new StackViewport(zoom, viewport.Width / 2 - point.X * zoom, viewport.Height / 2 - point.Y * zoom).Clamped(content, viewport);

    public static StackViewport Fit(StackSize content, StackSize viewport)
    {
        if (content.Width <= 0 || content.Height <= 0) return Identity;
        var z = Math.Clamp(Math.Min(1, Math.Min((viewport.Width - 24) / content.Width, (viewport.Height - 24) / content.Height)), MinZoom, MaxZoom);
        return new StackViewport(z, 0, 0).Clamped(content, viewport);
    }

    public StackViewport Zoomed(double value, StackPoint anchor, StackSize content, StackSize viewport)
    {
        var z = Math.Clamp(value, MinZoom, MaxZoom);
        var k = z / Zoom;
        return new StackViewport(z, anchor.X - (anchor.X - PanX) * k, anchor.Y - (anchor.Y - PanY) * k).Clamped(content, viewport);
    }

    public StackViewport Panned(double dx, double dy, StackSize content, StackSize viewport) =>
        new StackViewport(Zoom, PanX + dx, PanY + dy).Clamped(content, viewport);

    public StackViewport Clamped(StackSize content, StackSize viewport)
    {
        var zoom = Zoom;
        double Axis(double p, double length, double visible)
        {
            var scaled = length * zoom;
            if (scaled <= visible) return (visible - scaled) / 2;
            return Math.Min(Math.Max(p, visible - scaled - Margin), Margin);
        }
        return new StackViewport(Zoom, Axis(PanX, content.Width, viewport.Width), Axis(PanY, content.Height, viewport.Height));
    }

    public StackViewport Lerp(StackViewport to, double t) =>
        new(Zoom + (to.Zoom - Zoom) * t, PanX + (to.PanX - PanX) * t, PanY + (to.PanY - PanY) * t);

    public StackPoint ToScreen(StackPoint p) => new(p.X * Zoom + PanX, p.Y * Zoom + PanY);

    public StackPoint ToContent(StackPoint p) => new((p.X - PanX) / Zoom, (p.Y - PanY) / Zoom);
}

public enum StackEdgeKind { Line, Curve, Elbow }

public readonly record struct StackEdge(StackPoint From, StackPoint To, StackEdgeKind Kind, double BusY, bool Lit, bool Label, bool FromRight);

public static class StackEdges
{
    public const int FanOutAbove = 4;

    public static List<StackEdge> Build(StackTree tree, StackGeometry geometry)
    {
        var path = tree.PathSet;
        var half = StackMetrics.CardWidth / 2;
        var output = new List<StackEdge>();
        if (geometry.Origin(tree.Root) is { } r)
        {
            var from = new StackPoint(r.X + half, StackMetrics.Pad + StackMetrics.PillHeight);
            output.Add(new StackEdge(from, new StackPoint(r.X + half, r.Y), StackEdgeKind.Line, 0, true, true, false));
        }
        foreach (var (parent, kids) in tree.Children)
        {
            if (geometry.Origin(parent) is not { } p || geometry.Bottom(parent) is not { } pb) continue;
            var from = new StackPoint(p.X + half, pb);
            var tops = new List<(int Number, StackPoint Top)>();
            foreach (var k in kids)
                if (geometry.Origin(k) is { } o) tops.Add((k, new StackPoint(o.X + half, o.Y)));
            if (tops.Count == 0) continue;
            var firstTop = tops.Min(t => t.Top.Y);
            var busY = pb + (firstTop - pb) / 2;
            var fan = tops.Count > FanOutAbove;
            foreach (var (k, top) in tops)
            {
                var lit = path.Contains(k) && path.Contains(parent);
                output.Add(new StackEdge(from, top, fan ? StackEdgeKind.Elbow : StackEdgeKind.Curve, busY, lit, lit || !fan, from.X > top.X + 1));
            }
        }
        return output;
    }

    public static double ElbowRadius(StackEdge e) =>
        Math.Max(0, Math.Min(Math.Min(18, Math.Abs(e.To.X - e.From.X) / 2), Math.Min(e.BusY - e.From.Y, e.To.Y - e.BusY)));
}
