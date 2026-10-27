using System.Text.RegularExpressions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PullYard.Core.Api;
using PullYard.Core.Util;
using PullYard.Services;
using VisualState = PullYard.Core.Api.VisualState;


namespace PullYard.Controls;

public static class Ui
{
    public static FontFamily Mono { get; } = new("Cascadia Mono, Consolas");
    public static FontFamily Icons { get; } = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    public static TextBlock Text(string? text, double size = 13, string color = "text", Windows.UI.Text.FontWeight? weight = null, bool wrap = false, int maxLines = 0, bool mono = false, bool select = false)
    {
        var t = new TextBlock
        {
            Text = text ?? "",
            Foreground = Palette.Brush(color),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = wrap || maxLines > 1 ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
            IsTextSelectionEnabled = select,
            VerticalAlignment = VerticalAlignment.Center
        };
        if (maxLines > 0) t.MaxLines = maxLines;
        if (weight is { } w) t.FontWeight = w;
        if (mono) t.FontFamily = Mono;
        return TextZoom.Track(t, size);
    }

    public static TextBlock Caption(string? text, string color = "muted") => Text(text, 12, color);

    public static FontIcon Glyph(string glyph, double size = 13, string color = "muted") => TextZoom.Track(new FontIcon
    {
        Glyph = glyph,
        FontFamily = Icons,
        Foreground = Palette.Brush(color),
        VerticalAlignment = VerticalAlignment.Center
    }, size);

    public static T Named<T>(T element, string? name, string? help = null) where T : DependencyObject
    {
        if (!string.IsNullOrEmpty(name)) AutomationProperties.SetName(element, name);
        if (!string.IsNullOrEmpty(help)) AutomationProperties.SetHelpText(element, help);
        return element;
    }

    public static T Expandable<T>(T element, string name, bool expanded) where T : DependencyObject
    {
        AutomationProperties.SetName(element, name);
        AutomationProperties.SetItemStatus(element, expanded ? L.T("A11y_Expanded", "Expanded") : L.T("A11y_Collapsed", "Collapsed"));
        return element;
    }

    private static readonly Regex ShortcutHint = new(@"\s*\((?:Ctrl|Alt|Shift|Esc|F\d)[^)]*\)\s*$", RegexOptions.Compiled);

    public static string SpokenName(string tooltip) => ShortcutHint.Replace(tooltip, "");

    public static FontIcon StatusGlyph(string glyph, double size, string color, string label)
    {
        var icon = Glyph(glyph, size, color);
        Tip(icon, label);
        AutomationProperties.SetName(icon, label);
        return icon;
    }

    public static StackPanel H(double spacing, params UIElement?[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var c in children)
            if (c is not null) p.Children.Add(c);
        return p;
    }

    public static StackPanel V(double spacing, params UIElement?[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var c in children)
            if (c is not null) p.Children.Add(c);
        return p;
    }

    public static Border IconTile(string glyph, string color, double size = 20) => new()
    {
        Width = size,
        Height = size,
        CornerRadius = new CornerRadius(size * 0.28),
        Background = Palette.Brush(color, 0.14),
        Child = TextZoom.Track(new FontIcon { Glyph = glyph, FontFamily = Icons, Foreground = Palette.Brush(color), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }, size * 0.55),
        VerticalAlignment = VerticalAlignment.Center
    };

