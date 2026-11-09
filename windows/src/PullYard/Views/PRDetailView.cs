using System.ComponentModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Html;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using Windows.System;
using Windows.UI.Core;
using VisualState = PullYard.Core.Api.VisualState;

namespace PullYard.Views;

public sealed class PRDetailView : Grid
{
    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly ItemRef itemRef;
    private PRDetailViewModel? model;
    private readonly ContentControl root = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false };
    private PRContent? content;
    private readonly LiveRefresh live;
    private bool subscribed;

    public PRDetailView(ItemRef r)
    {
        itemRef = r;
        live = new LiveRefresh(this, OnLive);
        Children.Add(root);
        root.Content = Ui.Loading();
        Loaded += (_, _) =>
        {
            if (subscribed) return;
            subscribed = true;
            app.RefreshRequested += OnRefresh;
            app.LiveTick += live.Tick;
            Start();
        };
        Unloaded += (_, _) =>
        {
            subscribed = false;
            app.RefreshRequested -= OnRefresh;
            app.LiveTick -= live.Tick;
            if (model is not null) model.PropertyChanged -= OnModel;
        };
    }

    private void OnRefresh() => model?.Load(true).Forget();

    private void OnLive() => model?.Load(live: true).Forget();

    private void Start()
    {
        model ??= app.PrModel(itemRef);
        if (model is null) return;
        model.PropertyChanged -= OnModel;
        model.PropertyChanged += OnModel;
        Update();
        model.Open().Forget();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PRDetailViewModel.Pr) or nameof(PRDetailViewModel.Error) or nameof(PRDetailViewModel.NotPR) or nameof(PRDetailViewModel.StackTree) or nameof(PRDetailViewModel.Preview) or nameof(PRDetailViewModel.Tab)) Update();
    }

    private void Update()
    {
        if (model is null) return;
        if (model.NotPR)
        {
            root.Content = new IssueDetailView(itemRef);
            return;
        }
        if (model.Pr is not null)
        {
            if (content is null)
            {
                content = new PRContent(model);
                root.Content = content;
            }
            return;
        }
        if (model.Error is null && model.Tab == PRTab.Stack && model.StackTree is not null && model.Preview is { } node)
        {
            if (root.Content is not StackPreviewContent) root.Content = new StackPreviewContent(model, node);
            return;
        }
        if (model.Error is null && root.Content is StackPreviewContent) return;
        root.Content = model.Error is { } e ? Ui.Error(e, () => model.Load().Forget()) : Ui.Loading();
    }
}

public sealed class PRContent : Grid, IShortcutHost
{
    private readonly AppViewModel app = AppViewModel.Shared;
    private readonly PRDetailViewModel model;
    private readonly StackPanel header = Ui.V(8);
    private readonly ContentControl titleHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private readonly StackPanel banners = Ui.V(6);
    private readonly TabStrip tabs = new(nameof(PRTab.Conversation));
    private readonly Grid tabArea = new();
    private readonly StackPanel toolbar = Ui.H(2);
    private readonly RefreshFooter status = new(compact: true);
    private readonly WakeLoader busy = Ui.Spinner(16);
    private readonly Dictionary<PRTab, FrameworkElement> tabViews = new();
    private HtmlView? conversation;
    private HtmlView? diff;
    private ListView? fileList;
    private TextBox? fileFilter;
    private TextBlock? viewedCount;
    private int lastScrollToken;
    private int lastFocusToken;
    private Button? nextThread;
    private int renderedDiffVersion = -1;
    private string renderedFilter = "";
    private string renderedLayout = "";
    private string lastHtml = "";
    private CheckBox? wrapBox;
    private ComboBox? layoutBox;
    private ComboBox? scopeBox;
    private readonly ContentControl interdiffBanner = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private bool splitFits;
    private bool syncingReviewBar;

