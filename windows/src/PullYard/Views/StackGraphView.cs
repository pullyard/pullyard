using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PullYard.Controls;
using PullYard.Core.Claude;
using PullYard.Core.Stacks;
using PullYard.Services;
using Windows.Foundation;
using Windows.System;
using XPath = Microsoft.UI.Xaml.Shapes.Path;

namespace PullYard.Views;

public sealed class StackGraphView : Grid
{
    private static readonly Dictionary<string, double> Zooms = new();

    private readonly StackTab owner;
    private readonly Canvas edgeLayer = new() { IsHitTestVisible = false };
    private readonly XPath dimEdges = new() { StrokeThickness = 1.1, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly XPath litEdges = new() { StrokeThickness = 1.8, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly CompositeTransform dimTransform = new();
    private readonly CompositeTransform litTransform = new();
    private readonly Canvas content = new();
    private readonly CompositeTransform contentTransform = new();
    private readonly Dictionary<int, FrameworkElement> cards = new();
    private readonly List<FrameworkElement> labels = new();
    private readonly TextBlock zoomText = Ui.Text("100%", 12, "text");
    private readonly RectangleGeometry clip = new();
    private StackTree? tree;
    private StackGeometry? geometry;
    private IReadOnlyDictionary<int, ClaudeSessionInfo> sessions = new Dictionary<int, ClaudeSessionInfo>();
    private Func<int, string> noteKey = _ => "";
    private StackViewport vp = StackViewport.Identity;
    private bool placed;
    private bool compact;
    private bool labelsShown = true;
    private bool dimmedEdges;
    private Size size;
    private Point? pressAt;
    private Point lastDrag;
    private bool dragging;
    private bool dragged;
    private StackViewport animFrom;
    private StackViewport animTo;
    private DateTimeOffset animStart;
    private bool animating;

    public StackGraphView(StackTab owner)
    {
        this.owner = owner;
        Background = Palette.Brush("sunken");
        Clip = clip;
        dimEdges.StrokeDashArray = new DoubleCollection { 5 / 1.1, 4 / 1.1 };
        litEdges.Stroke = Palette.Brush("indigo");
        dimEdges.Stroke = Palette.Brush("dim");
        edgeLayer.Children.Add(dimEdges);
        edgeLayer.Children.Add(litEdges);
        Children.Add(edgeLayer);
        content.RenderTransform = contentTransform;
        TextZoom.Exclude(content);
        Children.Add(content);
        var controls = ZoomControls();
        controls.HorizontalAlignment = HorizontalAlignment.Right;
        controls.VerticalAlignment = VerticalAlignment.Bottom;
        controls.Margin = new Thickness(12);
        Children.Add(controls);

        ManipulationMode = ManipulationModes.TranslateX | ManipulationModes.TranslateY | ManipulationModes.Scale;
        ManipulationDelta += OnManipulation;
        PointerWheelChanged += OnWheel;
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        PointerCaptureLost += (_, _) => EndDrag();
        DoubleTapped += OnDoubleTapped;
        SizeChanged += (_, e) =>
        {
            size = e.NewSize;
            clip.Rect = new Rect(0, 0, size.Width, size.Height);
            Render();
        };
        Unloaded += (_, _) => StopAnimation();
    }

    private StackSize View => new(size.Width, size.Height);

    private string TreeKey => tree is null ? "" : $"{tree.Root}|{tree.Base}";

    public void Show(StackTree next, IReadOnlyDictionary<int, ClaudeSessionInfo> matched, Func<int, string> keyFor)
    {
        var previous = geometry;
        var moved = tree is null || tree.Current != next.Current || tree.Root != next.Root;
        tree = next;
        sessions = matched;
        noteKey = keyFor;
        var noted = next.Nodes.Keys.Where(n => StackNotes.Shared.HasNotes(keyFor(n))).ToHashSet();
        geometry = new StackGeometry(new Core.Stacks.StackLayout(next), noted);
        if (moved) placed = false;
        else if (previous is not null && geometry.Size != previous.Size) vp = vp.Clamped(geometry.Size, View);
        BuildEdges();
        BuildStatic();
        ClearCards();
        Render();
    }

    private void BuildEdges()
    {
        if (tree is null || geometry is null) return;
        var dim = new PathFigureCollection();
        var lit = new PathFigureCollection();
        foreach (var e in StackEdges.Build(tree, geometry))
            (e.Lit ? lit : dim).Add(Figure(e));
        if (dimEdges.Data is PathGeometry oldDim) oldDim.Transform = null;
        if (litEdges.Data is PathGeometry oldLit) oldLit.Transform = null;
        dimEdges.Data = new PathGeometry { Figures = dim, Transform = dimTransform };
        litEdges.Data = new PathGeometry { Figures = lit, Transform = litTransform };
    }

    private static PathFigure Figure(StackEdge e)
    {
        static Point P(double x, double y) => new(x, y);
        var f = new PathFigure { StartPoint = P(e.From.X, e.From.Y), IsClosed = false, IsFilled = false, Segments = new PathSegmentCollection() };
        switch (e.Kind)
        {
            case StackEdgeKind.Curve:
            {
                var midY = (e.From.Y + e.To.Y) / 2;
                f.Segments.Add(new BezierSegment { Point1 = P(e.From.X, midY), Point2 = P(e.To.X, midY), Point3 = P(e.To.X, e.To.Y) });
                break;
            }
            case StackEdgeKind.Elbow when Math.Abs(e.To.X - e.From.X) > 1:
            {
                var r = StackEdges.ElbowRadius(e);
                var sign = e.To.X > e.From.X ? 1 : -1;
                f.Segments.Add(new LineSegment { Point = P(e.From.X, e.BusY - r) });
                f.Segments.Add(new QuadraticBezierSegment { Point1 = P(e.From.X, e.BusY), Point2 = P(e.From.X + sign * r, e.BusY) });
                f.Segments.Add(new LineSegment { Point = P(e.To.X - sign * r, e.BusY) });
                f.Segments.Add(new QuadraticBezierSegment { Point1 = P(e.To.X, e.BusY), Point2 = P(e.To.X, e.BusY + r) });
                f.Segments.Add(new LineSegment { Point = P(e.To.X, e.To.Y) });
                break;
            }
            default:
                f.Segments.Add(new LineSegment { Point = P(e.To.X, e.To.Y) });
                break;
        }
        return f;
    }

    private void BuildStatic()
    {
        foreach (var l in labels) content.Children.Remove(l);
        labels.Clear();
        if (tree is null || geometry is null) return;
        if (geometry.Origin(tree.Root) is { } root)
        {
            var pill = new Border
            {
                Width = StackMetrics.PillWidth,
                Height = StackMetrics.PillHeight,
                CornerRadius = new CornerRadius(StackMetrics.PillHeight / 2),
                Background = Palette.Brush("raised"),
                BorderBrush = Palette.Brush("text", 0.16),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12, 0, 12, 0),
                Child = Ui.H(6, StackUi.Fixed("⎇", 13, "muted"), StackUi.Fixed(tree.Base, 13, "text", mono: true))
            };
            ((FrameworkElement)pill.Child).HorizontalAlignment = HorizontalAlignment.Center;
            Ui.Tip(pill, tree.Base);
            Canvas.SetLeft(pill, root.X + (StackMetrics.CardWidth - StackMetrics.PillWidth) / 2);
            Canvas.SetTop(pill, StackMetrics.Pad);
            labels.Add(pill);
            content.Children.Add(pill);
        }
        foreach (var e in StackEdges.Build(tree, geometry))
        {
            if (!e.Label) continue;
            var t = StackUi.Fixed(L.T("Stack_StackedOn", "stacked on"), 10, e.Lit ? "indigo" : "dim");
            t.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var w = t.DesiredSize.Width;
            var h = t.DesiredSize.Height;
            Canvas.SetLeft(t, e.FromRight ? e.To.X - 6 - w : e.To.X + 6);
            Canvas.SetTop(t, e.To.Y - 12 - h / 2);
            t.IsHitTestVisible = false;
            t.Tag = "label";
            t.Visibility = labelsShown ? Visibility.Visible : Visibility.Collapsed;
            labels.Add(t);
            content.Children.Add(t);
        }
    }

    private void ClearCards()
    {
        foreach (var c in cards.Values) content.Children.Remove(c);
        cards.Clear();
    }

    private void Render()
    {
        if (tree is null || geometry is null || size.Width <= 0 || size.Height <= 0) return;
        if (!placed)
        {
            placed = true;
            var zoom = Zooms.TryGetValue(TreeKey, out var z) ? z : 1;
            vp = geometry.Center(tree.Current) is { } c ? StackViewport.Centered(c, zoom, geometry.Size, View) : StackViewport.Identity.Clamped(geometry.Size, View);
        }
        vp = vp.Clamped(geometry.Size, View);
        foreach (var t in new[] { contentTransform, dimTransform, litTransform })
        {
            t.ScaleX = vp.Zoom;
            t.ScaleY = vp.Zoom;
            t.TranslateX = vp.PanX;
            t.TranslateY = vp.PanY;
        }
        var dimNow = vp.Zoom < StackMetrics.LabelsFrom;
        if (dimNow != dimmedEdges)
        {
            dimmedEdges = dimNow;
            dimEdges.Stroke = Palette.Brush(dimNow ? "muted" : "dim");
        }
        var showLabels = vp.Zoom >= StackMetrics.LabelsFrom;
        if (showLabels != labelsShown)
        {
            labelsShown = showLabels;
            foreach (var l in labels)
                if (l.Tag as string == "label") l.Visibility = showLabels ? Visibility.Visible : Visibility.Collapsed;
        }
        var nowCompact = vp.Zoom < StackMetrics.CompactBelow;
        if (nowCompact != compact)
        {
            compact = nowCompact;
            ClearCards();
        }
        var visible = geometry.Visible(tree.Nodes.Keys, vp, View);
        foreach (var n in cards.Keys.Where(n => !visible.Contains(n)).ToList())
        {
            content.Children.Remove(cards[n]);
            cards.Remove(n);
        }
        foreach (var n in visible)
        {
            if (cards.ContainsKey(n) || geometry.Origin(n) is not { } o || !tree.Nodes.TryGetValue(n, out var node)) continue;
            var card = compact ? CompactCard(node) : Card(node);
            Canvas.SetLeft(card, o.X);
            Canvas.SetTop(card, o.Y);
            cards[n] = card;
            content.Children.Add(card);
        }
        zoomText.Text = $"{Math.Round(vp.Zoom * 100)}%";
        Zooms[TreeKey] = vp.Zoom;
    }

    private void Set(StackViewport next, bool animated = false)
    {
        if (geometry is null) return;
        next = next.Clamped(geometry.Size, View);
        if (!animated || !Motion.Enabled)
        {
            StopAnimation();
            vp = next;
            Render();
            return;
        }
        animFrom = vp;
        animTo = next;
        animStart = DateTimeOffset.Now;
        if (animating) return;
        animating = true;
        CompositionTarget.Rendering += OnFrame;
    }

    private void OnFrame(object? sender, object e)
    {
        var t = Math.Min(1, (DateTimeOffset.Now - animStart).TotalMilliseconds / 220);
        var eased = 1 - Math.Pow(1 - t, 3);
        vp = animFrom.Lerp(animTo, eased);
        Render();
        if (t >= 1) StopAnimation();
    }

    private void StopAnimation()
    {
        if (!animating) return;
        animating = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private StackPoint Middle => new(size.Width / 2, size.Height / 2);

    public void Fit()
    {
        if (geometry is not null) Set(StackViewport.Fit(geometry.Size, View), true);
    }

    public void FocusCurrent()
    {
        if (tree is null || geometry?.Center(tree.Current) is not { } c) return;
        Set(StackViewport.Centered(c, Math.Max(vp.Zoom, 1), geometry.Size, View), true);
    }

    private void ZoomAt(double zoom, StackPoint at, bool animated = false)
    {
        if (geometry is null) return;
        Set(vp.Zoomed(zoom, at, geometry.Size, View), animated);
    }

    private void Pan(double dx, double dy)
    {
        if (geometry is null) return;
        StopAnimation();
        Set(vp.Panned(dx, dy, geometry.Size, View));
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        var delta = point.Properties.MouseWheelDelta;
        e.Handled = true;
        if (delta == 0) return;
        if (e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control))
        {
            StopAnimation();
            ZoomAt(vp.Zoom * Math.Pow(1.0015, delta), new StackPoint(point.Position.X, point.Position.Y));
        }
        else if (point.Properties.IsHorizontalMouseWheel) Pan(-delta * 0.8, 0);
        else if (e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift)) Pan(delta * 0.8, 0);
        else Pan(0, delta * 0.8);
    }

