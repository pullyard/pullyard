using CommunityToolkit.Mvvm.ComponentModel;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Html;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using PullYard.Services;

namespace PullYard.ViewModels;

public enum PRTab { Conversation, Commits, Checks, Files, Stack, Jira }

public sealed record ReviewerInfo(string Login, string? Avatar, string State, bool IsTeam = false, bool CodeOwner = false);

public sealed record StaleReview(string Login, int? Commits);

public sealed record CiFixLaunch(ClaudeTarget Target, ClaudeTab? Tab, string HeadOid, DateTimeOffset At);

public sealed partial class PRDetailViewModel : ObservableObject
{
    public ItemRef Ref { get; }
    public IPRBackend Backend { get; }
    public GitHubApi? Api => Backend.GitHub;
    public PRFeatures Features => Backend.Features;
    public GitProvider Provider => Backend.Features.Provider;

    [ObservableProperty] private PRRepository? repo;
    [ObservableProperty] private PullRequestDetail? pr;
    [ObservableProperty] private string viewerLogin = "";
    [ObservableProperty] private bool notPR;
    [ObservableProperty] private bool loading;
    [ObservableProperty] private DateTimeOffset? lastUpdated;
    [ObservableProperty] private string? refreshError;
    [ObservableProperty] private string? error;
    [ObservableProperty] private string? actionError;
    [ObservableProperty] private bool busy;
    [ObservableProperty] private PRTab tab = PRTab.Conversation;
    [ObservableProperty] private StackTree? stackTree;
    [ObservableProperty] private StackNode? preview;
    [ObservableProperty] private string html = "";
    [ObservableProperty] private int scrollToBottomToken;
    [ObservableProperty] private List<DiffFile> files = new();
    [ObservableProperty] private bool filesLoaded;
    [ObservableProperty] private bool filesLoading;
    [ObservableProperty] private string? filesError;
    [ObservableProperty] private string? scrollTarget;
    [ObservableProperty] private int diffVersion;
    [ObservableProperty] private CiFixLaunch? ciFix;
    [ObservableProperty] private RulesStatus rulesState = RulesStatus.Loading;
    [ObservableProperty] private CodeOwnersStatus codeOwnersState = CodeOwnersStatus.Loading;
    [ObservableProperty] private DiffScope diffScope = DiffScope.All;
    [ObservableProperty] private List<DiffFile> interdiffFiles = new();
    [ObservableProperty] private bool interdiffLoading;
    [ObservableProperty] private string? interdiffError;
    [ObservableProperty] private bool interdiffRebased;
    private string? interdiffKey;
    private string? rulesKey;
    private string? ownersKey;
    private DateTimeOffset? rulesFetched;
    private CancellationTokenSource? viewedLoad;

    public HashSet<string> ViewedPaths { get; private set; } = new();
    public List<string> ChangedPaths { get; private set; } = new();
    public HashSet<string> Collapsed { get; private set; } = new();
    public List<PendingComment> Pending { get; } = new();
    public bool FilesInInspector { get; set; }

    private bool FilesVisible => Tab == PRTab.Files || FilesInInspector;

    private Task? activeLoad;
    private Task? queuedLoad;
    private bool reloadFiles;
    private string? forcedReason;
    private bool reloadStack;
    private string? stackKey;
    private string? filesOid;
    private bool filesOutdated;
    private string? signature;
    private bool pulseUnsupported;
    private DateTimeOffset lastFullFetch;

    public static readonly TimeSpan FullFetchInterval = TimeSpan.FromMinutes(5);
    private CancellationTokenSource? mergeRecheck;
    private int mergeRechecks;
    private Dictionary<string, List<ReviewThread>> threadIndex = new();
    private Dictionary<string, List<ReviewThread>> outdatedByPath = new();
    private readonly Dictionary<string, CiFailure> ciFailures = new();

    public PRDetailViewModel(ItemRef r, IPRBackend backend, string? cacheAccount)
    {
        Ref = r;
        Backend = backend;
        CacheAccount = cacheAccount;
        if (!backend.Features.CodeOwners) codeOwnersState = CodeOwnersStatus.Missing;
    }

