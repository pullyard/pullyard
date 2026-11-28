using PullYard.Core.Api;
using PullYard.Core.Html;
using Xunit;

namespace PullYard.Core.Tests;

public class DiffIntralineTests
{
    private static DiffLine Line(int id, DiffLineKind kind, string text, int? oldLine, int? newLine) =>
        new() { Id = id, Kind = kind, Text = text, OldLine = oldLine, NewLine = newLine };

    private static DiffFile File(string name, string patch) => new(new PRFile { Filename = name, Status = "modified", Patch = patch });

    [Fact]
    public void ChangedRangeFindsMiddle()
    {
        Assert.Equal(new IntralineRange(14, 2), DiffIntraline.ChangedRange("let timeout = 30", "let timeout = 45"));
    }

    [Fact]
    public void ChangedRangeSkipsUnrelatedLines()
    {
        Assert.Null(DiffIntraline.ChangedRange("return value", "import Foundation"));
    }

    [Fact]
    public void ChangedRangeSkipsIdenticalLines()
    {
        Assert.Null(DiffIntraline.ChangedRange("same", "same"));
    }

    [Fact]
    public void ChangedRangeMarksOnlyTheSideWithInsertedText()
    {
        Assert.Null(DiffIntraline.ChangedRange("ab", "aXb"));
        Assert.Equal(new IntralineRange(1, 1), DiffIntraline.ChangedRange("aXb", "ab"));
    }

    [Fact]
    public void ChangedRangeSkipsEmptyAndLongLines()
    {
        Assert.Null(DiffIntraline.ChangedRange("", "x"));
        var longLine = new string('a', DiffIntraline.MaxLength) + "b";
        Assert.Null(DiffIntraline.ChangedRange(longLine, longLine + "c"));
    }

    [Fact]
    public void ChangedRangeKeepsSurrogatePairsWhole()
    {
        Assert.Equal(new IntralineRange(1, 2), DiffIntraline.ChangedRange("x\U0001F600y", "x\U0001F603y"));
    }

    [Fact]
    public void PartnersPairDeletionsWithAdditionsInOrder()
    {
        var lines = new[]
        {
            Line(1, DiffLineKind.Del, "a = 1", 1, null),
            Line(2, DiffLineKind.Del, "b = 2", 2, null),
            Line(3, DiffLineKind.Add, "a = 3", null, 1),
            Line(4, DiffLineKind.Context, "c", 3, 2),
            Line(5, DiffLineKind.Add, "d = 4", null, 3),
        };
        var pairs = DiffIntraline.Partners(lines);
        Assert.Equal("a = 3", pairs[1]);
        Assert.Equal("a = 1", pairs[3]);
        Assert.False(pairs.ContainsKey(2));
        Assert.False(pairs.ContainsKey(5));
    }

    [Fact]
    public void PartnersRestartAfterADeletionFollowsAdditions()
    {
        var pairs = DiffIntraline.Partners(DiffParser.Parse("@@ -1,2 +1,2 @@\n-a\n+b\n-c\n+d"));
        Assert.Equal("b", pairs[1]);
        Assert.Equal("a", pairs[2]);
        Assert.Equal("d", pairs[3]);
        Assert.Equal("c", pairs[4]);
    }

    [Fact]
    public void PartnersDoNotCrossHunks()
    {
        var pairs = DiffIntraline.Partners(DiffParser.Parse("@@ -1 +1 @@\n-a\n@@ -5 +5 @@\n+b"));
        Assert.Empty(pairs);
    }

    [Fact]
    public void MarkRangeCountsEntitiesAsOneCharacter()
    {
        Assert.Equal("a <span class=\"x\">&lt;</span> b", DiffHtml.MarkRange("a &lt; b", 2, 1, "x"));
        Assert.Equal("<span class=\"x\">&#39;q&#39;</span>", DiffHtml.MarkRange("&#39;q&#39;", 0, 3, "x"));
    }

    [Fact]
    public void MarkRangeReopensAcrossSyntaxSpans()
    {
        var html = DiffHtml.MarkRange("<span class=\"k\">let</span> x", 1, 4, "x");
        Assert.Equal("<span class=\"k\">l<span class=\"x\">et</span></span><span class=\"x\"> x</span>", html);
    }

    [Fact]
    public void MarkRangeIgnoresEmptyRanges()
    {
        Assert.Equal("abc", DiffHtml.MarkRange("abc", 1, 0, "x"));
    }

    [Fact]
    public void UnifiedRenderHighlightsChangedSpans()
    {
        var html = DiffHtml.Render(new[] { File("a.cs", "@@ -1 +1 @@\n-let timeout = 30\n+let timeout = 45") }, new DiffRenderOptions());
        Assert.Contains("<span class=\"iwd\">30</span>", html);
        Assert.Contains("<span class=\"iwa\">45</span>", html);
    }

    [Fact]
    public void SplitRenderHighlightsChangedSpansAndEscapes()
    {
        var html = DiffHtml.Render(new[] { File("a.txt", "@@ -1 +1 @@\n-if (a < b) go\n+if (a > b) go") }, new DiffRenderOptions { Split = true });
        Assert.Contains("<span class=\"iwd\">&lt;</span>", html);
        Assert.Contains("<span class=\"iwa\">&gt;</span>", html);
    }

    [Fact]
    public void UnrelatedPairsGetNoHighlight()
    {
        var html = DiffHtml.Render(new[] { File("a.txt", "@@ -1 +1 @@\n-return value\n+import Foundation") }, new DiffRenderOptions());
        Assert.DoesNotContain("class=\"iwa\"", html);
        Assert.DoesNotContain("class=\"iwd\"", html);
    }

    [Fact]
    public void CommentableGutterUsesItsOwnClass()
    {
        var html = DiffHtml.Render(new[] { File("a.txt", "@@ -1 +1 @@\n+x") }, new DiffRenderOptions { Commentable = true });
        Assert.Contains("class=\"g ca\" data-c=\"a.txt|RIGHT|1\"", html);
        Assert.DoesNotContain("g cm", html);
    }
}
