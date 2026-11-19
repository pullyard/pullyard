using PullYard.Core.Html;
using PullYard.Core.Theming;
using Xunit;

namespace PullYard.Core.Tests;

public class ThemeTokensTests
{
    private static readonly uint White = 0xFFFFFFFF;

    private static uint Backdrop(bool system, bool dark) => ThemeTokens.Resolve("window", system, dark);

    private static uint Surface(string key, bool system, bool dark) => ThemeTokens.Over(ThemeTokens.Resolve(key, system, dark), Backdrop(system, dark));

    [Fact]
    public void BrandAndSystemResolveDifferentSurfaces()
    {
        Assert.Equal(0xFFFDFCFAu, ThemeTokens.Resolve("panel", false, false));
        Assert.Equal(0xFF101828u, ThemeTokens.Resolve("panel", false, true));
        Assert.Equal(0xB3FFFFFFu, ThemeTokens.Resolve("panel", true, false));
        Assert.Equal(0x0DFFFFFFu, ThemeTokens.Resolve("panel", true, true));
        Assert.Equal(0x80FFFFFFu, ThemeTokens.Resolve("list", true, false));
        Assert.Equal(0x4C3A3A3Au, ThemeTokens.Resolve("list", true, true));
        Assert.Equal(0u, ThemeTokens.Resolve("sidebar", true, true) >> 24);
        Assert.Equal(0u, ThemeTokens.Resolve("bar", true, false) >> 24);
    }

    [Fact]
    public void LinesUseTheSpecifiedOpacity()
    {
        Assert.Equal(0x141A2333u, ThemeTokens.Resolve("line", false, false));
        Assert.Equal(0x1AA0AEC4u, ThemeTokens.Resolve("line", false, true));
        Assert.Equal(0x261A2333u, ThemeTokens.Resolve("lineStrong", false, false));
        Assert.Equal(0x2EA0AEC4u, ThemeTokens.Resolve("lineStrong", false, true));
        Assert.Equal(0x0F000000u, ThemeTokens.Resolve("line", true, false));
        Assert.Equal(0x28FFFFFFu, ThemeTokens.Resolve("lineStrong", true, true));
    }

    [Fact]
    public void SystemStyleTakesAccentFromTheSystem()
    {
        var accent = new SystemAccent(0xFF8E562E, 0xFF6B3F1F, 0xFFE0B48C, 0xFFF0D4BC);
        Assert.Equal(0xFF8E562Eu, ThemeTokens.Resolve("accent", true, false, accent));
        Assert.Equal(0xFFE0B48Cu, ThemeTokens.Resolve("accent", true, true, accent));
        Assert.Equal(0xFF6B3F1Fu, ThemeTokens.Resolve("link", true, false, accent));
        Assert.Equal(0xFFF0D4BCu, ThemeTokens.Resolve("sky", true, true, accent));
        Assert.Equal(0xFF8E562Eu, ThemeTokens.Resolve("accentFill", true, true, accent));
        Assert.Equal(0xFF2A8BC8u, ThemeTokens.Resolve("accent", false, false, accent));
        Assert.Equal(0xFF1D70A6u, ThemeTokens.Resolve("accentFill", false, true, accent));
    }

    [Fact]
    public void UnknownKeyFallsBackToMuted()
    {
        Assert.Equal(ThemeTokens.Resolve("muted", false, true), ThemeTokens.Resolve("nope", false, true));
        Assert.False(ThemeTokens.Has("nope"));
        Assert.True(ThemeTokens.Has("sky"));
    }

    [Theory]
    [InlineData("accentFill")]
    [InlineData("greenFill")]
    [InlineData("violetFill")]
    [InlineData("redFill")]
    [InlineData("slateFill")]
    [InlineData("coralFill")]
    public void FillsCarryWhiteTextInEveryMode(string key)
    {
        foreach (var system in new[] { false, true })
        foreach (var dark in new[] { false, true })
        {
            Assert.True(ThemeTokens.Contrast(White, ThemeTokens.Resolve(key, system, dark)) >= 4.5, $"{key} system={system} dark={dark}");
            Assert.Equal(White, ThemeTokens.Resolve("onFill", system, dark));
        }
    }