    public string? CacheAccount { get; }

    public bool CanWrite => Repo?.CanWrite ?? false;

    public int PendingCount => Pending.Count;

    public bool IsGitLab => Features.IsGitLab;

    public string NumberText => Provider.NumberPrefix() + (Pr?.Number ?? Ref.Number);

    public string ChecksTitle => IsGitLab ? L.T("PR_Pipeline", "Pipeline") : L.T("PR_TabChecks", "Checks");

    public string UpdateBranchTitle => IsGitLab ? L.T("MR_Rebase", "Rebase") : L.T("Merge_UpdateBranch", "Update branch");

    public string UpdatedToast => IsGitLab ? L.T("MR_RebaseStarted", "Rebase started") : L.F("PR_BranchUpdated", "Branch updated from {0}", Pr?.BaseRefName ?? "");

    public bool CanApprove => Pr is { } pr && (pr.ViewerCanApprove ?? !pr.ViewerDidAuthor) && pr.ViewerApproved != true;

    public (int Additions, int Deletions)? DiffStat
    {
        get
        {
            if (Pr is not { } pr) return null;
            if (Features.IsGitHub || pr.Additions + pr.Deletions > 0) return (pr.Additions, pr.Deletions);
            if (!FilesLoaded) return null;
            return (Files.Sum(f => f.Additions), Files.Sum(f => f.Deletions));
        }
    }

    public ReviewedCommit? LastReviewed => Pr is { } pr ? Interdiff.LastReviewed(pr, ViewerLogin) : null;

    public List<DiffFile> DisplayedFiles => DiffScope == DiffScope.SinceReview ? InterdiffFiles : Files;

    partial void OnDiffScopeChanged(DiffScope value)
    {
        DiffVersion++;
        if (value == DiffScope.SinceReview) LoadInterdiff().Forget();
    }

    public async Task LoadInterdiff(bool force = false)
    {
        if (Pr is not { } pr || LastReviewed is not { } reviewed || Api is not { } api)
        {
            DiffScope = DiffScope.All;
            return;
        }
        var key = $"{reviewed.Oid}...{pr.HeadRefOid}";
        if ((!force && key == interdiffKey) || InterdiffLoading) return;
        InterdiffLoading = true;
        try
        {
            var result = await api.Compare(Ref.Repo, reviewed.Oid, pr.HeadRefOid);
            var raw = result.Files ?? new();
            var parsed = await Task.Run(() => raw.Select(f => new DiffFile(f)).ToList());
            InterdiffFiles = parsed;
            interdiffKey = key;
            InterdiffError = null;
            InterdiffRebased = reviewed.Rewritten || (result.BehindBy ?? 0) > 0;
            Collapsed.ExceptWith(parsed.Select(f => f.Id));
            DiffVersion++;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            InterdiffError = e.Message;
        }
        finally
        {
            InterdiffLoading = false;
        }
    }

    public List<ReviewerInfo> Reviewers
    {
        get
        {
            if (Pr is not { } pr) return new();
            var result = pr.LatestOpinionatedReviews.Items.Where(r => r.Author is not null).Select(r => new ReviewerInfo(r.Author!.Login, r.Author.AvatarUrl, r.State)).ToList();
            var done = result.Select(r => r.Login).ToHashSet();
            foreach (var req in pr.ReviewRequests.Items)
            {
                if (req.RequestedReviewer is not { } rv || done.Contains(rv.Display)) continue;
                result.Add(new ReviewerInfo(rv.Display, rv.AvatarUrl, "PENDING", rv.IsTeam, req.AsCodeOwner == true));
            }
            return result;
        }
    }

    public List<MergeRequirement> Requirements => Pr is { } pr ? MergeReadiness.Requirements(pr, RulesState) : new();