    public PRContent(PRDetailViewModel model)
    {
        this.model = model;
        lastFocusToken = model.ThreadFocusToken;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var top = new Grid { Padding = new Thickness(16, 12, 12, 0), ColumnSpacing = 8, RowSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        top.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        top.Children.Add(titleHost);
        var tools = Ui.H(4, busy, status, toolbar);
        tools.VerticalAlignment = VerticalAlignment.Top;
        SetColumn(tools, 1);
        top.Children.Add(tools);
        SetRow(header, 1);
        SetColumnSpan(header, 2);
        top.Children.Add(header);
        Children.Add(top);
        banners.Padding = new Thickness(16, 6, 16, 0);
        SetRow(banners, 1);
        Children.Add(banners);
        var tabRow = Ui.V(0, tabs, Ui.Line());
        tabRow.Margin = new Thickness(0, 6, 0, 0);
        SetRow(tabRow, 2);
        Children.Add(tabRow);
        SetRow(tabArea, 3);
        Children.Add(tabArea);
        Shortcuts.ShortLinkKey(this);
        Shortcuts.NextThreadKey(this);

        tabs.SelectionChanged += id => model.Tab = Enum.Parse<PRTab>(id);
        status.Retry = () => model.Load(true).Forget();
        busy.Visibility = Visibility.Collapsed;
        model.PropertyChanged += OnModel;
        JiraService.Account.Changed += OnJiraChanged;
        Settings.Shared.Changed += OnSettings;
        Unloaded += (_, _) =>
        {
            model.PropertyChanged -= OnModel;
            JiraService.Account.Changed -= OnJiraChanged;
            Settings.Shared.Changed -= OnSettings;
            WatchFixTab(null);
        };
        Loaded += (_, _) =>
        {
            model.PropertyChanged -= OnModel;
            model.PropertyChanged += OnModel;
            JiraService.Account.Changed -= OnJiraChanged;
            JiraService.Account.Changed += OnJiraChanged;
            Settings.Shared.Changed -= OnSettings;
            Settings.Shared.Changed += OnSettings;
            RenderAll();
        };
        CharacterReceived += OnReviewCharacter;
        AddShortcuts();
        RenderAll();
    }

    private PullRequestDetail Pr => model.Pr!;

    private void AddShortcuts()
    {
        var index = 0;
        foreach (var tab in Enum.GetValues<PRTab>())
        {
            var t = tab;
            var acc = new KeyboardAccelerator { Key = VirtualKey.Number1 + index, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
            acc.Invoked += (_, e) =>
            {
                e.Handled = true;
                if (TabAvailable(t)) model.Tab = t;
            };
            KeyboardAccelerators.Add(acc);
            index++;
        }
    }

    private bool TabAvailable(PRTab t) => t switch
    {
        PRTab.Stack => model.StackTree is not null,
        PRTab.Jira => model.Pr is { } pr && JiraService.Account.ShowsTab(pr),
        _ => true
    };

    private void OnJiraChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (model.Pr is null) return;
        RenderTabs();
        if (model.Tab == PRTab.Jira && !TabAvailable(PRTab.Jira)) model.Tab = PRTab.Conversation;
    });

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PRDetailViewModel.Pr):
                RenderAll();
                break;
            case nameof(PRDetailViewModel.StackTree):
                RenderHeader();
                RenderTabs();
                ShowTab();
                break;
            case nameof(PRDetailViewModel.Repo):
                RenderHeader();
                RenderBanners();
                break;
            case nameof(PRDetailViewModel.RulesState):
            case nameof(PRDetailViewModel.CodeOwnersState):
            case nameof(PRDetailViewModel.Ownership):
            case nameof(PRDetailViewModel.Risks):
                RenderHeader();
                break;
            case nameof(PRDetailViewModel.Tab):
                ShowTab();
                break;
            case nameof(PRDetailViewModel.Html):
                RenderConversation();
                break;
            case nameof(PRDetailViewModel.ScrollToBottomToken):
                if (model.ScrollToBottomToken != lastScrollToken)
                {
                    lastScrollToken = model.ScrollToBottomToken;
                    conversation?.ScrollToBottom();
                }
                break;
            case nameof(PRDetailViewModel.ThreadFocusToken):
                FocusThread();
                break;
            case nameof(PRDetailViewModel.Loading):
            case nameof(PRDetailViewModel.LastUpdated):
            case nameof(PRDetailViewModel.RefreshError):
                status.Update(model.LastUpdated, model.Loading, model.RefreshError);
                break;
            case nameof(PRDetailViewModel.Busy):
                busy.Visibility = model.Busy ? Visibility.Visible : Visibility.Collapsed;
                break;
            case nameof(PRDetailViewModel.ActionError):
                if (model.ActionError is { } err)
                {
                    model.ActionError = null;
                    Dialogs.Alert(XamlRoot, L.T("Common_Error", "Error"), err).Forget();
                }
                break;
            case nameof(PRDetailViewModel.LastReviewed):
            case nameof(PRDetailViewModel.DiffScope):
            case nameof(PRDetailViewModel.InterdiffLoading):
            case nameof(PRDetailViewModel.InterdiffError):
            case nameof(PRDetailViewModel.InterdiffRebased):
            case nameof(PRDetailViewModel.InterdiffFiles):
                SyncScope();
                RenderInterdiffBanner();
                RenderFiles();
                break;
            case nameof(PRDetailViewModel.DiffVersion):
            case nameof(PRDetailViewModel.Files):
            case nameof(PRDetailViewModel.FilesLoaded):
            case nameof(PRDetailViewModel.FilesError):
                RenderFiles();
                break;
            case nameof(PRDetailViewModel.ScrollTarget):
                if (model.ScrollTarget is { } path)
                {
                    diff?.Send(new JsonObject { ["op"] = "scrollToFile", ["path"] = path });
                    if (fileList is not null) fileList.SelectedItem = (fileList.ItemsSource as IEnumerable<FileListItem>)?.FirstOrDefault(f => f.File.Id == path);
                }
                break;
            case nameof(PRDetailViewModel.PendingCount):
                RenderToolbar();
                break;
            case nameof(PRDetailViewModel.CiFix):
            case nameof(PRDetailViewModel.ReviewFix):
                RenderBanners();
                break;
        }
    }

    private void RenderAll()
    {
        if (model.Pr is null) return;
        RenderHeader();
        RenderBanners();
        RenderToolbar();
        RenderTabs();
        ShowTab();
        RenderConversation();
        SyncNextThread();
        if (tabViews.ContainsKey(PRTab.Commits)) tabViews[PRTab.Commits] = BuildCommits(tabViews[PRTab.Commits]);
        if (tabViews.ContainsKey(PRTab.Checks)) tabViews[PRTab.Checks] = BuildChecks(tabViews[PRTab.Checks]);
        status.Update(model.LastUpdated, model.Loading, model.RefreshError);
    }

    private void RenderHeader()
    {
        if (model.Pr is null) return;
        var pr = Pr;
        header.Children.Clear();
        var titleText = Ui.Text("", 20, "text", FontWeights.Bold, wrap: true, select: true);
        titleText.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = pr.Title + "  " });
        titleText.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = model.NumberText, Foreground = Palette.Brush("dim"), FontWeight = FontWeights.Normal });
        titleHost.Content = titleText;
        var branchBase = BranchChip(pr.BaseRefName, "sky");
        var branchHead = BranchChip(pr.HeadRefName, "violet");
        var time = Ui.Caption(Fmt.Rel(pr.CreatedAt));
        Ui.Tip(time, Fmt.Full(pr.CreatedAt));
        var meta = new WrapPanel(8, Ui.StateBadge(pr.VisualState), Ui.Avatar(pr.Author?.AvatarUrl, 18), Ui.Text(pr.Author?.Login ?? "ghost", 13, "text", FontWeights.SemiBold),
            branchBase, Ui.Glyph("", 11, "dim"), branchHead);
        if (model.DiffStat is { } stat) meta.Children.Add(Ui.DiffStat(stat.Additions, stat.Deletions));
        meta.Children.Add(time);
        header.Children.Add(meta);
        var reviewers = model.Reviewers;
        if (pr.Labels.Items.Count > 0 || reviewers.Count > 0 || pr.Assignees.Items.Count > 0)
        {
            var row = new WrapPanel(6);
            foreach (var l in pr.Labels.Items) row.Children.Add(Ui.LabelChip(l));
            if (reviewers.Count > 0)
            {
                row.Children.Add(Ui.Caption(L.T("PR_Reviewers", "Reviewers:")));
                foreach (var r in reviewers) row.Children.Add(ReviewerBadge(r));
            }
            if (pr.Assignees.Items.Count > 0)
            {
                row.Children.Add(Ui.Caption(L.T("PR_Assignees", "Assignees:")));
                foreach (var a in pr.Assignees.Items)
                {
                    var av = Ui.Avatar(a.AvatarUrl, 18);
                    Ui.Tip(av, a.Login);
                    row.Children.Add(av);
                }
            }
            header.Children.Add(row);
        }
        if (model.StackTree is { } tree) header.Children.Add(StackUi.Strip(tree, model.Ref.Repo, () => model.Tab = PRTab.Stack));
        if (pr.IsOpen && RiskStrip(model) is { } risks) header.Children.Add(risks);
        if (MergeStatusBar(model, app, () => Dialogs.Merge(XamlRoot, model).Forget(), () => Dialogs.Reviewers(XamlRoot, model).Forget()) is { } bar) header.Children.Add(bar);
    }

    private static string RiskGlyph(RiskKind kind) => kind switch
    {
        RiskKind.Migrations => "\uE81E",
        RiskKind.Ci => "\uE713",
        RiskKind.Infrastructure => "\uE770",
        RiskKind.Dependencies => "\uE7B8",
        RiskKind.Secrets => "\uE192",
        RiskKind.Access => "\uE8D7",
        RiskKind.LargeDeletion => "\uE738",
        RiskKind.LargeChange => "\uE8FD",
        _ => "\uE897"
    };

    private static FrameworkElement? RiskStrip(PRDetailViewModel model)
    {
        var risks = model.Risks;
        if (risks.Count == 0) return null;
        var row = new WrapPanel(6, Ui.Caption(L.T("Risk_LookCloser", "Look closer:")));
        foreach (var r in risks)
        {
            var chip = Ui.Chip(r.Title, r.Strong ? "amber" : "muted", RiskGlyph(r.Kind));
            var b = new Button { Content = chip, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0) };
            var tip = r.Detail;
            if (r.Files.Count > 0) tip += "\n\n" + string.Join("\n", r.Files.Take(12));
            if (r.Files.Count > 12) tip += "\n" + L.F("Risk_MoreFiles", "…and {0} more", r.Files.Count - 12);
            Ui.Tip(b, tip);
            Ui.Named(b, r.Title, r.Detail);
            var first = r.Files.FirstOrDefault();
            b.Click += (_, _) =>
            {
                if (first is null) return;
                model.RevealFile(first);
                model.LoadFiles().Forget();
            };
            row.Children.Add(b);
        }
        return row;
    }

    public static Border BranchChip(string name, string color)
    {
        var chip = Ui.Chip(name, color, null, mono: true);
        chip.Tapped += (_, _) => WindowInterop.Copy(name);
        Ui.Tip(chip, L.T("Common_ClickToCopy", "Click to copy"));
        return chip;
    }

    public static FrameworkElement ReviewerBadge(ReviewerInfo r)
    {
        var (glyph, color, title) = r.State switch
        {
            "APPROVED" => ("", "green", "approved"),
            "CHANGES_REQUESTED" => ("", "red", "changes requested"),
            "COMMENTED" => ("", "muted", "commented"),
            "DISMISSED" => ("", "muted", "dismissed"),
            _ => ("", "amber", "review pending")
        };
        var p = Ui.H(3, Ui.Avatar(r.Avatar, 18), Ui.Glyph(glyph, r.State is "APPROVED" or "CHANGES_REQUESTED" or "COMMENTED" ? 11 : 6, color));
        Ui.Tip(p, $"{r.Login}: {title}");
        Ui.Named(p, $"{r.Login}: {title}");
        return p;
    }

    private static bool requirementsExpanded = true;

    public static FrameworkElement? MergeStatusBar(PRDetailViewModel model, AppViewModel app, Action onMerge, Action? onRequestReview = null)
    {
        if (model.Pr is not { IsOpen: true } pr) return null;
        var checks = pr.Checks;
        var requirements = model.Requirements;
        var ok = checks.Count(c => c.Outcome == CheckOutcome.Success);
        var anyFailed = checks.Count(c => c.Outcome == CheckOutcome.Failure);
        var anyPending = checks.Count(c => c.Outcome == CheckOutcome.Pending);
        var s = PRDetailViewModel.Headline(pr, requirements);
        var row = new WrapPanel(8, Ui.Glyph(s.glyph, 14, s.color), Ui.Text(s.text, 13));
        if (pr.AutoMergeRequest is { } auto)
        {
            var method = auto.MergeMethod is { } m ? $" ({MergeMethods.Title(m)})" : "";
            row.Children.Add(Ui.Text("· " + L.T("Merge_AutoEnabled", "auto-merge enabled") + method, 13, "green"));
        }
        if (checks.Count > 0)
        {
            var chips = Ui.H(6);
            if (anyFailed > 0) chips.Children.Add(Ui.H(2, Ui.Glyph("", 11, "red"), Ui.Caption(anyFailed.ToString(), "red")));
            if (anyPending > 0) chips.Children.Add(Ui.H(2, Ui.Glyph("", 11, "amber"), Ui.Caption(anyPending.ToString(), "amber")));
            chips.Children.Add(Ui.H(2, Ui.Glyph("", 11, "green"), Ui.Caption(ok.ToString(), "green")));
            var b = new Button { Content = chips, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(4, 0, 4, 0) };
            Ui.Tip(b, model.ChecksTitle);
            Ui.Named(b, model.ChecksTitle, L.F("PR_ChecksSummary", "{0} failed, {1} pending, {2} passed", anyFailed, anyPending, ok));
            b.Click += (_, _) => model.Tab = PRTab.Checks;
            row.Children.Add(b);
        }
        var actions = Ui.H(6);
        if (model.Features.UpdateBranch && pr.MergeStateStatus == "BEHIND" && (model.CanWrite || pr.ViewerCanUpdate))
            actions.Children.Add(Ui.Button(model.UpdateBranchTitle, () => UpdateBranch(model).Forget()));
        if (model.IsGitLab && pr.IsDraft && pr.ViewerCanUpdate)
            actions.Children.Add(Ui.Button(L.T("MR_MarkReady", "Mark as ready"), () => model.Simple(PRAction.ReadyForReview).Forget()));
        if (model.CanWrite && !pr.IsDraft)
        {
            var merge = Ui.Button(L.T("Merge_Merge", "Merge…"), onMerge, accent: s.ready);
            actions.Children.Add(merge);
        }
        var grid = Ui.Columns((row, Ui.Star), (actions, Ui.Auto));
        if (requirements.Count == 0)
            return new Border { Background = Palette.Brush(s.color, 0.08), CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 6, 8, 6), Child = grid };
        var list = RequirementsList(model, pr, requirements, onRequestReview);
        list.Visibility = requirementsExpanded ? Visibility.Visible : Visibility.Collapsed;
        var toggle = new Button { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(4, 2, 4, 2) };
        void SyncToggle()
        {
            var label = requirementsExpanded ? L.T("Merge_HideRequirements", "Hide merge requirements") : L.T("Merge_ShowRequirements", "Show merge requirements");
            toggle.Content = Ui.Glyph(requirementsExpanded ? "" : "", 11, "muted");
            Ui.Tip(toggle, label);
            Ui.Named(toggle, label);
        }
        SyncToggle();
        toggle.Click += (_, _) =>
        {
            requirementsExpanded = !requirementsExpanded;
            list.Visibility = requirementsExpanded ? Visibility.Visible : Visibility.Collapsed;
            SyncToggle();
        };
        actions.Children.Add(toggle);
        return new Border { Background = Palette.Brush(s.color, 0.08), CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 6, 8, 6), Child = Ui.V(6, grid, list) };
    }

    private static StackPanel RequirementsList(PRDetailViewModel model, PullRequestDetail pr, List<MergeRequirement> requirements, Action? onRequestReview)
    {
        static int Rank(RequirementState s) => s switch
        {
            RequirementState.Missing => 0,
            RequirementState.Pending => 1,
            RequirementState.Unknown => 2,
            RequirementState.Advisory => 3,
            _ => 4
        };
        bool CanPerform(RequirementAction a) => a switch
        {
            RequirementAction.RequestReview => onRequestReview is not null && model.Features.RequestReviewers && (model.CanWrite || pr.ViewerDidAuthor),
            RequirementAction.UpdateBranch => false,
            RequirementAction.ReadyForReview => pr.ViewerCanUpdate,
            _ => true
        };
        void Perform(RequirementAction a)
        {
            switch (a)
            {
                case RequirementAction.RequestReview: onRequestReview?.Invoke(); break;
                case RequirementAction.ShowChecks: model.Tab = PRTab.Checks; break;
                case RequirementAction.ShowConversation: model.NextUnresolvedThread(); break;
                case RequirementAction.ShowConflicts:
                    model.Tab = PRTab.Conversation;
                    model.ScrollToBottomToken++;
                    break;
                case RequirementAction.UpdateBranch: model.Simple(PRAction.UpdateBranch).Forget(); break;
                case RequirementAction.ReadyForReview: model.Simple(PRAction.ReadyForReview).Forget(); break;
            }
        }
        var panel = Ui.V(4);
        Ui.Named(panel, L.T("Merge_Requirements", "Merge requirements"));
        foreach (var r in requirements.Select((r, i) => (r, i)).OrderBy(x => Rank(x.r.State)).ThenBy(x => x.i).Select(x => x.r))
        {
            var (glyph, color, spoken) = r.State switch
            {
                RequirementState.Satisfied => ("", "green", L.T("Merge_ReqMet", "met")),
                RequirementState.Missing => ("", "red", L.T("Merge_ReqBlocking", "blocking")),
                RequirementState.Pending => ("", "amber", L.T("Merge_ReqPending", "in progress")),
                RequirementState.Unknown => ("", "muted", L.T("Merge_ReqUnknown", "unknown")),
                _ => ("", "muted", L.T("Merge_ReqAdvisory", "doesn’t block"))
            };
            var text = Ui.V(1, Ui.Text(r.Title, 13, r.State == RequirementState.Satisfied ? "muted" : "text", wrap: true));
            if (r.Detail is { } d) text.Children.Add(Ui.Caption(d));
            UIElement? action = null;
            if (r.Action is { } a && r.State != RequirementState.Satisfied && CanPerform(a))
            {
                var title = a switch
                {
                    RequirementAction.RequestReview => L.T("Merge_ActRequestReview", "Request review"),
                    RequirementAction.ShowChecks => model.IsGitLab ? L.T("MR_ActShowPipeline", "Show pipeline") : model.Features.IsBitbucket ? L.T("BB_ActShowBuilds", "Show builds") : L.T("Merge_ActShowChecks", "Show checks"),
                    RequirementAction.ShowConversation => L.T("Merge_ActShowConversation", "Show conversation"),
                    RequirementAction.ShowConflicts => L.T("Merge_ActShowConflicts", "View conflicts"),
                    RequirementAction.UpdateBranch => model.UpdateBranchTitle,
                    _ => model.IsGitLab ? L.T("MR_MarkReady", "Mark as ready") : L.T("Merge_ActReady", "Ready for review")
                };
                action = Ui.Link(title, () => Perform(a));
            }
            var line = Ui.Columns((Ui.Glyph(glyph, 12, color), Ui.Auto), (text, Ui.Star), (action, Ui.Auto));
            Ui.Named(line, r.Title, spoken);
            panel.Children.Add(line);
        }
        if (model.Ownership is { } ownership && (ownership.Groups.Count > 0 || ownership.Unowned.Count > 0))
        {
            var owners = CodeOwnersSection(ownership, CanPerform(RequirementAction.RequestReview) ? () => Perform(RequirementAction.RequestReview) : null);
            owners.Margin = new Thickness(0, 4, 0, 0);
            panel.Children.Add(owners);
        }
        return panel;
    }

    private const int OwnerGroupLimit = 6;

    private static StackPanel CodeOwnersSection(OwnershipSummary summary, Action? onRequestReview)
    {
        static string Files(int n) => n == 1 ? L.T("Owners_OneFile", "1 file") : L.F("Owners_Files", "{0} files", n);
        static string Color(OwnerStatus s) => s switch
        {
            OwnerStatus.Approved => "green",
            OwnerStatus.ChangesRequested => "red",
            OwnerStatus.Requested => "amber",
            _ => "text"
        };
        static string Title(OwnerStatus s) => s switch
        {
            OwnerStatus.Approved => L.T("Owners_Approved", "approved"),
            OwnerStatus.ChangesRequested => L.T("Owners_ChangesRequested", "changes requested"),
            OwnerStatus.Requested => L.T("Owners_Requested", "review requested"),
            _ => L.T("Owners_NotRequested", "not requested")
        };
        var title = L.T("Owners_Title", "Code owners");
        var panel = Ui.V(4);
        Ui.Named(panel, title);
        var header = Ui.H(6, Ui.Text(title, 12, "muted", FontWeights.SemiBold), Ui.Text(summary.SourcePath, 12, "dim", mono: true));
        UIElement? request = onRequestReview is not null && summary.Suggestions(new HashSet<string>()).Count > 0
            ? Ui.Link(L.T("Owners_Request", "Request owners"), onRequestReview)
            : null;
        panel.Children.Add(Ui.Columns((header, Ui.Star), (request, Ui.Auto)));
        foreach (var group in summary.Groups.Take(OwnerGroupLimit))
        {
            var row = new WrapPanel(6);
            foreach (var o in group.Owners)
            {
                var handle = Ui.Text("@" + o.Handle, 13, Color(o.Status));
                Ui.Tip(handle, $"@{o.Handle}: {Title(o.Status)}");
                row.Children.Add(handle);
            }
            var count = Ui.Caption(Files(group.Files.Count));
            Ui.Tip(count, string.Join("\n", group.Files));
            row.Children.Add(count);
            var line = Ui.Columns((Ui.Glyph(group.Satisfied ? "\ue73e" : "\ue716", 12, group.Satisfied ? "green" : "muted"), Ui.Auto), (row, Ui.Star));
            Ui.Named(line, string.Join(", ", group.Owners.Select(o => $"{o.Handle}, {Title(o.Status)}")), Files(group.Files.Count));
            panel.Children.Add(line);
        }
        if (summary.Groups.Count > OwnerGroupLimit)
        {
            var more = Ui.Caption(L.F("Owners_MoreGroups", "+{0} more owner groups", summary.Groups.Count - OwnerGroupLimit));
            more.Margin = new Thickness(20, 0, 0, 0);
            panel.Children.Add(more);
        }
        if (summary.Unowned.Count > 0)
        {
            var text = L.F("Owners_Unowned", "{0} without a code owner", Files(summary.Unowned.Count));
            var caption = Ui.Caption(text);
            Ui.Tip(caption, string.Join("\n", summary.Unowned));
            var line = Ui.Columns((Ui.Glyph("\ue9ce", 12, "amber"), Ui.Auto), (caption, Ui.Star));
            Ui.Named(line, text);
            panel.Children.Add(line);
        }
        return panel;
    }

    private void RenderBanners()
    {
        banners.Children.Clear();
        if (model.Pr is null) return;
        if (!model.Features.Agent)
        {
            banners.Visibility = Visibility.Collapsed;
            return;
        }
        if (ReReviewBanner(model, () => Dialogs.Reviewers(XamlRoot, model).Forget()) is { } rr) banners.Children.Add(rr);
        if (FixBanner(Pr, () => Dialogs.FixWithClaude(XamlRoot, model).Forget()) is { } fix) banners.Children.Add(fix);
        if (CloseLoopBanner(model, ids => Dialogs.CloseLoopThreads(XamlRoot, model, ids).Forget()) is { } loop) banners.Children.Add(loop);
        var launch = model.CiFix is { } l && l.HeadOid == Pr.HeadRefOid ? l : null;
        var fixTab = launch?.Tab is { } t && app.Claude.Tabs.Contains(t) ? t : null;
        WatchFixTab(fixTab);
        if (CiBanner(model, launch, fixTab, () => Dialogs.FixCi(XamlRoot, model).Forget(), () => ConfirmRerun().Forget(), () => OpenFixTab(fixTab)) is { } ciBanner) banners.Children.Add(ciBanner);
        banners.Visibility = banners.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private ClaudeTab? watchedTab;

    private void WatchFixTab(ClaudeTab? tab)
    {
        if (ReferenceEquals(watchedTab, tab)) return;
        if (watchedTab is not null) watchedTab.PropertyChanged -= OnFixTab;
        watchedTab = tab;
        if (tab is not null) tab.PropertyChanged += OnFixTab;
    }

    private void OnFixTab(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(ClaudeTab.State)) return;
        DispatcherQueue.TryEnqueue(RenderBanners);
    }

    private void OpenFixTab(ClaudeTab? tab)
    {
        if (tab is null) return;
        app.Section = Section.Claude;
        app.Claude.SelectedTab = tab;
    }

    private async Task ConfirmRerun()
    {
        var runs = model.FailedRuns;
        if (runs == 0) return;
        var message = runs == 1 ? L.T("Checks_RerunOne", "GitHub Actions will re-run the failed jobs of 1 workflow run on the latest commit.") : L.F("Checks_RerunMany", "GitHub Actions will re-run the failed jobs of {0} workflow runs on the latest commit.", runs);
        if (await Dialogs.Confirm(XamlRoot, L.T("Checks_RerunTitle", "Re-run failed jobs?"), L.T("Checks_RerunButton", "Re-run"), destructive: false, message: message))
            await model.RerunFailed();
    }

    public static FrameworkElement? CiBanner(PRDetailViewModel model, CiFixLaunch? launch, ClaudeTab? fixTab, Action fix, Action rerun, Action openTab)
    {
        if (model.Pr is not { IsOpen: true }) return null;
        var failing = model.FailingChecks;
        if (failing.Count == 0) return null;
        var text = failing.Count == 1 ? L.T("CiFix_OneFailing", "1 check failing") : L.F("CiFix_Failing", "{0} checks failing", failing.Count);
        var row = Ui.H(8, Ui.IconTile("\uEA39", "red", 18), Ui.Text(text, 13));
        var names = Ui.Text("· " + string.Join(", ", failing.Take(3).Select(c => c.FullTitle)) + (failing.Count > 3 ? ", …" : ""), 13, "muted");
        names.TextTrimming = TextTrimming.CharacterEllipsis;
        names.MaxWidth = 520;
        row.Children.Add(names);
        if (fixTab is { } tab)
        {
            var label = tab.Running ? L.T("CiFix_Running", "Fix running") : L.T("CiFix_Session", "Fix session");
            var running = new Button
            {
                Content = Ui.Chip(label + " · " + tab.State.Title(), tab.State.ColorKey(), "\uE945"),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0)
            };
            Ui.Tip(running, L.T("CiFix_OpenSession", "Open the agent session"));
            Ui.Named(running, label + " · " + tab.State.Title(), L.T("CiFix_OpenSession", "Open the agent session"));
            running.Click += (_, _) => openTab();
            row.Children.Add(running);
        }
        else if (launch is { Tab: null } external)
        {
            row.Children.Add(Ui.Chip(L.F("CiFix_Launched", "Fix launched in {0} · {1}", external.Target.Title(), Fmt.Rel(external.At)), "slate", "\uE945"));
        }
        else if (launch is { Tab: not null })
        {
            row.Children.Add(Ui.Chip(L.T("CiFix_SessionClosed", "Fix session closed"), "dim", "\uE945"));
        }
        var actions = Ui.H(6);
        if (model.CanWrite && model.FailedRuns > 0) actions.Children.Add(Ui.Button(L.T("Checks_RerunShort", "Re-run failed"), rerun));
        var button = Ui.Button(L.T("Fix_Button", "Fix with agent"), fix, accent: true);
        var (coral, onCoral) = Palette.Filled("coral");
        button.Background = coral;
        button.Foreground = onCoral;
        actions.Children.Add(button);
        var grid = Ui.Columns((row, Ui.Star), (actions, Ui.Auto));
        return new Border { Background = Palette.Brush("red", 0.08), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6, 8, 6), Child = grid };
    }

    public static FrameworkElement? ReReviewBanner(PRDetailViewModel model, Action more)
    {
        var pr = model.Pr!;
        var stale = model.StaleReviews;
        if (!pr.IsOpen || !(pr.ViewerDidAuthor || pr.ViewerCanUpdate) || stale.Count == 0) return null;
        var logins = stale.Select(s => s.Login).ToList();
        var who = stale.Count == 1 ? $"@{stale[0].Login}" : string.Join(", ", stale.SkipLast(1).Select(s => "@" + s.Login)) + $" and @{stale[^1].Login}";
        var counts = stale.Where(s => s.Commits is not null).Select(s => s.Commits!.Value).ToList();
        var what = counts.Count == stale.Count && counts.Count > 0 ? Fmt.Plural(counts.Max(), "commit", "commits") : "new commits";
        var message = pr.ViewerDidAuthor ? $"You pushed {what} after {who} reviewed" : $"{char.ToUpperInvariant(what[0])}{what[1..]} pushed after {who} reviewed";
        var row = Ui.H(8, Ui.IconTile("", "sky", 18), Ui.Text(message, 13));
        if (model.LastCommitDate is { } d) row.Children.Add(Ui.Caption("· " + Fmt.Rel(d)));
        var other = Ui.Button(L.T("ReReview_Other", "Other…"), more);
        var send = Ui.Button(logins.Count == 1 ? L.T("ReReview_Request", "Re-request review") : L.F("ReReview_RequestN", "Re-request review ({0})", logins.Count), () => { }, accent: true, glyph: "");
        send.Click += async (_, _) =>
        {
            send.IsEnabled = false;
            if (await model.RequestReviewers(logins)) send.Content = L.T("ReReview_Requested", "Requested");
            else send.IsEnabled = true;
        };
        var grid = Ui.Columns((row, Ui.Star), (Ui.H(6, other, send), Ui.Auto));
        return new Border { Background = Palette.Brush("sky", 0.08), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6, 8, 6), Child = grid };
    }

    public static FrameworkElement? CloseLoopBanner(PRDetailViewModel model, Action<IReadOnlyList<string>> open)
    {
        if (model.Pr is not { } pr || CloseLoop.Pending(model.ReviewFix, pr) is not { } pending) return null;
        var commits = pending.NewCommits == 1 ? L.T("CloseLoop_OneCommit", "1 new commit") : L.F("CloseLoop_Commits", "{0} new commits", pending.NewCommits);
        var threads = pending.Threads.Count == 1 ? L.T("CloseLoop_OneOpen", "1 thread still open") : L.F("CloseLoop_OpenN", "{0} threads still open", pending.Threads.Count);
        var message = Ui.Text(L.F("CloseLoop_Banner", "{0} since Fix with agent · {1}", commits, threads), 13);
        message.TextTrimming = TextTrimming.CharacterEllipsis;
        var row = Ui.H(8, Ui.IconTile("\uE8BD", "green", 18), message);
        var button = Ui.Button(L.T("CloseLoop_Button", "Reply and resolve…"), () => open(pending.Threads), accent: true);
        var (fill, text) = Palette.Filled("green");
        button.Background = fill;
        button.Foreground = text;
        var dismiss = Ui.IconButton("\uE711", L.T("Common_Dismiss", "Dismiss"), () => model.ReviewFix = null);
        var grid = Ui.Columns((row, Ui.Star), (Ui.H(6, button, dismiss), Ui.Auto));
        return new Border { Background = Palette.Brush("green", 0.07), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6, 8, 6), Child = grid };
    }

    public static FrameworkElement? FixBanner(PullRequestDetail pr, Action action)
    {
        var open = pr.ReviewThreads.Items.Where(t => !t.IsResolved).ToList();
        var unresolved = open.Count(t => !t.IsOutdated);
        var outdated = open.Count - unresolved;
        var lastCommit = pr.LastCommit.Items.FirstOrDefault()?.Commit.CommittedDate;
        var found = FixPromptExtractor.Latest(pr);
        if (found is { Date: { } fd } && lastCommit is { } lc && lc > fd && unresolved == 0) found = null;
        if (!pr.IsOpen || (unresolved == 0 && found is null)) return null;
        var row = Ui.H(8, Ui.IconTile("", "coral", 18));
        if (unresolved > 0) row.Children.Add(Ui.Text(Fmt.Plural(unresolved, "unresolved comment", "unresolved comments"), 13));
        if (outdated > 0)
        {
            var o = Ui.Text($"· {outdated} outdated", 13, "dim");
            Ui.Tip(o, L.T("Fix_OutdatedHelp", "Code these comments point to has changed since they were written"));
            row.Children.Add(o);
        }
        if (found is not null)
        {
            if (unresolved > 0) row.Children.Add(Ui.Text("·", 13, "dim"));
            row.Children.Add(Ui.Text(L.F("Fix_PromptBy", "Fix prompt by @{0}", found.Author) + (found.Date is { } d ? " · " + Fmt.Rel(d) : ""), 13, "muted"));
        }
        var button = Ui.Button(L.T("Fix_Button", "Fix with agent"), action, accent: true);
        var (fill, text) = Palette.Filled("coral");
        button.Background = fill;
        button.Foreground = text;
        var grid = Ui.Columns((row, Ui.Star), (button, Ui.Auto));
        return new Border { Background = Palette.Brush("coral", 0.08), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6, 8, 6), Child = grid };
    }

    private void RenderToolbar()
    {
        if (model.Pr is null) return;
        var pr = Pr;
        toolbar.Children.Clear();
        if (pr.IsOpen)
        {
            var reviewText = model.PendingCount == 0 ? L.T("PR_Review", "Review") : L.F("PR_ReviewN", "Review ({0})", model.PendingCount);
            var review = new SplitButton
            {
                Content = Ui.H(6, Ui.Glyph("", 13, "text"), new TextBlock { Text = reviewText })
            };
            review.Click += (_, _) => Dialogs.Review(XamlRoot, model).Forget();
            var flyout = Ui.Menu(Ui.MenuItem(L.T("PR_WriteReview", "Write review…"), () => Dialogs.Review(XamlRoot, model).Forget()));
            if (ClaudeLauncher.Available)
                flyout.Items.Add(Ui.MenuItem(L.T("Drafts_Menu", "Draft comments with agent…"), () => Dialogs.DraftComments(XamlRoot, model).Forget()));
            if (model.CanApprove) flyout.Items.Add(Ui.MenuItem(L.T("PR_Approve", "Approve"), () => ConfirmApprove().Forget()));
            if (CloseLoop.Replyable(pr).Count > 0)
                flyout.Items.Add(Ui.MenuItem(L.T("CloseLoop_Menu", "Reply and resolve threads…"), () => Dialogs.CloseLoopThreads(XamlRoot, model, model.ReviewFix?.ThreadIds ?? Array.Empty<string>()).Forget()));
            if (model.Features.RevokeApproval && pr.ViewerApproved == true)
                flyout.Items.Add(Ui.MenuItem(L.T("MR_RevokeApproval", "Revoke approval"), () => Confirm(L.T("MR_RevokeApprovalQ", "Revoke your approval?"), L.T("MR_RevokeApproval", "Revoke approval"), model.RevokeApproval, destructive: false).Forget()));
            if (model.Features.RequestReviewers)
            {
                flyout.Items.Add(Ui.Separator());
                flyout.Items.Add(Ui.MenuItem(L.T("PR_RequestReviewMenu", "Request review…"), () => Dialogs.Reviewers(XamlRoot, model).Forget(), ""));
            }
            review.Flyout = flyout;
            Ui.Tip(review, L.T("PR_SubmitReview", "Submit review"));
            Ui.Named(review, reviewText, L.T("PR_SubmitReview", "Submit review"));
            toolbar.Children.Add(review);
        }
        if (model.Features.Agent)
        {
            var fix = Ui.Button(L.T("Fix_Button", "Fix with agent"), () => Dialogs.FixWithClaude(XamlRoot, model).Forget(), glyph: "", tooltip: L.T("PR_FixWithAgent", "Send review comments to a new agent session"));
            toolbar.Children.Add(fix);
        }
        if (pr.IsOpen && !pr.IsDraft && model.CanWrite)
            toolbar.Children.Add(Ui.Button(L.T("PR_MergeButton", "Merge"), () => Dialogs.Merge(XamlRoot, model).Forget(), glyph: "", tooltip: model.IsGitLab ? L.T("MR_Merge", "Merge merge request") : L.T("PR_Merge", "Merge pull request")));
        toolbar.Children.Add(Ui.RefreshButton(() => model.Load(true)));
        var more = Ui.IconButton("", L.T("Common_MoreActions", "More actions"), () => { }, "text");
        more.Flyout = MoreMenu();
        var group = Ui.H(0, Ui.IconButton("", L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(pr.Url), "text"));
        if (model.Features.IsGitHub) group.Children.Add(Ui.IconButton("\uE8C8", L.T("Menu_CopyShortLinkHint", "Copy short link (Ctrl+Shift+C)"), CopyShortLink, "text"));
        group.Children.Add(more);
        var groupHost = new Border
        {
            Child = group,
            CornerRadius = new CornerRadius(6),
            BorderBrush = Palette.Brush("text", ThemeService.IsDark ? 0.14 : 0.12),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 0, 0)
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(groupHost, L.T("PR_BrowserAndMore", "Browser and more"));
        toolbar.Children.Add(groupHost);
    }

    private void CopyShortLink() => ShellView.CopyShortLink(ShortLink.Of(model.Ref));

    public bool HandleShortcut(string id)
    {
        if (id == Shortcuts.NextThread)
        {
            if (model.Pr is null || model.UnresolvedThreads == 0) return false;
            model.NextUnresolvedThread();
            return true;
        }
        if (id != Shortcuts.ShortLink || !model.Features.IsGitHub) return false;
        CopyShortLink();
        return true;
    }

    private MenuFlyout MoreMenu()
    {
        var pr = Pr;
        var menu = Ui.Menu(
            Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(pr.Url), "\uE774"),
            Ui.Separator(),
            Ui.MenuItem(L.T("Menu_CopyLink", "Copy Link"), () => WindowInterop.Copy(pr.Url), ""));
        if (model.Features.IsGitHub)
        {
            menu.Items.Add(Ui.MenuItem(L.T("Menu_CopyShortLink", "Copy Short Link"), CopyShortLink, "\uE8C8"));
            menu.Items.Add(Ui.MenuItem(L.F("PR_CopyCheckout", "Copy “gh pr checkout {0}”", pr.Number), () => WindowInterop.Copy($"gh pr checkout {pr.Number} -R {model.Ref.Repo.Full}"), ""));
        }
        else if (model.IsGitLab)
            menu.Items.Add(Ui.MenuItem(L.F("MR_CopyCheckout", "Copy “glab mr checkout {0}”", pr.Number), () => WindowInterop.Copy($"glab mr checkout {pr.Number} -R {model.Ref.Repo.Full}"), ""));
        menu.Items.Add(Ui.MenuItem(L.T("PR_CopyBranch", "Copy branch name"), () => WindowInterop.Copy(pr.HeadRefName), ""));
        menu.Items.Add(Ui.Separator());
        if (pr.ViewerCanUpdate && model.Features.Editing) menu.Items.Add(Ui.MenuItem(L.T("PR_Edit", "Edit title and description…"), () => Dialogs.EditPR(XamlRoot, model).Forget(), ""));
        if (pr.IsOpen)
        {
            if (model.Features.RequestReviewers)
                menu.Items.Add(Ui.MenuItem(L.T("PR_RequestReviewMenu", "Request review…"), () => Dialogs.Reviewers(XamlRoot, model).Forget()));
            if (pr.ViewerCanUpdate && model.Features.DraftToggle)
            {
                menu.Items.Add(pr.IsDraft
                    ? Ui.MenuItem(model.IsGitLab ? L.T("MR_MarkReady", "Mark as ready") : L.T("PR_ReadyForReview", "Ready for review"), () => model.Simple(PRAction.ReadyForReview).Forget())
                    : Ui.MenuItem(model.IsGitLab ? L.T("MR_MarkDraft", "Mark as draft") : L.T("PR_ConvertToDraft", "Convert to draft"), () => model.Simple(PRAction.ConvertToDraft).Forget()));
            }
            if (model.Features.UpdateBranch && (model.IsGitLab ? pr.MergeStateStatus == "BEHIND" : pr.MergeStateStatus is "BEHIND" or "BLOCKED" or "UNSTABLE"))
                menu.Items.Add(Ui.MenuItem(model.IsGitLab ? L.F("MR_RebaseOnto", "Rebase onto {0}", pr.BaseRefName) : L.F("PR_UpdateBranchFrom", "Update branch from {0}", pr.BaseRefName), () => UpdateBranch(model).Forget()));
            if (pr.AutoMergeRequest is not null)
                menu.Items.Add(Ui.MenuItem(L.T("PR_DisableAutoMerge", "Disable auto-merge"), () => Confirm(L.T("PR_DisableAutoMergeQ", "Disable auto-merge?"), L.T("PR_Disable", "Disable"), () => model.Simple(PRAction.DisableAutoMerge)).Forget()));
            menu.Items.Add(Ui.Separator());
            if (pr.ViewerCanUpdate)
            {
                menu.Items.Add(model.IsGitLab
                    ? Ui.MenuItem(L.T("MR_Close", "Close merge request…"), () => Confirm(L.T("MR_CloseQ", "Close merge request without merging?"), L.T("MR_CloseButton", "Close merge request"), () => model.Simple(PRAction.Close)).Forget())
                    : Ui.MenuItem(L.T("PR_Close", "Close pull request…"), () => Confirm(L.T("PR_CloseQ", "Close pull request without merging?"), L.T("PR_CloseButton", "Close pull request"), () => model.Simple(PRAction.Close)).Forget()));
            }
        }
        else if (!pr.Merged && pr.ViewerCanUpdate && model.Features.Reopen)
        {
            menu.Items.Add(Ui.MenuItem(model.IsGitLab ? L.T("MR_Reopen", "Reopen merge request") : L.T("PR_Reopen", "Reopen pull request"), () => model.Simple(PRAction.Reopen).Forget()));
        }
        if (model.Features.DeleteBranch && !pr.IsOpen && pr.HeadRef is not null && model.CanWrite)
            menu.Items.Add(Ui.MenuItem(L.F("PR_DeleteBranch", "Delete branch {0}…", pr.HeadRefName), () => Confirm(L.F("PR_DeleteBranchQ", "Delete branch {0}?", pr.HeadRefName), L.T("PR_DeleteBranchButton", "Delete branch"), model.DeleteBranch).Forget()));
        return menu;
    }

    private async Task ConfirmApprove()
    {
        var pending = model.PendingCount;
        var title = pending > 0
            ? L.F("PR_ApprovePendingQ", "Approve and submit {0} pending comment(s)?", pending)
            : model.IsGitLab ? L.T("MR_ApproveQ", "Approve this merge request?") : L.T("PR_ApproveQ", "Approve this pull request?");
        var button = pending > 0 ? L.T("PR_ApproveAndSubmit", "Approve and submit") : L.T("PR_Approve", "Approve");
        if (await Dialogs.Confirm(XamlRoot, title, button, destructive: false))
            await model.SubmitReview("APPROVE", "");
    }

    private async Task Confirm(string title, string button, Func<Task<bool>> action, bool destructive = true)
    {
        if (await Dialogs.Confirm(XamlRoot, title, button, destructive: destructive)) await action();
    }

    private static async Task UpdateBranch(PRDetailViewModel model)
    {
        if (await model.Simple(PRAction.UpdateBranch)) ShellView.Toast(model.UpdatedToast);
    }

    private void RenderTabs()
    {
        var pr = Pr;
        var unresolved = pr.ReviewThreads.Items.Count(t => !t.IsResolved && !t.IsOutdated);
        var checks = pr.Checks;
        var failed = checks.Count(c => c.Outcome == CheckOutcome.Failure);
        var pending = checks.Count(c => c.Outcome == CheckOutcome.Pending);
        var summary = checks.Count == 0 ? "0" : failed > 0 ? $"✕{failed}" : pending > 0 ? $"…{pending}" : $"✓{checks.Count}";
        var color = failed > 0 ? "red" : pending > 0 ? "amber" : checks.Count == 0 ? "muted" : "green";
        tabs.SetTabs(new TabSpec[]
        {
            new TabSpec(nameof(PRTab.Conversation), L.T("PR_TabConversation", "Conversation"), "", unresolved > 0 ? unresolved.ToString() : null),
            new TabSpec(nameof(PRTab.Commits), L.T("PR_TabCommits", "Commits"), "", (pr.AllCommits.TotalCount ?? pr.AllCommits.Items.Count).ToString()),
            new TabSpec(nameof(PRTab.Checks), model.ChecksTitle, "", summary, color),
            new TabSpec(nameof(PRTab.Files), L.T("PR_TabFiles", "Files changed"), "", pr.ChangedFiles.ToString())
        }.Concat(model.StackTree is { } tree ? new[] { new TabSpec(nameof(PRTab.Stack), L.T("PR_TabStack", "Stack"), StackUi.StackGlyph, tree.Count.ToString()) } : Array.Empty<TabSpec>())
         .Concat(JiraService.Account.ShowsTab(pr) ? new[] { new TabSpec(nameof(PRTab.Jira), L.T("PR_TabJira", "Jira"), "\uE8EC", JiraService.Account.Keys(pr).FirstOrDefault()) } : Array.Empty<TabSpec>()));
        tabs.Selected = model.Tab.ToString();
    }

    private void ShowTab()
    {
        tabs.Selected = model.Tab.ToString();
        if (model.Tab != PRTab.Stack && tabViews.Remove(PRTab.Stack, out var stackView)) tabArea.Children.Remove(stackView);
        if (!tabViews.ContainsKey(model.Tab))
        {
            var view = model.Tab switch
            {
                PRTab.Conversation => BuildConversation(),
                PRTab.Commits => BuildCommits(null),
                PRTab.Checks => BuildChecks(null),
                PRTab.Stack => new StackTab(model),
                PRTab.Jira => new JiraTab(model),
                _ => BuildFiles()
            };
            tabViews[model.Tab] = view;
            tabArea.Children.Add(view);
        }
        foreach (var (tab, view) in tabViews) view.Visibility = tab == model.Tab ? Visibility.Visible : Visibility.Collapsed;
        if (model.Tab == PRTab.Files) model.LoadFiles().Forget();
    }

    private FrameworkElement BuildConversation()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        conversation = new HtmlView();
        conversation.LinkClicked += url => HtmlView.OpenLink(url);
        conversation.ActionInvoked += OnConversationAction;
        grid.Children.Add(conversation);
        nextThread = Ui.Button("", model.NextUnresolvedThread, glyph: "\uE74B", tooltip: L.T("PR_NextThreadTip", "Jump to the next unresolved thread (Ctrl+Alt+Down)"));
        nextThread.HorizontalAlignment = HorizontalAlignment.Right;
        nextThread.VerticalAlignment = VerticalAlignment.Bottom;
        nextThread.Margin = new Thickness(10);
        grid.Children.Add(nextThread);
        SyncNextThread();
        var composer = Composer(L.T("PR_CommentPlaceholder", "Comment (Markdown) — Ctrl+Enter to send"), L.T("PR_Comment", "Comment"), model.Comment);
        SetRow(composer, 1);
        grid.Children.Add(composer);
        RenderConversation();
        return grid;
    }

    public static FrameworkElement Composer(string placeholder, string buttonText, Func<string, Task<bool>> send)
    {
        var box = new TextBox { PlaceholderText = placeholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 200 };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        Ui.Named(box, buttonText, placeholder);
        var button = TextZoom.Track(new Button { VerticalAlignment = VerticalAlignment.Bottom }, 14);
        var busy = false;
        void Sync()
        {
            var empty = box.Text.Trim().Length == 0;
            var accent = !empty && !busy;
            button.Style = (Style)Application.Current.Resources[accent ? "AccentButtonStyle" : "DefaultButtonStyle"];
            button.Content = busy ? Ui.H(6, Ui.Spinner(14), new TextBlock { Text = L.T("Composer_Sending", "Sending…") }) : buttonText;
            button.IsEnabled = !busy;
            var tip = busy ? L.T("Composer_Sending", "Sending…") : empty ? L.T("Composer_WriteFirst", "Write a comment to send it") : L.T("Composer_SendHint", "Send comment (Ctrl+Enter)");
            ToolTipService.SetToolTip(button, tip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, busy ? L.T("Composer_Sending", "Sending…") : buttonText);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(button, tip);
        }
        Sync();
        var wasEmpty = true;
        box.TextChanged += (_, _) =>
        {
            var empty = box.Text.Trim().Length == 0;
            if (empty == wasEmpty) return;
            wasEmpty = empty;
            Sync();
        };
        async Task Submit()
        {
            var body = box.Text;
            if (busy) return;
            if (body.Trim().Length == 0)
            {
                box.Focus(FocusState.Programmatic);
                return;
            }
            busy = true;
            Sync();
            try
            {
                if (await send(body)) box.Text = "";
            }
            finally
            {
                busy = false;
                wasEmpty = box.Text.Trim().Length == 0;
                Sync();
            }
        }
        button.Click += (_, _) => Submit().Forget();
        var acc = new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control };
        acc.Invoked += (_, e) =>
        {
            e.Handled = true;
            Submit().Forget();
        };
        box.KeyboardAccelerators.Add(acc);
        var grid = Ui.Columns((box, Ui.Star), (button, Ui.Auto));
        grid.Padding = new Thickness(10);
        var wrapper = new Grid();
        var line = Ui.Line();
        line.VerticalAlignment = VerticalAlignment.Top;
        wrapper.Children.Add(line);
        wrapper.Children.Add(grid);
        return wrapper;
    }

    private void RenderConversation()
    {
        if (conversation is null || model.Html.Length == 0 || model.Html == lastHtml) return;
        var first = lastHtml.Length == 0;
        lastHtml = model.Html;
        conversation.Render(model.Html, "conversation", first ? "top" : null);
        if (model.ScrollToBottomToken != lastScrollToken)
        {
            lastScrollToken = model.ScrollToBottomToken;
            conversation.ScrollToBottom();
        }
        FocusThread();
    }

    private void FocusThread()
    {
        if (conversation is null || lastHtml.Length == 0 || model.ThreadFocusToken == lastFocusToken) return;
        lastFocusToken = model.ThreadFocusToken;
        conversation.Send(new JsonObject { ["op"] = "focusThread" });
    }

    private void SyncNextThread()
    {
        if (nextThread is null) return;
        var open = model.UnresolvedThreads;
        nextThread.Visibility = open > 0 ? Visibility.Visible : Visibility.Collapsed;
        var label = open == 1 ? L.T("PR_NextThreadOne", "1 unresolved · Next") : L.F("PR_NextThreadMany", "{0} unresolved · Next", open);
        if (nextThread.Content is StackPanel panel && panel.Children.LastOrDefault() is TextBlock text) text.Text = label;
        AutomationProperties.SetName(nextThread, label);
    }

    private void OnConversationAction(string type, string id)
    {
        switch (type)
        {
            case "reply":
                if (Pr.ReviewThreads.Items.FirstOrDefault(t => t.Id == id) is { } thread) Dialogs.Reply(XamlRoot, model, thread).Forget();
                break;
            case "resolve":
                model.SetResolved(id, true).Forget();
                break;
            case "unresolve":
                model.SetResolved(id, false).Forget();
                break;
            case "file":
                model.RevealFile(id);
                model.LoadFiles().Forget();
                break;
        }
    }

    private FrameworkElement BuildCommits(FrameworkElement? existing)
    {
        var list = existing as ListView ?? ListSupport.Create("GenericRowTemplate");
        if (existing is null)
        {
            list.ItemClick += (_, e) =>
            {
                if (e.ClickedItem is CommitRowItem c) app.Open(Route.Commit(model.Ref.Repo, c.Commit.Oid), true);
            };
            list.SelectionMode = ListViewSelectionMode.None;
            list.ContextRequested += (_, args) =>
            {
                if ((args.OriginalSource as FrameworkElement)?.DataContext is not CommitRowItem c) return;
                args.Handled = true;
                Ui.Menu(
                    Ui.MenuItem(L.T("Commit_CopySha", "Copy SHA"), () => WindowInterop.Copy(c.Commit.Oid)),
                    Ui.MenuItem(L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(c.Commit.Url))).ShowAt((FrameworkElement)args.OriginalSource);
            };
        }
        if (model.Pr is { } pr)
        {
            var items = pr.AllCommits.Items.AsEnumerable().Reverse().Select(c => (object)new CommitRowItem(c.Commit)).ToList();
            if ((pr.AllCommits.TotalCount ?? 0) > pr.AllCommits.Items.Count)
                items.Add(new ActionRowItem(L.F("PR_AllCommits", "Show all {0} commits in browser", pr.AllCommits.TotalCount ?? 0), () => LinkBrowser.Open(pr.Url + "/commits")));
            list.ItemsSource = items;
        }
        return list;
    }

    private FrameworkElement BuildChecks(FrameworkElement? existing)
    {
        var list = existing as ListView ?? ListSupport.Create("GenericRowTemplate", ListViewSelectionMode.None);
        if (existing is null)
        {
            list.ItemClick += (_, e) =>
            {
                if (e.ClickedItem is ActionRowItem a) a.Action();
            };
        }
        if (model.Pr is { } pr)
        {
            var checks = pr.Checks.OrderBy(c => (int)c.Outcome).ThenBy(c => c.Title).ToList();
            var failedRuns = model.FailedRuns;
            var items = new List<object>();
            if (checks.Count == 0) items.Add(new TextRowItem(model.IsGitLab ? L.T("MR_NoPipeline", "No pipeline for the latest commit") : model.Features.IsBitbucket ? L.T("BB_NoBuilds", "No builds for the latest commit") : L.T("Checks_None", "No checks for the latest commit")));
            if (model.Features.RerunChecks && failedRuns > 0 && model.CanWrite) items.Add(new ActionRowItem(L.F("Checks_Rerun", "Re-run failed jobs ({0} workflow)", failedRuns), () => ConfirmRerun().Forget(), ""));
            foreach (var c in checks)
            {
                void Fix() => Dialogs.FixCi(XamlRoot, model, c).Forget();
                var backend = model.Backend;
                var reference = model.Ref;
                Action log = () => Dialogs.JobLog(XamlRoot, () => backend.JobLog(reference, c), c, model.Features.Agent ? l => Dialogs.FixCi(XamlRoot, model, c, l).Forget() : null).Forget();
                items.Add(new CheckRowItem(c, log, model.Features.Agent && CiFailures.IsFixable(c) ? new Action(Fix) : null, model.Features.JobLogs && backend.CanShowLog(c)));
            }
            list.ItemsSource = items;
        }
        return list;
    }

    private FrameworkElement BuildFiles()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.3, GridUnitType.Star), MinWidth = 180, MaxWidth = 300 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.7, GridUnitType.Star) });

        var side = new Grid { Background = ThemeService.IsBrand ? Palette.Brush("list") : null };
        side.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        side.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        fileFilter = new TextBox { PlaceholderText = L.T("Files_Filter", "Filter files") };
        viewedCount = Ui.Caption("");
        Ui.Tip(viewedCount, model.Features.ViewedFiles ? L.T("Files_Viewed", "Viewed") : L.T("Files_Count", "Files"));
        DispatcherTimer? debounce = null;
        fileFilter.TextChanged += (_, _) =>
        {
            debounce?.Stop();
            debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            debounce.Tick += (t, _) =>
            {
                ((DispatcherTimer)t!).Stop();
                RenderFiles();
            };
            debounce.Start();
        };
        var filterRow = Ui.Columns((fileFilter, Ui.Star), (viewedCount, Ui.Auto));
        filterRow.Padding = new Thickness(8);
        side.Children.Add(filterRow);
        fileList = ListSupport.Create("GenericRowTemplate");
        fileList.SelectionChanged += (_, _) =>
        {
            if (fileList.SelectedItem is FileListItem f && model.ScrollTarget != f.File.Id) model.RevealFile(f.File.Id);
        };
        SetRow(fileList, 1);
        side.Children.Add(fileList);
        grid.Children.Add(side);

        var line = Ui.Line(vertical: true);
        SetColumn(line, 1);
        grid.Children.Add(line);

        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        right.Children.Add(ReviewBar());
        SetRow(interdiffBanner, 1);
        right.Children.Add(interdiffBanner);
        RenderInterdiffBanner();
        diff = new HtmlView();
        diff.LinkClicked += url => HtmlView.OpenLink(url);
        diff.ActionInvoked += OnDiffAction;
        diff.SizeChanged += (_, e) =>
        {
            var fits = e.NewSize.Width >= DiffPrefs.SplitMinWidth;
            if (fits == splitFits) return;
            splitFits = fits;
            SyncReviewBar();
            RenderFiles();
        };
        SetRow(diff, 2);
        right.Children.Add(diff);
        SetColumn(right, 2);
        grid.Children.Add(right);
        renderedDiffVersion = -1;
        RenderFiles();
        return grid;
    }

    private static bool WrapPref => Settings.Shared.GetBool(DiffPrefs.WrapKey, true);

    private static bool SplitPref => Settings.Shared.GetBool(DiffPrefs.SplitKey, false);

    private bool SplitActive => SplitPref && splitFits;

    private FrameworkElement ReviewBar()
    {
        Button Nav(string glyph, string title, string key, string id)
        {
            var b = Ui.IconButton(glyph, L.F("Files_ShortcutTip", "{0} ({1})", title, key), () => Perform(id), "text");
            b.Padding = new Thickness(7, 4, 7, 4);
            AutomationProperties.SetName(b, title);
            AutomationProperties.SetAcceleratorKey(b, key);
            return b;
        }
        wrapBox = new CheckBox { Content = L.T("Files_WrapLines", "Wrap lines"), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(wrapBox, L.T("Files_WrapTip", "Wrap long lines (W)"));
        AutomationProperties.SetAcceleratorKey(wrapBox, "W");
        wrapBox.Click += (_, _) =>
        {
            if (!syncingReviewBar) Settings.Shared.Set(DiffPrefs.WrapKey, wrapBox.IsChecked == true);
        };
        layoutBox = new ComboBox { MinWidth = 104, VerticalAlignment = VerticalAlignment.Center };
        layoutBox.Items.Add(L.T("Files_Unified", "Unified"));
        layoutBox.Items.Add(L.T("Files_Split", "Split"));
        AutomationProperties.SetName(layoutBox, L.T("Files_DiffLayout", "Diff layout"));
        AutomationProperties.SetAcceleratorKey(layoutBox, "S");
        layoutBox.SelectionChanged += (_, _) =>
        {
            if (!syncingReviewBar && layoutBox.SelectedIndex >= 0 && splitFits) Settings.Shared.Set(DiffPrefs.SplitKey, layoutBox.SelectedIndex == 1);
        };
        var nav = Ui.H(2,
            Nav("\uE70E", L.T("Files_PrevFile", "Previous file"), "P", "p"),
            Nav("\uE70D", L.T("Files_NextFile", "Next file"), "N", "n"),
            Ui.Line(vertical: true),
            Nav("\uE74A", L.T("Files_PrevHunk", "Previous hunk"), "[", "["),
            Nav("\uE74B", L.T("Files_NextHunk", "Next hunk"), "]", "]"));
        scopeBox = new ComboBox { MinWidth = 120, VerticalAlignment = VerticalAlignment.Center };
        scopeBox.Items.Add(L.T("Files_ScopeAll", "All changes"));
        scopeBox.Items.Add("");
        AutomationProperties.SetName(scopeBox, L.T("Files_ScopeName", "Changes to show"));
        ToolTipService.SetToolTip(scopeBox, L.T("Files_ScopeTip", "Show only what changed since your last review"));
        scopeBox.SelectionChanged += (_, _) =>
        {
            if (!syncingReviewBar && scopeBox.SelectedIndex >= 0) model.DiffScope = scopeBox.SelectedIndex == 1 ? DiffScope.SinceReview : DiffScope.All;
        };
        var options = Ui.H(12, wrapBox, layoutBox);
        var row = Ui.Columns((nav, Ui.Auto), (scopeBox, Ui.Auto), (null, Ui.Star), (options, Ui.Auto));
        row.ColumnSpacing = 12;
        row.Padding = new Thickness(8, 4, 10, 4);
        AutomationProperties.SetName(row, L.T("Files_ReviewBar", "Review navigation"));
        SyncReviewBar();
        SyncScope();
        var line = Ui.Line();
        line.VerticalAlignment = VerticalAlignment.Bottom;
        var bar = new Grid();
        bar.Children.Add(row);
        bar.Children.Add(line);
        return bar;
    }

    private void SyncReviewBar()
    {
        if (wrapBox is null || layoutBox is null) return;
        syncingReviewBar = true;
        wrapBox.IsChecked = WrapPref;
        layoutBox.SelectedIndex = SplitActive ? 1 : 0;
        layoutBox.IsEnabled = splitFits;
        ToolTipService.SetToolTip(layoutBox, splitFits ? L.T("Files_LayoutTip", "Unified or side-by-side diff (S)") : L.T("Files_LayoutNarrow", "Widen the window to use split view"));
        syncingReviewBar = false;
    }

    private static string SinceTitle(ReviewedCommit r) => r.CommitsSince switch
    {
        null => L.T("Files_ScopeSince", "Since your review"),
        1 => L.T("Files_ScopeSinceOne", "Since your review · 1 commit"),
        { } n => L.F("Files_ScopeSinceN", "Since your review · {0} commits", n)
    };

    private void SyncScope()
    {
        if (scopeBox is null) return;
        syncingReviewBar = true;
        if (model.LastReviewed is { } reviewed)
        {
            scopeBox.Items[1] = SinceTitle(reviewed);
            scopeBox.SelectedIndex = model.DiffScope == DiffScope.SinceReview ? 1 : 0;
            scopeBox.Visibility = Visibility.Visible;
        }
        else
        {
            scopeBox.SelectedIndex = 0;
            scopeBox.Visibility = Visibility.Collapsed;
        }
        syncingReviewBar = false;
    }

    private void RenderInterdiffBanner()
    {
        if (model.DiffScope != DiffScope.SinceReview)
        {
            interdiffBanner.Content = null;
            interdiffBanner.Visibility = Visibility.Collapsed;
            return;
        }
        interdiffBanner.Visibility = Visibility.Visible;
        string? text = null;
        if (model.InterdiffLoading) text = L.T("Interdiff_Loading", "Comparing with the commit you reviewed…");
        else if (model.InterdiffError is { } e) text = L.F("Interdiff_Error", "Couldn’t load changes since your review: {0}", e);
        else if (model.InterdiffRebased) text = L.F("Interdiff_Rebased", "The branch was rebased or force-pushed after your review, so this can include changes from {0}.", model.Pr?.BaseRefName ?? L.T("Interdiff_BaseBranch", "the base branch"));
        else if (model.InterdiffFiles.Count == 0) text = L.T("Interdiff_Empty", "No file changes since your review.");
        var line = Ui.Line();
        line.VerticalAlignment = VerticalAlignment.Bottom;
        var host = new Grid();
        if (text is null)
        {
            var note = Ui.Caption(L.T("Interdiff_ReadOnly", "Read-only: comments are hidden while comparing with your last review. Switch to All changes to comment."));
            note.TextWrapping = TextWrapping.WrapWholeWords;
            note.Margin = new Thickness(12, 4, 12, 4);
            host.Children.Add(note);
        }
        else
        {
            var failed = model.InterdiffError is not null;
            var message = Ui.Caption(text);
            message.TextWrapping = TextWrapping.WrapWholeWords;
            var retry = failed ? Ui.Button(L.T("Common_Retry", "Retry"), () => model.LoadInterdiff(true).Forget()) : null;
            var row = Ui.Columns((Ui.Glyph(failed ? "\uE7BA" : "\uE946", 13, failed ? "amber" : "muted"), Ui.Auto), (message, Ui.Star), (retry, Ui.Auto));
            row.ColumnSpacing = 8;
            row.Padding = new Thickness(12, 5, 12, 5);
            host.Background = Palette.Brush("amber", 0.12);
            host.Children.Add(row);
        }
        host.Children.Add(line);
        interdiffBanner.Content = host;
    }

    private void OnSettings(string key)
    {
        if (key is not (DiffPrefs.WrapKey or DiffPrefs.SplitKey)) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            SyncReviewBar();
            RenderFiles();
        });
    }

    private void OnReviewCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (e.Handled || model.Tab != PRTab.Files || diff is null) return;
        var key = e.Character switch
        {
            'n' => "n",
            'p' => "p",
            '[' => "[",
            ']' => "]",
            'v' => "v",
            'w' => "w",
            's' => "s",
            _ => null
        };
        if (key is null || XamlRoot is null) return;
        if (FocusManager.GetFocusedElement(XamlRoot) is TextBox or RichEditBox or PasswordBox or AutoSuggestBox) return;
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down)) return;
        if (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down)) return;
        e.Handled = Perform(key);
    }

    private bool Perform(string key)
    {
        switch (key)
        {
            case "n" or "p" or "[" or "]" or "v":
                if (diff is null || !model.FilesLoaded) return false;
                diff.Send(new JsonObject { ["op"] = "review", ["key"] = key });
                return true;
            case "w":
                Settings.Shared.Set(DiffPrefs.WrapKey, !WrapPref);
                return true;
            case "s":
                if (!splitFits) return false;
                Settings.Shared.Set(DiffPrefs.SplitKey, !SplitActive);
                return true;
            default:
                return false;
        }
    }

    private void RenderFiles()
    {
        if (diff is null || fileList is null) return;
        var interdiff = model.DiffScope == DiffScope.SinceReview;
        if (!model.FilesLoaded && !interdiff)
        {
            if (model.FilesError is { } e) diff.Render($"<div class=\"tl\"><p class=\"empty\">{ConversationHtml.Esc(e)}</p></div>");
            return;
        }
        var filter = fileFilter?.Text.Trim() ?? "";
        var shown = model.DisplayedFiles;
        var visible = shown.Where(f => filter.Length == 0 || f.Id.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
        var selected = model.ScrollTarget;
        fileList.ItemsSource = visible.Select(f => new FileListItem(f, model.ViewedPaths.Contains(f.Id), model.ThreadCount(f.Id))).ToList();
        if (selected is not null) fileList.SelectedItem = (fileList.ItemsSource as List<FileListItem>)?.FirstOrDefault(f => f.File.Id == selected);
        if (viewedCount is not null) viewedCount.Text = model.Features.ViewedFiles ? $"{model.ViewedPaths.Intersect(shown.Select(f => f.Id)).Count()}/{shown.Count}" : shown.Count.ToString();
        var layout = $"{WrapPref}|{SplitActive}|{model.DiffScope}";
        if (renderedDiffVersion == model.DiffVersion && renderedFilter == filter && renderedLayout == layout) return;
        var first = renderedDiffVersion < 0;
        renderedDiffVersion = model.DiffVersion;
        renderedFilter = filter;
        renderedLayout = layout;
        var html = DiffHtml.Render(shown, model.RenderOptions(filter, WrapPref, SplitActive));
        diff.Render(html, "diff", first && selected is not null ? "file:" + selected : first ? "top" : null, "flush review");
    }

    private void OnDiffAction(string type, string id)
    {
        switch (type)
        {
            case "comment":
            {
                var parts = id.Split('|');
                if (model.DiffScope == DiffScope.All && parts.Length >= 3 && int.TryParse(parts[^1], out var line))
                {
                    var path = string.Join("|", parts[..^2]);
                    Dialogs.InlineComment(XamlRoot, model, new DiffAnchor(path, line, parts[^2])).Forget();
                }
                break;
            }
            case "viewed":
                model.ToggleViewed(id).Forget();
                break;
            case "copy":
                WindowInterop.Copy(id);
                break;
            case "blame":
                if (model.Pr is { } pr) RepoDetailView.OpenFile(model.Ref.Repo, pr.HeadRefOid.Length > 0 ? pr.HeadRefOid : $"refs/pull/{model.Ref.Number}/head", id, true);
                break;
            case "collapse":
                model.Collapsed.Add(id);
                break;
            case "expand":
                model.Collapsed.Remove(id);
                if (model.DisplayedFiles.FirstOrDefault(f => f.Id == id) is { } file)
                    diff?.Send(new JsonObject { ["op"] = "fileBody", ["path"] = id, ["html"] = DiffHtml.Body(file, model.RenderOptions("", WrapPref, SplitActive)) });
                break;
            case "review":
                Perform(id);
                break;
            case "reveal":
                model.RevealFile(id);
                break;
            case "deletePending":
                if (Guid.TryParse(id, out var gid)) model.RemovePending(gid);
                break;
            case "reply":
                if (Pr.ReviewThreads.Items.FirstOrDefault(t => t.Id == id) is { } thread) Dialogs.Reply(XamlRoot, model, thread).Forget();
                break;
            case "resolve":
                model.SetResolved(id, true).Forget();
                break;
            case "unresolve":
                model.SetResolved(id, false).Forget();
                break;
        }
    }
}

