using System.Globalization;
using System.Text;

namespace PullYard.Core.Theming;

public readonly record struct SystemAccent(uint Dark1, uint Dark2, uint Light2, uint Light3)
{
    public static SystemAccent Default { get; } = new(0xFF005FB8, 0xFF003E92, 0xFF60CDFF, 0xFF99EBFF);
}

public static class ThemeTokens
{
    public readonly record struct Row(uint BrandLight, uint BrandDark, uint SystemLight, uint SystemDark)
    {
        public uint Pick(bool system, bool dark) => system ? (dark ? SystemDark : SystemLight) : (dark ? BrandDark : BrandLight);
    }

    private static Row Solid(uint brandLight, uint brandDark) => new(Opaque(brandLight), Opaque(brandDark), Opaque(brandLight), Opaque(brandDark));

    private static Row Solid(uint brandLight, uint brandDark, uint systemLight, uint systemDark) => new(Opaque(brandLight), Opaque(brandDark), Opaque(systemLight), Opaque(systemDark));

    private static Row Same(uint rgb) => Solid(rgb, rgb);

    public static uint Opaque(uint rgb) => 0xFF000000 | (rgb & 0xFFFFFF);

    public static uint WithOpacity(uint rgb, double opacity) => ((uint)Math.Round(255 * Math.Clamp(opacity, 0, 1)) << 24) | (rgb & 0xFFFFFF);

    public static uint Fade(uint argb, double opacity) => ((uint)Math.Round((argb >> 24) * Math.Clamp(opacity, 0, 1)) << 24) | (argb & 0xFFFFFF);