    public static (string glyph, string color, string text, bool ready) Headline(PullRequestDetail pr, List<MergeRequirement> requirements)
    {
        var checks = pr.Checks;
        var anyFailed = checks.Count(c => c.Outcome == CheckOutcome.Failure);
        var anyPending = checks.Count(c => c.Outcome == CheckOutcome.Pending);
        var breakdown = MergeReadiness.Checks(checks, null);
        var failed = breakdown.FailedRequired.Count;
        var pending = breakdown.RunningRequired.Count;
        var firstMissing = requirements.FirstOrDefault(r => r.State == RequirementState.Missing);
        var firstPending = requirements.FirstOrDefault(r => r.State == RequirementState.Pending);
        var failedText = failed == 1 ? L.T("Merge_OneCheckFailed", "1 check failed") : L.F("Merge_ChecksFailed", "{0} checks failed", failed);
        var pendingText = pending == 1 ? L.T("Merge_OneCheckRunning", "1 check is still running") : L.F("Merge_ChecksRunning", "{0} checks are still running", pending);
        (string glyph, string color, string text, bool ready) s;
        if (pr.IsDraft) s = ("", "slate", L.T("Merge_Draft", "Draft — merging is unavailable"), false);
        else if (pr.Mergeable == "CONFLICTING" || pr.MergeStateStatus == "DIRTY") s = ("", "red", L.F("Merge_Conflicts", "Has conflicts with {0}", pr.BaseRefName), false);
        else
        {
            s = pr.MergeStateStatus switch
            {
                "BEHIND" => ("", "amber", L.F("Merge_Behind", "Branch is behind {0}", pr.BaseRefName), false),
                "BLOCKED" when pr.MergeBlocker is { } blocker => !blocker.StartsWith("Pipeline", StringComparison.Ordinal) ? ("\ue72e", "amber", blocker, false)
                    : failed > 0 ? ("\uea39", "red", failedText, false)
                    : ("\ue916", "amber", blocker, false),
                "BLOCKED" => pr.ReviewDecision switch
                {
                    "CHANGES_REQUESTED" => ("", "red", L.T("Review_ChangesRequested", "Changes requested"), false),
                    "REVIEW_REQUIRED" => ("", "amber", L.T("Review_Required", "Review required"), false),
                    _ => failed > 0 ? ("", "red", failedText, false)
                        : firstMissing is not null ? ("", "amber", firstMissing.Title, false)
                        : pending > 0 ? ("", "amber", pendingText, false)
                        : firstPending is not null ? ("", "amber", firstPending.Title, false)
                        : ("", "amber", L.T("Merge_Blocked", "Blocked by branch protection"), false)
                },
                "UNSTABLE" => anyFailed > 0 ? ("", "amber", L.T("Merge_CanMergeBut", "Can be merged, but ") + (anyFailed == 1 ? L.T("Merge_OneCheckFailed", "1 check failed") : L.F("Merge_ChecksFailed", "{0} checks failed", anyFailed)).ToLowerInvariant(), true)
                    : anyPending > 0 ? ("", "amber", anyPending == 1 ? L.T("Merge_OneCheckRunning", "1 check is still running") : L.F("Merge_ChecksRunning", "{0} checks are still running", anyPending), true)
                    : ("", "green", L.T("Merge_Ready", "Ready to merge"), true),
                "CLEAN" or "HAS_HOOKS" => ("", "green", L.T("Merge_Ready", "Ready to merge"), true),
                _ => ("", "slate", L.T("Merge_Checking", "Checking mergeability…"), false)
            };
        }
        return s;
    }

    public void PublishContext()
    {
        if (Pr is not { } pr || Api is not { } api) return;
        var key = StackNotes.Key(CacheAccount, api.Host, Ref.Repo, Ref.Number);
        var requirements = Requirements;
        var status = pr.IsOpen ? Headline(pr, requirements).text : pr.Merged ? "Merged" : pr.State.Length == 0 ? "" : pr.State[..1].ToUpperInvariant() + pr.State[1..].ToLowerInvariant();
        var snapshot = PRContextPublisher.Snapshot(Ref, pr, requirements, Ownership, ChangedPaths, LastReviewed, status);
        Task.Run(() =>
        {
            try
            {
                PRContextStore.Write(snapshot, key);
            }
            catch (Exception)
            {
            }
        }).Forget();
    }