public sealed record TextRowItem(string Text) : IRowContent
{
    public UIElement BuildRow()
    {
        var t = Ui.Text(Text, 13, "muted");
        t.Margin = new Thickness(0, 8, 0, 8);
        return t;
    }
}

public sealed record ActionRowItem(string Text, Action Action, string Glyph = "") : IRowContent
{
    public UIElement BuildRow()
    {
        var p = Ui.H(8, Ui.Glyph(Glyph, 12, "accent"), Ui.Text(Text, 13, "accent"));
        p.Margin = new Thickness(0, 8, 0, 8);
        return p;
    }
}

public sealed record CommitRowItem(CommitInfo Commit) : IRowContent
{
    public UIElement BuildRow()
    {
        var c = Commit;
        var body = Ui.V(2, Ui.Text(c.MessageHeadline, 13, maxLines: 2), Ui.Caption($"{c.Author?.User?.Login ?? c.Author?.Name ?? ""} · {Fmt.Rel(c.CommittedDate)}"));
        var right = Ui.H(8);
        if (Ui.CiIcon(c.StatusCheckRollup?.State) is { } ci) right.Children.Add(ci);
        right.Children.Add(Ui.Text(c.AbbreviatedOid, 12, "muted", mono: true));
        var grid = Ui.Columns((Ui.Avatar(c.Author?.AvatarUrl, 22), Ui.Auto), (body, Ui.Star), (right, Ui.Auto));
        grid.ColumnSpacing = 10;
        grid.Padding = new Thickness(0, 6, 0, 6);
        return grid;
    }
}