    private static readonly Dictionary<string, Row> Table = new()
    {
        ["window"] = Solid(0xF7F5F0, 0x0C1220, 0xF3F3F3, 0x202020),
        ["sidebar"] = new(0xFFEFECE5, 0xFF0A0F1B, 0x00FFFFFF, 0x00000000),
        ["list"] = new(0xFFF3F1EC, 0xFF0E1526, 0x80FFFFFF, 0x4C3A3A3A),
        ["panel"] = new(0xFFFDFCFA, 0xFF101828, 0xB3FFFFFF, 0x0DFFFFFF),
        ["raised"] = new(0xFFFFFFFF, 0xFF152036, 0xB3FFFFFF, 0x0DFFFFFF),
        ["overlay"] = Solid(0xFFFFFF, 0x152036, 0xF9F9F9, 0x2C2C2C),
        ["sunken"] = new(0xFFF1EEE8, 0xFF0A101C, 0x0A000000, 0x40000000),
        ["bar"] = new(0xFFF5F3EE, 0xFF111A2C, 0x00FFFFFF, 0x00000000),
        ["sub"] = new(0xFFF3F1EC, 0xFF111A2C, 0x0A000000, 0x40000000),
        ["code"] = Solid(0xF7F5F0, 0x0A101C, 0xF5F5F5, 0x1E1E1E),
        ["button"] = new(0xFFF3F1EC, 0xFF1B2740, 0xCCFFFFFF, 0x0FFFFFFF),
        ["line"] = new(WithOpacity(0x1A2333, 0.12), WithOpacity(0xA0AEC4, 0.14), 0x0F000000, 0x15FFFFFF),
        ["lineStrong"] = new(WithOpacity(0x1A2333, 0.20), WithOpacity(0xA0AEC4, 0.22), 0x1F000000, 0x28FFFFFF),
        ["cardLine"] = new(WithOpacity(0x1A2333, 0.08), WithOpacity(0xA0AEC4, 0.10), 0x0F000000, 0x19000000),
        ["text"] = new(0xFF1A2333, 0xFFE6EBF2, 0xE4000000, 0xFFFFFFFF),
        ["muted"] = new(0xFF5F6B7E, 0xFF8693A8, 0x9E000000, 0xC5FFFFFF),
        ["dim"] = new(0xFF646C80, 0xFF7D899F, 0x9E000000, 0x87FFFFFF),
        ["gutter"] = new(0xFF687084, 0xFF7D899F, 0x9E000000, 0x87FFFFFF),
        ["accent"] = Solid(0x2A8BC8, 0x5BB8EC),
        ["link"] = Solid(0x1F6FA3, 0x5BB8EC),
        ["green"] = Solid(0x2E8A57, 0x5DBE8A, 0x0F7B0F, 0x6CCB5F),
        ["red"] = Solid(0xC2412F, 0xE8746A, 0xC42B1C, 0xFF99A4),
        ["amber"] = Solid(0xB7791F, 0xE8B44C, 0x9D5D00, 0xFCE100),
        ["violet"] = Solid(0x6B55D6, 0x9D8CF0),
        ["coral"] = Solid(0xD8513F, 0xEE6F5F),
        ["teal"] = Solid(0x23877A, 0x56C2B0),
        ["indigo"] = Solid(0x4E5BC4, 0x8C97E8),
        ["slate"] = Solid(0x6B7486, 0x939CB0),
        ["orange"] = Solid(0xC7651A, 0xF0954A),
        ["amberText"] = Solid(0x9A6416, 0xE8B44C, 0x9D5D00, 0xFCE100),
        ["amberInk"] = Solid(0x9A6416, 0xE8B44C, 0x9D5D00, 0xFCE100),
        ["greenText"] = Solid(0x23703F, 0x5DBE8A, 0x0F7B0F, 0x6CCB5F),
        ["coralText"] = Solid(0xB8412F, 0xEE6F5F),
        ["coralInk"] = Solid(0xB8412F, 0xEE6F5F),
        ["harborLine"] = new(WithOpacity(0x1F6FA3, 0.22), WithOpacity(0x7DD3FC, 0.20), 0x33005FB8, 0x3360CDFF),
        ["wake"] = new(WithOpacity(0x1F6FA3, 0.55), WithOpacity(0x7DD3FC, 0.75), 0x8C005FB8, 0xBF60CDFF),
        ["addWord"] = new(WithOpacity(0x2E8A57, 0.26), WithOpacity(0x5DBE8A, 0.28), WithOpacity(0x0F7B0F, 0.28), WithOpacity(0x6CCB5F, 0.30)),
        ["delWord"] = new(WithOpacity(0xC2412F, 0.22), WithOpacity(0xE8746A, 0.28), WithOpacity(0xC42B1C, 0.26), WithOpacity(0xFF99A4, 0.30)),
        ["accentFill"] = Same(0x1D70A6),
        ["greenFill"] = Same(0x2B7F50),
        ["violetFill"] = Same(0x5E48C8),
        ["redFill"] = Same(0xB23A2A),
        ["slateFill"] = Same(0x5B6476),
        ["coralFill"] = Same(0xC24533),
        ["onCoral"] = Same(0xFFFFFF),
        ["onFill"] = Same(0xFFFFFF),
        ["hover"] = new(WithOpacity(0x1A2333, 0.04), WithOpacity(0xE6EBF2, 0.05), 0x09000000, 0x0FFFFFFF),
        ["selected"] = new(WithOpacity(0x1A2333, 0.07), WithOpacity(0xE6EBF2, 0.08), 0x0F000000, 0x15FFFFFF)
    };

    public static IReadOnlyCollection<string> Keys => Table.Keys;

    public static bool Has(string key) => key == "sky" || Table.ContainsKey(key);

    public static uint Resolve(string key, bool system, bool dark, SystemAccent? accent = null)
    {
        if (key == "sky") key = "link";
        if (system)
        {
            var tint = accent ?? SystemAccent.Default;
            switch (key)
            {
                case "accent": return Opaque(dark ? tint.Light2 : tint.Dark1);
                case "link": return Opaque(dark ? tint.Light3 : tint.Dark2);
                case "accentFill": return Opaque(tint.Dark1);
            }
        }
        if (!Table.TryGetValue(key, out var row)) row = Table["muted"];
        return row.Pick(system, dark);
    }

