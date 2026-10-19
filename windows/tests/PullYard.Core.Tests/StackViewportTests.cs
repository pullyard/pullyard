using PullYard.Core.Stacks;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class StackViewportTests
{
    private static readonly StackSize Content = new(6000, 2000);
    private static readonly StackSize View = new(1000, 700);

    [Fact]
    public void ZoomKeepsPointUnderCursor()
    {
        var start = new StackViewport(1, -2000, -500);
        var anchor = new StackPoint(300, 200);
        var before = start.ToContent(anchor);
        var next = start.Zoomed(1.4, anchor, Content, View);
        var after = next.ToContent(anchor);
        Assert.Equal(before.X, after.X, 3);
        Assert.Equal(before.Y, after.Y, 3);
    }

    [Fact]
    public void ZoomIsClampedToRange()
    {
        Assert.Equal(StackViewport.MaxZoom, StackViewport.Identity.Zoomed(50, new StackPoint(0, 0), Content, View).Zoom);
        Assert.Equal(StackViewport.MinZoom, StackViewport.Identity.Zoomed(0.001, new StackPoint(0, 0), Content, View).Zoom);
    }

    [Fact]
    public void SmallContentIsCentered()
    {
        var v = new StackViewport(1, 400, -300).Clamped(new StackSize(500, 300), View);
        Assert.Equal(250, v.PanX);
        Assert.Equal(200, v.PanY);
    }

    [Fact]
    public void PanStopsAtMargin()
    {
        var far = StackViewport.Identity.Panned(10_000, -10_000, Content, View);
        Assert.Equal(StackViewport.Margin, far.PanX);
        Assert.Equal(View.Height - Content.Height - StackViewport.Margin, far.PanY);
    }

    [Fact]
    public void CenteredPutsPointInMiddle()
    {
        var v = StackViewport.Centered(new StackPoint(3000, 1000), 1, Content, View);
        Assert.Equal(View.Width / 2, v.PanX + 3000);
        Assert.Equal(View.Height / 2, v.PanY + 1000);
    }

    [Fact]
    public void FitShowsEverything()
    {
        var v = StackViewport.Fit(new StackSize(3000, 800), View);
        Assert.True(3000 * v.Zoom <= View.Width);
        Assert.True(800 * v.Zoom <= View.Height);
        Assert.Equal((View.Width - 3000 * v.Zoom) / 2, v.PanX, 3);
    }

    [Fact]
    public void OnlyCardsInViewAreVisible()
    {
        var open = new List<StackNode> { Node(1, "root", "dev") };
        for (var n = 2; n <= 30; n++) open.Add(Node(n, $"c{n}", "root"));
        var tree = StackTree.Build(open[0], open, "acme/app")!;
        var geometry = new StackGeometry(new StackLayout(tree), new HashSet<int>());
        var vp = StackViewport.Centered(geometry.Center(2)!.Value, 1, geometry.Size, View);
        var visible = geometry.Visible(tree.Nodes.Keys, vp, View);
        Assert.Contains(2, visible);
        Assert.True(visible.Count < tree.Count / 2);
        var all = geometry.Visible(tree.Nodes.Keys, StackViewport.Fit(geometry.Size, new StackSize(20000, 4000)), new StackSize(20000, 4000));
        Assert.Equal(tree.Count, all.Count);
    }

    [Fact]
    public void NotesAddHeightOnlyToTheirLevel()
    {
        var a = Node(1, "a", "dev");
        var b = Node(2, "b", "a");
        var tree = StackTree.Build(a, new[] { a, b }, "acme/app")!;
        var plain = new StackGeometry(new StackLayout(tree), new HashSet<int>());
        var noted = new StackGeometry(new StackLayout(tree), new HashSet<int> { 1 });
        Assert.Equal(plain.Size.Height + StackMetrics.NoteGap + StackMetrics.NoteHeight, noted.Size.Height);
        Assert.Equal(plain.Origin(1), noted.Origin(1));
        Assert.Equal(plain.Bottom(1) + StackMetrics.NoteGap + StackMetrics.NoteHeight, noted.Bottom(1));
        Assert.Equal(plain.Bottom(2), noted.Bottom(2) - StackMetrics.NoteGap - StackMetrics.NoteHeight);
    }

    [Fact]
    public void TextZoomLevels()
    {
        Assert.Equal(1.0, ZoomLevels.Nearest(0));
        Assert.Equal(1.2, ZoomLevels.Nearest(1.17));
        Assert.Equal(1.1, ZoomLevels.Next(1.0));
        Assert.Equal(1.5, ZoomLevels.Next(1.5));
        Assert.Equal(0.9, ZoomLevels.Previous(1.0));
        Assert.Equal(0.8, ZoomLevels.Previous(0.8));
        Assert.Equal(0.8, ZoomLevels.Nearest(0.2));
    }

    private static StackNode Node(int number, string head, string @base) =>
        new(number, $"PR {number}", "OPEN", false, head, @base, "acme/app", null, null, null, null, null, null);
}