    private void OnManipulation(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        if (e.PointerDeviceType == PointerDeviceType.Mouse || geometry is null) return;
        StopAnimation();
        var next = vp.Panned(e.Delta.Translation.X, e.Delta.Translation.Y, geometry.Size, View);
        if (Math.Abs(e.Delta.Scale - 1) > 0.0001) next = next.Zoomed(next.Zoom * e.Delta.Scale, new StackPoint(e.Position.X, e.Position.Y), geometry.Size, View);
        vp = next;
        dragged = true;
        Render();
        e.Handled = true;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (e.Pointer.PointerDeviceType != PointerDeviceType.Mouse) return;
        var p = e.GetCurrentPoint(this);
        if (!p.Properties.IsLeftButtonPressed) return;
        pressAt = p.Position;
        lastDrag = p.Position;
        dragging = false;
        dragged = false;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (pressAt is not { } start) return;
        var p = e.GetCurrentPoint(this).Position;
        if (!dragging)
        {
            if (Math.Abs(p.X - start.X) < 4 && Math.Abs(p.Y - start.Y) < 4) return;
            dragging = true;
            dragged = true;
            CapturePointer(e.Pointer);
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeAll);
        }
        Pan(p.X - lastDrag.X, p.Y - lastDrag.Y);
        lastDrag = p;
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (dragging) ReleasePointerCapture(e.Pointer);
        EndDrag();
    }

    private void EndDrag()
    {
        pressAt = null;
        if (!dragging) return;
        dragging = false;
        ProtectedCursor = null;
    }

    private void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (geometry is null || e.OriginalSource is not DependencyObject source || IsInside(source, content) && source != content) return;
        var p = e.GetPosition(this);
        if (vp.Zoom < 0.95) ZoomAt(1, new StackPoint(p.X, p.Y), true);
        else Set(StackViewport.Fit(geometry.Size, View), true);
    }

    private bool IsInside(DependencyObject node, DependencyObject container)
    {
        for (var d = node; d is not null; d = VisualTreeHelper.GetParent(d))
        {
            if (d == container) return true;
            if (d == this) return false;
        }
        return false;
    }

    private static bool FromButton(object? source)
    {
        for (var d = source as DependencyObject; d is not null; d = VisualTreeHelper.GetParent(d))
        {
            if (d is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return true;
            if (d is Border { Tag: "card" }) return false;
        }
        return false;
    }

    private void Activate(int number)
    {
        if (dragged)
        {
            dragged = false;
            return;
        }
        owner.Open(number, false);
    }

    private FrameworkElement ZoomControls()
    {
        Button Icon(string glyph, string tip, Action action)
        {
            var b = Ui.IconButton(glyph, tip, action, "text");
            b.Padding = new Thickness(7, 4, 7, 4);
            return b;
        }
        var actual = new Button
        {
            Content = zoomText,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 2, 4, 2),
            MinWidth = 48
        };
        zoomText.TextAlignment = TextAlignment.Center;
        Ui.Tip(actual, L.T("Stack_ActualSize", "Actual size"));
        actual.Click += (_, _) => ZoomAt(1, Middle, true);
        var row = Ui.H(0,
            Icon("", L.T("Stack_ZoomOut", "Zoom out (Ctrl+wheel or pinch works too)"), () => ZoomAt(vp.Zoom - 0.15, Middle, true)),
            actual,
            Icon("", L.T("Stack_ZoomIn", "Zoom in"), () => ZoomAt(vp.Zoom + 0.15, Middle, true)),
            Icon("", L.T("Stack_Fit", "Fit to window"), () =>
            {
                if (geometry is not null) Set(StackViewport.Fit(geometry.Size, View), true);
            }),
            Icon("", L.T("Stack_ShowCurrent", "Show this pull request"), FocusCurrent));
        var border = new Border
        {
            Child = row,
            Padding = new Thickness(4, 2, 4, 2),
            CornerRadius = new CornerRadius(8),
            Background = Palette.Brush("raised"),
            BorderBrush = Palette.Brush("text", 0.16),
            BorderThickness = new Thickness(1)
        };
        border.PointerPressed += (_, e) => e.Handled = true;
        border.PointerWheelChanged += (_, e) => e.Handled = true;
        border.DoubleTapped += (_, e) => e.Handled = true;
        return border;
    }

    private FrameworkElement Card(StackNode node)
    {
        var current = node.Number == tree!.Current;
        var onPath = tree.OnPath(node.Number);
        var key = noteKey(node.Number);
        var noteCount = StackNotes.Shared.Count(key);
        var head = Ui.H(6, StackUi.Fixed($"#{node.Number}", 13, "text", FontWeights.SemiBold));
        if (node.JiraKey is { } jira) head.Children.Add(StackUi.Fixed(jira, 12, "muted", mono: true));
        var right = Ui.H(4, StackListRow.NoteButton(noteCount, () => owner.ShowNotes(node.Number), false), StackUi.StatusPill(node.Status, false));
        var top = Ui.Columns((head, Ui.Star), (right, Ui.Auto));
        top.ColumnSpacing = 4;
        var title = StackUi.Fixed(node.Title, 13, "text", FontWeights.SemiBold);
        title.Margin = new Thickness(0, 0, 0, 1);
        var stack = Ui.V(3, top, title, Field(L.T("Stack_Branch", "branch"), node.HeadRefName), Field(L.T("Stack_Base", "base"), node.BaseRefName));
        if (sessions.TryGetValue(node.Number, out var session))
        {
            var link = new HyperlinkButton { Content = StackUi.Fixed(session.Title, 12, "accent"), Padding = new Thickness(0), MinHeight = 0 };
            Ui.Tip(link, L.T("Stack_Resume", "Resume Claude Code session"));
            link.Click += (_, _) => owner.Resume(session);
            var label = StackUi.Fixed(L.T("Stack_Session", "session"), 12, "dim");
            label.Width = 48;
            stack.Children.Add(Ui.Columns((label, Ui.Auto), (link, Ui.Star)));
        }
        if (node.CommitOid is { } oid)
        {
            stack.Children.Add(new Border
            {
                Background = Palette.Brush("sunken"),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(6, 2, 6, 2),
                Margin = new Thickness(0, 1, 0, 0),
                Child = StackUi.Fixed($"› {oid} {node.CommitHeadline}", 11, "muted", mono: true)
            });
        }
        var card = new Border
        {
            Width = StackMetrics.CardWidth,
            Height = StackMetrics.CardHeight,
            Padding = new Thickness(10, 7, 10, 6),
            CornerRadius = new CornerRadius(10),
            Background = Palette.Brush("raised"),
            BorderBrush = current ? Palette.Brush("indigo") : Palette.Brush("text", 0.16),
            BorderThickness = new Thickness(current ? 2 : 1),
            Opacity = onPath ? 1 : 0.6,
            Child = stack
        };
        var author = node.Author is { } a ? $" · @{a}" : "";
        Ui.Tip(card, $"#{node.Number} {node.Title}{author} — " + (current ? L.T("Stack_ClickCenter", "click to center") : L.T("Stack_ClickOpen", "click to open")));
        card.Tag = "card";
        card.Tapped += (_, e) =>
        {
            e.Handled = true;
            if (!FromButton(e.OriginalSource)) Activate(node.Number);
        };
        card.ContextRequested += (_, e) =>
        {
            e.Handled = true;
            StackTab.CardMenu(owner, node, current, noteCount).ShowAt(card);
        };
        if (!geometry!.Noted.Contains(node.Number)) return card;
        var sticky = Sticky(StackNotes.Shared.Notes(key), node.Number);
        sticky.Opacity = onPath ? 1 : 0.75;
        var column = Ui.V(StackMetrics.NoteGap, card, sticky);
        column.Width = StackMetrics.CardWidth;
        return column;
    }

    private static FrameworkElement Field(string label, string value)
    {
        var l = StackUi.Fixed(label, 11.5, "dim");
        l.Width = 48;
        var v = StackUi.Fixed(value, 11.5, "text", mono: true);
        v.TextTrimming = TextTrimming.CharacterEllipsis;
        var row = Ui.Columns((l, Ui.Auto), (v, Ui.Star));
        row.ColumnSpacing = 6;
        return row;
    }

    private FrameworkElement Sticky(List<StackNote> notes, int number)
    {
        var sorted = notes.OrderByDescending(n => n.Updated).ToList();
        var header = Ui.Columns(
            (Ui.H(5, StackUi.FixedGlyph("", 11, "amber"), StackUi.Fixed(sorted.Count == 1 ? L.T("Notes_One", "1 note") : L.F("Notes_Many", "{0} notes", sorted.Count), 11, "amber", FontWeights.SemiBold)), Ui.Star),
            (StackUi.FixedGlyph("", 11, "muted"), Ui.Auto));
        var stack = Ui.V(3, header);
        foreach (var n in sorted.Take(2))
        {
            var color = n.Kind.ColorKey();
            var line = Ui.Columns(
                (new Border { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = Palette.Brush(color), VerticalAlignment = VerticalAlignment.Center }, Ui.Auto),
                (StackUi.Fixed(n.Kind.Title(), 11, color, FontWeights.SemiBold), Ui.Auto),
                (StackUi.Fixed(n.Text.Replace('\n', ' '), 12), Ui.Star));
            line.ColumnSpacing = 5;
            stack.Children.Add(line);
        }
        if (sorted.Count > 2) stack.Children.Add(StackUi.Fixed(L.F("Notes_More", "+{0} more", sorted.Count - 2), 11, "muted"));
        var border = new Border
        {
            Height = StackMetrics.NoteHeight,
            Padding = new Thickness(9, 6, 9, 6),
            CornerRadius = new CornerRadius(5),
            Background = Palette.Brush("amber", 0.16),
            BorderBrush = Palette.Brush("amber", 0.45),
            BorderThickness = new Thickness(1),
            Child = stack
        };
        Ui.Tip(border, L.T("Notes_ClickToEdit", "Click to read and edit all notes"));
        border.PointerEntered += (_, _) => border.Background = Palette.Brush("amber", 0.22);
        border.PointerExited += (_, _) => border.Background = Palette.Brush("amber", 0.16);
        border.Tapped += (_, e) =>
        {
            e.Handled = true;
            if (dragged)
            {
                dragged = false;
                return;
            }
            owner.ShowNotes(number);
        };
        return border;
    }

    private FrameworkElement CompactCard(StackNode node)
    {
        var current = node.Number == tree!.Current;
        var status = node.Status;
        var color = status.ColorKey();
        var head = Ui.H(10, StackUi.Fixed($"#{node.Number}", 40, "text", FontWeights.Bold));
        if (geometry!.Noted.Contains(node.Number)) head.Children.Add(StackUi.FixedGlyph("", 30, "amber"));
        var text = Ui.V(6, head, StackUi.Fixed(status.Title(), 26, color, FontWeights.SemiBold));
        text.Margin = new Thickness(20, 0, 20, 0);
        text.VerticalAlignment = VerticalAlignment.Center;
        var grid = Ui.Columns((new Border { Width = 14, Background = Palette.Brush(color) }, Ui.Auto), (text, Ui.Star));
        grid.ColumnSpacing = 0;
        var card = new Border
        {
            Width = StackMetrics.CardWidth,
            Height = StackMetrics.CardHeight,
            CornerRadius = new CornerRadius(12),
            Background = Palette.Brush("raised"),
            BorderBrush = current ? Palette.Brush("indigo") : Palette.Brush("text", 0.16),
            BorderThickness = new Thickness(current ? 8 : 3),
            Opacity = tree.OnPath(node.Number) ? 1 : 0.6,
            Child = grid
        };
        Ui.Tip(card, $"#{node.Number} {node.Title}");
        card.Tapped += (_, e) =>
        {
            e.Handled = true;
            Activate(node.Number);
        };
        return card;
    }
}
