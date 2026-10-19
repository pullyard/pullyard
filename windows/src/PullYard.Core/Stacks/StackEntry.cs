using PullYard.Core.Api;

namespace PullYard.Core.Stacks;

public sealed class StackEntry
{
    public const int MaxRepos = 8;

    public RepoRef Repo { get; }
    public StackTree Tree { get; }
    public List<int> Mine { get; }
    public DateTimeOffset Updated { get; }

    public StackEntry(RepoRef repo, StackTree tree, List<int> mine, DateTimeOffset updated)
    {
        Repo = repo;
        Tree = tree;
        Mine = mine;
        Updated = updated;
    }

    public string Id => $"{Repo.Full}#{Tree.Root}";

    public ItemRef Ref => new(Repo, Tree.Current);

    public List<StackNode> Ordered => StackRows.BreadthFirst(Tree);

    public bool SameAs(StackEntry other) => Repo == other.Repo && Updated == other.Updated && Mine.SequenceEqual(other.Mine) && Tree.SameAs(other.Tree);

    public static List<StackEntry> Collect(RepoRef repo, IReadOnlyList<int> mine, IReadOnlyList<StackNode> open)
    {
        var byRoot = new Dictionary<int, StackEntry>();
        var index = new Dictionary<int, StackNode>();
        foreach (var n in open) index.TryAdd(n.Number, n);
        foreach (var number in mine)
        {
            if (!index.TryGetValue(number, out var node) || StackTree.Build(node, open, repo.Full) is not { } tree) continue;
            if (byRoot.ContainsKey(tree.Root)) continue;
            var mineHere = mine.Where(tree.Nodes.ContainsKey).ToList();
            var updated = tree.Nodes.Values.Select(n => n.UpdatedAt).Where(d => d is not null).Select(d => d!.Value).DefaultIfEmpty(DateTimeOffset.MinValue).Max();
            byRoot[tree.Root] = new StackEntry(repo, tree, mineHere, updated);
        }
        return byRoot.Values.OrderByDescending(e => e.Updated).ToList();
    }

    public static List<(RepoRef Repo, List<int> Numbers)> PickRepos(IEnumerable<SearchItem> items)
    {
        var repos = new List<(RepoRef Repo, bool Stacked, List<int> Numbers)>();
        foreach (var item in items)
        {
            if (!item.IsPR) continue;
            var i = repos.FindIndex(r => r.Repo == item.Repo);
            if (i >= 0)
            {
                repos[i].Numbers.Add(item.Number);
                if (item.StackedOn is not null) repos[i] = (repos[i].Repo, true, repos[i].Numbers);
            }
            else
            {
                repos.Add((item.Repo, item.StackedOn is not null, new List<int> { item.Number }));
            }
        }
        return repos.Where(r => r.Stacked).Concat(repos.Where(r => !r.Stacked)).Take(MaxRepos).Select(r => (r.Repo, r.Numbers)).ToList();
    }
}
