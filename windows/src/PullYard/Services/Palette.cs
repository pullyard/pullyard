using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using PullYard.Core.Api;
using PullYard.Core.Theming;
using Windows.UI;
using Windows.UI.ViewManagement;
using VisualState = PullYard.Core.Api.VisualState;

namespace PullYard.Services;

public static class Palette
{
    private static readonly Dictionary<(string Key, byte Alpha), SolidColorBrush> Brushes = new();
    private static UISettings? uiSettings;
    private static SystemAccent? accent;
    private static bool watchingAccent;

    public static bool IsDark => ThemeService.IsDark;

    public static bool MicaActive { get; set; }

    public static Color Hex(uint rgb, byte alpha = 255) => Color.FromArgb(alpha, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    public static Color Hex(string? hex, byte alpha = 255)
    {
        var s = (hex ?? "").Trim('#');
        if (s.Length == 3) s = string.Concat(s.Select(c => $"{c}{c}"));
        return uint.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var v) ? Hex(v, alpha) : Hex(0x888888u, alpha);
    }

    public static Color Get(string key, byte alpha = 255)
    {
        if (ThemeService.IsHighContrast) return HighContrast(key, alpha);
        var system = ThemeService.Style == ThemeStyle.System;
        var argb = ThemeTokens.Resolve(key, system, IsDark, system ? Accent() : null);
        var a = (int)(argb >> 24);
        if (system && MicaActive && key == "window") a = 0;
        return Color.FromArgb((byte)((a * alpha + 127) / 255), (byte)((argb >> 16) & 0xFF), (byte)((argb >> 8) & 0xFF), (byte)(argb & 0xFF));
    }

    public static uint Argb(string key)
    {
        var c = Get(key);
        return ((uint)c.A << 24) | ((uint)c.R << 16) | ((uint)c.G << 8) | c.B;
    }

    public static SolidColorBrush Brush(string key, double opacity = 1)
    {
        var alpha = (byte)Math.Round(255 * Math.Clamp(opacity, 0, 1));
        if (Brushes.TryGetValue((key, alpha), out var brush)) return brush;
        brush = new SolidColorBrush(Get(key, alpha));
        Brushes[(key, alpha)] = brush;
        return brush;
    }

    public static SolidColorBrush TextBrush(string key) => Brush(ThemeTokens.TextKey(key));

    public static void Refresh()
    {
        foreach (var pair in Brushes)
        {
            var color = Get(pair.Key.Key, pair.Key.Alpha);
            if (!pair.Value.Color.Equals(color)) pair.Value.Color = color;
        }
    }

    public static (SolidColorBrush Fill, SolidColorBrush Text) Filled(string key) => (Brush(ThemeTokens.FillKey(key)), Brush("onFill"));

    public static SolidColorBrush HexBrush(string? hex, double opacity = 1) => new(Hex(hex, (byte)Math.Round(255 * opacity)));

    public static string CssHex(string key) => ThemeTokens.Css(Argb(key));

    private static uint Pack(Color c) => 0xFF000000 | ((uint)c.R << 16) | ((uint)c.G << 8) | c.B;

    private static SystemAccent ReadAccent()
    {
        try
        {
            uiSettings ??= new UISettings();
            return new SystemAccent(
                Pack(uiSettings.GetColorValue(UIColorType.AccentDark1)),
                Pack(uiSettings.GetColorValue(UIColorType.AccentDark2)),
                Pack(uiSettings.GetColorValue(UIColorType.AccentLight2)),
                Pack(uiSettings.GetColorValue(UIColorType.AccentLight3)));
        }
        catch
        {
            return SystemAccent.Default;
        }
    }

    private static SystemAccent Accent() => accent ??= ReadAccent();

    public static void WatchAccent(Microsoft.UI.Dispatching.DispatcherQueue queue, Action changed)
    {
        if (watchingAccent) return;
        try
        {
            uiSettings ??= new UISettings();
            uiSettings.ColorValuesChanged += (_, _) => queue.TryEnqueue(() =>
            {
                var next = ReadAccent();
                if (accent is { } known && known == next) return;
                accent = next;
                changed();
            });
            watchingAccent = true;
        }
        catch
        {
        }
    }

    private static Color HighContrast(string key, byte alpha)
    {
        if (key == "hover") return SystemColor(UIElementType.Window, 0);
        var type = key switch
        {
            "window" or "sidebar" or "list" or "panel" or "raised" or "overlay" or "sunken" or "bar" or "sub" or "code" or "button" => UIElementType.Window,
            "dim" or "gutter" or "line" => UIElementType.GrayText,
            "accent" or "sky" or "link" => UIElementType.Hotlight,
            "selected" or "accentFill" or "greenFill" or "violetFill" or "redFill" or "slateFill" or "coralFill" => UIElementType.Highlight,
            "onFill" => UIElementType.HighlightText,
            _ => UIElementType.WindowText
        };
        return SystemColor(type, alpha);
    }

    private static Color SystemColor(UIElementType type, byte alpha = 255)
    {
        try
        {
            uiSettings ??= new UISettings();
            var c = uiSettings.UIElementColor(type);
            return Color.FromArgb(alpha, c.R, c.G, c.B);
        }
        catch
        {
            var dark = type is UIElementType.Window or UIElementType.HighlightText;
            return Hex(dark ? 0x000000u : 0xFFFFFFu, alpha);
        }
    }

    public static string StateKey(VisualState s) => s.ColorKey();

    private static readonly string[] ProjectColors = { "sky", "violet", "coral", "orange", "teal", "green", "indigo", "amber" };

    public static string ProjectKey(string path)
    {
        ulong h = 1469598103934665603;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(path))
            h = unchecked((h ^ b) * 1099511628211);
        return ProjectColors[(int)(h % (ulong)ProjectColors.Length)];
    }

    public static string BranchKey(string branch)
    {
        var b = branch.ToLowerInvariant();
        if (b is "main" or "master" or "develop" or "dev" or "staging" or "release") return "slate";
        if (b.StartsWith("feat")) return "green";
        if (b.StartsWith("fix") || b.StartsWith("hotfix") || b.StartsWith("bug")) return "amber";
        if (b.StartsWith("chore") || b.StartsWith("refactor") || b.StartsWith("docs")) return "teal";
        if (System.Text.RegularExpressions.Regex.IsMatch(b, "^[a-z]+-[0-9]+")) return "violet";
        return "muted";
    }

    public static string ProjectOptionKey(string name) => name switch
    {
        "BLUE" => "sky",
        "GREEN" => "green",
        "YELLOW" => "amber",
        "ORANGE" => "coral",
        "RED" => "red",
        "PINK" => "coral",
        "PURPLE" => "violet",
        _ => "slate"
    };

    public static string CheckKey(CheckOutcome o) => o switch
    {
        CheckOutcome.Success => "green",
        CheckOutcome.Failure => "red",
        CheckOutcome.Pending => "amber",
        _ => "muted"
    };

    public static string CheckGlyph(CheckOutcome o) => o switch
    {
        CheckOutcome.Success => "",
        CheckOutcome.Failure => "",
        CheckOutcome.Pending => "",
        CheckOutcome.Skipped => "",
        _ => ""
    };

    public static (string Glyph, string Key)? CiIcon(string? state) => state switch
    {
        "SUCCESS" => ("", "green"),
        "FAILURE" or "ERROR" => ("", "red"),
        "PENDING" or "EXPECTED" => ("", "amber"),
        _ => null
    };

    public static Color Transparent => Microsoft.UI.Colors.Transparent;
}
