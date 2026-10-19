using System.Text.RegularExpressions;
using PullYard.Core.Api;

namespace PullYard.Core.Stacks;

public sealed record StackNode(
    int Number,
    string Title,
    string State,
    bool IsDraft,
    string HeadRefName,
    string BaseRefName,
    string? HeadRepo,
    string? Author,
    DateTimeOffset? UpdatedAt,
    string? ReviewDecision,
    string? Ci,
    string? CommitOid,
    string? CommitHeadline)
{
    private static readonly Regex JiraPattern = new("(?<![A-Za-z0-9])[A-Z][A-Z0-9]+-[0-9]+(?![0-9])", RegexOptions.Compiled);

    public VisualState VisualState => VisualStates.Pr(State, IsDraft);

    public StackStatus Status => StackStatuses.Of(this);

    public string? JiraKey => FindJiraKey(HeadRefName) ?? FindJiraKey(Title);

    public StackNode Merging(StackNode fresh) => new(Number, fresh.Title, fresh.State, fresh.IsDraft, fresh.HeadRefName, fresh.BaseRefName,
        fresh.HeadRepo ?? HeadRepo, fresh.Author ?? Author, fresh.UpdatedAt ?? UpdatedAt, fresh.ReviewDecision ?? ReviewDecision,
        fresh.Ci ?? Ci, fresh.CommitOid ?? CommitOid, fresh.CommitHeadline ?? CommitHeadline);

    public static string? FindJiraKey(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var m = JiraPattern.Match(text);
        return m.Success ? m.Value : null;
    }
}

public enum StackStatus { Merged, Closed, Draft, CiFailed, ChangesRequested, Ready, Checking, Review }

public static class StackStatuses
{
    public static StackStatus Of(StackNode n) => n.State switch
    {
        "MERGED" => StackStatus.Merged,
        "CLOSED" => StackStatus.Closed,
        _ when n.IsDraft => StackStatus.Draft,
        _ when n.Ci is "FAILURE" or "ERROR" => StackStatus.CiFailed,
        _ when n.ReviewDecision == "CHANGES_REQUESTED" => StackStatus.ChangesRequested,
        _ when n.Ci is "PENDING" or "EXPECTED" => StackStatus.Checking,
        _ when n.ReviewDecision == "APPROVED" => StackStatus.Ready,
        _ => StackStatus.Review
    };

    public static string ColorKey(this StackStatus s) => s switch
    {
        StackStatus.Merged => "violet",
        StackStatus.Closed or StackStatus.CiFailed or StackStatus.ChangesRequested => "red",
        StackStatus.Draft => "slate",
        StackStatus.Ready => "green",
        _ => "amber"
    };

    public static bool NeedsAttention(this StackStatus s) => s is StackStatus.CiFailed or StackStatus.ChangesRequested;
}

public sealed class StackTree
{
    public string Base { get; }
    public int Current { get; }
    public int Root { get; }
    public IReadOnlyDictionary<int, StackNode> Nodes { get; }
    public IReadOnlyDictionary<int, int> Parent { get; }
    public IReadOnlyDictionary<int, IReadOnlyList<int>> Children { get; }

    public StackTree(string @base, int current, int root, Dictionary<int, StackNode> nodes, Dictionary<int, int> parent, Dictionary<int, IReadOnlyList<int>> children)
    {
        Base = @base;
        Current = current;
        Root = root;
        Nodes = nodes;
        Parent = parent;
        Children = children;
    }

    public int Count => Nodes.Count;

    public IReadOnlyList<int> ChildrenOf(int number) => Children.TryGetValue(number, out var c) ? c : Array.Empty<int>();

    public StackNode? ParentNode(int number) => Parent.TryGetValue(number, out var p) && Nodes.TryGetValue(p, out var n) ? n : null;

    public List<StackNode> Line
    {
        get
        {
            var numbers = new List<int>();
            int? n = Current;
            var seen = new HashSet<int>();
            while (n is { } x && seen.Add(x))
            {
                numbers.Insert(0, x);
                n = Parent.TryGetValue(x, out var p) ? p : null;
            }
            var down = Current;
            while (ChildrenOf(down) is { Count: > 0 } kids && seen.Add(kids[0]))
            {
                numbers.Add(kids[0]);
                down = kids[0];
            }
            return numbers.Where(Nodes.ContainsKey).Select(x => Nodes[x]).ToList();
        }
    }

    private HashSet<int>? pathSet;

    public HashSet<int> PathSet
    {
        get
        {
            if (pathSet is not null) return pathSet;
            var output = new HashSet<int>();
            int? n = Current;
            while (n is { } x && output.Add(x)) n = Parent.TryGetValue(x, out var p) ? p : null;
            var stack = new Stack<int>(ChildrenOf(Current));
            while (stack.Count > 0)
            {
                var x = stack.Pop();
                if (!output.Add(x)) continue;
                foreach (var c in ChildrenOf(x)) stack.Push(c);
            }
            pathSet = output;
            return output;
        }
    }

    public bool OnPath(int number) => PathSet.Contains(number);

    public bool SameAs(StackTree? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (Base != other.Base || Current != other.Current || Root != other.Root || Nodes.Count != other.Nodes.Count || Parent.Count != other.Parent.Count || Children.Count != other.Children.Count) return false;
        foreach (var (k, v) in Nodes)
            if (!other.Nodes.TryGetValue(k, out var o) || o != v) return false;
        foreach (var (k, v) in Parent)
            if (!other.Parent.TryGetValue(k, out var o) || o != v) return false;
        foreach (var (k, v) in Children)
            if (!other.Children.TryGetValue(k, out var o) || !o.SequenceEqual(v)) return false;
        return true;
    }