public sealed record CheckRowItem(CheckContext Check, Action ShowLog, Action? Fix = null, bool Logs = true) : IRowContent
{
    public UIElement BuildRow()
    {
        var c = Check;
        var parts = new List<string>
        {
            c.Outcome switch
            {
                CheckOutcome.Success => "Successful",
                CheckOutcome.Failure => "Failed",
                CheckOutcome.Pending => c.Status == "QUEUED" ? "Queued" : "In progress",
                CheckOutcome.Neutral => c.Conclusion == "CANCELLED" ? "Cancelled" : "Neutral",
                _ => "Skipped"
            }
        };
        if (c.Duration is { } d) parts.Add(d);
        if (!string.IsNullOrEmpty(c.Description)) parts.Add(c.Description);
        var body = Ui.V(1, Ui.Text(c.FullTitle, 13), Ui.Caption(string.Join(" · ", parts)));
        var right = Ui.H(4);
        if (Fix is not null) right.Children.Add(Ui.Button(L.T("Fix_Button", "Fix with agent"), Fix, glyph: "\uE945", tooltip: L.T("CiFix_RowHelp", "Send this check's log and the PR context to Claude Code")));
        if (Logs && c.Outcome is not CheckOutcome.Pending and not CheckOutcome.Skipped)
            right.Children.Add(Ui.Button(L.T("Checks_Log", "Log"), ShowLog));
        if (c.Link is { } link) right.Children.Add(Ui.IconButton("", L.T("Menu_OpenInBrowser", "Open in Browser"), () => LinkBrowser.Open(link)));
        var grid = Ui.Columns((Ui.CheckIcon(c.Outcome, 15), Ui.Auto), (body, Ui.Star), (right, Ui.Auto));
        grid.ColumnSpacing = 10;
        grid.Padding = new Thickness(0, 4, 0, 4);
        return grid;
    }
}

