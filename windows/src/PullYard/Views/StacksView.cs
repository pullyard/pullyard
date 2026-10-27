using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed class StacksView : ListPane
{
    private readonly StacksViewModel vm = new();
    private bool syncing;

    public StacksView() : base(L.T("Section_Stacks", "Stacks"), "GenericRowTemplate")
    {
        List.SelectionChanged += OnSelection;
        vm.PropertyChanged += OnVm;
        Model.PropertyChanged += OnModel;
        Unloaded += (_, _) => Model.PropertyChanged -= OnModel;
        Loaded += (_, _) =>
        {
            Model.PropertyChanged -= OnModel;
            Model.PropertyChanged += OnModel;
        };
        vm.Restore(Model.Account);
        Render();
    }

    protected override void OnAttached() => vm.Load(Model.Api, Model.Account).Forget();

    protected override void OnLiveTick() => vm.Load(Model.Api, Model.Account).Forget();

    protected override Task OnPullRefresh() => vm.Load(Model.Api, Model.Account, force: true);

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppViewModel.DetailRoot)) SyncSelection();
        if (e.PropertyName is nameof(AppViewModel.Api) or nameof(AppViewModel.Account))
        {
            vm.Restore(Model.Account);
            vm.Load(Model.Api, Model.Account).Forget();
        }
    }

    private void OnVm(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(StacksViewModel.Entries)) Render();
        else UpdateState();
    }

    private void Render()
    {
        syncing = true;
        List.ItemsSource = vm.Entries.Select(e => new StackEntryRow(e)).ToList();
        syncing = false;
        SyncSelection();
        UpdateState();
    }

    private void UpdateState()
    {
        CountText.Text = vm.Entries.Count > 0 ? vm.Entries.Count.ToString() : "";
        SetLoading(vm.Loading, vm.Entries.Count > 0);
        Footer.Update(vm.LastUpdated, vm.Refreshing && !vm.Loading, vm.Entries.Count == 0 ? null : vm.Error);
        if (vm.Entries.Count > 0)
        {
            ShowOverlay(null);
            return;
        }
        if (vm.Loading || !vm.Loaded) ShowOverlay(Ui.Loading());
        else if (vm.Error is { } err) ShowOverlay(Ui.Error(err, () => vm.Load(Model.Api, Model.Account, force: true).Forget()));
        else ShowOverlay(Ui.EmptyState(L.T("Stacks_EmptyTitle", "No stacked pull requests"), L.T("Stacks_EmptyMessage", "Open a pull request on another pull request’s branch and it shows up here.")));
    }

    private void SyncSelection()
    {
        syncing = true;
        var route = Model.DetailRoot;
        List.SelectedItem = (List.ItemsSource as List<StackEntryRow>)?.FirstOrDefault(r => route is { Kind: RouteKind.PullRequest } && r.Entry.Repo == route.Item?.Repo && r.Entry.Tree.Nodes.ContainsKey(route.Item!.Number));
        syncing = false;
    }

    private void OnSelection(object sender, SelectionChangedEventArgs e)
    {
        if (syncing || List.SelectedItem is not StackEntryRow row) return;
        var route = Route.Pr(row.Entry.Ref);
        if (route == Model.DetailRoot) return;
        if (Model.PrModel(row.Entry.Ref) is { } next)
        {
            next.Tab = PRTab.Stack;
            if (next.Pr is null && row.Entry.Tree.Nodes.TryGetValue(row.Entry.Tree.Current, out var node))
                next.SeedStack(node, StackStore.Shared.MemoryNodes(Model.Account, Model.Api?.Host ?? "", row.Entry.Repo) ?? row.Entry.Tree.Nodes.Values.ToList());
        }
        Model.Select(route);
    }
}

public sealed record StackEntryRow(StackEntry Entry) : IRowContent
{
    public UIElement BuildRow()
    {
        var e = Entry;
        var nodes = e.Ordered;
        var root = e.Tree.Nodes.TryGetValue(e.Tree.Root, out var r) ? r : null;
        var title = Ui.H(6, Ui.Glyph(StackUi.StackGlyph, 12, "indigo"), Ui.Text(root is null ? "" : $"#{root.Number} {root.Title}", 13.5, "text", FontWeights.SemiBold));
        var meta = Ui.H(5, Ui.Caption(e.Repo.Full), Ui.Caption("·"), Ui.Caption(L.F("Stack_OnBase", "on {0}", e.Tree.Base)), Ui.Caption("·"), Ui.Caption(Fmt.Rel(e.Updated)));
        var dots = StackUi.Dots(nodes.Select(n => (n.Status.ColorKey(), e.Mine.Contains(n.Number) ? 0.9 : 0.4, 12.0)));
        Ui.Tip(dots, string.Join("\n", nodes.Select(n => $"#{n.Number} {n.Title} — {n.Status.Title()}")));
        var counts = Ui.H(6, dots, Ui.Caption(nodes.Count == 1 ? L.T("Stack_OnePRShort", "1 PR") : L.F("Stack_ManyPRsShort", "{0} PRs", nodes.Count)));
        if (e.Mine.Count < nodes.Count) counts.Children.Add(Ui.Caption(L.F("Stack_Yours", "· {0} yours", e.Mine.Count), "dim"));
        var failing = nodes.Count(n => n.Status.NeedsAttention());
        if (failing > 0)
        {
            var warn = Ui.H(3, Ui.Glyph("", 11, "red"), Ui.Caption(failing.ToString(), "red"));
            Ui.Tip(warn, failing == 1 ? L.T("Stack_AttentionOne", "1 pull request needs attention") : L.F("Stack_AttentionMany", "{0} pull requests need attention", failing));
            counts.Children.Add(warn);
        }
        var body = Ui.V(4, title, meta, counts);
        body.Padding = new Thickness(0, 8, 0, 8);
        return body;
    }
}