    public static Border Chip(string text, string color = "muted", string? glyph = null, bool mono = false)
    {
        var content = H(4);
        if (glyph is not null) content.Children.Add(Glyph(glyph, 10, color));
        var t = Text(text, 11.5, color, FontWeights.Medium);
        if (mono) t.FontFamily = Mono;
        t.MaxWidth = 260;
        content.Children.Add(t);
        return new Border
        {
            Background = Palette.Brush(color, 0.12),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 1, 7, 2),
            Child = content,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static Border LabelChip(LabelInfo label)
    {
        var t = Text(label.Name, 11, "text", FontWeights.Medium);
        return new Border
        {
            Background = Palette.HexBrush(label.Color, 0.22),
            BorderBrush = Palette.HexBrush(label.Color, 0.7),
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 0, 7, 1),
            Child = t,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static FrameworkElement StateBadge(VisualState state, bool compact = false)
    {
        var key = Palette.StateKey(state);
        if (compact)
        {
            var badge = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(11),
                Background = Palette.Brush(key, 0.15),
                Child = TextZoom.Track(new FontIcon { Glyph = state.Glyph(), FontFamily = Icons, Foreground = Palette.Brush(key), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }, 11),
                VerticalAlignment = VerticalAlignment.Top
            };
            Tip(badge, StateTitle(state));
            AutomationProperties.SetName(badge, StateTitle(state));
            return badge;
        }
        var (fill, white) = Palette.Filled(key);
        return new Border
        {
            Background = fill,
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(9, 2, 10, 3),
            VerticalAlignment = VerticalAlignment.Center,
            Child = H(5,
                TextZoom.Track(new FontIcon { Glyph = state.Glyph(), FontFamily = Icons, Foreground = white }, 11),
                TextZoom.Track(new TextBlock { Text = StateTitle(state), FontWeight = FontWeights.SemiBold, Foreground = white }, 12.5))
        };
    }

    public static string StateTitle(VisualState state) => state switch
    {
        VisualState.Open or VisualState.IssueOpen => L.T("State_Open", "Open"),
        VisualState.Draft => L.T("State_Draft", "Draft"),
        VisualState.Merged => L.T("State_Merged", "Merged"),
        VisualState.Closed => L.T("State_Closed", "Closed"),
        VisualState.Completed => L.T("State_Completed", "Completed"),
        VisualState.NotPlanned => L.T("State_NotPlanned", "Not planned"),
        _ => state.Title()
    };

    public static FrameworkElement Avatar(string? url, double size = 20, bool ring = false)
    {
        var p = new PersonPicture { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(p, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (!string.IsNullOrEmpty(url))
        {
            try
            {
                var sep = url.Contains('?') ? "&" : "?";
                var px = (int)(size * 2);
                p.ProfilePicture = new BitmapImage(new Uri($"{url}{sep}s={px}")) { DecodePixelWidth = px, DecodePixelType = DecodePixelType.Physical };
            }
            catch
            {
            }
        }
        if (!ring) return p;
        return new Border
        {
            Width = size + 1,
            Height = size + 1,
            CornerRadius = new CornerRadius((size + 1) / 2),
            BorderBrush = Palette.Brush("text", ThemeService.IsDark ? 0.22 : 0.16),
            BorderThickness = new Thickness(0.5),
            Child = p,
            VerticalAlignment = VerticalAlignment.Center
        };
    }

    public static StackPanel DiffStat(int additions, int deletions, double size = 12) =>
        H(4, Text($"+{additions}", size, "green"), Text($"−{deletions}", size, "red"));

    public static FrameworkElement? CiIcon(string? state, double size = 12)
    {
        if (Palette.CiIcon(state) is not { } ci) return null;
        return StatusGlyph(ci.Glyph, size, ci.Key, CiTitle(state) ?? "");
    }

    public static FontIcon CheckIcon(CheckOutcome outcome, double size) => StatusGlyph(Palette.CheckGlyph(outcome), size, Palette.CheckKey(outcome), outcome switch
    {
        CheckOutcome.Success => L.T("Check_Passed", "Passed"),
        CheckOutcome.Failure => L.T("Check_Failed", "Failed"),
        CheckOutcome.Pending => L.T("Check_Pending", "Pending"),
        CheckOutcome.Skipped => L.T("Check_Skipped", "Skipped"),
        _ => L.T("Check_Neutral", "Neutral")
    });

    public static string? CiTitle(string? state) => state switch
    {
        "SUCCESS" => L.T("Ci_Passed", "Checks passed"),
        "FAILURE" or "ERROR" => L.T("Ci_Failed", "Checks failed"),
        "PENDING" or "EXPECTED" => L.T("Ci_Running", "Checks running"),
        _ => null
    };

    public static Border Card(UIElement child, double radius = 10, string fill = "raised", double padding = 12) => new()
    {
        Background = Palette.Brush(fill),
        CornerRadius = new CornerRadius(radius),
        Padding = new Thickness(padding),
        Child = child
    };

    public static Button Button(string text, Action onClick, bool accent = false, string? glyph = null, string? tooltip = null)
    {
        var b = new Button();
        if (glyph is not null)
        {
            b.Content = H(6, Glyph(glyph, 12, accent ? "text" : "text"), new TextBlock { Text = text });
            AutomationProperties.SetName(b, text);
        }
        else b.Content = text;
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += (_, _) => onClick();
        if (tooltip is not null) ToolTipService.SetToolTip(b, tooltip);
        return TextZoom.Track(b, 14);
    }

    public static Button IconButton(string glyph, string tooltip, Action onClick, string color = "muted")
    {
        var b = new Button
        {
            Content = Glyph(glyph, 14, color),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 5, 8, 5)
        };
        ToolTipService.SetToolTip(b, tooltip);
        var spoken = SpokenName(tooltip);
        AutomationProperties.SetName(b, spoken);
        if (spoken != tooltip) AutomationProperties.SetHelpText(b, tooltip);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static HyperlinkButton Link(string text, Action onClick, double size = 12)
    {
        var b = new HyperlinkButton { Content = text, Padding = new Thickness(0) };
        b.Click += (_, _) => onClick();
        return TextZoom.Track(b, size);
    }

    public static Microsoft.UI.Xaml.Shapes.Rectangle Line(bool vertical = false)
    {
        var r = new Microsoft.UI.Xaml.Shapes.Rectangle { Fill = Palette.Brush("text", ThemeService.IsDark ? 0.10 : 0.08) };
        if (vertical) r.Width = 1;
        else r.Height = 1;
        return r;
    }

    public static Grid Columns(params (UIElement? Element, GridLength Width)[] cols)
    {
        var g = new Grid { ColumnSpacing = 8 };
        for (var i = 0; i < cols.Length; i++)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = cols[i].Width });
            if (cols[i].Element is { } e)
            {
                Grid.SetColumn((FrameworkElement)e, i);
                g.Children.Add(e);
            }
        }
        return g;
    }

