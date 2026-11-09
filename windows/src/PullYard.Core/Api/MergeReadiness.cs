using System.Text.Json;

namespace PullYard.Core.Api;

public enum CapabilityState { Supported, Unsupported, Unavailable, Unknown }

public sealed record BranchRules
{
    public int RequiredApprovals { get; init; }
    public bool CodeOwnerReview { get; init; }
    public bool LastPushApproval { get; init; }
    public bool ThreadResolution { get; init; }
    public IReadOnlySet<string> RequiredChecks { get; init; } = new HashSet<string>();
    public bool ReviewRulesKnown { get; init; }
    public bool CheckRulesKnown { get; init; }

    public static bool IsClassicProtected(byte[]? branch)
    {
        var root = Parse(branch);
        return root is { } r && Obj(r, "protection") is { } p && Bool(p, "enabled");
    }

    public static BranchRules From(byte[]? rules, byte[]? branch, byte[]? protection)
    {
        var approvals = 0;
        bool codeOwner = false, lastPush = false, threads = false;
        var checks = new HashSet<string>();
        var ruleset = Parse(rules);
        var info = Parse(branch);
        var classic = Parse(protection);

        if (ruleset is { ValueKind: JsonValueKind.Array } list)
        {
            foreach (var rule in list.EnumerateArray())
            {
                var type = rule.TryGetProperty("type", out var t) ? t.GetString() : null;
                var p = Obj(rule, "parameters");
                if (type == "pull_request" && p is { } pr)
                {
                    approvals = Math.Max(approvals, Int(pr, "required_approving_review_count"));
                    codeOwner |= Bool(pr, "require_code_owner_review");
                    lastPush |= Bool(pr, "require_last_push_approval");
                    threads |= Bool(pr, "required_review_thread_resolution");
                }
                else if (type == "required_status_checks" && p is { } sc && sc.TryGetProperty("required_status_checks", out var arr) && arr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var c in arr.EnumerateArray())
                        if (c.TryGetProperty("context", out var ctx) && ctx.GetString() is { } name) checks.Add(name);
                }
            }
        }

        if (info is { } i && Obj(i, "protection") is { } bp && Obj(bp, "required_status_checks") is { } rsc && Str(rsc, "enforcement_level") != "off")
            checks.UnionWith(CheckNames(rsc));

        if (classic is { } cl)
        {
            if (Obj(cl, "required_pull_request_reviews") is { } rv)
            {
                approvals = Math.Max(approvals, Int(rv, "required_approving_review_count"));
                codeOwner |= Bool(rv, "require_code_owner_reviews");
                lastPush |= Bool(rv, "require_last_push_approval");
            }
            if (Obj(cl, "required_conversation_resolution") is { } cr) threads |= Bool(cr, "enabled");
            if (Obj(cl, "required_status_checks") is { } cs) checks.UnionWith(CheckNames(cs));
        }