    public OwnershipSummary? Ownership => Pr is { } pr && CodeOwnersState.Owners is { } owners ? OwnershipSummary.Build(owners, ChangedPaths, pr) : null;

    public DateTimeOffset? LastCommitDate => Pr?.LastCommit.Items.FirstOrDefault()?.Commit.CommittedDate;

    public List<StaleReview> StaleReviews
    {
        get
        {
            if (Pr is not { IsOpen: true } pr) return new();
            var pending = pr.ReviewRequests.Items.Select(r => r.RequestedReviewer?.Display).Where(d => d is not null).ToHashSet();
            var oids = pr.AllCommits.Items.Select(c => c.Commit.Oid).ToList();
            var result = new List<StaleReview>();
            foreach (var r in pr.LatestOpinionatedReviews.Items)
            {
                if (r.Author?.Login is not { } login || login == ViewerLogin || login.EndsWith("[bot]") || pending.Contains(login)) continue;
                if (r.Commit?.Oid is not { } oid || oid == pr.HeadRefOid) continue;
                var idx = oids.LastIndexOf(oid);
                int? after = idx >= 0 ? oids.Count - 1 - idx : null;
                result.Add(new StaleReview(login, after is > 0 ? after : null));
            }
            return result;
        }
    }

    public List<string> ReviewersToReRequest => StaleReviews.Select(s => s.Login).ToList();

    public Task Load(bool full = false, bool live = false)
    {
        if (full)
        {
            reloadFiles = true;
            reloadStack = true;
            forcedReason = "refresh";
        }
        else if (!live) forcedReason ??= "load";
        if (queuedLoad is not null) return queuedLoad;
        if (activeLoad is not null)
        {
            var current = activeLoad;
            queuedLoad = Chain(current);
            return queuedLoad;
        }
        return StartLoad();
    }

    public Task Open() => Load(live: Pr is not null);

    private async Task Chain(Task current)
    {
        try
        {
            await current;
        }
        catch
        {
        }
        await StartLoad();
    }

    private async Task StartLoad()
    {
        queuedLoad = null;
        var task = Fetch();
        activeLoad = task;
        try
        {
            await task;
        }
        finally
        {
            if (activeLoad == task) activeLoad = null;
        }
    }

    private async Task Fetch()
    {
        var forced = forcedReason;
        forcedReason = null;
        string reason;
        if (Pr is null) reason = "first";
        else if (forced is not null) reason = forced;
        else if (DateTimeOffset.Now - lastFullFetch >= FullFetchInterval) reason = "stale";
        else if (signature is null) reason = "no baseline";
        else if (pulseUnsupported) reason = "pulse unsupported";
        else if (await Unchanged())
        {
            if (FilesVisible && (!FilesLoaded || filesOutdated || FilesError is not null)) LoadFiles().Forget();
            return;
        }
        else reason = pulseUnsupported ? "pulse unsupported" : "changed";
        Loading = true;
        try
        {
            var r = await Diagnostics.WithNote($"full: {reason}", () => Backend.Load(Ref));
            ViewerLogin = r.Viewer;
            if (r.Repository?.PullRequest is not { } pr)
            {
                NotPR = true;
                return;
            }
            Repo = r.Repository;
            var newHtml = ConversationHtml.Render(pr);
            ViewedPaths = pr.Files?.ViewedPaths ?? new();
            ChangedPaths = pr.Files?.Items.Select(f => f.Path).ToList() ?? new();
            LoadMoreViewed(pr.Files?.NextCursor);
            LoadRules(pr, forced == "refresh");
            LoadCodeOwners(pr);
            IndexThreads(pr.ReviewThreads.Items);
            signature = r.Signature ?? PullRequestSignature.Of(pr);
            lastFullFetch = DateTimeOffset.Now;
            if (FilesLoaded) filesOid ??= pr.HeadRefOid;
            if (reloadFiles || (FilesLoaded && filesOid != pr.HeadRefOid)) filesOutdated = true;
            reloadFiles = false;
            Pr = pr;
            if (newHtml != Html) Html = newHtml;
            Error = null;
            RefreshError = null;
            LastUpdated = DateTimeOffset.Now;
            NotifyDerived();
            PublishContext();
            if (DiffScope == DiffScope.SinceReview)
            {
                if (LastReviewed is null) DiffScope = DiffScope.All;
                else LoadInterdiff().Forget();
            }
            if (reloadStack)
            {
                reloadStack = false;
                LoadStack(true).Forget();
            }
            else if (stackKey != StackCacheKey(pr) || Tab == PRTab.Stack)
            {
                LoadStack().Forget();
            }
            ScheduleMergeRecheck(pr);
            if (FilesVisible && (filesOutdated || !FilesLoaded)) LoadFiles(filesOutdated).Forget();
            else if (FilesLoaded) DiffVersion++;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            if (Pr is null) Error = e.Message;
            else RefreshError = e.Message;
        }
        finally
        {
            Loading = false;
        }
    }

