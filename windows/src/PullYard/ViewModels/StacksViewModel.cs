using CommunityToolkit.Mvvm.ComponentModel;
using PullYard.Core.Api;
using PullYard.Core.Stacks;

namespace PullYard.ViewModels;

public sealed partial class StacksViewModel : ObservableObject
{
    private static (string? Account, List<StackEntry> Entries, DateTimeOffset At)? last;

    [ObservableProperty] private List<StackEntry> entries = new();
    [ObservableProperty] private bool loading;
    [ObservableProperty] private bool refreshing;
    [ObservableProperty] private string? error;
    [ObservableProperty] private DateTimeOffset? lastUpdated;
    [ObservableProperty] private bool loaded;

    private int generation;

    public static void Reset() => last = null;

    public void Restore(string? account)
    {
        if (last is not { } l || l.Account != account)
        {
            Entries = new();
            LastUpdated = null;
            Error = null;
            return;
        }
        Entries = l.Entries;
        LastUpdated = l.At;
    }

    public async Task Load(GitHubApi? api, string? account, bool force = false)
    {
        if (api is null) return;
        var mine = ++generation;
        Loading = true;
        Refreshing = Entries.Count > 0;
        try
        {
            var query = string.Join(" ", PRFilter.Mine.Query(), "is:pr", "is:open", "archived:false", "sort:updated-desc");
            var items = (await api.Search(query)).Nodes;
            var found = new List<StackEntry>();
            foreach (var (repo, numbers) in StackEntry.PickRepos(items))
            {
                if (await StackStore.Shared.Nodes(api, repo, account, force) is not { } nodes) continue;
                found.AddRange(StackEntry.Collect(repo, numbers, nodes));
            }
            found = found.OrderByDescending(e => e.Updated).ToList();
            if (mine != generation) return;
            if (found.Count != Entries.Count || found.Zip(Entries).Any(p => !p.First.SameAs(p.Second))) Entries = found;
            Error = null;
            LastUpdated = DateTimeOffset.Now;
            last = (account, found, LastUpdated.Value);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            if (mine == generation) Error = e.Message;
        }
        finally
        {
            if (mine == generation)
            {
                Loading = false;
                Refreshing = false;
                Loaded = true;
            }
        }
    }
}
