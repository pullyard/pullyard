using PullYard.Core.Api;
using PullYard.Core.Html;
using Xunit;

namespace PullYard.Core.Tests;

public class DiffExpandTests
{
    private static DiffFile File(string name, string patch, string status = "modified") => new(new PRFile { Filename = name, Status = status, Patch = patch });

    private static int CountOf(string s, string part)
    {
        var count = 0;
        for (var i = s.IndexOf(part, StringComparison.Ordinal); i >= 0; i = s.IndexOf(part, i + part.Length, StringComparison.Ordinal)) count++;
        return count;
    }

    [Fact]
    public void FullFileFillsGapsAroundHunk()
    {
        var lines = DiffParser.Parse("@@ -3,2 +3,2 @@\n line3\n-old4\n+new4");
        var full = DiffExpand.FullFile(lines, new[] { "line1", "line2", "line3", "new4", "line5" });
        Assert.Equal(new[] { "line1", "line2", "line3", "old4", "new4", "line5" }, full.Select(l => l.Text));
        Assert.Equal(1, full[0].OldLine);
        Assert.True(full[0].OutsideHunk);
        Assert.Equal(5, full[^1].NewLine);
        Assert.Equal(5, full[^1].OldLine);
        Assert.False(full[0].Commentable);
        Assert.True(full[2].Commentable);
        Assert.Equal(Enumerable.Range(0, full.Count), full.Select(l => l.Id));
    }

    [Fact]
    public void FullFileKeepsOffsetsBetweenHunks()
    {
        var patch = "@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10,2 +11,2 @@\n j\n-k\n+K";
        var text = "a\nb\nc\n3\n4\n5\n6\n7\n8\n9\nj\nK\nz\n";
        var full = DiffExpand.FullFile(DiffParser.Parse(patch), text);
        Assert.Equal(new[] { "a", "b", "c", "3", "4", "5", "6", "7", "8", "9", "j", "k", "K", "z" }, full.Select(l => l.Text));
        var three = full.Single(l => l.Text == "3");
        Assert.Equal(3, three.OldLine);
        Assert.Equal(4, three.NewLine);
        Assert.True(three.OutsideHunk);
        var tail = full[^1];
        Assert.Equal(12, tail.OldLine);
        Assert.Equal(13, tail.NewLine);
        Assert.DoesNotContain(full, l => l.Kind is DiffLineKind.Hunk or DiffLineKind.Meta);
        Assert.All(full.Where(l => l.Kind != DiffLineKind.Context), l => Assert.False(l.OutsideHunk));
    }

    [Fact]
    public void FullFileStopsAtTheEndOfTheText()
    {
        var full = DiffExpand.FullFile(DiffParser.Parse("@@ -1 +1 @@\n-x\n+y"), new[] { "y" });
        Assert.Equal(new[] { "x", "y" }, full.Select(l => l.Text));
    }

    [Fact]
    public void HeaderParsesCountsAndDefaults()
    {
        var h = DiffExpand.Header("@@ -10 +12,3 @@ func");
        Assert.Equal(new DiffHunkHeader(10, 1, 12, 3), h);
        Assert.Null(DiffExpand.Header("not a hunk"));
    }

    [Fact]
    public void SplitLinesDropsTrailingNewlineAndCarriageReturns()
    {
        Assert.Equal(new[] { "a", "b" }, DiffExpand.SplitLines("a\r\nb\n"));
        Assert.Equal(new[] { "a", "", "b" }, DiffExpand.SplitLines("a\n\nb"));
        Assert.Empty(DiffExpand.SplitLines(""));
    }

    [Fact]
    public void CanExpandRejectsHugeFiles()
    {
        Assert.True(DiffExpand.CanExpand(string.Concat(Enumerable.Repeat("x\n", DiffExpand.MaxLines))));
        Assert.False(DiffExpand.CanExpand(string.Concat(Enumerable.Repeat("x\n", DiffExpand.MaxLines + 1))));
    }

    [Fact]
    public void HeaderOffersFullFileOnlyWhenEnabled()
    {
        var file = File("a.cs", "@@ -1 +1 @@\n-x\n+y");
        Assert.Contains("postFile(this,'fullFile')", DiffHtml.Render(new[] { file }, new DiffRenderOptions { ShowFullFile = true }));
        Assert.DoesNotContain("fullFile", DiffHtml.Render(new[] { file }, new DiffRenderOptions()));
        var removed = File("b.cs", "@@ -1 +0,0 @@\n-x", "removed");
        Assert.DoesNotContain("fullFile", DiffHtml.Render(new[] { removed }, new DiffRenderOptions { ShowFullFile = true }));
    }

    [Fact]
    public void FullFileRenderShowsWholeFileAndLimitsComments()
    {
        var file = File("a.cs", "@@ -3,2 +3,2 @@\n line3\n-old4\n+new4");
        var options = new DiffRenderOptions
        {
            Commentable = true,
            ShowFullFile = true,
            FullFiles = new Dictionary<string, string> { ["a.cs"] = "line1\nline2\nline3\nnew4\nline5\n" }
        };
        var html = DiffHtml.Render(new[] { file }, options);
        Assert.Contains("postFile(this,'changesOnly')", html);
        Assert.Contains("Show changes only", html);
        Assert.DoesNotContain("'fullFile'", html);
        Assert.DoesNotContain("<tr class=\"hk\">", html);
        Assert.Contains("line1", html);
        Assert.Contains("line5", html);
        Assert.Equal(6, CountOf(html, "data-c="));
        Assert.Contains("data-c=\"a.cs|RIGHT|4\"", html);
        Assert.DoesNotContain("a.cs|RIGHT|5", html);
        Assert.Equal(1, CountOf(html, "<tr class=\"hs\">"));
    }

    [Fact]
    public void FullFileRenderWorksInSplitView()
    {
        var file = File("a.txt", "@@ -2 +2 @@\n-b\n+B");
        var html = DiffHtml.Render(new[] { file }, new DiffRenderOptions
        {
            Commentable = true,
            Split = true,
            FullFiles = new Dictionary<string, string> { ["a.txt"] = "a\nB\nc" }
        });
        Assert.Equal(3, CountOf(html, "<tr class=\"sp"));
        Assert.Equal(1, CountOf(html, "<tr class=\"sp hs\">"));
        Assert.Equal(2, CountOf(html, "data-c="));
    }

    [Fact]
    public void TooLargeFullFileFallsBackToChanges()
    {
        var file = File("a.txt", "@@ -1 +1 @@\n-x\n+y");
        var html = DiffHtml.Render(new[] { file }, new DiffRenderOptions
        {
            FullFiles = new Dictionary<string, string> { ["a.txt"] = string.Concat(Enumerable.Repeat("y\n", DiffExpand.MaxLines + 1)) }
        });
        Assert.Contains("too large to show in full", html);
        Assert.Contains("<tr class=\"hk\">", html);
        Assert.Contains("'changesOnly'", html);
    }
}