    [Theory]
    [InlineData("text", 7.0)]
    [InlineData("muted", 4.5)]
    [InlineData("dim", 4.0)]
    public void TextStaysLegibleOnEverySurface(string key, double minimum)
    {
        foreach (var system in new[] { false, true })
        foreach (var dark in new[] { false, true })
        foreach (var surface in new[] { "list", "panel", "raised" })
        {
            var background = Surface(surface, system, dark);
            var ratio = ThemeTokens.Contrast(ThemeTokens.Resolve(key, system, dark), background);
            Assert.True(ratio >= minimum, $"{key} on {surface} system={system} dark={dark}: {ratio:0.00}");
        }
    }

    [Theory]
    [InlineData("amber")]
    [InlineData("green")]
    [InlineData("coral")]
    [InlineData("sky")]
    public void SmallColouredTextUsesLegibleVariants(string key)
    {
        var text = ThemeTokens.TextKey(key);
        foreach (var system in new[] { false, true })
        foreach (var dark in new[] { false, true })
        {
            var ratio = ThemeTokens.Contrast(ThemeTokens.Resolve(text, system, dark), Surface("raised", system, dark));
            Assert.True(ratio >= 4.5, $"{text} system={system} dark={dark}: {ratio:0.00}");
        }
    }

    [Fact]
    public void FillKeysMapStateColours()
    {
        Assert.Equal("accentFill", ThemeTokens.FillKey("accent"));
        Assert.Equal("greenFill", ThemeTokens.FillKey("green"));
        Assert.Equal("violetFill", ThemeTokens.FillKey("violet"));
        Assert.Equal("redFill", ThemeTokens.FillKey("red"));
        Assert.Equal("slateFill", ThemeTokens.FillKey("slate"));
        Assert.Equal("coralFill", ThemeTokens.FillKey("coral"));
        Assert.Equal("amber", ThemeTokens.FillKey("amber"));
    }

    [Fact]
    public void ContrastAndCompositingMatchKnownValues()
    {
        Assert.Equal(21.0, ThemeTokens.Contrast(0xFF000000, White), 2);
        Assert.Equal(1.0, ThemeTokens.Contrast(White, White), 2);
        Assert.Equal(0xFF7F7F7Fu, ThemeTokens.Over(0x80000000, White));
        Assert.Equal(0x0AFFFFFFu, ThemeTokens.Fade(0x14FFFFFF, 0.5));
    }

    [Fact]
    public void CssFormatsOpaqueAndTranslucentColours()
    {
        Assert.Equal("#1a2333", ThemeTokens.Css(0xFF1A2333));
        Assert.Equal("rgba(255,255,255,0.702)", ThemeTokens.Css(0xB3FFFFFF));
        Assert.Equal("rgba(0,0,0,0)", ThemeTokens.Css(0x00000000));
    }

    [Fact]
    public void CssVarsFollowTheActiveStyle()
    {
        var brand = ThemeTokens.CssVars(false, true);
        Assert.Contains("--fg:#e6ebf2;", brand);
        Assert.Contains("--page:#101828;", brand);
        Assert.Contains("--fill:#1d70a6;", brand);
        Assert.Contains("color-scheme:dark;", brand);
        var system = ThemeTokens.CssVars(true, false);
        Assert.Contains("--fg:rgba(0,0,0,0.894);", system);
        Assert.Contains("--page:transparent;", system);
        Assert.Contains("--green:#0f7b0f;", system);
        Assert.Contains("--raised:#f9f9f9;", system);
        Assert.Contains("--code:#f5f5f5;", system);
        Assert.Contains("--card:rgba(255,255,255,0.702);", system);
        Assert.Contains("color-scheme:light;", system);
        Assert.DoesNotContain("#0969da", system);
    }

    [Fact]
    public void ConversationCssUsesSuppliedVars()
    {
        var before = ConversationHtml.Vars;
        try
        {
            ConversationHtml.Vars = ":root{--fg:#123456;}";
            Assert.StartsWith(":root{--fg:#123456;}", ConversationHtml.Css);
            ConversationHtml.Vars = null;
            Assert.StartsWith(":root{--fg:", ConversationHtml.Css);
            Assert.DoesNotContain("#cf222e", ConversationHtml.Css);
        }
        finally
        {
            ConversationHtml.Vars = before;
        }
    }
}