    public static StackTree? Build(StackNode current, IEnumerable<StackNode> open, string repo, int limit = 60)
    {
        var all = new Dictionary<int, StackNode>();
        foreach (var n in open) all[n.Number] = n;
        all[current.Number] = all.TryGetValue(current.Number, out var known) ? known.Merging(current) : current;

        var repoKey = repo.ToLowerInvariant();
        var owner = new Dictionary<string, StackNode>();
        bool Preferred(StackNode a, StackNode b)
        {
            if (a.Number == current.Number || b.Number == current.Number) return a.Number == current.Number;
            var da = a.UpdatedAt ?? DateTimeOffset.MinValue;
            var db = b.UpdatedAt ?? DateTimeOffset.MinValue;
            return da == db ? a.Number > b.Number : da > db;
        }
        foreach (var n in all.Values)
        {
            if (n.HeadRepo?.ToLowerInvariant() != repoKey || (n.State != "OPEN" && n.Number != current.Number)) continue;
            if (owner.TryGetValue(n.HeadRefName, out var existing) && !Preferred(n, existing)) continue;
            owner[n.HeadRefName] = n;
        }

        StackNode? ParentOf(StackNode n) => owner.TryGetValue(n.BaseRefName, out var p) && p.Number != n.Number ? p : null;

        var kids = new Dictionary<int, List<int>>();
        foreach (var n in all.Values)
        {
            if (ParentOf(n) is not { } p) continue;
            if (!kids.TryGetValue(p.Number, out var list)) kids[p.Number] = list = new List<int>();
            list.Add(n.Number);
        }
        foreach (var list in kids.Values) list.Sort();

        var path = new List<int> { current.Number };
        var seen = new HashSet<int> { current.Number };
        var top = all[current.Number];
        while (ParentOf(top) is { } p && seen.Add(p.Number))
        {
            path.Insert(0, p.Number);
            top = p;
        }

        var included = new HashSet<int>(path);
        var queue = new List<int> { top.Number };
        var queued = new HashSet<int> { top.Number };
        for (var i = 0; i < queue.Count; i++)
        {
            if (!kids.TryGetValue(queue[i], out var cs)) continue;
            foreach (var c in cs)
            {
                if (queued.Contains(c)) continue;
                if (!included.Contains(c) && included.Count >= limit) continue;
                included.Add(c);
                queued.Add(c);
                queue.Add(c);
            }
        }
        if (included.Count <= 1) return null;

        var nodes = new Dictionary<int, StackNode>();
        var parent = new Dictionary<int, int>();
        var children = new Dictionary<int, IReadOnlyList<int>>();
        foreach (var x in included)
        {
            nodes[x] = all[x];
            if (x != top.Number && ParentOf(all[x]) is { } p && included.Contains(p.Number)) parent[x] = p.Number;
            if (kids.TryGetValue(x, out var cs))
            {
                var kept = cs.Where(c => included.Contains(c) && c != top.Number).ToList();
                if (kept.Count > 0) children[x] = kept;
            }
        }
        return new StackTree(top.BaseRefName, current.Number, top.Number, nodes, parent, children);
    }
}

public readonly record struct StackSlot(double Column, int Level);

public sealed class StackLayout
{
    public IReadOnlyDictionary<int, StackSlot> Slots { get; }
    public int Columns { get; }
    public int Levels { get; }

    public StackLayout(StackTree tree)
    {
        var slots = new Dictionary<int, StackSlot>();
        var next = 0;
        var depth = 0;
        void Place(int n, int level)
        {
            depth = Math.Max(depth, level);
            var cs = tree.ChildrenOf(n);
            if (cs.Count == 0)
            {
                slots[n] = new StackSlot(next, level);
                next++;
                return;
            }
            foreach (var c in cs) Place(c, level + 1);
            var cols = cs.Where(slots.ContainsKey).Select(c => slots[c].Column).ToList();
            slots[n] = new StackSlot(cols.Count == 0 ? 0 : (cols.Min() + cols.Max()) / 2, level);
        }
        Place(tree.Root, 1);
        Slots = slots;
        Columns = Math.Max(next, 1);
        Levels = depth;
    }
}

public static class StackRows
{
    public static List<(StackNode Node, int Depth)> Ordered(StackTree tree)
    {
        var output = new List<(StackNode, int)>();
        var stack = new Stack<(int, int)>();
        stack.Push((tree.Root, 0));
        var seen = new HashSet<int>();
        while (stack.Count > 0)
        {
            var (n, depth) = stack.Pop();
            if (!seen.Add(n)) continue;
            if (tree.Nodes.TryGetValue(n, out var node)) output.Add((node, depth));
            var cs = tree.ChildrenOf(n);
            for (var i = cs.Count - 1; i >= 0; i--) stack.Push((cs[i], depth + 1));
        }
        return output;
    }

    public static List<StackNode> BreadthFirst(StackTree tree)
    {
        var output = new List<StackNode>();
        var queue = new Queue<int>();
        queue.Enqueue(tree.Root);
        var seen = new HashSet<int>();
        while (queue.Count > 0)
        {
            var n = queue.Dequeue();
            if (!seen.Add(n)) continue;
            if (tree.Nodes.TryGetValue(n, out var node)) output.Add(node);
            foreach (var c in tree.ChildrenOf(n)) queue.Enqueue(c);
        }
        return output;
    }
}
