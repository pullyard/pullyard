using PullYard.Core.Api;
using PullYard.Core.Html;
using Xunit;

namespace PullYard.Core.Tests;

public class DiffLayoutTests
{
    private static List<DiffLine> Lines(string patch) => DiffParser.Parse(patch);

    private static List<string> Shape(IEnumerable<SplitDiffRow> rows) =>
        rows.Select(r => r.Full ? $"full:{r.Left!.Id}" : $"{(r.Left is { } a ? a.Id.ToString() : "_")}|{(r.Right is { } b ? b.Id.ToString() : "_")}").ToList();

    [Fact]
    public void PairsRemovalsWithAdditionsInOrder()
    {
        var rows = DiffSplit.Pair(Lines("@@ -1,4 +1,3 @@\n a\n-b\n-c\n+B\n d"));
        Assert.Equal(new[] { "full:0", "1|1", "2|4", "3|_", "5|5" }, Shape(rows));
    }

    [Fact]
    public void ExtraAdditionsGetFillerOnLeft()
    {
        var rows = DiffSplit.Pair(Lines("@@ -1,2 +1,4 @@\n-x\n+X\n+Y\n+Z\n k"));
        Assert.Equal(new[] { "full:0", "1|2", "_|3", "_|4", "5|5" }, Shape(rows));
    }

    [Fact]
    public void AdditionsBeforeRemovalsDoNotPairAcrossRuns()
    {
        var rows = DiffSplit.Pair(Lines("@@ -1,1 +1,1 @@\n+new\n-old"));
        Assert.Equal(new[] { "full:0", "_|1", "2|_" }, Shape(rows));
    }

    [Fact]
    public void HunksAndMetaStayFullWidth()
    {
        var rows = DiffSplit.Pair(Lines("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n@@ -9 +9 @@\n c"));
        Assert.Equal(new[] { "full:0", "1|2", "full:3", "full:4", "5|5" }, Shape(rows));
    }

    [Fact]
    public void RemovalRunsAcrossContextAreSeparate()
    {
        var rows = DiffSplit.Pair(Lines("@@ -1,3 +1,3 @@\n-a\n m\n+b"));
        Assert.Equal(new[] { "full:0", "1|_", "2|2", "_|3" }, Shape(rows));
    }

    [Fact]
    public void LeadingColumnsCountsSpacesAndTabStops()
    {
        Assert.Equal(0, DiffText.LeadingColumns("return x"));
        Assert.Equal(4, DiffText.LeadingColumns("    return x"));
        Assert.Equal(8, DiffText.LeadingColumns("\t\treturn"));
        Assert.Equal(4, DiffText.LeadingColumns("  \treturn"));
        Assert.Equal(3, DiffText.LeadingColumns("   "));
    }

    [Fact]
    public void HangingColumnsIncludeSignAndContinuationIndent()
    {
        Assert.Equal(3, DiffText.HangingColumns("let a = 1", 40));
        Assert.Equal(11, DiffText.HangingColumns("        let a = 1", 40));
        Assert.Equal(7, DiffText.HangingColumns("\tlet a = 1", 40));
    }

    [Fact]
    public void HangingColumnsAreCappedByLimit()
    {
        Assert.Equal(20, DiffText.HangingColumns(new string(' ', 60) + "x", 20));
        Assert.Equal(0, DiffText.HangingColumns("    x", 0));
        Assert.Equal(0, DiffText.HangingColumns("    x", -5));
    }

    [Fact]
    public void ExpandTabsAlignsToTabStops()
    {
        Assert.Equal("no tabs", DiffText.ExpandTabs("no tabs"));
        Assert.Equal("    x", DiffText.ExpandTabs("\tx"));
        Assert.Equal("ab  c", DiffText.ExpandTabs("ab\tc"));
        Assert.Equal("a   b", DiffText.ExpandTabs("a\t\tb", 2));
    }

    private static DiffFile File(string name, string patch) => new(new PRFile { Filename = name, Status = "modified", Patch = patch });

    [Fact]
    public void SplitRenderUsesFourColumnRowsAndKeepsHunksFullWidth()
    {
        var html = DiffHtml.Render(new[] { File("a.cs", "@@ -1,2 +1,2 @@\n-old\n+new\n same") }, new DiffRenderOptions { Split = true });
        Assert.Contains("class=\"dt split", html);
        Assert.Contains("<td class=\"c\" colspan=\"3\">", html);
        Assert.Equal(2, CountOf(html, "<tr class=\"sp"));
    }

    [Fact]
    public void WrapRenderAddsHangingIndentAndExpandsTabs()
    {
        var html = DiffHtml.Render(new[] { File("a.txt", "@@ -1 +1 @@\n+\tvalue") }, new DiffRenderOptions { Wrap = true });
        Assert.Contains("--h:7", html);
        Assert.Contains("+    value", html);
        Assert.DoesNotContain("\t", html);
        var plain = DiffHtml.Render(new[] { File("a.txt", "@@ -1 +1 @@\n+x") }, new DiffRenderOptions { Wrap = false });
        Assert.Contains("class=\"dt nw", plain);
    }

    [Fact]
    public void HighlightsCodeButFallsBackToPlainForLongLines()
    {
        var html = DiffHtml.Render(new[] { File("a.cs", "@@ -1 +1 @@\n+return \"x\";") }, new DiffRenderOptions());
        Assert.Contains("<span class=\"k\">return</span>", html);
        var longLine = "return " + new string('a', DiffPrefs.MaxHighlightLength);
        var plain = DiffHtml.Render(new[] { File("b.cs", "@@ -1 +1 @@\n+" + longLine) }, new DiffRenderOptions());
        Assert.DoesNotContain("<span class=\"k\">", plain);
        var unknown = DiffHtml.Render(new[] { File("notes.txt", "@@ -1 +1 @@\n+return 1") }, new DiffRenderOptions());
        Assert.DoesNotContain("<span class=\"k\">", unknown);
    }

    private static int CountOf(string s, string part)
    {
        var count = 0;
        for (var i = s.IndexOf(part, StringComparison.Ordinal); i >= 0; i = s.IndexOf(part, i + part.Length, StringComparison.Ordinal)) count++;
        return count;
    }
}
