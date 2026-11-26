using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PullYard.Controls;
using PullYard.Core;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace PullYard.Views;

public static class WelcomeTour
{
    public const string SeenKey = "ui.welcomeTourSeen";

    private static TourOverlay? current;

    public static bool Seen => Settings.Shared.GetBool(SeenKey, false);

    public static Task ShowIfNeeded(XamlRoot? root, Action onSetSail) => Seen ? Task.CompletedTask : Show(root, onSetSail);

    public static Task Show(XamlRoot? root, Action onSetSail)
    {
        if (current is not null) return current.Completion;
        if (root is null) return Task.CompletedTask;
        TourOverlay overlay;
        try
        {
            overlay = new TourOverlay(root, onSetSail);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "welcome tour build failed");
            return Task.CompletedTask;
        }
        current = overlay;
        Settings.Shared.Set(SeenKey, true);
        overlay.Open();
        return overlay.Completion;
    }

    private sealed class Tween
    {
        public object? Key;
        public double Start;
        public double Duration;
        public bool Repeat;
        public Func<double, double> Ease = t => t;
        public Action<double> Apply = _ => { };
        public Action? Done;
    }

    private sealed class TourOverlay : Grid
    {
        private const int Count = 5;
        private const double StageWidth = 928;
        private const double StageHeight = 380;
        private const double WaveStep = 10;

        private static readonly FontFamily Serif = new("Sitka Display, Sitka Text, Georgia");
        private static readonly Func<double, double> Linear = t => t;
        private static readonly Func<double, double> Brand = Curve(0.22, 1, 0.36, 1);
        private static readonly Func<double, double> EaseIn = Curve(0.42, 0, 1, 1);
        private static readonly Func<double, double> EaseOut = Curve(0, 0, 0.58, 1);

        private static readonly uint[][] Skies =
        {
            new uint[] { 0x0B1226, 0x1A2540, 0x2A2160 },
            new uint[] { 0x101A38, 0x3A2E7A, 0x1F5C8F },
            new uint[] { 0x15274F, 0x6B4CC2, 0x2A8BC8 },
            new uint[] { 0x182A52, 0x8A4FB0, 0x3C9AD0 },
            new uint[] { 0x1C2A55, 0xC2557A, 0xF07563 }
        };

        private static readonly (uint Color, double Alpha, double Top, double Speed, double Parallax)[] WaveLayers =
        {
            (0x1F7FB8, 0.35, 0.18, 0.9, 0.2),
            (0x0E3A5F, 0.75, 0.36, 1.25, 0.45),
            (0x081A2E, 0.95, 0.56, 1.7, 0.75)
        };

        private readonly XamlRoot root;
        private readonly Action onSetSail;
        private readonly Popup popup = new();
        private readonly TaskCompletionSource done = new();
        private readonly UIElement? previousFocus;
        private readonly bool motion = Motion.Enabled;
        private readonly bool contrast = ThemeService.IsHighContrast;
        private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        private readonly List<Tween> tweens = new();

        private readonly Canvas field = new() { IsHitTestVisible = false };
        private readonly GradientStop skyTop = new() { Offset = 0 };
        private readonly GradientStop skyMiddle = new() { Offset = 0.5 };
        private readonly GradientStop skyBottom = new() { Offset = 1 };
        private readonly GradientStop glowInner = new() { Offset = 0 };
        private readonly GradientStop glowOuter = new() { Offset = 1 };
        private readonly Ellipse glow = new();
        private readonly Canvas starLayer = new();
        private readonly Canvas shootLayer = new();
        private readonly Canvas glintLayer = new();
        private readonly Canvas wakeLayer = new();
        private readonly List<(Rectangle Shape, double X, double Y, double Radius, double Speed, double Seed)> stars = new();
        private readonly List<(Line Trail, GradientStop Head, Ellipse Spark)> shooting = new();
        private readonly List<(Rectangle Shape, double X, double Y, double Speed, double Seed)> glints = new();
        private readonly PathFigure[] waveFigures = { new() { IsClosed = true, IsFilled = true }, new() { IsClosed = true, IsFilled = true }, new() { IsClosed = true, IsFilled = true } };
        private readonly List<LineSegment>[] waveSegments = { new(), new(), new() };
        private readonly List<(PathFigure Figure, BezierSegment Curve, bool Upper)> wakes = new();
        private readonly Ellipse wakeTip = new() { Width = 10, Height = 10, Fill = new SolidColorBrush(Color.FromArgb(178, 255, 255, 255)) };
        private readonly Canvas ship = new() { Width = 110, Height = 84 };
        private readonly RotateTransform shipTurn = new() { CenterX = 55, CenterY = 42 };
        private readonly TranslateTransform shipMove = new();
        private readonly List<Ellipse> puffs = new();

        private readonly Grid chrome = new();
        private readonly Grid stage = new() { Width = StageWidth, Height = StageHeight };
        private readonly Viewbox viewbox = new() { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        private readonly Button skip = new();
        private readonly Button back = new();
        private readonly Button primary = new();
        private readonly TextBlock primaryLabel = new() { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        private readonly SolidColorBrush primaryFill = new(Palette.Hex(0x2A8BC8));
        private readonly SolidColorBrush primaryHover = new(Palette.Hex(0x3496D4));
        private readonly SolidColorBrush primaryPressed = new(Palette.Hex(0x2479AE));
        private readonly Border ring = new() { CornerRadius = new CornerRadius(21), BorderThickness = new Thickness(2), IsHitTestVisible = false, Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
        private readonly ScaleTransform ringScale = new();
        private readonly List<(Button Button, Border Pill)> dots = new();
        private readonly Brush dotOn;
        private readonly Brush dotOff;

        private IDisposable? modal;
        private FrameworkElement? currentPage;
        private TranslateTransform? sceneFloat;
        private int page = -1;
        private double progress;
        private double leave;
        private double streak;
        private double width;
        private double height;
        private double lastAmbient = -1;
        private bool leaving;
        private bool opened;
        private bool closed;
        private bool looping;
        private bool dirty = true;
        private bool layoutDirty = true;
        private bool hostVisible = true;

        public Task Completion => done.Task;

        private bool Ambient => motion && !contrast;

        private double Now => clock.Elapsed.TotalSeconds;

        private bool NeedsLoop => opened && !closed && hostVisible && (Ambient || tweens.Count > 0 || (dirty && !contrast));

        public TourOverlay(XamlRoot root, Action onSetSail)
        {
            this.root = root;
            this.onSetSail = onSetSail;
            previousFocus = FocusManager.GetFocusedElement(root) as UIElement;
            dotOn = contrast ? Palette.Brush("text") : Ink(0.95);
            dotOff = contrast ? Palette.Brush("dim") : Ink(0.3);
            Background = contrast ? Palette.Brush("window") : new SolidColorBrush(Palette.Hex(0x0B1226));
            RequestedTheme = contrast ? (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default : ElementTheme.Dark;
            TabFocusNavigation = KeyboardNavigationMode.Cycle;
            AutomationProperties.SetName(this, L.F("WelcomeTour_Name", "Welcome to {0}", AppInfo.DisplayName));
            if (!contrast) Children.Add(BuildBackdrop());
            Children.Add(BuildChrome());
            PreviewKeyDown += OnKey;
            Loaded += OnLoaded;
            ShowPage(0, true, true);
        }

        public void Open()
        {
            opened = true;
            modal = DiagnosticsService.Modal();
            Resize();
            root.Changed += OnRootChanged;
            popup.XamlRoot = root;
            popup.Child = this;
            popup.Closed += (_, _) => Close();
            popup.IsOpen = true;
            Opacity = 0;
            Animate(motion ? 0.35 : 0.15, EaseOut, e => Opacity = e, force: true);
            dirty = true;
            EnsureLoop();
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            Loaded -= OnLoaded;
            primary.Focus(FocusState.Programmatic);
            Announce();
        }

        private void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Resize();

        private void Resize()
        {
            if (closed) return;
            hostVisible = root.IsHostVisible;
            var w = root.Size.Width;
            var h = root.Size.Height;
            if (w > 0 && h > 0 && (Math.Abs(w - width) > 0.5 || Math.Abs(h - height) > 0.5))
            {
                width = w;
                height = h;
                Width = w;
                Height = h;
                field.Width = w;
                field.Height = h;
                field.Clip = new RectangleGeometry { Rect = new Rect(0, 0, w, h) };
                viewbox.Margin = new Thickness(64, 64, 64, Math.Max(150, h * 0.3 + 8));
                glow.Width = w * 1.1;
                glow.Height = h * 0.95;
                if (!contrast) BuildWaves();
                layoutDirty = true;
                dirty = true;
            }
            if (hostVisible) EnsureLoop();
            else StopLoop();
        }

        private void Close()
        {
            if (closed) return;
            closed = true;
            StopLoop();
            tweens.Clear();
            root.Changed -= OnRootChanged;
            PreviewKeyDown -= OnKey;
            if (popup.IsOpen) popup.IsOpen = false;
            popup.Child = null;
            modal?.Dispose();
            modal = null;
            if (current == this) current = null;
            try
            {
                previousFocus?.Focus(FocusState.Programmatic);
            }
            catch
            {
            }
            done.TrySetResult();
        }

        private void Finish(bool sail)
        {
            if (leaving || closed) return;
            leaving = true;
            chrome.IsHitTestVisible = false;
            Cancel("ring");
            Cancel("dot");
            if (sail && Ambient)
            {
                Animate(1.0, EaseIn, e => chrome.Opacity = 1 - e);
                Animate(0.8, EaseIn, e =>
                {
                    streak = e;
                    layoutDirty = true;
                });
                Animate(1.0, EaseIn, e => leave = e);
                Animate(0.35, EaseOut, e => Opacity = 1 - e, () => Complete(true), 0.9, true);
                return;
            }
            Animate(motion ? 0.3 : 0.2, EaseOut, e => Opacity = 1 - e, () => Complete(sail), force: true);
        }

        private void Complete(bool sail)
        {
            Close();
            if (!sail) return;
            try
            {
                onSetSail();
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "welcome tour set sail failed");
            }
        }

        private void Advance()
        {
            if (page < Count - 1) Go(page + 1);
            else Finish(true);
        }

        private void OnKey(object sender, KeyRoutedEventArgs e)
        {
            if (closed) return;
            if (leaving)
            {
                e.Handled = true;
                return;
            }
            var alt = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            switch (e.Key)
            {
                case VirtualKey.Escape:
                    e.Handled = true;
                    Finish(false);
                    return;
                case VirtualKey.Left when !alt:
                    e.Handled = true;
                    Go(page - 1);
                    return;
                case VirtualKey.Right when !alt:
                    e.Handled = true;
                    Go(page + 1);
                    return;
                case VirtualKey.Enter:
                    if (FocusManager.GetFocusedElement(root) is Button focused && !ReferenceEquals(focused, primary)) return;
                    e.Handled = true;
                    Advance();
                    return;
                case VirtualKey.Tab:
                case VirtualKey.Space:
                case VirtualKey.Menu:
                case VirtualKey.Shift:
                case VirtualKey.Control:
                    return;
                case VirtualKey.F4 when alt:
                    return;
            }
            e.Handled = true;
        }

        private void Go(int index)
        {
            var target = Math.Clamp(index, 0, Count - 1);
            if (leaving || closed || target == page) return;
            ShowPage(target, target > page, false);
        }

        private void ShowPage(int target, bool forward, bool initial)
        {
            page = target;
            Cancel("dot");
            var previous = currentPage;
            var (view, shift, scene) = BuildPage(target);
            currentPage = view;
            sceneFloat = scene;
            stage.Children.Add(view);
            var dx = motion && !initial ? (forward ? 70.0 : -70.0) : 0;
            if (previous is { RenderTransform: TranslateTransform oldShift } old)
            {
                Cancel(old);
                old.IsHitTestVisible = false;
                var startOpacity = old.Opacity;
                var startX = oldShift.X;
                Animate(motion ? 0.45 : 0.15, motion ? Brand : EaseOut, e =>
                {
                    old.Opacity = startOpacity * (1 - e);
                    oldShift.X = startX + (-dx - startX) * e;
                }, () => stage.Children.Remove(old), force: true, key: old);
            }
            if (!initial)
            {
                view.Opacity = 0;
                shift.X = dx;
                Animate(motion ? 0.6 : 0.15, motion ? Brand : EaseOut, e =>
                {
                    view.Opacity = e;
                    shift.X = dx * (1 - e);
                }, force: true, key: view);
            }
            var from = progress;
            Animate(0.6, Brand, e =>
            {
                progress = from + (target - from) * e;
                dirty = true;
            }, key: "progress");
            dirty = true;
            EnsureLoop();
            UpdateControls();
            if (!initial) Announce();
        }

        private void UpdateControls()
        {
            var last = page == Count - 1;
            var focused = FocusManager.GetFocusedElement(root);
            back.Opacity = page > 0 ? 1 : 0;
            back.IsHitTestVisible = page > 0;
            back.IsTabStop = page > 0;
            skip.Visibility = last ? Visibility.Collapsed : Visibility.Visible;
            if ((page == 0 && ReferenceEquals(focused, back)) || (last && ReferenceEquals(focused, skip))) primary.Focus(FocusState.Programmatic);
            var label = last ? L.T("WelcomeTour_SetSail", "Set sail") : L.T("WelcomeTour_Next", "Next");
            primaryLabel.Text = label;
            AutomationProperties.SetName(primary, label);
            primary.Padding = new Thickness(last ? 34 : 28, 0, last ? 34 : 28, 0);
            if (!contrast)
            {
                primaryFill.Color = Palette.Hex(last ? 0xC24533u : 0x2A8BC8u);
                primaryHover.Color = Palette.Hex(last ? 0xD0503Du : 0x3496D4u);
                primaryPressed.Color = Palette.Hex(last ? 0xA93B2Bu : 0x2479AEu);
            }
            for (var i = 0; i < dots.Count; i++)
            {
                var pill = dots[i].Pill;
                var on = i == page;
                pill.Background = on ? dotOn : dotOff;
                AutomationProperties.SetItemStatus(dots[i].Button, on ? L.T("WelcomeTour_CurrentPage", "Current page") : "");
                var fromWidth = pill.Width;
                var toWidth = on ? 22.0 : 7.0;
                if (Math.Abs(fromWidth - toWidth) < 0.1) continue;
                Animate(0.4, Brand, e => pill.Width = fromWidth + (toWidth - fromWidth) * e, key: pill);
            }
            if (last && Ambient)
            {
                Animate(1.4, EaseOut, e =>
                {
                    ringScale.ScaleX = 1 + 0.35 * e;
                    ringScale.ScaleY = 1 + 0.35 * e;
                    ring.Opacity = 0.8 * (1 - e);
                }, key: "ring", repeat: true);
            }
            else
            {
                Cancel("ring");
                ring.Opacity = 0;
            }
        }

        private void Announce()
        {
            if (page < 0) return;
            try
            {
                var text = L.F("WelcomeTour_PageAnnounce", "Page {0} of {1}. {2}. {3}", page + 1, Count, Title(page).Replace('\n', ' '), Subtitle(page));
                var peer = FrameworkElementAutomationPeer.FromElement(primary) ?? FrameworkElementAutomationPeer.CreatePeerForElement(primary);
                peer?.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "welcome-tour-page");
            }
            catch
            {
            }
        }

        private Grid BuildChrome()
        {
            viewbox.Child = stage;
            chrome.Children.Add(viewbox);

            skip.Content = Label(L.T("WelcomeTour_Skip", "Skip"), 14, Ink(0.85), FontWeights.SemiBold);
            skip.Padding = new Thickness(16, 7, 16, 7);
            skip.CornerRadius = new CornerRadius(16);
            skip.HorizontalAlignment = HorizontalAlignment.Right;
            skip.VerticalAlignment = VerticalAlignment.Top;
            skip.Margin = new Thickness(0, 56, 24, 0);
            AutomationProperties.SetName(skip, L.T("WelcomeTour_Skip", "Skip"));
            AutomationProperties.SetAcceleratorKey(skip, "Escape");
            Soft(skip);
            skip.Click += (_, _) => Finish(false);
            chrome.Children.Add(skip);

            back.Content = Icon("", 13, Ink(0.85));
            back.Width = 40;
            back.Height = 40;
            back.Padding = new Thickness(0);
            back.MinWidth = 0;
            back.MinHeight = 0;
            back.CornerRadius = new CornerRadius(20);
            back.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(back, L.T("WelcomeTour_Back", "Back"));
            Soft(back);
            back.Click += (_, _) => Go(page - 1);

            var dotsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            for (var i = 0; i < Count; i++)
            {
                var index = i;
                var pill = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = dotOff, VerticalAlignment = VerticalAlignment.Center };
                var b = new Button { Content = pill, Padding = new Thickness(3, 8, 3, 8), MinWidth = 0, MinHeight = 0, CornerRadius = new CornerRadius(8) };
                Clear(b);
                AutomationProperties.SetName(b, L.F("WelcomeTour_Page", "Page {0}", i + 1));
                b.Click += (_, _) => Go(index);
                dots.Add((b, pill));
                dotsPanel.Children.Add(b);
            }

            TextZoom.Track(primaryLabel, 15);
            primary.Content = primaryLabel;
            primary.Height = 42;
            primary.MinWidth = 0;
            primary.MinHeight = 0;
            primary.CornerRadius = new CornerRadius(21);
            primary.Padding = new Thickness(28, 0, 28, 0);
            primary.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetAcceleratorKey(primary, "Enter");
            if (contrast) primary.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            else Paint(primary, primaryFill, primaryHover, primaryPressed, Ink());
            primary.Click += (_, _) => Advance();
            ring.BorderBrush = new SolidColorBrush(Palette.Hex(0xF8A59A));
            ring.RenderTransform = ringScale;
            var primaryHost = new Grid { VerticalAlignment = VerticalAlignment.Center };
            primaryHost.Children.Add(ring);
            primaryHost.Children.Add(primary);

            var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 36) };
            bar.Children.Add(back);
            bar.Children.Add(dotsPanel);
            bar.Children.Add(primaryHost);
            chrome.Children.Add(bar);
            return chrome;
        }

        private void Paint(Button b, Brush fill, Brush hover, Brush pressed, Brush text)
        {
            var none = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            b.Background = fill;
            b.Foreground = text;
            b.BorderBrush = none;
            b.BorderThickness = new Thickness(0);
            b.Resources["ButtonBackground"] = fill;
            b.Resources["ButtonBackgroundPointerOver"] = hover;
            b.Resources["ButtonBackgroundPressed"] = pressed;
            b.Resources["ButtonForeground"] = text;
            b.Resources["ButtonForegroundPointerOver"] = text;
            b.Resources["ButtonForegroundPressed"] = text;
            b.Resources["ButtonBorderBrush"] = none;
            b.Resources["ButtonBorderBrushPointerOver"] = none;
            b.Resources["ButtonBorderBrushPressed"] = none;
        }

        private void Soft(Button b)
        {
            if (contrast) return;
            Paint(b, Ink(0.12), Ink(0.2), Ink(0.08), Ink(0.85));
        }

        private void Clear(Button b)
        {
            if (contrast) return;
            Paint(b, new SolidColorBrush(Microsoft.UI.Colors.Transparent), Ink(0.08), Ink(0.04), Ink());
        }

        private Grid BuildBackdrop()
        {
            var host = new Grid { IsHitTestVisible = false };
            AutomationProperties.SetAccessibilityView(host, AccessibilityView.Raw);
            var sky = new LinearGradientBrush { StartPoint = new Point(0.3, 0), EndPoint = new Point(0.7, 1) };
            sky.GradientStops.Add(skyTop);
            sky.GradientStops.Add(skyMiddle);
            sky.GradientStops.Add(skyBottom);
            host.Children.Add(new Rectangle { Fill = sky });

            var glowBrush = new RadialGradientBrush();
            glowBrush.GradientStops.Add(glowInner);
            glowBrush.GradientStops.Add(glowOuter);
            glow.Fill = glowBrush;
            field.Children.Add(glow);

            var white = new SolidColorBrush(Microsoft.UI.Colors.White);
            for (var i = 0; i < 110; i++)
            {
                var seed = i * 12.9898;
                var radius = 0.6 + Fract(Math.Sin(seed * 3.1) * 9813.13) * 1.6;
                var star = new Rectangle { Fill = white, Width = radius, Height = radius, RadiusX = radius / 2, RadiusY = radius / 2 };
                stars.Add((star, Fract(Math.Sin(seed) * 43758.5453), Fract(Math.Sin(seed * 1.7) * 23421.631) * 0.6, radius, 0.8 + Fract(seed) * 2.2, seed));
                starLayer.Children.Add(star);
            }
            field.Children.Add(starLayer);

            for (var lane = 0; lane < 3; lane++)
            {
                var head = new GradientStop { Offset = 1, Color = Color.FromArgb(0, 255, 255, 255) };
                var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
                brush.GradientStops.Add(new GradientStop { Offset = 0, Color = Color.FromArgb(0, 255, 255, 255) });
                brush.GradientStops.Add(head);
                var trail = new Line { Stroke = brush, StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Visibility = Visibility.Collapsed };
                var spark = new Ellipse { Width = 3.6, Height = 3.6, Fill = white, Visibility = Visibility.Collapsed };
                shooting.Add((trail, head, spark));
                shootLayer.Children.Add(trail);
                shootLayer.Children.Add(spark);
            }
            field.Children.Add(shootLayer);

            for (var l = 0; l < WaveLayers.Length; l++)
            {
                var geometry = new PathGeometry();
                geometry.Figures.Add(waveFigures[l]);
                field.Children.Add(new Path { Data = geometry, Fill = new SolidColorBrush(Palette.Hex(WaveLayers[l].Color, (byte)Math.Round(255 * WaveLayers[l].Alpha))) });
            }

            var glint = new SolidColorBrush(Palette.Hex(0xBFE0FF));
            for (var i = 0; i < 26; i++)
            {
                var seed = i * 7.31;
                var shape = new Rectangle { Fill = glint, Height = 1.4, Width = 4, RadiusX = 0.7, RadiusY = 0.7, Opacity = 0 };
                glints.Add((shape, Fract(Math.Sin(seed) * 43758.5453), 0.24 + Fract(Math.Sin(seed * 1.9) * 2731.3) * 0.5, 1.1 + Fract(seed) * 1.6, seed));
                glintLayer.Children.Add(shape);
            }
            field.Children.Add(glintLayer);

            foreach (var upper in new[] { true, false })
            {
                var color = upper ? LogoArt.Violet : LogoArt.Sky;
                foreach (var (thickness, alpha) in new[] { (22.0, 0.07), (10.0, 0.18), (3.0, 0.85) })
                {
                    var curve = new BezierSegment();
                    var figure = new PathFigure { IsFilled = false };
                    figure.Segments.Add(curve);
                    var geometry = new PathGeometry();
                    geometry.Figures.Add(figure);
                    wakeLayer.Children.Add(new Path
                    {
                        Data = geometry,
                        Stroke = new SolidColorBrush(LogoArt.Alpha(color, alpha)),
                        StrokeThickness = thickness,
                        StrokeStartLineCap = PenLineCap.Round,
                        StrokeEndLineCap = PenLineCap.Round
                    });
                    wakes.Add((figure, curve, upper));
                }
            }
            wakeLayer.Children.Add(wakeTip);
            field.Children.Add(wakeLayer);

            BuildShip();
            var turn = new TransformGroup();
            turn.Children.Add(shipTurn);
            turn.Children.Add(shipMove);
            ship.RenderTransform = turn;
            field.Children.Add(ship);

            host.Children.Add(field);
            return host;
        }

        private void BuildShip()
        {
            const double w = 110;
            const double h = 84;
            var halo = new RadialGradientBrush();
            halo.GradientStops.Add(new GradientStop { Offset = 0, Color = Palette.Hex(0xF07563, 115) });
            halo.GradientStops.Add(new GradientStop { Offset = 1, Color = Palette.Hex(0xF07563, 0) });
            var shadow = new Ellipse { Width = 150, Height = 56, Fill = halo };
            Canvas.SetLeft(shadow, -20);
            Canvas.SetTop(shadow, 46);
            ship.Children.Add(shadow);
            for (var i = 0; i < 4; i++)
            {
                var puff = new Ellipse { Fill = new SolidColorBrush(Microsoft.UI.Colors.White), Width = 5, Height = 5, Opacity = 0 };
                puffs.Add(puff);
                ship.Children.Add(puff);
            }
            var hull = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
            hull.GradientStops.Add(new GradientStop { Offset = 0, Color = LogoArt.HullTop });
            hull.GradientStops.Add(new GradientStop { Offset = 1, Color = LogoArt.HullBottom });
            ship.Children.Add(new Path { Data = LogoArt.Polygon(true, new Point(0, h * 0.52), new Point(w, h * 0.52), new Point(w * 0.83, h * 0.95), new Point(w * 0.18, h * 0.95)), Fill = hull });
            ship.Children.Add(LogoArt.Rect(0, h * 0.52, w, h * 0.06, 0, LogoArt.Deck));
            var porthole = new Ellipse { Width = w * 0.08, Height = w * 0.08, Fill = new SolidColorBrush(LogoArt.Deck) };
            Canvas.SetLeft(porthole, w * 0.72);
            Canvas.SetTop(porthole, h * 0.66);
            ship.Children.Add(porthole);
            ship.Children.Add(LogoArt.Rect(w * 0.6, h * 0.05, w * 0.1, h * 0.3, 3, LogoArt.CabinShade));
            ship.Children.Add(LogoArt.Rect(w * 0.6, h * 0.05, w * 0.1, h * 0.07, 2, LogoArt.HullTop));
            ship.Children.Add(LogoArt.Rect(w * 0.29, h * 0.24, w * 0.46, h * 0.3, 5, LogoArt.Cabin));
            ship.Children.Add(LogoArt.Rect(w * 0.36, h * 0.31, w * 0.1, h * 0.1, 2, LogoArt.Window));
            ship.Children.Add(LogoArt.Rect(w * 0.5, h * 0.31, w * 0.1, h * 0.1, 2, LogoArt.Window));
        }

        private void BuildWaves()
        {
            var seaTop = height * 0.7;
            var seaHeight = height * 0.3;
            var count = (int)Math.Ceiling((width + 8) / WaveStep) + 1;
            for (var l = 0; l < WaveLayers.Length; l++)
            {
                var figure = waveFigures[l];
                var list = waveSegments[l];
                var baseline = seaTop + seaHeight * WaveLayers[l].Top;
                figure.Segments.Clear();
                list.Clear();
                figure.StartPoint = new Point(0, height);
                figure.Segments.Add(new LineSegment { Point = new Point(0, baseline) });
                for (var i = 0; i < count; i++)
                {
                    var segment = new LineSegment { Point = new Point(i * WaveStep, baseline) };
                    list.Add(segment);
                    figure.Segments.Add(segment);
                }
                figure.Segments.Add(new LineSegment { Point = new Point((count - 1) * WaveStep, height) });
            }
        }

        private void EnsureLoop()
        {
            if (looping || !NeedsLoop) return;
            looping = true;
            CompositionTarget.Rendering += OnFrame;
        }

        private void StopLoop()
        {
            if (!looping) return;
            looping = false;
            CompositionTarget.Rendering -= OnFrame;
        }

        private void OnFrame(object? sender, object e)
        {
            if (closed)
            {
                StopLoop();
                return;
            }
            var now = Now;
            Step(now);
            if (closed) return;
            if (!contrast && (Ambient || dirty) && width > 0 && height > 0)
            {
                try
                {
                    Render(now);
                }
                catch (Exception error)
                {
                    ErrorLog.Write(error, "welcome tour frame failed");
                    StopLoop();
                    return;
                }
            }
            dirty = false;
            if (!NeedsLoop) StopLoop();
        }

        private void Step(double now)
        {
            if (tweens.Count == 0) return;
            foreach (var tween in tweens.ToArray())
            {
                if (closed) return;
                if (!tweens.Contains(tween) || now < tween.Start) continue;
                try
                {
                    var t = tween.Duration <= 0 ? 1 : (now - tween.Start) / tween.Duration;
                    if (tween.Repeat)
                    {
                        tween.Apply(tween.Ease(t - Math.Floor(t)));
                        continue;
                    }
                    t = Math.Min(1, t);
                    tween.Apply(tween.Ease(t));
                    if (t < 1) continue;
                    tweens.Remove(tween);
                    tween.Done?.Invoke();
                }
                catch (Exception error)
                {
                    tweens.Remove(tween);
                    ErrorLog.Write(error, "welcome tour animation failed");
                }
            }
        }

        private void Animate(double duration, Func<double, double> ease, Action<double> apply, Action? done = null, double delay = 0, bool force = false, object? key = null, bool repeat = false)
        {
            if (closed) return;
            if (key is not null) Cancel(key);
            if (!motion && !force)
            {
                if (!repeat) apply(1);
                done?.Invoke();
                return;
            }
            tweens.Add(new Tween { Key = key, Start = Now + delay, Duration = duration, Ease = ease, Apply = apply, Done = done, Repeat = repeat });
            EnsureLoop();
        }

        private void After(double delay, Action action) => Animate(0, Linear, _ => { }, action, delay);

        private void Cancel(object key) => tweens.RemoveAll(t => Equals(t.Key, key));

        private void Render(double now)
        {
            var time = Ambient ? now : 1.3;
            var full = !Ambient || layoutDirty || now - lastAmbient >= 1 / 30.0;
            UpdateSky(time);
            UpdateShip(time);
            UpdateShooting(time);
            if (sceneFloat is not null) sceneFloat.Y = Ambient ? Math.Sin(time * Math.PI / 3.2) * 6 : 0;
            if (!full) return;
            lastAmbient = now;
            UpdateStars(time);
            UpdateWaves(time);
            UpdateGlints(time);
            layoutDirty = false;
        }

        private void UpdateSky(double time)
        {
            var clamped = Math.Clamp(progress, 0, Skies.Length - 1);
            var lower = (int)Math.Floor(clamped);
            var upper = Math.Min(Skies.Length - 1, lower + 1);
            var t = clamped - lower;
            var a = Mix(Skies[lower][0], Skies[upper][0], t);
            var b = Mix(Skies[lower][1], Skies[upper][1], t);
            var c = Mix(Skies[lower][2], Skies[upper][2], t);
            skyTop.Color = a;
            skyMiddle.Color = b;
            skyBottom.Color = a;
            glowInner.Color = Color.FromArgb(230, c.R, c.G, c.B);
            glowOuter.Color = Color.FromArgb(0, c.R, c.G, c.B);
            var drift = Math.Sin(time * 0.3) * 0.08;
            Canvas.SetLeft(glow, width * (0.5 + drift) - glow.Width / 2);
            Canvas.SetTop(glow, height * (0.45 - drift) - glow.Height / 2);
            starLayer.Opacity = Math.Max(0, 1 - progress * 0.3);
            shootLayer.Opacity = Math.Max(0, 1 - progress * 0.2);
        }

        private void UpdateShip(double time)
        {
            var travel = Math.Min(1, progress / 4);
            var baseX = width * (0.12 + 0.7 * travel);
            var x = baseX + (width * 1.3 - baseX) * leave;
            var y = height * 0.73 + (Ambient ? Math.Sin(time * 1.6) * 4 : 0);
            shipMove.X = x - 55;
            shipMove.Y = y - 42;
            shipTurn.Angle = Ambient ? Math.Sin(time * 1.4) * 2 : 0;
            for (var i = 0; i < puffs.Count; i++)
            {
                var age = Fract(time * 0.35 + i * 0.25);
                var radius = 5 + age * 10;
                var puff = puffs[i];
                puff.Width = radius;
                puff.Height = radius;
                Canvas.SetLeft(puff, 110 * 0.66 + age * 14 - radius / 2);
                Canvas.SetTop(puff, 84 * 0.04 - age * 26 + 18 - radius / 2);
                puff.Opacity = (1 - age) * 0.35;
            }
            var tip = new Point(x - 48, y + 22);
            wakeLayer.Opacity = x > 60 ? 1 : 0;
            foreach (var (figure, curve, upperBranch) in wakes)
            {
                var start = new Point(-20, upperBranch ? tip.Y - height * 0.08 : tip.Y + height * 0.06);
                figure.StartPoint = start;
                curve.Point1 = new Point(start.X + (tip.X - start.X) * 0.55, start.Y);
                curve.Point2 = new Point(start.X + (tip.X - start.X) * 0.45, tip.Y);
                curve.Point3 = tip;
            }
            Canvas.SetLeft(wakeTip, tip.X - 5);
            Canvas.SetTop(wakeTip, tip.Y - 5);
        }

        private void UpdateShooting(double time)
        {
            for (var lane = 0; lane < shooting.Count; lane++)
            {
                var (trail, head, spark) = shooting[lane];
                var period = 5.5 + lane * 2.3;
                var shifted = time + lane * 1.9;
                var local = shifted % period;
                const double flight = 0.9;
                if (!Ambient || leaving || local >= flight)
                {
                    trail.Visibility = Visibility.Collapsed;
                    spark.Visibility = Visibility.Collapsed;
                    continue;
                }
                var t = local / flight;
                var cycle = (int)Math.Floor(shifted / period);
                var seed = (cycle * 7 + lane * 13) * 1.618;
                var startX = (0.15 + Fract(Math.Sin(seed) * 43758.5453) * 0.7) * width;
                var startY = (0.04 + Fract(Math.Sin(seed * 2.3) * 9731.17) * 0.28) * height;
                var travel = width * 0.22;
                var hx = startX + travel * t;
                var hy = startY + travel * 0.42 * t;
                var tx = hx - 90 * (1 - t * 0.4);
                var ty = hy - 38 * (1 - t * 0.4);
                var fade = Math.Sin(t * Math.PI);
                trail.X1 = tx;
                trail.Y1 = ty;
                trail.X2 = hx;
                trail.Y2 = hy;
                head.Color = Color.FromArgb((byte)Math.Round(255 * 0.9 * fade), 255, 255, 255);
                Canvas.SetLeft(spark, hx - 1.8);
                Canvas.SetTop(spark, hy - 1.8);
                spark.Opacity = fade;
                trail.Visibility = Visibility.Visible;
                spark.Visibility = Visibility.Visible;
            }
        }

        private void UpdateStars(double time)
        {
            var place = layoutDirty || streak > 0;
            foreach (var (shape, fx, fy, radius, speed, seed) in stars)
            {
                if (place)
                {
                    var length = radius + (radius * 26 - radius) * streak;
                    shape.Width = length;
                    Canvas.SetLeft(shape, fx * width - length + radius);
                    Canvas.SetTop(shape, fy * height);
                }
                shape.Opacity = (0.35 + 0.65 * (0.5 + 0.5 * Math.Sin(time * speed + seed))) * 0.85;
            }
        }

        private void UpdateWaves(double time)
        {
            var seaTop = height * 0.7;
            var seaHeight = height * 0.3;
            for (var l = 0; l < WaveLayers.Length; l++)
            {
                var layer = WaveLayers[l];
                var baseline = seaTop + seaHeight * layer.Top;
                var list = waveSegments[l];
                for (var i = 0; i < list.Count; i++)
                {
                    var x = i * WaveStep;
                    var phase = x / 80 + time * layer.Speed - progress * 2.4 * layer.Parallax;
                    list[i].Point = new Point(x, baseline + Math.Sin(phase) * 7 + Math.Sin(phase * 0.43 + 1.3) * 4);
                }
            }
        }

        private void UpdateGlints(double time)
        {
            var seaTop = height * 0.7;
            var seaHeight = height * 0.3;
            foreach (var (shape, fx, fy, speed, seed) in glints)
            {
                var pulse = Math.Max(0, Math.Sin(time * speed + seed * 3));
                var w = 4 + pulse * 10;
                shape.Width = w;
                Canvas.SetLeft(shape, fx * width - w / 2);
                Canvas.SetTop(shape, seaTop + seaHeight * fy);
                shape.Opacity = pulse * 0.55;
            }
        }

        private (Grid View, TranslateTransform Shift, TranslateTransform Scene) BuildPage(int index)
        {
            var eyebrow = Label(Eyebrow(index).ToUpper(System.Globalization.CultureInfo.CurrentUICulture), 12, Tone(0xF07563, "coral"), FontWeights.SemiBold);
            eyebrow.CharacterSpacing = 100;
            var subtitle = Label(Subtitle(index), 17, Ink(0.78), wrap: true);
            subtitle.MaxWidth = 420;
            subtitle.HorizontalAlignment = HorizontalAlignment.Left;
            var text = new StackPanel { Spacing = 18, Width = 460, VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(eyebrow);
            text.Children.Add(Reveal(Title(index), 44));
            text.Children.Add(subtitle);

            var floatShift = new TranslateTransform();
            var scene = new Grid { Width = 420, Height = 340, VerticalAlignment = VerticalAlignment.Center, RenderTransform = floatShift };
            AutomationProperties.SetAccessibilityView(scene, AccessibilityView.Raw);
            scene.Children.Add(index switch
            {
                0 => HeroScene(),
                1 => OverviewScene(),
                2 => KeysScene(),
                3 => MergeScene(),
                _ => AgentScene()
            });

            var shift = new TranslateTransform();
            var view = new Grid { ColumnSpacing = 48, RenderTransform = shift, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            view.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(460) });
            view.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(420) });
            Grid.SetColumn(text, 0);
            Grid.SetColumn(scene, 1);
            view.Children.Add(text);
            view.Children.Add(scene);
            return (view, shift, floatShift);
        }

        private FrameworkElement Reveal(string text, double size)
        {
            var panel = new StackPanel { Spacing = 2 };
            var n = 0;
            foreach (var line in text.Split('\n'))
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = size * 0.24 };
                foreach (var word in line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                {
                    var t = Label(word, size, Ink(), FontWeights.SemiBold);
                    t.FontFamily = Serif;
                    t.CharacterSpacing = -14;
                    AutomationProperties.SetAccessibilityView(t, AccessibilityView.Raw);
                    if (motion)
                    {
                        var rise = new TranslateTransform { Y = 18 };
                        t.RenderTransform = rise;
                        t.Opacity = 0;
                        Animate(0.7, Brand, e =>
                        {
                            t.Opacity = e;
                            rise.Y = 18 * (1 - e);
                        }, delay: 0.1 + n * 0.06);
                    }
                    row.Children.Add(t);
                    n++;
                }
                panel.Children.Add(row);
            }
            AutomationProperties.SetName(panel, text.Replace('\n', ' '));
            AutomationProperties.SetHeadingLevel(panel, AutomationHeadingLevel.Level1);
            return panel;
        }

        private FrameworkElement HeroScene()
        {
            var g = new Grid();
            if (!contrast)
            {
                g.Children.Add(Halo(0x6B55D6, 0.45, 320));
                g.Children.Add(Halo(0x38BDF8, 0.18, 220));
            }
            var logo = new LogoLoader(300, once: true, drawSeconds: 2.0) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAccessibilityView(logo, AccessibilityView.Raw);
            var scale = new ScaleTransform();
            var holder = new Grid { RenderTransform = scale, RenderTransformOrigin = new Point(0.5, 0.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            holder.Children.Add(logo);
            g.Children.Add(holder);
            if (motion)
            {
                holder.Opacity = 0;
                scale.ScaleX = 0.85;
                scale.ScaleY = 0.85;
                Animate(0.8, Brand, e =>
                {
                    holder.Opacity = e;
                    scale.ScaleX = 0.85 + 0.15 * e;
                    scale.ScaleY = 0.85 + 0.15 * e;
                });
            }
            return g;
        }

        private FrameworkElement OverviewScene()
        {
            var tiles = new (string Title, string Glyph, uint Rgb, string Key, int Target)[]
            {
                (L.T("WelcomeTour_TileReviews", "Reviews waiting"), PRFilter.ReviewRequested.Glyph(), 0xF07563, "coral", 4),
                (L.T("WelcomeTour_TileReady", "Ready to merge"), PullYard.Core.Api.VisualStates.Glyph(PullYard.Core.Api.VisualState.Merged), 0x5DBE8A, "green", 2),
                (L.T("WelcomeTour_TileFailing", "Failing checks"), Palette.CheckGlyph(PullYard.Core.Api.CheckOutcome.Failure), 0xE8746A, "red", 1),
                (L.T("WelcomeTour_TileMentioned", "Mentioned"), PRFilter.Mentioned.Glyph(), 0x8C97E8, "indigo", 3)
            };
            var grid = new Grid { RowSpacing = 12, ColumnSpacing = 12, VerticalAlignment = VerticalAlignment.Center };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var numbers = new List<(TextBlock Text, ScaleTransform Pop, int Target)>();
            for (var i = 0; i < tiles.Length; i++)
            {
                var tile = tiles[i];
                var badge = new Border
                {
                    Width = 30,
                    Height = 30,
                    CornerRadius = new CornerRadius(15),
                    Background = contrast ? Palette.Brush("window") : Tone(tile.Rgb, tile.Key, 0.2),
                    BorderBrush = contrast ? Palette.Brush("text") : null,
                    BorderThickness = new Thickness(contrast ? 1 : 0),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Child = Icon(tile.Glyph, 14, Tone(tile.Rgb, tile.Key))
                };
                ((FontIcon)badge.Child).HorizontalAlignment = HorizontalAlignment.Center;
                var pop = new ScaleTransform();
                var number = Label("0", 30, Ink(), FontWeights.Bold);
                number.RenderTransform = pop;
                number.RenderTransformOrigin = new Point(0, 0.5);
                number.HorizontalAlignment = HorizontalAlignment.Left;
                numbers.Add((number, pop, tile.Target));
                var caption = Label(tile.Title, 13, Ink(0.7), FontWeights.SemiBold);
                var body = new StackPanel { Spacing = 8 };
                body.Children.Add(badge);
                body.Children.Add(number);
                body.Children.Add(caption);
                var card = Card(body);
                Grid.SetColumn(card, i % 2);
                Grid.SetRow(card, i / 2);
                grid.Children.Add(card);
            }
            for (var step = 1; step <= 4; step++)
            {
                var s = step;
                After(0.22 * step, () =>
                {
                    foreach (var (text, pop, target) in numbers)
                    {
                        var value = Math.Min(target, s).ToString(Fmt.Culture);
                        if (text.Text == value) continue;
                        text.Text = value;
                        Animate(0.35, Brand, e =>
                        {
                            pop.ScaleX = 1.18 - 0.18 * e;
                            pop.ScaleY = 1.18 - 0.18 * e;
                        });
                    }
                });
            }
            return grid;
        }

        private FrameworkElement KeysScene()
        {
            var ctrl = L.T("WelcomeTour_KeyCtrl", "Ctrl");
            var shift = L.T("WelcomeTour_KeyShift", "Shift");
            var rows = new (string[] Caps, bool Chord, string Detail)[]
            {
                (new[] { "J", "K" }, false, L.T("WelcomeTour_KeyNextPrevious", "Next / previous")),
                (new[] { ctrl, "K" }, true, L.T("WelcomeTour_KeyPalette", "Command palette")),
                (new[] { ctrl, "L" }, true, L.T("WelcomeTour_KeyLink", "Open a link")),
                (new[] { ctrl, shift, "K" }, true, L.T("WelcomeTour_KeyAgent", "Jump to an agent")),
                (new[] { ctrl, "/" }, true, L.T("WelcomeTour_KeyShortcuts", "All shortcuts"))
            };
            var list = new StackPanel { Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
            for (var i = 0; i < rows.Length; i++)
            {
                var (caps, chord, detail) = rows[i];
                var keys = new StackPanel { Orientation = Orientation.Horizontal, Spacing = chord ? 5 : 8, VerticalAlignment = VerticalAlignment.Center };
                for (var j = 0; j < caps.Length; j++)
                {
                    if (j > 0 && chord) keys.Children.Add(Label("+", 13, Ink(0.5)));
                    keys.Children.Add(Cap(caps[j]));
                }
                var description = Label(detail, 15, Ink(0.85), FontWeights.Medium, wrap: true);
                var row = new Grid { ColumnSpacing = 14 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(description, 1);
                row.Children.Add(keys);
                row.Children.Add(description);
                list.Children.Add(row);
                if (!motion) continue;
                var slide = new TranslateTransform { X = 30 };
                row.RenderTransform = slide;
                row.Opacity = 0;
                Animate(0.5, Brand, e =>
                {
                    row.Opacity = e;
                    slide.X = 30 * (1 - e);
                }, delay: 0.16 * (i + 1));
            }
            return list;
        }

        private FrameworkElement Cap(string key)
        {
            var text = Label(key, 15, Ink(), FontWeights.SemiBold, mono: true);
            text.HorizontalAlignment = HorizontalAlignment.Center;
            var cap = new Border
            {
                MinWidth = 36,
                Height = 34,
                Padding = new Thickness(10, 0, 10, 0),
                CornerRadius = new CornerRadius(8),
                Background = contrast ? Palette.Brush("window") : Ink(0.14),
                BorderBrush = contrast ? Palette.Brush("text") : Ink(0.25),
                BorderThickness = new Thickness(1),
                Child = text
            };
            if (contrast) return cap;
            var holder = new Grid();
            holder.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(Color.FromArgb(77, 0, 0, 0)), RenderTransform = new TranslateTransform { Y = 2 } });
            holder.Children.Add(cap);
            return holder;
        }

        private FrameworkElement MergeScene()
        {
            var items = new[]
            {
                L.T("WelcomeTour_MergeApproved", "Approved by 2 reviewers"),
                L.T("WelcomeTour_MergeChecks", "All 12 checks passing"),
                L.T("WelcomeTour_MergeConflicts", "No conflicts with main"),
                L.T("WelcomeTour_MergeRules", "Branch rules satisfied")
            };
            var checklist = new StackPanel { Spacing = 10 };
            var rows = new List<(FontIcon Icon, ScaleTransform Pop, TextBlock Text)>();
            foreach (var item in items)
            {
                var pop = new ScaleTransform();
                var icon = Icon("", 16, contrast ? Palette.Brush("dim") : Ink(0.4));
                icon.RenderTransform = pop;
                icon.RenderTransformOrigin = new Point(0.5, 0.5);
                var text = Label(item, 15, contrast ? Palette.Brush("dim") : Ink(0.55));
                rows.Add((icon, pop, text));
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                row.Children.Add(icon);
                row.Children.Add(text);
                checklist.Children.Add(row);
            }
            var mergeIcon = Icon(PullYard.Core.Api.VisualStates.Glyph(PullYard.Core.Api.VisualState.Merged), 14, contrast ? Palette.Brush("onFill") : Ink());
            var mergeText = Label(L.T("WelcomeTour_MergeButton", "Merge…"), 15, contrast ? Palette.Brush("onFill") : Ink(), FontWeights.SemiBold);
            var mergeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
            mergeRow.Children.Add(mergeIcon);
            mergeRow.Children.Add(mergeText);
            var pillScale = new ScaleTransform();
            var pill = new Border
            {
                Height = 40,
                Padding = new Thickness(18, 0, 18, 0),
                CornerRadius = new CornerRadius(20),
                Background = contrast ? Palette.Brush("greenFill") : Tone(0x2B7F50, "greenFill"),
                HorizontalAlignment = HorizontalAlignment.Left,
                RenderTransform = pillScale,
                RenderTransformOrigin = new Point(0.5, 0.5),
                Child = mergeRow
            };
            var panel = new StackPanel { Spacing = 14, VerticalAlignment = VerticalAlignment.Center };
            panel.Children.Add(Card(checklist));
            panel.Children.Add(pill);

            for (var i = 0; i < rows.Count; i++)
            {
                var (icon, pop, text) = rows[i];
                After(0.26 * (i + 1), () =>
                {
                    icon.Glyph = "";
                    icon.Foreground = Tone(0x5DBE8A, "green");
                    text.Foreground = contrast ? Palette.Brush("text") : Ink(0.95);
                    Animate(0.35, BackOut, e =>
                    {
                        pop.ScaleX = 0.6 + 0.4 * e;
                        pop.ScaleY = 0.6 + 0.4 * e;
                    });
                });
            }
            After(0.26 * rows.Count + 0.45, () =>
            {
                mergeIcon.Glyph = "";
                mergeText.Text = L.T("WelcomeTour_Merged", "Merged into main");
                pill.Background = contrast ? Palette.Brush("violetFill") : Tone(0x6B55D6, "violetFill");
                Animate(0.4, BackOut, e =>
                {
                    pillScale.ScaleX = 1 + 0.04 * e;
                    pillScale.ScaleY = 1 + 0.04 * e;
                });
            });
            return panel;
        }

        private FrameworkElement AgentScene()
        {
            var fixRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            fixRow.Children.Add(Icon("", 14, contrast ? Palette.Brush("onCoral") : Ink()));
            fixRow.Children.Add(Label(L.T("Fix_Button", "Fix with agent"), 15, contrast ? Palette.Brush("onCoral") : Ink(), FontWeights.SemiBold));
            var fix = new Border
            {
                Height = 40,
                Padding = new Thickness(18, 0, 18, 0),
                CornerRadius = new CornerRadius(20),
                Background = contrast ? Palette.Brush("coralFill") : Tone(0xC24533, "coralFill"),
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = fixRow
            };

            var pulse = new Ellipse { Width = 7, Height = 7, Fill = Tone(0xF07563, "coral"), VerticalAlignment = VerticalAlignment.Center };
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            header.Children.Add(pulse);
            header.Children.Add(Label(L.T("WelcomeTour_AgentRunning", "Agent running · 1m"), 13, Tone(0xF8A59A, "coral"), FontWeights.SemiBold));
            var log = new StackPanel { Spacing = 8 };
            log.Children.Add(header);
            var lines = new[]
            {
                L.T("WelcomeTour_AgentRead", "Reading 3 review comments…"),
                L.T("WelcomeTour_AgentEdit", "Updating SyncEngine.cs"),
                L.T("WelcomeTour_AgentTests", "Running tests · 48 passed"),
                L.T("WelcomeTour_AgentPush", "Pushed fix to the branch")
            };
            for (var i = 0; i < lines.Length; i++)
            {
                var full = lines[i];
                var line = Label("› " + full, 13, Ink(0.8), mono: true);
                line.Opacity = 0;
                log.Children.Add(line);
                After(0.42 * (i + 1), () =>
                {
                    line.Opacity = 1;
                    Animate(0.35, Linear, e =>
                    {
                        var shown = (int)Math.Ceiling(full.Length * e);
                        line.Text = "› " + full[..Math.Clamp(shown, 0, full.Length)];
                    });
                });
            }

            if (motion) Animate(1.6, Linear, e => pulse.Opacity = 0.3 + 0.7 * (0.5 - 0.5 * Math.Cos(2 * Math.PI * e)), key: "dot", repeat: true);

            var panel = new StackPanel { Spacing = 14, VerticalAlignment = VerticalAlignment.Center };
            panel.Children.Add(fix);
            panel.Children.Add(Card(log));
            return panel;
        }

        private Border Card(UIElement child) => new()
        {
            Background = contrast ? Palette.Brush("window") : Ink(0.1),
            BorderBrush = contrast ? Palette.Brush("text") : Ink(0.16),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(14),
            Child = child
        };

        private static Ellipse Halo(uint rgb, double alpha, double size)
        {
            var brush = new RadialGradientBrush();
            brush.GradientStops.Add(new GradientStop { Offset = 0, Color = Palette.Hex(rgb, (byte)Math.Round(255 * alpha)) });
            brush.GradientStops.Add(new GradientStop { Offset = 1, Color = Palette.Hex(rgb, 0) });
            return new Ellipse { Width = size, Height = size, Fill = brush, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        }

        private Brush Ink(double opacity = 1) => contrast ? Palette.Brush("text") : new SolidColorBrush(Color.FromArgb(Alpha(opacity), 255, 255, 255));

        private Brush Tone(uint rgb, string key, double opacity = 1) => contrast ? Palette.Brush(key) : new SolidColorBrush(Palette.Hex(rgb, Alpha(opacity)));

        private static byte Alpha(double opacity) => (byte)Math.Round(255 * Math.Clamp(opacity, 0, 1));

        private static TextBlock Label(string text, double size, Brush brush, Windows.UI.Text.FontWeight? weight = null, bool wrap = false, bool mono = false)
        {
            var t = new TextBlock
            {
                Text = text,
                Foreground = brush,
                TextWrapping = wrap ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
                TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            if (weight is { } w) t.FontWeight = w;
            if (mono) t.FontFamily = Ui.Mono;
            return TextZoom.Track(t, size);
        }

        private static FontIcon Icon(string glyph, double size, Brush brush) => TextZoom.Track(new FontIcon
        {
            Glyph = glyph,
            FontFamily = Ui.Icons,
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Center
        }, size);

        private static string Eyebrow(int index) => index switch
        {
            0 => L.T("WelcomeTour_Eyebrow1", "Welcome aboard"),
            1 => L.T("WelcomeTour_Eyebrow2", "Your harbor"),
            2 => L.T("WelcomeTour_Eyebrow3", "Review at speed"),
            3 => L.T("WelcomeTour_Eyebrow4", "Merge with confidence"),
            _ => L.T("WelcomeTour_Eyebrow5", "Agents on deck")
        };

        private static string Title(int index) => index switch
        {
            0 => L.T("WelcomeTour_Title1", "Pull requests,\nwithout the browser."),
            1 => L.T("WelcomeTour_Title2", "Start every day\non Overview."),
            2 => L.T("WelcomeTour_Title3", "Your keyboard\nis the fast lane."),
            3 => L.T("WelcomeTour_Title4", "Know it’s ready\nbefore you merge."),
            _ => L.T("WelcomeTour_Title5", "Hand the fix\nto an agent.")
        };

        private static string Subtitle(int index) => index switch
        {
            0 => L.F("WelcomeTour_Subtitle1", "{0} is a native home for your code reviews. Your token stays on this PC, and everything refreshes on its own.", AppInfo.DisplayName),
            1 => L.T("WelcomeTour_Subtitle2", "See what’s waiting for you, what’s failing and what’s ready to merge — one glance, then jump straight in."),
            2 => L.T("WelcomeTour_Subtitle3", "J and K walk the list. Ctrl+K finds everything, Ctrl+L opens a link, Ctrl+Shift+K jumps to an agent and Ctrl+/ shows every shortcut."),
            3 => L.T("WelcomeTour_Subtitle4", "Every requirement is checked live: reviews, checks, conflicts, branch rules. Merge asks once more before it ships."),
            _ => L.T("WelcomeTour_Subtitle5", "Failing checks or review comments? Start an agent from the pull request and keep reviewing while it works.")
        };

        private static Color Mix(uint a, uint b, double t)
        {
            byte Channel(int shift)
            {
                var from = (a >> shift) & 0xFF;
                var to = (b >> shift) & 0xFF;
                return (byte)Math.Round(from + (to - (double)from) * t);
            }
            return Color.FromArgb(255, Channel(16), Channel(8), Channel(0));
        }

        private static double Fract(double value) => value - Math.Floor(value);

        private static double BackOut(double t)
        {
            const double c1 = 1.70158;
            const double c3 = c1 + 1;
            var u = t - 1;
            return 1 + c3 * u * u * u + c1 * u * u;
        }

        private static Func<double, double> Curve(double x1, double y1, double x2, double y2) => t =>
        {
            if (t <= 0) return 0;
            if (t >= 1) return 1;
            double lo = 0, hi = 1, u = t;
            for (var i = 0; i < 24; i++)
            {
                u = (lo + hi) / 2;
                if (Bezier(x1, x2, u) < t) lo = u;
                else hi = u;
            }
            return Bezier(y1, y2, u);
        };

        private static double Bezier(double a, double b, double u)
        {
            var v = 1 - u;
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u;
        }
    }
}