    private async Task<bool> Unchanged()
    {
        try
        {
            if (await Backend.Pulse(Ref) is not { } pulse || pulse != signature) return false;
            LastUpdated = DateTimeOffset.Now;
            RefreshError = null;
            if (Pr is { } pr) ScheduleMergeRecheck(pr);
            return true;
        }
        catch (OperationCanceledException)
        {
            return true;
        }
        catch (ApiException e) when (e.SchemaError)
        {
            pulseUnsupported = true;
            return false;
        }
        catch (Exception e)
        {
            RefreshError = e.Message;
            return true;
        }
    }

    private async void LoadMoreViewed(string? cursor)
    {
        viewedLoad?.Cancel();
        if (cursor is null || Api is not { } api) return;
        var cts = new CancellationTokenSource();
        viewedLoad = cts;
        try
        {
            for (var pages = 0; cursor is not null && pages < 30; pages++)
            {
                var page = await api.PullRequestFilesPage(Ref, cursor, cts.Token);
                if (cts.IsCancellationRequested || page is null) return;
                ViewedPaths.UnionWith(page.ViewedPaths);
                ChangedPaths.AddRange(page.Items.Select(f => f.Path));
                cursor = page.NextCursor;
            }
            DiffVersion++;
            if (CodeOwnersState.Owners is not null) OnPropertyChanged(nameof(Ownership));
            PublishContext();
        }
        catch (Exception)
        {
        }
    }

    private async void LoadRules(PullRequestDetail pr, bool force)
    {
        if (Api is not { } api) return;
        var key = $"{Ref.Repo.Full}|{pr.BaseRefName}";
        var fresh = rulesFetched is { } at && DateTimeOffset.Now - at < TimeSpan.FromMinutes(5);
        if (!force && key == rulesKey && (fresh || RulesState.Phase == RulesPhase.Loading)) return;
        if (key != rulesKey) RulesState = RulesStatus.Loading;
        rulesKey = key;
        rulesFetched = DateTimeOffset.Now;
        try
        {
            var rules = await api.BranchRules(Ref.Repo, pr.BaseRefName, Repo?.ViewerPermission == "ADMIN");
            if (rulesKey != key) return;
            RulesState = RulesStatus.Loaded(rules);
            PublishContext();
        }
        catch (Exception)
        {
            if (rulesKey != key) return;
            rulesFetched = null;
            if (RulesState.Rules is null) RulesState = RulesStatus.Failed;
        }
    }

    private async void LoadCodeOwners(PullRequestDetail pr)
    {
        if (!Features.CodeOwners || Api is not { } api || pr.BaseTipOid is not { } baseOid) return;
        var key = $"{Ref.Repo.Full}|{baseOid}";
        if (key == ownersKey) return;
        ownersKey = key;
        try
        {
            var owners = await api.CodeOwners(Ref.Repo, baseOid);
            if (ownersKey != key) return;
            CodeOwnersState = owners is null ? CodeOwnersStatus.Missing : CodeOwnersStatus.Loaded(owners);
            PublishContext();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            if (ownersKey != key) return;
            ownersKey = null;
            CodeOwnersState = CodeOwnersStatus.Failed;
        }
    }

