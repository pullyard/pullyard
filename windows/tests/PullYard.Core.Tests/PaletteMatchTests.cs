using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class PaletteMatchTests
{
    [Fact]
    public void PrefixBeatsWordBoundaryBeatsInnerMatchBeatsFuzzy()
    {
        Assert.Equal(1000, PaletteMatch.Score("refresh", "ref"));
        Assert.Equal(797, PaletteMatch.Score("go refresh", "ref"));
        Assert.Equal(599, PaletteMatch.Score("prefresh", "ref"));
        Assert.Equal(296, PaletteMatch.Score("rxef", "ref"));
        Assert.Null(PaletteMatch.Score("abc", "z"));
    }

    [Fact]
    public void EveryTokenMustMatchTitleOrHalfWeightExtra()
    {
        var tokens = PaletteMatch.Tokens("Zoom text");
        Assert.Equal(new[] { "zoom", "text" }, tokens);
        Assert.Equal(1000 + 500, PaletteMatch.Score("Zoom In", "text size bigger", tokens));
        Assert.Null(PaletteMatch.Score("Zoom In", "bigger", tokens));
        Assert.Equal(0, PaletteMatch.Score("anything", "", PaletteMatch.Tokens("   ")));
    }

    [Fact]
    public void RankKeepsOriginalOrderForTies()
    {
        var items = new[] { "Zoom Out", "Zoom In", "Refresh" };
        Assert.Equal(new[] { "Zoom Out", "Zoom In" }, PaletteMatch.Rank(items, PaletteMatch.Tokens("zoom"), s => s, _ => ""));
        Assert.Equal(items, PaletteMatch.Rank(items, PaletteMatch.Tokens(""), s => s, _ => ""));
    }
}
