using PullYard.Core.Api;
using PullYard.Core.Stacks;
using Xunit;

namespace PullYard.Core.Tests;

public class StackTreeTests
{
    private const string Repo = "acme/app";

    private static StackNode Pr(int number, string head, string @base, string state = "OPEN", bool draft = false, string? headRepo = "acme/app", string? ci = null, string? review = null, long updated = 0) =>
        new(number, $"PR {number}", state, draft, head, @base, headRepo, "dev", DateTimeOffset.FromUnixTimeSeconds(updated), review, ci, null, null);

    [Fact]
    public void LinearStack()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var tree = StackTree.Build(p1, new[] { p1, p2 }, Repo);
        Assert.NotNull(tree);
        Assert.Equal("dev", tree!.Base);
        Assert.Equal(1, tree.Root);
        Assert.Equal(new[] { 2 }, tree.ChildrenOf(1));
        Assert.Equal(1, tree.Parent[2]);
        Assert.Equal(new[] { 1, 2 }, tree.Line.Select(n => n.Number));
    }

    [Fact]
    public void BranchingStackKeepsSiblings()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var p3 = Pr(3, "p3", "p1");
        var tree = StackTree.Build(p2, new[] { p3, p1, p2 }, Repo)!;
        Assert.Equal(3, tree.Count);
        Assert.Equal(new[] { 2, 3 }, tree.ChildrenOf(1));
        Assert.True(tree.OnPath(1));
        Assert.True(tree.OnPath(2));
        Assert.False(tree.OnPath(3));
        Assert.Equal(new[] { 1, 2 }, tree.Line.Select(n => n.Number));
    }

    [Fact]
    public void UnrelatedPullRequestsOnBaseAreLeftOut()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var other = Pr(9, "other", "dev");
        var tree = StackTree.Build(p2, new[] { p1, p2, other }, Repo)!;
        Assert.Equal(new[] { 1, 2 }, tree.Nodes.Keys.OrderBy(n => n));
    }

    [Fact]
    public void SinglePullRequestIsNotAStack()
    {
        var p1 = Pr(1, "p1", "dev");
        var other = Pr(9, "other", "dev");
        Assert.Null(StackTree.Build(p1, new[] { p1, other }, Repo));
    }

    [Fact]
    public void ForkBranchWithSameNameIsNotAParent()
    {
        var fork = Pr(5, "dev", "main", headRepo: "someone/app");
        var p1 = Pr(1, "p1", "dev");
        Assert.Null(StackTree.Build(p1, new[] { fork, p1 }, Repo));
    }

    [Fact]
    public void CurrentPullRequestMissingFromOpenListIsAdded()
    {
        var merged = Pr(1, "p1", "dev", state: "MERGED");
        var p2 = Pr(2, "p2", "p1");
        var tree = StackTree.Build(merged, new[] { p2 }, Repo)!;
        Assert.Equal(1, tree.Root);
        Assert.Equal(new[] { 2 }, tree.ChildrenOf(1));
    }

    [Fact]
    public void CycleDoesNotHang()
    {
        var a = Pr(1, "a", "b");
        var b = Pr(2, "b", "a");
        var tree = StackTree.Build(a, new[] { a, b }, Repo)!;
        Assert.Equal(2, tree.Count);
        Assert.Equal(2, new StackLayout(tree).Slots.Count);
        Assert.Equal(2, StackRows.Ordered(tree).Count);
    }

    [Fact]
    public void DuplicateHeadPrefersMostRecent()
    {
        var old = Pr(1, "p1", "dev", updated: 10);
        var fresh = Pr(4, "p1", "dev", updated: 20);
        var child = Pr(2, "p2", "p1");
        var tree = StackTree.Build(child, new[] { old, fresh, child }, Repo)!;
        Assert.Equal(4, tree.Parent[2]);
    }

    [Fact]
    public void LimitAlwaysKeepsCurrentPath()
    {
        var open = new List<StackNode> { Pr(1, "root", "dev") };
        for (var n = 2; n <= 40; n++) open.Add(Pr(n, $"leaf{n}", "root"));
        var deep = Pr(100, "deep", "leaf40");
        open.Add(deep);
        var tree = StackTree.Build(deep, open, Repo, limit: 5)!;
        Assert.Contains(100, tree.Nodes.Keys);
        Assert.Contains(40, tree.Nodes.Keys);
        Assert.True(tree.Count <= 5);
    }

    [Fact]
    public void LayoutCentersParentOverChildren()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var p3 = Pr(3, "p3", "p1");
        var layout = new StackLayout(StackTree.Build(p1, new[] { p1, p2, p3 }, Repo)!);
        Assert.Equal(2, layout.Columns);
        Assert.Equal(2, layout.Levels);
        Assert.Equal(new StackSlot(0.5, 1), layout.Slots[1]);
        Assert.Equal(new StackSlot(0, 2), layout.Slots[2]);
        Assert.Equal(new StackSlot(1, 2), layout.Slots[3]);
    }

    [Fact]
    public void RowsAreDepthFirstWithDepth()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var p3 = Pr(3, "p3", "p2");
        var p4 = Pr(4, "p4", "p1");
        var tree = StackTree.Build(p1, new[] { p1, p2, p3, p4 }, Repo)!;
        Assert.Equal(new[] { (1, 0), (2, 1), (3, 2), (4, 1) }, StackRows.Ordered(tree).Select(r => (r.Node.Number, r.Depth)));
        Assert.Equal(new[] { 1, 2, 4, 3 }, StackRows.BreadthFirst(tree).Select(n => n.Number));
    }

    [Fact]
    public void SameAsComparesContent()
    {
        var p1 = Pr(1, "p1", "dev");
        var p2 = Pr(2, "p2", "p1");
        var a = StackTree.Build(p1, new[] { p1, p2 }, Repo)!;
        var b = StackTree.Build(p1, new[] { p1, p2 }, Repo)!;
        var c = StackTree.Build(p1, new[] { p1, p2 with { Title = "renamed" } }, Repo)!;
        Assert.True(a.SameAs(b));
        Assert.False(a.SameAs(c));
        Assert.False(a.SameAs(null));
    }

    [Fact]
    public void Status()
    {
        Assert.Equal(StackStatus.Draft, Pr(1, "a", "b", draft: true).Status);
        Assert.Equal(StackStatus.CiFailed, Pr(1, "a", "b", ci: "FAILURE", review: "APPROVED").Status);
        Assert.Equal(StackStatus.ChangesRequested, Pr(1, "a", "b", review: "CHANGES_REQUESTED").Status);
        Assert.Equal(StackStatus.Checking, Pr(1, "a", "b", ci: "PENDING", review: "APPROVED").Status);
        Assert.Equal(StackStatus.Ready, Pr(1, "a", "b", ci: "SUCCESS", review: "APPROVED").Status);
        Assert.Equal(StackStatus.Review, Pr(1, "a", "b", ci: "SUCCESS").Status);
        Assert.Equal(StackStatus.Merged, Pr(1, "a", "b", state: "MERGED").Status);
        Assert.Equal(StackStatus.Closed, Pr(1, "a", "b", state: "CLOSED").Status);
    }

    [Fact]
    public void JiraKey()
    {
        Assert.Equal("COM-1640", StackNode.FindJiraKey("COM-1640-fe-implement-onboarding"));
        Assert.Equal("ABC2-12", StackNode.FindJiraKey("feature/ABC2-12_fix"));
        Assert.Null(StackNode.FindJiraKey("fix-123-login"));
        Assert.Null(StackNode.FindJiraKey("release/v2-1"));
        Assert.Equal("PAY-7", (Pr(1, "plain-branch", "dev") with { Title = "PAY-7 Checkout" }).JiraKey);
    }

    [Fact]
    public void EdgesUseCurvesUpToFourChildrenAndBusAbove()
    {
        var open = new List<StackNode> { Pr(1, "root", "dev") };
        for (var n = 2; n <= 6; n++) open.Add(Pr(n, $"c{n}", "root"));
        var tree = StackTree.Build(open[1], open, Repo)!;
        var edges = StackEdges.Build(tree, new StackGeometry(new StackLayout(tree), new HashSet<int>()));
        Assert.Equal(StackEdgeKind.Line, edges[0].Kind);
        Assert.All(edges.Skip(1), e => Assert.Equal(StackEdgeKind.Elbow, e.Kind));
        Assert.Equal(2, edges.Count(e => e.Lit));

        var small = StackTree.Build(open[1], open.Take(4), Repo)!;
        var curves = StackEdges.Build(small, new StackGeometry(new StackLayout(small), new HashSet<int>()));
        Assert.All(curves.Skip(1), e => Assert.Equal(StackEdgeKind.Curve, e.Kind));
    }

    [Fact]
    public void EntriesGroupOneStackPerRoot()
    {
        StackNode N(int number, string head, string @base) => Pr(number, head, @base, updated: number);
        var open = new List<StackNode> { N(1, "a", "dev"), N(2, "b", "a"), N(3, "c", "a"), N(4, "lone", "dev") };
        var entries = StackEntry.Collect(new RepoRef("acme", "app"), new[] { 2, 3, 4 }, open);
        Assert.Single(entries);
        Assert.Equal(1, entries[0].Tree.Root);
        Assert.Equal(new[] { 2, 3 }, entries[0].Mine);
        Assert.Equal(new[] { 1, 2, 3 }, entries[0].Ordered.Select(n => n.Number));
    }
}