    public static string FillKey(string key) => key switch
    {
        "accent" or "sky" or "link" => "accentFill",
        "green" => "greenFill",
        "violet" => "violetFill",
        "red" => "redFill",
        "slate" or "muted" or "dim" => "slateFill",
        "coral" => "coralFill",
        _ => key
    };

    public static string TextKey(string key) => key switch
    {
        "amber" => "amberInk",
        "green" => "greenText",
        "coral" => "coralInk",
        "sky" => "link",
        _ => key
    };

    public static uint Over(uint top, uint bottom)
    {
        var a = (top >> 24) / 255.0;
        uint Mix(int shift)
        {
            var t = (top >> shift) & 0xFF;
            var b = (bottom >> shift) & 0xFF;
            return (uint)Math.Round(t * a + b * (1 - a)) & 0xFF;
        }
        return 0xFF000000 | (Mix(16) << 16) | (Mix(8) << 8) | Mix(0);
    }

    public static double Luminance(uint rgb)
    {
        static double Channel(uint v)
        {
            var c = v / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Channel((rgb >> 16) & 0xFF) + 0.7152 * Channel((rgb >> 8) & 0xFF) + 0.0722 * Channel(rgb & 0xFF);
    }

    public static double Contrast(uint foreground, uint background)
    {
        var a = Luminance(Over(foreground, background));
        var b = Luminance(background);
        return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }

    public static string Css(uint argb)
    {
        var a = argb >> 24;
        var r = (argb >> 16) & 0xFF;
        var g = (argb >> 8) & 0xFF;
        var b = argb & 0xFF;
        if (a == 255) return $"#{r:x2}{g:x2}{b:x2}";
        return $"rgba({r},{g},{b},{(a / 255.0).ToString("0.###", CultureInfo.InvariantCulture)})";
    }

    public static string CssVars(Func<string, uint> resolve, bool dark, bool opaquePage)
    {
        var sb = new StringBuilder(":root{");
        void Add(string name, string value) => sb.Append("--").Append(name).Append(':').Append(value).Append(';');
        void Key(string name, string key) => Add(name, Css(resolve(key)));
        void Tint(string name, string key, double opacity) => Add(name, Css(Fade(resolve(key), opacity)));
        Key("fg", "text");
        Key("muted", "muted");
        Key("dim", "dim");
        Key("gutter", "gutter");
        Key("border", "line");
        Key("sub", "sub");
        Key("card", "raised");
        Key("raised", "overlay");
        Key("sunken", "sunken");
        Key("code", "code");
        Key("button", "button");
        Key("hover", "hover");
        Key("link", "link");
        Key("sky", "link");
        Key("accent", "accent");
        Key("green", "green");
        Key("red", "red");
        Key("amber", "amber");
        Key("purple", "violet");
        Key("coral", "coral");
        Key("teal", "teal");
        Key("indigo", "indigo");
        Key("k", "coral");
        Key("fill", "accentFill");
        Key("greenfill", "greenFill");
        Key("redfill", "redFill");
        Key("purplefill", "violetFill");
        Key("coralfill", "coralFill");
        Key("coralink", "coralInk");
        Key("amberink", "amberInk");
        Key("oncoral", "onCoral");
        Key("harbor", "harborLine");
        Key("wake", "wake");
        Key("addword", "addWord");
        Key("delword", "delWord");
        Tint("add", "green", dark ? 0.14 : 0.12);
        Tint("del", "red", dark ? 0.14 : 0.11);
        Tint("hunkbg", "link", 0.08);
        Tint("mine", "link", 0.08);
        Tint("coralbg", "coral", dark ? 0.08 : 0.06);
        Tint("pending", "amber", 0.25);
        Add("page", opaquePage ? Css(resolve("panel")) : "transparent");
        Add("onaccent", dark ? "#0c1220" : "#ffffff");
        sb.Append("color-scheme:").Append(dark ? "dark" : "light").Append(";}");
        return sb.ToString();
    }

    public static string CssVars(bool system, bool dark, SystemAccent? accent = null) =>
        CssVars(key => Resolve(key, system, dark, accent), dark, !system);
}