    private void NotifyDerived()
    {
        OnPropertyChanged(nameof(CanWrite));
        OnPropertyChanged(nameof(Reviewers));
        OnPropertyChanged(nameof(Requirements));
        OnPropertyChanged(nameof(StaleReviews));
        OnPropertyChanged(nameof(LastCommitDate));
        OnPropertyChanged(nameof(LastReviewed));
        OnPropertyChanged(nameof(DiffStat));
    }

    private void ScheduleMergeRecheck(PullRequestDetail pr)
    {
        var unknown = pr.IsOpen && (pr.MergeStateStatus == "UNKNOWN" || pr.Mergeable == "UNKNOWN");
        if (!unknown)
        {
            mergeRechecks = 0;
            return;
        }
        if (mergeRechecks >= 5) return;
        mergeRechecks++;
        var delay = TimeSpan.FromSeconds(mergeRechecks * 2);
        mergeRecheck?.Cancel();
        var cts = new CancellationTokenSource();
        mergeRecheck = cts;
        Recheck(delay, cts.Token).Forget();
    }

    private async Task Recheck(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, ct);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        await Load(live: true);
    }

    private static string StackCacheKey(PullRequestDetail pr) =>
        $"{pr.Number}|{pr.State}|{pr.IsDraft}|{pr.HeadRepository?.NameWithOwner}|{pr.HeadRefName}|{pr.BaseRefName}";

    private void InvalidateStack()
    {
        if (Api is not { } api) return;
        StackStore.Shared.Invalidate(CacheAccount, api.Host, Ref.Repo);
        reloadStack = true;
    }

    public async Task LoadStack(bool force = false)
    {
        if (!Features.Stack || Api is not { } api || Pr is not { } pr) return;
        stackKey = StackCacheKey(pr);
        if (await StackStore.Shared.Cached(CacheAccount, api.Host, Ref.Repo) is { } hit)
        {
            ApplyStack(hit.Nodes);
            if (!force && hit.Fresh) return;
        }
        if (await StackStore.Shared.Fetch(api, Ref.Repo, CacheAccount) is { } nodes) ApplyStack(nodes);
    }

    public void SeedStack(StackNode node, IReadOnlyList<StackNode> nodes)
    {
        if (Pr is not null) return;
        Preview = node;
        StackTree = StackTree.Build(node, nodes, Ref.Repo.Full);
        Tab = PRTab.Stack;
    }

    public StackNode? CurrentNode => Pr is { } pr
        ? new StackNode(pr.Number, pr.Title, pr.State, pr.IsDraft, pr.HeadRefName, pr.BaseRefName, pr.HeadRepository?.NameWithOwner, pr.Author?.Login, null, null, null, null, null)
        : null;

    private void ApplyStack(List<StackNode> nodes)
    {
        if (CurrentNode is not { } current) return;
        var tree = StackTree.Build(current, nodes, Ref.Repo.Full);
        if (tree is null ? StackTree is not null : !tree.SameAs(StackTree)) StackTree = tree;
        if (tree is null && Tab == PRTab.Stack) Tab = PRTab.Conversation;
    }

    public async Task LoadFiles(bool force = false)
    {
        if (!force && (FilesLoading || FilesLoaded && !filesOutdated)) return;
        if (Pr is not { } pr) return;
        FilesLoading = true;
        filesOutdated = false;
        var oid = pr.HeadRefOid;
        try
        {
            var raw = await Backend.Files(Ref, pr);
            var parsed = await Task.Run(() => raw.Select(f => new DiffFile(f)).ToList());
            if (!FilesLoaded) Collapsed = parsed.Where(f => ViewedPaths.Contains(f.Id) || f.Lines.Count > 1500).Select(f => f.Id).ToHashSet();
            filesOid = oid;
            Files = parsed;
            FilesLoaded = true;
            FilesError = null;
            DiffVersion++;
            OnPropertyChanged(nameof(DiffStat));
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            filesOutdated = FilesLoaded;
            FilesError = e.Message;
        }
        finally
        {
            FilesLoading = false;
        }
    }

    private void IndexThreads(IEnumerable<ReviewThread> threads)
    {
        var idx = new Dictionary<string, List<ReviewThread>>();
        var outdated = new Dictionary<string, List<ReviewThread>>();
        foreach (var t in threads)
        {
            if (t.Line is { } line)
            {
                var key = $"{t.Path}|{t.DiffSide}|{line}";
                if (!idx.TryGetValue(key, out var l)) idx[key] = l = new();
                l.Add(t);
            }
            else
            {
                if (!outdated.TryGetValue(t.Path, out var l)) outdated[t.Path] = l = new();
                l.Add(t);
            }
        }
        threadIndex = idx;
        outdatedByPath = outdated;
    }

    public DiffRenderOptions RenderOptions(string filter, bool wrap = true, bool split = false)
    {
        var interdiff = DiffScope == DiffScope.SinceReview;
        return new()
        {
            Wrap = wrap,
            Split = split,
            Review = true,
            Commentable = !interdiff && (Pr?.IsOpen ?? false),
            ShowViewed = Features.ViewedFiles,
            ShowBlame = Pr is not null && Features.Blame,
            BlameLabel = L.T("Code_Blame", "Blame"),
            BlameTitle = L.T("PR_BlameAtHead", "Blame this file at the pull request head"),
            Viewed = ViewedPaths,
            Collapsed = Collapsed,
            Threads = interdiff ? new Dictionary<string, List<ReviewThread>>() : threadIndex,
            Outdated = interdiff ? new Dictionary<string, List<ReviewThread>>() : outdatedByPath,
            Pending = interdiff ? Array.Empty<PendingComment>() : Pending,
            Filter = filter
        };
    }

    public int ThreadCount(string path) => (Pr?.ReviewThreads.Items ?? new()).Count(t => t.Path == path);

    public void RevealFile(string path)
    {
        Tab = PRTab.Files;
        if (Collapsed.Remove(path)) DiffVersion++;
        ScrollTarget = null;
        ScrollTarget = path;
    }

    private async Task<bool> Run(Func<Task> op, bool reload = true, bool stack = false)
    {
        Busy = true;
        try
        {
            if (stack) InvalidateStack();
            await op();
            if (reload)
            {
                forcedReason = "mutation";
                await Load();
            }
            return true;
        }
        catch (Exception e)
        {
            ActionError = e.Message;
            return false;
        }
        finally
        {
            Busy = false;
        }
    }

    public async Task<bool> Comment(string body)
    {
        if (Pr is not { } pr) return false;
        var ok = await Run(() => Backend.Comment(Ref, pr, body));
        if (ok) ScrollToBottomToken++;
        return ok;
    }

    public async Task<bool> SubmitReview(string @event, string body)
    {
        if (Pr is not { } pr) return false;
        var comments = Pending.ToList();
        var files = Files;
        var ok = await Run(() => Backend.SubmitReview(Ref, pr, @event, body, comments, files));
        if (ok)
        {
            Pending.Clear();
            OnPropertyChanged(nameof(PendingCount));
            DiffVersion++;
            ScrollToBottomToken++;
        }
        return ok;
    }

    public async Task<bool> AddInline(DiffAnchor anchor, string body, bool immediately)
    {
        var c = new PendingComment { Path = anchor.Path, Line = anchor.Line, Side = anchor.Side, Body = body };
        if (immediately)
        {
            if (Pr is not { } pr) return false;
            var files = Files;
            return await Run(() => Backend.SubmitReview(Ref, pr, "COMMENT", "", new[] { c }, files));
        }
        Pending.Add(c);
        OnPropertyChanged(nameof(PendingCount));
        DiffVersion++;
        return true;
    }

    public void RemovePending(Guid id)
    {
        if (Pending.RemoveAll(p => p.Id == id) > 0)
        {
            OnPropertyChanged(nameof(PendingCount));
            DiffVersion++;
        }
    }

    public void ClearPending()
    {
        Pending.Clear();
        OnPropertyChanged(nameof(PendingCount));
        DiffVersion++;
    }

    public Task<bool> Reply(string threadId, string body) => Run(() => Backend.Reply(Ref, threadId, body));

    public Task<bool> SetResolved(string threadId, bool resolved) => Run(() => Backend.SetResolved(Ref, threadId, resolved));

    public async Task<bool> Merge(string method, string? title, string? body, bool deleteBranch)
    {
        if (Pr is not { } pr) return false;
        string? branchError = null;
        var ok = await Run(stack: true, op: async () => branchError = await Backend.Merge(Ref, pr, method, title, body, deleteBranch));
        if (ok && branchError is not null) ActionError = L.F("Merge_BranchNotDeleted", "Merged, but the branch {0} couldn’t be deleted: {1}", pr.HeadRefName, branchError);
        return ok;
    }

    public Task<bool> EnableAutoMerge(string method) =>
        Pr is { } pr ? Run(() => Backend.EnableAutoMerge(Ref, pr, method)) : Task.FromResult(false);

    public Task<bool> Simple(PRAction action) =>
        Pr is { } pr ? Run(() => Backend.Perform(action, Ref, pr), stack: true) : Task.FromResult(false);

    public Task<bool> RevokeApproval() =>
        Pr is { } pr ? Run(() => Backend.RevokeApproval(Ref, pr)) : Task.FromResult(false);

    public Task<bool> Edit(string title, string body) =>
        Pr is { } pr ? Run(() => Backend.Edit(Ref, pr, title, body), stack: true) : Task.FromResult(false);

    public Task<bool> RequestReviewers(List<string> logins) => Run(() => Backend.RequestReviewers(Ref, logins));

    public Task<bool> DeleteBranch() =>
        Pr is { } pr ? Run(() => Backend.DeleteBranch(Ref, pr)) : Task.FromResult(false);

    public async Task ToggleViewed(string path)
    {
        if (Pr is not { } pr || !Features.ViewedFiles) return;
        var viewed = ViewedPaths.Contains(path);
        if (viewed)
        {
            ViewedPaths.Remove(path);
        }
        else
        {
            ViewedPaths.Add(path);
            Collapsed.Add(path);
        }
        DiffVersion++;
        await Run(() => Backend.SetViewed(Ref, pr, path, !viewed), reload: false);
    }

    public List<CheckContext> FailingChecks => CiFailures.Failing(Pr?.Checks ?? new());

    public int FailedRuns => FailingChecks.Where(c => c.RunId is not null).Select(c => c.RunId).Distinct().Count();

    private string CiKey(CheckContext c) => $"{Pr?.HeadRefOid}|{c.Id}|{c.Conclusion ?? c.State}|{c.CompletedAt?.ToUnixTimeSeconds()}";

    public CiFailure? CachedCiFailure(CheckContext c)
    {
        lock (ciFailures) return ciFailures.TryGetValue(CiKey(c), out var f) ? f : null;
    }

    public async Task<List<CiFailure>> CollectCiFailures(IReadOnlyList<CheckContext> checks, IReadOnlyDictionary<long, string>? knownLogs, CancellationToken ct)
    {
        var found = new Dictionary<string, CiFailure>();
        foreach (var c in checks)
            if (CachedCiFailure(c) is { } hit) found[c.Id] = hit;
        var missing = checks.Where(c => !found.ContainsKey(c.Id)).ToList();
        if (missing.Count > 0 && Api is { } api)
        {
            var fetched = await Task.Run(() => CiFailures.Collect(api, Ref.Repo, missing, knownLogs, ct), ct);
            lock (ciFailures)
            {
                if (ciFailures.Count > 60) ciFailures.Clear();
                foreach (var f in fetched)
                {
                    found[f.Check.Id] = f;
                    if (f.LogError is null) ciFailures[CiKey(f.Check)] = f;
                }
            }
        }
        return checks.Where(c => found.ContainsKey(c.Id)).Select(c => found[c.Id]).ToList();
    }

    public Task<bool> RerunFailed()
    {
        var runs = FailingChecks.Where(c => c.RunId is not null).Select(c => c.RunId!.Value).Distinct().ToList();
        return Run(() => Backend.RerunFailed(Ref, runs));
    }
}

public static class GitHubApiVars
{
    public static Dictionary<string, object?> Of(params (string, object?)[] pairs) => pairs.ToDictionary(p => p.Item1, p => p.Item2);
}
