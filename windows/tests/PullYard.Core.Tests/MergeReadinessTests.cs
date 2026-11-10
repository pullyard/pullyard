using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PullYard.Core.Api;
using PullYard.Core.Forges;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class MergeReadinessTests
{
    private static PullRequestDetail Pr(JsonObject? overrides = null)
    {
        var json = new JsonObject
        {
            ["id"] = "PR_1", ["number"] = 7, ["title"] = "T", ["url"] = "https://github.com/o/r/pull/7", ["state"] = "OPEN",
            ["isDraft"] = false, ["merged"] = false, ["mergeable"] = "MERGEABLE", ["mergeStateStatus"] = "BLOCKED",
            ["body"] = "", ["bodyHTML"] = "", ["createdAt"] = "2026-01-01T00:00:00Z",
            ["headRefName"] = "feature", ["baseRefName"] = "main", ["headRefOid"] = "head",
            ["labels"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["reviewRequests"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["latestOpinionatedReviews"] = new JsonObject { ["nodes"] = new JsonArray() },
            ["reviewThreads"] = new JsonObject { ["nodes"] = new JsonArray() },
        };
        foreach (var (k, v) in overrides ?? new JsonObject()) json[k] = v?.DeepClone();
        return JsonSerializer.Deserialize<PullRequestDetail>(json.ToJsonString(), Json.GraphQL)!;
    }

    private static JsonObject Checks(params JsonObject[] nodes) => new()
    {
        ["lastCommit"] = new JsonObject
        {
            ["nodes"] = new JsonArray(new JsonObject
            {
                ["commit"] = new JsonObject
                {
                    ["oid"] = "head",
                    ["statusCheckRollup"] = new JsonObject { ["state"] = "FAILURE", ["contexts"] = new JsonObject { ["nodes"] = new JsonArray(nodes) } },
                },
            }),
        },
    };

    private static JsonObject Run(string name, string? conclusion = "SUCCESS", bool? required = null)
    {
        var n = new JsonObject { ["__typename"] = "CheckRun", ["databaseId"] = Math.Abs(name.GetHashCode() % 100000), ["name"] = name, ["status"] = conclusion is null ? "IN_PROGRESS" : "COMPLETED" };
        if (conclusion is not null) n["conclusion"] = conclusion;
        if (required is not null) n["isRequired"] = required;
        return n;
    }

    private static JsonObject Review(string login, string state, string oid = "head") =>
        new() { ["state"] = state, ["commit"] = new JsonObject { ["oid"] = oid }, ["author"] = new JsonObject { ["login"] = login, ["avatarUrl"] = "" } };

    private static readonly BranchRules Known = new() { ReviewRulesKnown = true, CheckRulesKnown = true };

    [Fact]
    public void ParsesRulesetsAndClassicChecks()
    {
        var rules = """
        [{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_last_push_approval":true,"required_review_thread_resolution":true}},
         {"type":"pull_request","parameters":{"required_approving_review_count":2,"require_code_owner_review":true}},
         {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}},
         {"type":"deletion"}]
        """;
        var branch = """{"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"everyone","contexts":["lint"],"checks":[{"context":"lint"}]}}}""";
        var r = BranchRules.From(Encoding.UTF8.GetBytes(rules), Encoding.UTF8.GetBytes(branch), null);
        Assert.Equal(2, r.RequiredApprovals);
        Assert.True(r.CodeOwnerReview && r.LastPushApproval && r.ThreadResolution);
        Assert.Equal(new[] { "build", "lint" }, r.RequiredChecks.OrderBy(x => x));
        Assert.True(r.ReviewRulesKnown && r.CheckRulesKnown);
    }

    [Fact]
    public void ClassicProtectionNeedsAdmin()
    {
        var branch = Encoding.UTF8.GetBytes("""{"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"off","contexts":["ci"]}}}""");
        Assert.True(BranchRules.IsClassicProtected(branch));
        var hidden = BranchRules.From(Encoding.UTF8.GetBytes("[]"), branch, null);
        Assert.False(hidden.ReviewRulesKnown);
        Assert.Empty(hidden.RequiredChecks);
        var protection = Encoding.UTF8.GetBytes("""{"required_pull_request_reviews":{"required_approving_review_count":3,"require_code_owner_reviews":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"contexts":["ci"]}}""");
        var admin = BranchRules.From(Encoding.UTF8.GetBytes("[]"), branch, protection);
        Assert.True(admin.ReviewRulesKnown);
        Assert.Equal(3, admin.RequiredApprovals);
        Assert.True(admin.ThreadResolution);
        Assert.Equal(new[] { "ci" }, admin.RequiredChecks);
        Assert.Equal(CapabilityState.Unavailable, RulesStatus.Loaded(hidden).ReviewRules);
        Assert.Equal(CapabilityState.Supported, RulesStatus.Loaded(admin).ReviewRules);
        Assert.Equal(CapabilityState.Unknown, RulesStatus.Failed.ReviewRules);
    }

    [Fact]
    public void OptionalFailureDoesNotBlock()
    {
        var o = Checks(Run("build", required: true), Run("coverage", "FAILURE", false));
        o["mergeStateStatus"] = "UNSTABLE";
        var list = MergeReadiness.Requirements(Pr(o), RulesStatus.Loaded(Known));
        Assert.Equal(RequirementState.Satisfied, list.First(r => r.Kind == RequirementKind.Checks).State);
        Assert.Equal(RequirementState.Advisory, list.First(r => r.Kind == RequirementKind.OptionalChecks).State);
        Assert.DoesNotContain(list, r => r.Blocks);
    }

    [Fact]
    public void RequiredFailureAndNotStarted()
    {
        var pr = Pr(Checks(Run("build", "FAILURE", true), Run("lint", required: false)));
        var rules = Known with { RequiredChecks = new HashSet<string> { "build", "deploy-preview" } };
        var b = MergeReadiness.Checks(pr.Checks, rules);
        Assert.Equal(new[] { "build" }, b.FailedRequired.Select(c => c.Title));
        Assert.Equal(new[] { "deploy-preview" }, b.NotStarted);
        var row = MergeReadiness.Requirements(pr, RulesStatus.Loaded(rules)).First(r => r.Kind == RequirementKind.Checks);
        Assert.Equal(RequirementState.Missing, row.State);
        Assert.Equal("1 required check failed", row.Title);

        var waiting = Pr(Checks(Run("build", required: true)));
        var pending = MergeReadiness.Requirements(waiting, RulesStatus.Loaded(Known with { RequiredChecks = new HashSet<string> { "build", "e2e" } })).First(r => r.Kind == RequirementKind.Checks);
        Assert.Equal(RequirementState.Pending, pending.State);
        Assert.Equal("Not started: e2e", pending.Detail);
    }

    [Fact]
    public void LegacyServerTreatsAllChecksAsBlocking()
    {
        var b = MergeReadiness.Checks(Pr(Checks(Run("build", "FAILURE"))).Checks, null);
        Assert.False(b.RequiredKnown);
        Assert.Single(b.FailedRequired);
    }

    [Fact]
    public void ApprovalsCodeOwnersAndLastPush()
    {
        var rules = Known with { RequiredApprovals = 2 };
        var one = Pr(new JsonObject { ["latestOpinionatedReviews"] = new JsonObject { ["nodes"] = new JsonArray(Review("alice", "APPROVED")) } });
        var row = MergeReadiness.Requirements(one, RulesStatus.Loaded(rules)).First(r => r.Kind == RequirementKind.Approvals);
        Assert.Equal("1 of 2 required approvals", row.Title);
        Assert.Equal("Needs 1 more approval", row.Detail);
        Assert.Equal(RequirementAction.RequestReview, row.Action);

        var owners = Known with { RequiredApprovals = 1, LastPushApproval = true, CodeOwnerReview = true };
        var pr = Pr(new JsonObject
        {
            ["latestOpinionatedReviews"] = new JsonObject { ["nodes"] = new JsonArray(Review("alice", "APPROVED", "old")) },
            ["reviewRequests"] = new JsonObject { ["nodes"] = new JsonArray(new JsonObject { ["asCodeOwner"] = true, ["requestedReviewer"] = new JsonObject { ["__typename"] = "Team", ["name"] = "Core", ["combinedSlug"] = "o/core" } }) },
        });
        var list = MergeReadiness.Requirements(pr, RulesStatus.Loaded(owners));
        Assert.Equal(RequirementState.Missing, list.First(r => r.Kind == RequirementKind.LastPush).State);
        Assert.Equal("Waiting for o/core", list.First(r => r.Kind == RequirementKind.CodeOwners).Detail);
        var team = pr.ReviewRequests.Items[0].RequestedReviewer!;
        Assert.True(team.IsTeam);
        Assert.Equal("o/core", team.Display);
    }

    [Fact]
    public void ReviewRequiredFallsBackWhenRulesFail()
    {
        var pr = Pr(new JsonObject { ["reviewDecision"] = "REVIEW_REQUIRED" });
        var list = MergeReadiness.Requirements(pr, RulesStatus.Failed);
        Assert.Equal("Branch rules couldn’t be read", list.First(r => r.Kind == RequirementKind.Approvals).Detail);
        Assert.Contains(list, r => r.Kind == RequirementKind.Rules && r.State == RequirementState.Unknown);
    }

    [Fact]
    public void ConflictsBehindDraftHiddenAndClosed()
    {
        Assert.Equal(RequirementAction.ShowConflicts, MergeReadiness.Requirements(Pr(new JsonObject { ["mergeable"] = "CONFLICTING" }), RulesStatus.Loading).First(r => r.Kind == RequirementKind.Conflicts).Action);
        Assert.Contains(MergeReadiness.Requirements(Pr(new JsonObject { ["mergeStateStatus"] = "BEHIND" }), RulesStatus.Loading), r => r.Kind == RequirementKind.Behind);
        Assert.Equal(RequirementKind.Draft, MergeReadiness.Requirements(Pr(new JsonObject { ["isDraft"] = true }), RulesStatus.Loading)[0].Kind);
        Assert.Contains(MergeReadiness.Requirements(Pr(), RulesStatus.Loaded(Known)), r => r.Kind == RequirementKind.OtherRules);
        Assert.Empty(MergeReadiness.Requirements(Pr(new JsonObject { ["state"] = "MERGED" }), RulesStatus.Loading));
    }

    [Fact]
    public void ThreadResolutionRule()
    {
        var thread = new JsonObject { ["id"] = "t1", ["isResolved"] = false, ["path"] = "a", ["comments"] = new JsonObject { ["nodes"] = new JsonArray() } };
        var pr = Pr(new JsonObject { ["reviewThreads"] = new JsonObject { ["nodes"] = new JsonArray(thread) } });
        Assert.Equal(RequirementState.Advisory, MergeReadiness.Requirements(pr, RulesStatus.Loaded(Known)).First(r => r.Kind == RequirementKind.Conversations).State);
        var row = MergeReadiness.Requirements(pr, RulesStatus.Loaded(Known with { ThreadResolution = true })).First(r => r.Kind == RequirementKind.Conversations);
        Assert.Equal(RequirementState.Missing, row.State);
        Assert.Equal(RequirementAction.ShowConversation, row.Action);
    }

    [Fact]
    public void FilesPageAndLegacyQuery()
    {
        var page = JsonSerializer.Deserialize<FileViewedPage>("""{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"path":"a","viewerViewedState":"VIEWED"},{"path":"b","viewerViewedState":"UNVIEWED"},null]}""", Json.GraphQL)!;
        Assert.Equal(new[] { "a" }, page.ViewedPaths);
        Assert.Equal("c1", page.NextCursor);
        Assert.Contains("isRequired(pullRequestNumber: $number)", Q.PullRequest);
        Assert.DoesNotContain("isRequired", Q.PullRequestLegacy);
        Assert.DoesNotContain("asCodeOwner", Q.PullRequestLegacy);
        Assert.DoesNotContain("combinedSlug", Q.PullRequestLegacy);
    }

    [Fact]
    public void ForgeDefaultsDoNotClaimReview()
    {
        Assert.Equal(CapabilityState.Unsupported, ForgeCapabilities.Initial.PullRequestReview);
        Assert.Equal(CapabilityState.Unsupported, ForgeCapabilities.Initial.MergeRequirements);
    }
}