    public static GridLength Auto => GridLength.Auto;
    public static GridLength Star => new(1, GridUnitType.Star);

    public static WakeLoader Spinner(double size = 16) => new(size);

    public static Button RefreshButton(Func<Task> refresh, string? tooltip = null)
    {
        Button? button = null;
        button = IconButton("\uE72C", tooltip ?? L.T("Refresh_Button", "Refresh (Ctrl+R)"), async () =>
        {
            if (button is null || !button.IsEnabled) return;
            button.IsEnabled = false;
            try
            {
                await Task.WhenAll(refresh(), Task.Delay(600));
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "refresh failed");
            }
            finally
            {
                button.IsEnabled = true;
            }
        }, "text");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L.T("Common_Refresh", "Refresh"));
        return button;
    }

    public static Button RefreshButton(Action refresh, string? tooltip = null) => RefreshButton(() =>
    {
        refresh();
        return Task.CompletedTask;
    }, tooltip);

    public static FrameworkElement Error(string message, Action? retry = null, string? title = null)
    {
        var tile = IconTile("\uE7BA", "red", 44);
        tile.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetAccessibilityView(tile, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var heading = Text(title ?? L.T("Common_CouldntLoad", "Couldn’t load"), 13.5, "text", FontWeights.SemiBold, wrap: true);
        heading.TextAlignment = TextAlignment.Center;
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        var detail = Text(message, 12.5, "muted", wrap: true, select: true);
        detail.TextAlignment = TextAlignment.Center;
        detail.HorizontalAlignment = HorizontalAlignment.Center;
        var panel = V(12, tile, V(4, heading, detail));
        if (retry is not null)
        {
            var b = Button(L.T("Common_Retry", "Retry"), retry);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(b);
        }
        panel.HorizontalAlignment = HorizontalAlignment.Center;
        panel.VerticalAlignment = VerticalAlignment.Center;
        panel.MaxWidth = 340;
        panel.Margin = new Thickness(24);
        AutomationProperties.SetLiveSetting(panel, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        return panel;
    }

    public static FrameworkElement EmptyState(string title, string? message = null, string filter = "", Action? clear = null, string? actionTitle = null, Action? action = null)
    {
        var filtering = filter.Length > 0;
        FrameworkElement mark;
        if (filtering)
        {
            var tile = IconTile("\uE721", "muted", 44);
            AutomationProperties.SetAccessibilityView(tile, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            mark = tile;
        }
        else
        {
            mark = new DrawnLogoMark(title, 64);
        }
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        var heading = Text(filtering ? L.F("Empty_NoMatches", "No matches for “{0}”", filter) : title, 13.5, "text", FontWeights.SemiBold, maxLines: 2);
        heading.TextAlignment = TextAlignment.Center;
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        var words = V(4, heading);
        if ((filtering ? L.T("Empty_TryDifferent", "Try a different search.") : message) is { Length: > 0 } detail)
        {
            var t = Text(detail, 12.5, "muted", wrap: true);
            t.TextAlignment = TextAlignment.Center;
            t.HorizontalAlignment = HorizontalAlignment.Center;
            words.Children.Add(t);
        }
        var panel = V(12, mark, words);
        if (filtering && clear is not null)
        {
            var b = Button(L.T("Empty_ClearFilter", "Clear filter"), clear);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(b);
        }
        else if (!filtering && actionTitle is not null && action is not null)
        {
            var b = Button(actionTitle, action);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(b);
        }
        panel.HorizontalAlignment = HorizontalAlignment.Center;
        panel.VerticalAlignment = VerticalAlignment.Center;
        panel.MaxWidth = 300;
        panel.Margin = new Thickness(24);
        return panel;
    }

    public static FrameworkElement EmptyNote(string title, string? message = null)
    {
        var panel = V(2, Text(title, 12.5, "muted", wrap: true));
        if (message is { Length: > 0 }) panel.Children.Add(Text(message, 12, "dim", wrap: true));
        panel.Padding = new Thickness(0, 4, 0, 4);
        return panel;
    }

    public static FrameworkElement Loading(double size = 56) => new LogoLoader(size)
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center
    };

    public static FrameworkElement Empty(string glyph, string color, string message)
    {
        var tile = IconTile(glyph, color, 44);
        tile.HorizontalAlignment = HorizontalAlignment.Center;
        var t = Text(message, 13, "muted", wrap: true);
        t.TextAlignment = TextAlignment.Center;
        var p = V(10, tile, t);
        p.HorizontalAlignment = HorizontalAlignment.Center;
        p.VerticalAlignment = VerticalAlignment.Center;
        p.Margin = new Thickness(24);
        return p;
    }

    public static MenuFlyoutItem MenuItem(string text, Action onClick, string? glyph = null, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph is not null) item.Icon = new FontIcon { Glyph = glyph, FontFamily = Icons };
        item.Click += (_, _) => onClick();
        return item;
    }

    public static ToggleMenuFlyoutItem CheckItem(string text, bool on, Action onClick)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
        item.Click += (_, _) => onClick();
        return item;
    }

    public static MenuFlyout Menu(params MenuFlyoutItemBase?[] items)
    {
        var m = new MenuFlyout();
        foreach (var i in items)
            if (i is not null) m.Items.Add(i);
        return m;
    }

    public static MenuFlyoutSeparator Separator() => new();

    public static void Tip(DependencyObject element, string? text)
    {
        if (!string.IsNullOrEmpty(text)) ToolTipService.SetToolTip(element, text);
    }

    public static string Plural(int n, string one, string many) => Fmt.Plural(n, one, many);
}