        var rulesetOk = ruleset is { ValueKind: JsonValueKind.Array };
        var classicProtected = info is { } inf && Obj(inf, "protection") is { } pr2 && Bool(pr2, "enabled");
        return new BranchRules
        {
            RequiredApprovals = approvals,
            CodeOwnerReview = codeOwner,
            LastPushApproval = lastPush,
            ThreadResolution = threads,
            RequiredChecks = checks,
            ReviewRulesKnown = rulesetOk && (!classicProtected || classic is not null),
            CheckRulesKnown = rulesetOk && info is not null,
        };
    }

    private static IEnumerable<string> CheckNames(JsonElement e)
    {
        if (e.TryGetProperty("contexts", out var ctx) && ctx.ValueKind == JsonValueKind.Array)
            foreach (var c in ctx.EnumerateArray()) if (c.GetString() is { } s) yield return s;
        if (e.TryGetProperty("checks", out var chk) && chk.ValueKind == JsonValueKind.Array)
            foreach (var c in chk.EnumerateArray()) if (Str(c, "context") is { } s) yield return s;
    }

    private static JsonElement? Parse(byte[]? data)
    {
        if (data is null) return null;
        try
        {
            using var doc = JsonDocument.Parse(data);
            return doc.RootElement.Clone();
        }
        catch (JsonException) { return null; }
    }

    private static JsonElement? Obj(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Object ? v : null;

    private static bool Bool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static int Int(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : 0;

    private static string? Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}

public enum RulesPhase { Loading, Loaded, Failed }

public sealed record RulesStatus(RulesPhase Phase, BranchRules? Rules = null)
{
    public static readonly RulesStatus Loading = new(RulesPhase.Loading);
    public static readonly RulesStatus Failed = new(RulesPhase.Failed);
    public static RulesStatus Loaded(BranchRules rules) => new(RulesPhase.Loaded, rules);

    public CapabilityState ReviewRules => Phase == RulesPhase.Loaded
        ? (Rules!.ReviewRulesKnown ? CapabilityState.Supported : CapabilityState.Unavailable)
        : CapabilityState.Unknown;
}

public enum RequirementState { Satisfied, Missing, Pending, Unknown, Advisory }

public enum RequirementAction { RequestReview, ShowChecks, ShowConversation, ShowConflicts, UpdateBranch, ReadyForReview }

public enum RequirementKind { Draft, Conflicts, Behind, ChangesRequested, Approvals, CodeOwners, LastPush, Checks, OptionalChecks, Conversations, Rules, OtherRules }

public sealed record MergeRequirement(RequirementKind Kind, RequirementState State, string Title, string? Detail = null, RequirementAction? Action = null)
{
    public bool Blocks => State is RequirementState.Missing or RequirementState.Pending;
}

public sealed class CheckBreakdown
{
    public bool RequiredKnown { get; init; }
    public List<CheckContext> Required { get; init; } = new();
    public List<CheckContext> Optional { get; init; } = new();
    public List<string> NotStarted { get; init; } = new();

    public List<CheckContext> FailedRequired => Required.Where(c => c.Outcome == CheckOutcome.Failure).ToList();
    public List<CheckContext> RunningRequired => Required.Where(c => c.Outcome == CheckOutcome.Pending).ToList();
    public List<CheckContext> FailedOptional => Optional.Where(c => c.Outcome == CheckOutcome.Failure).ToList();
}

public static class MergeReadiness
{
    public static CheckBreakdown Checks(List<CheckContext> checks, BranchRules? rules)
    {
        var flagged = checks.Any(c => c.IsRequired is not null);
        var ruleNames = rules?.CheckRulesKnown == true ? rules.RequiredChecks : null;
        List<CheckContext> required, optional;
        var known = true;
        if (flagged)
        {
            required = checks.Where(c => c.IsRequired == true).ToList();
            optional = checks.Where(c => c.IsRequired != true).ToList();
        }
        else if (ruleNames is not null)
        {
            required = checks.Where(c => ruleNames.Contains(c.Title)).ToList();
            optional = checks.Where(c => !ruleNames.Contains(c.Title)).ToList();
        }
        else
        {
            known = false;
            required = checks.ToList();
            optional = new();
        }
        var notStarted = ruleNames is null ? new List<string>() : ruleNames.Except(checks.Select(c => c.Title)).OrderBy(n => n, StringComparer.Ordinal).ToList();
        return new CheckBreakdown { RequiredKnown = known, Required = required, Optional = optional, NotStarted = notStarted };
    }

    public static List<MergeRequirement> Requirements(PullRequestDetail pr, RulesStatus status)
    {
        var list = new List<MergeRequirement>();
        if (!pr.IsOpen) return list;
        if (pr.ForgeMerge is { } merge) return merge.Provider == "bitbucket" ? Bitbucket(pr, merge) : GitLab(pr, merge);
        var rules = status.Rules;
        var loading = status.Phase == RulesPhase.Loading;

        if (pr.IsDraft)
            list.Add(new(RequirementKind.Draft, RequirementState.Missing, "Draft pull request", "Mark it ready for review before merging", RequirementAction.ReadyForReview));

        if (pr.Mergeable == "CONFLICTING" || pr.MergeStateStatus == "DIRTY")
            list.Add(new(RequirementKind.Conflicts, RequirementState.Missing, $"Conflicts with {pr.BaseRefName}", "Resolve them before merging", RequirementAction.ShowConflicts));
        else if (pr.Mergeable == "UNKNOWN")
            list.Add(new(RequirementKind.Conflicts, RequirementState.Pending, "Checking for conflicts…"));
        else
            list.Add(new(RequirementKind.Conflicts, RequirementState.Satisfied, $"No conflicts with {pr.BaseRefName}"));

        if (pr.MergeStateStatus == "BEHIND")
            list.Add(new(RequirementKind.Behind, RequirementState.Missing, $"Branch is behind {pr.BaseRefName}", "The base branch requires it to be up to date", RequirementAction.UpdateBranch));

        list.AddRange(ReviewRequirements(pr, rules, status.ReviewRules, loading));
        list.AddRange(CheckRequirements(pr, rules));
        if (ConversationRequirement(pr, rules, loading) is { } c) list.Add(c);

        if (status.Phase == RulesPhase.Failed)
            list.Add(new(RequirementKind.Rules, RequirementState.Unknown, "Branch rules couldn’t be read", "Showing what GitHub reports for this pull request"));
        if (pr.MergeStateStatus == "BLOCKED" && !list.Any(r => r.Blocks))
            list.Add(new(RequirementKind.OtherRules, RequirementState.Unknown, "Blocked by a rule PullYard can’t see", "For example deployments, signed commits or a merge queue. Check the pull request on GitHub"));
        return list;
    }

    private static IEnumerable<MergeRequirement> ReviewRequirements(PullRequestDetail pr, BranchRules? rules, CapabilityState access, bool loading)
    {
        var reviews = pr.LatestOpinionatedReviews.Items;
        var approvals = reviews.Where(r => r.State == "APPROVED").ToList();
        var blockers = reviews.Where(r => r.State == "CHANGES_REQUESTED").Select(r => r.Author?.Login).OfType<string>().ToList();
        var known = access == CapabilityState.Supported;
        var required = rules?.RequiredApprovals ?? 0;

        if (blockers.Count > 0)
            yield return new(RequirementKind.ChangesRequested, RequirementState.Missing, "Changes requested", "By " + string.Join(", ", blockers), RequirementAction.RequestReview);

        if (required > 0)
        {
            var title = $"{approvals.Count} of {required} required approvals";
            if (approvals.Count >= required) yield return new(RequirementKind.Approvals, RequirementState.Satisfied, title);
            else
            {
                var more = required - approvals.Count;
                yield return new(RequirementKind.Approvals, RequirementState.Missing, title, more == 1 ? "Needs 1 more approval" : $"Needs {more} more approvals", RequirementAction.RequestReview);
            }
        }
        else if (pr.ReviewDecision == "REVIEW_REQUIRED")
        {
            var detail = access switch
            {
                CapabilityState.Supported => null,
                CapabilityState.Unavailable => "The exact number of approvals isn’t visible with your access",
                _ => loading ? null : "Branch rules couldn’t be read",
            };
            yield return new(RequirementKind.Approvals, RequirementState.Missing, "Review required", detail, RequirementAction.RequestReview);
        }
        else if (pr.ReviewDecision == "APPROVED")
            yield return new(RequirementKind.Approvals, RequirementState.Satisfied, approvals.Count == 1 ? "Approved" : $"Approved by {approvals.Count} reviewers");
        else if (known && blockers.Count == 0)
            yield return new(RequirementKind.Approvals, RequirementState.Satisfied, "No approvals required");
        else if (loading)
            yield return new(RequirementKind.Approvals, RequirementState.Pending, "Reading review rules…");

        if (rules?.CodeOwnerReview == true)
        {
            var waiting = pr.ReviewRequests.Items.Where(r => r.AsCodeOwner == true).Select(r => r.RequestedReviewer?.Display).OfType<string>().ToList();
            if (waiting.Count > 0)
                yield return new(RequirementKind.CodeOwners, RequirementState.Missing, "Code owner review required", "Waiting for " + string.Join(", ", waiting), RequirementAction.RequestReview);
            else if (pr.ReviewDecision == "REVIEW_REQUIRED" && approvals.Count >= Math.Max(required, 1))
                yield return new(RequirementKind.CodeOwners, RequirementState.Missing, "Code owner review required", "No code owner has approved yet", RequirementAction.RequestReview);
            else if (approvals.Count > 0)
                yield return new(RequirementKind.CodeOwners, RequirementState.Satisfied, "Code owner review");
        }

        if (rules?.LastPushApproval == true && approvals.Count > 0)
        {
            if (approvals.Any(a => a.Commit?.Oid == pr.HeadRefOid))
                yield return new(RequirementKind.LastPush, RequirementState.Satisfied, "Latest push approved");
            else
                yield return new(RequirementKind.LastPush, RequirementState.Missing, "Latest push isn’t approved", "Approvals were given before the last commit", RequirementAction.RequestReview);
        }
    }

    private static IEnumerable<MergeRequirement> CheckRequirements(PullRequestDetail pr, BranchRules? rules)
    {
        var b = Checks(pr.Checks, rules);
        var label = b.RequiredKnown ? "required check" : "check";
        var failed = b.FailedRequired;
        var running = b.RunningRequired;
        if (failed.Count > 0)
            yield return new(RequirementKind.Checks, RequirementState.Missing, Count(failed.Count, label) + " failed", Names(failed.Select(c => c.Title)), RequirementAction.ShowChecks);
        else if (running.Count > 0 || b.NotStarted.Count > 0)
        {
            var parts = new List<string>();
            if (running.Count > 0) parts.Add("Running: " + Names(running.Select(c => c.Title)));
            if (b.NotStarted.Count > 0) parts.Add("Not started: " + Names(b.NotStarted));
            yield return new(RequirementKind.Checks, RequirementState.Pending, "Waiting for " + Count(running.Count + b.NotStarted.Count, label), string.Join(" · ", parts), RequirementAction.ShowChecks);
        }
        else if (b.Required.Count > 0)
            yield return new(RequirementKind.Checks, RequirementState.Satisfied, b.Required.Count == 1 ? $"1 {label} passed" : $"All {b.Required.Count} {label}s passed", null, RequirementAction.ShowChecks);
        else if (b.RequiredKnown)
            yield return new(RequirementKind.Checks, RequirementState.Satisfied, "No required checks");

        if (b.RequiredKnown && b.FailedOptional.Count > 0)
            yield return new(RequirementKind.OptionalChecks, RequirementState.Advisory, Count(b.FailedOptional.Count, "optional check") + " failed", "Doesn’t block merging", RequirementAction.ShowChecks);
    }

    private static MergeRequirement? ConversationRequirement(PullRequestDetail pr, BranchRules? rules, bool loading)
    {
        var open = pr.ReviewThreads.Items.Count(t => !t.IsResolved);
        var title = open == 1 ? "1 unresolved conversation" : $"{open} unresolved conversations";
        if (rules?.ThreadResolution == true)
            return open == 0
                ? new(RequirementKind.Conversations, RequirementState.Satisfied, "All conversations resolved")
                : new(RequirementKind.Conversations, RequirementState.Missing, title, "Branch rules require resolving them", RequirementAction.ShowConversation);
        if (open == 0) return null;
        var detail = rules?.ReviewRulesKnown == true ? "Not required to merge" : loading ? null : "May not block merging";
        return new(RequirementKind.Conversations, RequirementState.Advisory, title, detail, RequirementAction.ShowConversation);
    }

    private static readonly HashSet<string> GitLabCovered = new()
    {
        "mergeable", "conflict", "broken_status", "need_rebase", "checking", "unchecked", "preparing", "approvals_syncing",
        "draft_status", "not_open", "not_approved", "requested_changes", "ci_must_pass", "ci_still_running", "discussions_not_resolved"
    };

    public static List<MergeRequirement> GitLab(PullRequestDetail pr, ForgeMergeInfo merge)
    {
        var list = new List<MergeRequirement>();
        if (pr.IsDraft)
            list.Add(new(RequirementKind.Draft, RequirementState.Missing, "Draft merge request", "Mark it as ready before merging", RequirementAction.ReadyForReview));
        list.Add(merge.Status switch
        {
            "conflict" or "broken_status" => new(RequirementKind.Conflicts, RequirementState.Missing, $"Conflicts with {pr.BaseRefName}", "Resolve them before merging"),
            "checking" or "unchecked" or "preparing" or "approvals_syncing" => new(RequirementKind.Conflicts, RequirementState.Pending, "Checking for conflicts…"),
            _ => new(RequirementKind.Conflicts, RequirementState.Satisfied, $"No conflicts with {pr.BaseRefName}")
        });
        if (merge.Status == "need_rebase")
            list.Add(new(RequirementKind.Behind, RequirementState.Missing, $"Needs a rebase onto {pr.BaseRefName}", "The project allows only fast-forward merges", RequirementAction.UpdateBranch));

        var approvers = pr.LatestOpinionatedReviews.Items.Count(r => r.State == "APPROVED");
        if (merge.Status == "requested_changes")
            list.Add(new(RequirementKind.ChangesRequested, RequirementState.Missing, "Changes requested", "A reviewer asked for changes"));
        if (merge.ApprovalsRequired is { } required && required > 0)
        {
            var left = merge.ApprovalsLeft ?? Math.Max(required - approvers, 0);
            var given = Math.Max(required - left, 0);
            var title = $"{given} of {required} required approvals";
            list.Add(left == 0
                ? new(RequirementKind.Approvals, RequirementState.Satisfied, title)
                : new(RequirementKind.Approvals, RequirementState.Missing, title, MoreApprovals(left)));
        }
        else if (merge.Status == "not_approved")
            list.Add(new(RequirementKind.Approvals, RequirementState.Missing, "Approval required", merge.ApprovalsLeft is { } l ? MoreApprovals(l) : null));
        else if (merge.ApprovalsRequired is not null)
            list.Add(new(RequirementKind.Approvals, RequirementState.Satisfied, approvers > 0 ? (approvers == 1 ? "Approved" : $"Approved by {approvers} reviewers") : "No approvals required"));

        var failed = pr.Checks.Where(c => c.Outcome == CheckOutcome.Failure).ToList();
        var running = pr.Checks.Where(c => c.Outcome == CheckOutcome.Pending).ToList();
        if (merge.Status is "ci_must_pass" or "ci_still_running")
        {
            if (failed.Count > 0)
                list.Add(new(RequirementKind.Checks, RequirementState.Missing, Count(failed.Count, "job") + " failed", "The pipeline must succeed", RequirementAction.ShowChecks));
            else if (pr.Checks.Count == 0 && merge.Status == "ci_must_pass")
                list.Add(new(RequirementKind.Checks, RequirementState.Missing, "A pipeline must run and succeed", null, RequirementAction.ShowChecks));
            else
                list.Add(new(RequirementKind.Checks, RequirementState.Pending, "Pipeline is still running", running.Count == 0 ? null : "Running: " + Names(running.Select(c => c.Title)), RequirementAction.ShowChecks));
        }
        else if (failed.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Advisory, Count(failed.Count, "job") + " failed", "Doesn’t block merging", RequirementAction.ShowChecks));
        else if (running.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Pending, "Pipeline is running", "Running: " + Names(running.Select(c => c.Title)), RequirementAction.ShowChecks));
        else if (pr.Checks.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Satisfied, "Pipeline passed", null, RequirementAction.ShowChecks));

        var open = pr.ReviewThreads.Items.Count(t => !t.IsResolved);
        var threads = open == 1 ? "1 unresolved thread" : $"{open} unresolved threads";
        if (merge.Status == "discussions_not_resolved")
            list.Add(new(RequirementKind.Conversations, RequirementState.Missing, open > 0 ? threads : "All threads must be resolved", "The project requires resolving them", RequirementAction.ShowConversation));
        else if (open > 0)
            list.Add(new(RequirementKind.Conversations, RequirementState.Advisory, threads, "Not required to merge", RequirementAction.ShowConversation));

        if (!GitLabCovered.Contains(merge.Status))
            list.Add(new(RequirementKind.OtherRules, RequirementState.Missing, pr.MergeBlocker ?? "Blocked by a project rule", "Reported by GitLab"));
        return list;
    }

    public static List<MergeRequirement> Bitbucket(PullRequestDetail pr, ForgeMergeInfo merge)
    {
        var list = new List<MergeRequirement>();
        if (pr.IsDraft)
            list.Add(new(RequirementKind.Draft, RequirementState.Missing, "Draft pull request", "Mark it ready for review before merging", RequirementAction.ReadyForReview));
        list.Add(pr.Mergeable == "CONFLICTING"
            ? new(RequirementKind.Conflicts, RequirementState.Missing, $"Conflicts with {pr.BaseRefName}", "Resolve them before merging")
            : new(RequirementKind.Conflicts, RequirementState.Satisfied, $"No conflicts with {pr.BaseRefName}"));
        var reviews = pr.LatestOpinionatedReviews.Items;
        var blockers = reviews.Where(r => r.State == "CHANGES_REQUESTED").Select(r => r.Author?.Login).OfType<string>().ToList();
        var approvals = reviews.Count(r => r.State == "APPROVED");
        if (blockers.Count > 0)
            list.Add(new(RequirementKind.ChangesRequested, RequirementState.Advisory, "Changes requested", "By " + string.Join(", ", blockers)));
        list.Add(approvals > 0
            ? new(RequirementKind.Approvals, RequirementState.Satisfied, approvals == 1 ? "Approved" : $"Approved by {approvals} reviewers")
            : new(RequirementKind.Approvals, RequirementState.Advisory, "No approvals yet", "Branch restrictions may require them"));
        var failed = pr.Checks.Where(c => c.Outcome == CheckOutcome.Failure).ToList();
        var running = pr.Checks.Where(c => c.Outcome == CheckOutcome.Pending).ToList();
        if (failed.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Advisory, Count(failed.Count, "build") + " failed", Names(failed.Select(c => c.Title)), RequirementAction.ShowChecks));
        else if (running.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Pending, "Waiting for " + Count(running.Count, "build"), Names(running.Select(c => c.Title)), RequirementAction.ShowChecks));
        else if (pr.Checks.Count > 0)
            list.Add(new(RequirementKind.Checks, RequirementState.Satisfied, pr.Checks.Count == 1 ? "1 build passed" : $"All {pr.Checks.Count} builds passed", null, RequirementAction.ShowChecks));
        if (merge.OpenTasks is { } tasks && tasks > 0)
            list.Add(new(RequirementKind.Conversations, RequirementState.Advisory, Count(tasks, "open task"), "Merge checks may require resolving them", RequirementAction.ShowConversation));
        list.Add(new(RequirementKind.OtherRules, RequirementState.Unknown, "Merge checks aren’t visible", "Bitbucket rejects the merge if a required check fails"));
        return list;
    }

    private static string MoreApprovals(int left) => left == 1 ? "Needs 1 more approval" : $"Needs {left} more approvals";

    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n} {noun}s";

    private static string Names(IEnumerable<string> names)
    {
        var list = names.ToList();
        return list.Count > 4 ? string.Join(", ", list.Take(4)) + $" +{list.Count - 4}" : string.Join(", ", list);
    }
}