public sealed record FileListItem(DiffFile File, bool Viewed, int Threads) : IRowContent
{
    public UIElement BuildRow()
    {
        var color = File.Status switch
        {
            "added" => "green",
            "removed" => "red",
            "renamed" => "violet",
            _ => "amber"
        };
        var letter = Ui.Text(File.StatusLetter, 11, color, FontWeights.Bold, mono: true);
        letter.Width = 12;
        var dir = Ui.Text(File.Directory, 11, "muted");
        dir.TextTrimming = TextTrimming.CharacterEllipsis;
        var right = Ui.H(4);
        if (Threads > 0) right.Children.Add(Ui.Glyph("", 11));
        if (Viewed) right.Children.Add(Ui.Glyph("", 12, "green"));
        var grid = Ui.Columns((letter, Ui.Auto), (Ui.V(0, Ui.Text(File.FileName, 13), dir), Ui.Star), (right, Ui.Auto));
        grid.ColumnSpacing = 6;
        grid.Padding = new Thickness(0, 3, 0, 3);
        Ui.Tip(grid, File.Id);
        return grid;
    }
}

public static class MergeMethods
{
    public static readonly string[] All = { "MERGE", "SQUASH", "REBASE" };

    public static string Title(string m) => m switch
    {
        "SQUASH" => L.T("Merge_Squash", "Squash and merge"),
        "REBASE" => L.T("Merge_Rebase", "Rebase and merge"),
        _ => L.T("Merge_Commit", "Merge commit")
    };
}
