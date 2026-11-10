use std::collections::BTreeSet;

use serde_json::Value;

use super::models::{CheckContext, CheckOutcome, PullRequestDetail};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapabilityState {
    Supported,
    Unsupported,
    Unavailable,
    Unknown,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BranchRules {
    pub required_approvals: i64,
    pub code_owner_review: bool,
    pub last_push_approval: bool,
    pub thread_resolution: bool,
    pub required_checks: BTreeSet<String>,
    pub review_rules_known: bool,
    pub check_rules_known: bool,
}

fn parse(data: Option<&[u8]>) -> Option<Value> {
    data.and_then(|d| serde_json::from_slice(d).ok())
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn check_names(v: &Value) -> Vec<String> {
    let mut out: Vec<String> = v.get("contexts").and_then(Value::as_array).map(|a| a.iter().filter_map(|c| c.as_str().map(String::from)).collect()).unwrap_or_default();
    if let Some(a) = v.get("checks").and_then(Value::as_array) {
        out.extend(a.iter().filter_map(|c| c.get("context").and_then(Value::as_str).map(String::from)));
    }
    out
}

impl BranchRules {
    pub fn is_classic_protected(branch: Option<&[u8]>) -> bool {
        parse(branch).and_then(|b| b.get("protection").map(|p| flag(p, "enabled"))).unwrap_or(false)
    }

    pub fn from_responses(rules: Option<&[u8]>, branch: Option<&[u8]>, protection: Option<&[u8]>) -> BranchRules {
        let mut r = BranchRules::default();
        let ruleset = parse(rules).filter(Value::is_array);
        let info = parse(branch).filter(Value::is_object);
        let classic = parse(protection).filter(Value::is_object);
        for rule in ruleset.as_ref().and_then(Value::as_array).into_iter().flatten() {
            let params = rule.get("parameters");
            match rule.get("type").and_then(Value::as_str) {
                Some("pull_request") => {
                    if let Some(p) = params {
                        r.required_approvals = r.required_approvals.max(p.get("required_approving_review_count").and_then(Value::as_i64).unwrap_or(0));
                        r.code_owner_review |= flag(p, "require_code_owner_review");
                        r.last_push_approval |= flag(p, "require_last_push_approval");
                        r.thread_resolution |= flag(p, "required_review_thread_resolution");
                    }
                }
                Some("required_status_checks") => {
                    if let Some(list) = params.and_then(|p| p.get("required_status_checks")).and_then(Value::as_array) {
                        r.required_checks.extend(list.iter().filter_map(|c| c.get("context").and_then(Value::as_str).map(String::from)));
                    }
                }
                _ => {}
            }
        }
        if let Some(rsc) = info.as_ref().and_then(|i| i.get("protection")).and_then(|p| p.get("required_status_checks")) {
            if rsc.get("enforcement_level").and_then(Value::as_str) != Some("off") {
                r.required_checks.extend(check_names(rsc));
            }
        }
        if let Some(c) = &classic {
            if let Some(rv) = c.get("required_pull_request_reviews") {
                r.required_approvals = r.required_approvals.max(rv.get("required_approving_review_count").and_then(Value::as_i64).unwrap_or(0));
                r.code_owner_review |= flag(rv, "require_code_owner_reviews");
                r.last_push_approval |= flag(rv, "require_last_push_approval");
            }
            if let Some(cr) = c.get("required_conversation_resolution") {
                r.thread_resolution |= flag(cr, "enabled");
            }
            if let Some(cs) = c.get("required_status_checks") {
                r.required_checks.extend(check_names(cs));
            }
        }
        let classic_protected = info.as_ref().and_then(|i| i.get("protection")).map(|p| flag(p, "enabled")).unwrap_or(false);
        r.review_rules_known = ruleset.is_some() && (!classic_protected || classic.is_some());
        r.check_rules_known = ruleset.is_some() && info.is_some();
        r
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RulesStatus {
    Loading,
    Loaded(BranchRules),
    Failed,
}

impl RulesStatus {
    pub fn rules(&self) -> Option<&BranchRules> {
        match self {
            RulesStatus::Loaded(r) => Some(r),
            _ => None,
        }
    }

    pub fn review_rules(&self) -> CapabilityState {
        match self {
            RulesStatus::Loaded(r) if r.review_rules_known => CapabilityState::Supported,
            RulesStatus::Loaded(_) => CapabilityState::Unavailable,
            _ => CapabilityState::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum RequirementState {
    Missing,
    Pending,
    Unknown,
    Advisory,
    Satisfied,
}

impl RequirementState {
    pub fn blocks(self) -> bool {
        matches!(self, RequirementState::Missing | RequirementState::Pending)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequirementAction {
    RequestReview,
    ShowChecks,
    ShowConversation,
    ShowConflicts,
    UpdateBranch,
    ReadyForReview,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequirementKind {
    Draft,
    Conflicts,
    Behind,
    ChangesRequested,
    Approvals,
    CodeOwners,
    LastPush,
    Checks,
    OptionalChecks,
    Conversations,
    Rules,
    OtherRules,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeRequirement {
    pub kind: RequirementKind,
    pub state: RequirementState,
    pub title: String,
    pub detail: Option<String>,
    pub action: Option<RequirementAction>,
}

fn req(kind: RequirementKind, state: RequirementState, title: impl Into<String>, detail: Option<String>, action: Option<RequirementAction>) -> MergeRequirement {
    MergeRequirement { kind, state, title: title.into(), detail, action }
}

#[derive(Debug, Clone, Default)]
pub struct CheckBreakdown {
    pub required_known: bool,
    pub required: Vec<CheckContext>,
    pub optional: Vec<CheckContext>,
    pub not_started: Vec<String>,
}

impl CheckBreakdown {
    pub fn failed_required(&self) -> Vec<&CheckContext> {
        self.required.iter().filter(|c| c.outcome() == CheckOutcome::Failure).collect()
    }

    pub fn running_required(&self) -> Vec<&CheckContext> {
        self.required.iter().filter(|c| c.outcome() == CheckOutcome::Pending).collect()
    }

    pub fn failed_optional(&self) -> Vec<&CheckContext> {
        self.optional.iter().filter(|c| c.outcome() == CheckOutcome::Failure).collect()
    }
}

pub fn check_breakdown(checks: &[CheckContext], rules: Option<&BranchRules>) -> CheckBreakdown {
    let flagged = checks.iter().any(|c| c.is_required.is_some());
    let names = rules.filter(|r| r.check_rules_known).map(|r| &r.required_checks);
    let mut b = CheckBreakdown::default();
    if flagged {
        b.required_known = true;
        b.required = checks.iter().filter(|c| c.is_required == Some(true)).cloned().collect();
        b.optional = checks.iter().filter(|c| c.is_required != Some(true)).cloned().collect();
    } else if let Some(names) = names {
        b.required_known = true;
        b.required = checks.iter().filter(|c| names.contains(&c.title())).cloned().collect();
        b.optional = checks.iter().filter(|c| !names.contains(&c.title())).cloned().collect();
    } else {
        b.required = checks.to_vec();
    }
    if let Some(names) = names {
        let reported: BTreeSet<String> = checks.iter().map(|c| c.title()).collect();
        b.not_started = names.difference(&reported).cloned().collect();
    }
    b
}

fn count(n: usize, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

fn names<S: AsRef<str>>(list: &[S]) -> String {
    let all: Vec<&str> = list.iter().map(|s| s.as_ref()).collect();
    if all.len() > 4 {
        format!("{} +{}", all[..4].join(", "), all.len() - 4)
    } else {
        all.join(", ")
    }
}

pub fn requirements(pr: &PullRequestDetail, status: &RulesStatus) -> Vec<MergeRequirement> {
    use RequirementAction as A;
    use RequirementKind as K;
    use RequirementState as S;
    let mut out = vec![];
    if !pr.is_open() {
        return out;
    }
    let rules = status.rules();
    let loading = *status == RulesStatus::Loading;
    let base = &pr.base_ref_name;

    if pr.is_draft {
        out.push(req(K::Draft, S::Missing, "Draft pull request", Some("Mark it ready for review before merging".into()), Some(A::ReadyForReview)));
    }
    if pr.mergeable == "CONFLICTING" || pr.merge_state_status.as_deref() == Some("DIRTY") {
        out.push(req(K::Conflicts, S::Missing, format!("Conflicts with {base}"), Some("Resolve them before merging".into()), Some(A::ShowConflicts)));
    } else if pr.mergeable == "UNKNOWN" {
        out.push(req(K::Conflicts, S::Pending, "Checking for conflicts…", None, None));
    } else {
        out.push(req(K::Conflicts, S::Satisfied, format!("No conflicts with {base}"), None, None));
    }
    if pr.merge_state_status.as_deref() == Some("BEHIND") {
        out.push(req(K::Behind, S::Missing, format!("Branch is behind {base}"), Some("The base branch requires it to be up to date".into()), Some(A::UpdateBranch)));
    }

    review_requirements(pr, rules, status.review_rules(), loading, &mut out);
    check_requirements(pr, rules, &mut out);
    conversation_requirement(pr, rules, loading, &mut out);

    if *status == RulesStatus::Failed {
        out.push(req(K::Rules, S::Unknown, "Branch rules couldn’t be read", Some("Showing what GitHub reports for this pull request".into()), None));
    }
    if pr.merge_state_status.as_deref() == Some("BLOCKED") && !out.iter().any(|r| r.state.blocks()) {
        out.push(req(K::OtherRules, S::Unknown, "Blocked by a rule PullYard can’t see", Some("For example deployments, signed commits or a merge queue. Check the pull request on GitHub".into()), None));
    }
    out
}

fn review_requirements(pr: &PullRequestDetail, rules: Option<&BranchRules>, access: CapabilityState, loading: bool, out: &mut Vec<MergeRequirement>) {
    use RequirementAction as A;
    use RequirementKind as K;
    use RequirementState as S;
    let reviews = &pr.latest_opinionated_reviews.nodes;
    let approvals: Vec<_> = reviews.iter().filter(|r| r.state == "APPROVED").collect();
    let blockers: Vec<String> = reviews.iter().filter(|r| r.state == "CHANGES_REQUESTED").filter_map(|r| r.author.as_ref().map(|a| a.login.clone())).collect();
    let required = rules.map(|r| r.required_approvals).unwrap_or(0);
    let have = approvals.len() as i64;
    let decision = pr.review_decision.as_deref();

    if !blockers.is_empty() {
        out.push(req(K::ChangesRequested, S::Missing, "Changes requested", Some(format!("By {}", blockers.join(", "))), Some(A::RequestReview)));
    }
    if required > 0 {
        let title = format!("{have} of {required} required approvals");
        if have >= required {
            out.push(req(K::Approvals, S::Satisfied, title, None, None));
        } else {
            let more = required - have;
            let detail = if more == 1 { "Needs 1 more approval".to_string() } else { format!("Needs {more} more approvals") };
            out.push(req(K::Approvals, S::Missing, title, Some(detail), Some(A::RequestReview)));
        }
    } else if decision == Some("REVIEW_REQUIRED") {
        let detail = match access {
            CapabilityState::Supported => None,
            CapabilityState::Unavailable => Some("The exact number of approvals isn’t visible with your access".to_string()),
            _ if loading => None,
            _ => Some("Branch rules couldn’t be read".to_string()),
        };
        out.push(req(K::Approvals, S::Missing, "Review required", detail, Some(A::RequestReview)));
    } else if decision == Some("APPROVED") {
        let title = if have == 1 { "Approved".to_string() } else { format!("Approved by {have} reviewers") };
        out.push(req(K::Approvals, S::Satisfied, title, None, None));
    } else if access == CapabilityState::Supported && blockers.is_empty() {
        out.push(req(K::Approvals, S::Satisfied, "No approvals required", None, None));
    } else if loading {
        out.push(req(K::Approvals, S::Pending, "Reading review rules…", None, None));
    }

    if rules.map(|r| r.code_owner_review).unwrap_or(false) {
        let waiting: Vec<String> = pr.review_requests.nodes.iter().filter(|r| r.as_code_owner == Some(true)).filter_map(|r| r.requested_reviewer.as_ref().map(|x| x.display())).collect();
        if !waiting.is_empty() {
            out.push(req(K::CodeOwners, S::Missing, "Code owner review required", Some(format!("Waiting for {}", waiting.join(", "))), Some(A::RequestReview)));
        } else if decision == Some("REVIEW_REQUIRED") && have >= required.max(1) {
            out.push(req(K::CodeOwners, S::Missing, "Code owner review required", Some("No code owner has approved yet".into()), Some(A::RequestReview)));
        } else if have > 0 {
            out.push(req(K::CodeOwners, S::Satisfied, "Code owner review", None, None));
        }
    }

    if rules.map(|r| r.last_push_approval).unwrap_or(false) && have > 0 {
        if approvals.iter().any(|a| a.commit.as_ref().map(|c| c.oid.as_str()) == Some(pr.head_ref_oid.as_str())) {
            out.push(req(K::LastPush, S::Satisfied, "Latest push approved", None, None));
        } else {
            out.push(req(K::LastPush, S::Missing, "Latest push isn’t approved", Some("Approvals were given before the last commit".into()), Some(A::RequestReview)));
        }
    }
}

fn check_requirements(pr: &PullRequestDetail, rules: Option<&BranchRules>, out: &mut Vec<MergeRequirement>) {
    use RequirementAction as A;
    use RequirementKind as K;
    use RequirementState as S;
    let checks = pr.checks();
    let b = check_breakdown(&checks, rules);
    let label = if b.required_known { "required check" } else { "check" };
    let failed = b.failed_required();
    let running = b.running_required();
    if !failed.is_empty() {
        let titles: Vec<String> = failed.iter().map(|c| c.title()).collect();
        out.push(req(K::Checks, S::Missing, format!("{} failed", count(failed.len(), label)), Some(names(&titles)), Some(A::ShowChecks)));
    } else if !running.is_empty() || !b.not_started.is_empty() {
        let mut parts = vec![];
        if !running.is_empty() {
            let titles: Vec<String> = running.iter().map(|c| c.title()).collect();
            parts.push(format!("Running: {}", names(&titles)));
        }
        if !b.not_started.is_empty() {
            parts.push(format!("Not started: {}", names(&b.not_started)));
        }
        out.push(req(K::Checks, S::Pending, format!("Waiting for {}", count(running.len() + b.not_started.len(), label)), Some(parts.join(" · ")), Some(A::ShowChecks)));
    } else if !b.required.is_empty() {
        let title = if b.required.len() == 1 { format!("1 {label} passed") } else { format!("All {} {label}s passed", b.required.len()) };
        out.push(req(K::Checks, S::Satisfied, title, None, Some(A::ShowChecks)));
    } else if b.required_known {
        out.push(req(K::Checks, S::Satisfied, "No required checks", None, None));
    }
    let optional = b.failed_optional();
    if b.required_known && !optional.is_empty() {
        out.push(req(K::OptionalChecks, S::Advisory, format!("{} failed", count(optional.len(), "optional check")), Some("Doesn’t block merging".into()), Some(A::ShowChecks)));
    }
}

fn conversation_requirement(pr: &PullRequestDetail, rules: Option<&BranchRules>, loading: bool, out: &mut Vec<MergeRequirement>) {
    use RequirementAction as A;
    use RequirementKind as K;
    use RequirementState as S;
    let open = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved).count();
    let title = if open == 1 { "1 unresolved conversation".to_string() } else { format!("{open} unresolved conversations") };
    if rules.map(|r| r.thread_resolution).unwrap_or(false) {
        if open == 0 {
            out.push(req(K::Conversations, S::Satisfied, "All conversations resolved", None, None));
        } else {
            out.push(req(K::Conversations, S::Missing, title, Some("Branch rules require resolving them".into()), Some(A::ShowConversation)));
        }
        return;
    }
    if open == 0 {
        return;
    }
    let detail = if rules.map(|r| r.review_rules_known).unwrap_or(false) {
        Some("Not required to merge".to_string())
    } else if loading {
        None
    } else {
        Some("May not block merging".to_string())
    };
    out.push(req(K::Conversations, S::Advisory, title, detail, Some(A::ShowConversation)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn pr(overrides: Value) -> PullRequestDetail {
        let mut base = json!({
            "id": "PR_1", "number": 7, "title": "T", "url": "https://github.com/o/r/pull/7", "state": "OPEN",
            "isDraft": false, "merged": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "baseRefName": "main", "headRefOid": "head",
            "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false
        });
        for (k, v) in overrides.as_object().cloned().unwrap_or_default() {
            base[k] = v;
        }
        serde_json::from_value(base).unwrap()
    }

    fn checks(nodes: Value) -> Value {
        json!({ "lastCommit": { "nodes": [{ "commit": { "oid": "head", "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": nodes } } } }] } })
    }

    fn run(name: &str, conclusion: Option<&str>, required: Option<bool>) -> Value {
        let mut n = json!({ "__typename": "CheckRun", "databaseId": name.len(), "name": name, "status": if conclusion.is_some() { "COMPLETED" } else { "IN_PROGRESS" } });
        if let Some(c) = conclusion {
            n["conclusion"] = json!(c);
        }
        if let Some(r) = required {
            n["isRequired"] = json!(r);
        }
        n
    }

    fn known() -> BranchRules {
        BranchRules { review_rules_known: true, check_rules_known: true, ..Default::default() }
    }

    fn find(list: &[MergeRequirement], kind: RequirementKind) -> &MergeRequirement {
        list.iter().find(|r| r.kind == kind).unwrap()
    }

    #[test]
    fn parses_rulesets_and_classic_checks() {
        let rules = br#"[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_last_push_approval":true,"required_review_thread_resolution":true}},
            {"type":"pull_request","parameters":{"required_approving_review_count":2,"require_code_owner_review":true}},
            {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}},{"type":"deletion"}]"#;
        let branch = br#"{"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"everyone","contexts":["lint"],"checks":[{"context":"lint"}]}}}"#;
        let r = BranchRules::from_responses(Some(rules), Some(branch), None);
        assert_eq!(r.required_approvals, 2);
        assert!(r.code_owner_review && r.last_push_approval && r.thread_resolution);
        assert_eq!(r.required_checks.iter().cloned().collect::<Vec<_>>(), vec!["build", "lint"]);
        assert!(r.review_rules_known && r.check_rules_known);
    }

    #[test]
    fn classic_protection_needs_admin() {
        let branch = br#"{"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"off","contexts":["ci"]}}}"#;
        assert!(BranchRules::is_classic_protected(Some(branch)));
        let hidden = BranchRules::from_responses(Some(b"[]"), Some(branch), None);
        assert!(!hidden.review_rules_known);
        assert!(hidden.required_checks.is_empty());
        assert_eq!(RulesStatus::Loaded(hidden).review_rules(), CapabilityState::Unavailable);
        let protection = br#"{"required_pull_request_reviews":{"required_approving_review_count":3},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"contexts":["ci"]}}"#;
        let admin = BranchRules::from_responses(Some(b"[]"), Some(branch), Some(protection));
        assert!(admin.review_rules_known && admin.thread_resolution);
        assert_eq!(admin.required_approvals, 3);
        assert_eq!(RulesStatus::Failed.review_rules(), CapabilityState::Unknown);
        assert_eq!(BranchRules::from_responses(None, None, None), BranchRules::default());
    }

    #[test]
    fn optional_failure_does_not_block() {
        let mut o = checks(json!([run("build", Some("SUCCESS"), Some(true)), run("coverage", Some("FAILURE"), Some(false))]));
        o["mergeStateStatus"] = json!("UNSTABLE");
        let list = requirements(&pr(o), &RulesStatus::Loaded(known()));
        assert_eq!(find(&list, RequirementKind::Checks).state, RequirementState::Satisfied);
        assert_eq!(find(&list, RequirementKind::OptionalChecks).state, RequirementState::Advisory);
        assert!(!list.iter().any(|r| r.state.blocks()));
    }

    #[test]
    fn required_failure_and_not_started() {
        let p = pr(checks(json!([run("build", Some("FAILURE"), Some(true)), run("lint", Some("SUCCESS"), Some(false))])));
        let mut rules = known();
        rules.required_checks = ["build", "deploy-preview"].iter().map(|s| s.to_string()).collect();
        let b = check_breakdown(&p.checks(), Some(&rules));
        assert_eq!(b.not_started, vec!["deploy-preview"]);
        let row = find(&requirements(&p, &RulesStatus::Loaded(rules.clone())), RequirementKind::Checks).clone();
        assert_eq!(row.state, RequirementState::Missing);
        assert_eq!(row.title, "1 required check failed");
        let waiting = pr(checks(json!([run("build", Some("SUCCESS"), Some(true))])));
        let row = find(&requirements(&waiting, &RulesStatus::Loaded(rules)), RequirementKind::Checks).clone();
        assert_eq!(row.state, RequirementState::Pending);
        assert_eq!(row.detail.as_deref(), Some("Not started: deploy-preview"));
    }

    #[test]
    fn legacy_server_treats_all_checks_as_blocking() {
        let p = pr(checks(json!([run("build", Some("FAILURE"), None)])));
        let b = check_breakdown(&p.checks(), None);
        assert!(!b.required_known);
        assert_eq!(b.failed_required().len(), 1);
    }

    #[test]
    fn approvals_code_owners_and_last_push() {
        let rules = BranchRules { required_approvals: 2, ..known() };
        let one = pr(json!({ "latestOpinionatedReviews": { "nodes": [{ "state": "APPROVED", "commit": { "oid": "head" }, "author": { "login": "alice", "avatarUrl": "" } }] } }));
        let list = requirements(&one, &RulesStatus::Loaded(rules));
        let row = find(&list, RequirementKind::Approvals);
        assert_eq!(row.title, "1 of 2 required approvals");
        assert_eq!(row.detail.as_deref(), Some("Needs 1 more approval"));
        let owners = BranchRules { required_approvals: 1, last_push_approval: true, code_owner_review: true, ..known() };
        let p = pr(json!({
            "latestOpinionatedReviews": { "nodes": [{ "state": "APPROVED", "commit": { "oid": "old" }, "author": { "login": "alice", "avatarUrl": "" } }] },
            "reviewRequests": { "nodes": [{ "asCodeOwner": true, "requestedReviewer": { "__typename": "Team", "name": "Core", "combinedSlug": "o/core" } }] }
        }));
        let list = requirements(&p, &RulesStatus::Loaded(owners));
        assert_eq!(find(&list, RequirementKind::LastPush).state, RequirementState::Missing);
        assert_eq!(find(&list, RequirementKind::CodeOwners).detail.as_deref(), Some("Waiting for o/core"));
        let team = p.review_requests.nodes[0].requested_reviewer.as_ref().unwrap();
        assert!(team.is_team());
        assert_eq!(team.display(), "o/core");
    }

    #[test]
    fn review_required_falls_back_when_rules_fail() {
        let p = pr(json!({ "reviewDecision": "REVIEW_REQUIRED" }));
        let list = requirements(&p, &RulesStatus::Failed);
        assert_eq!(find(&list, RequirementKind::Approvals).detail.as_deref(), Some("Branch rules couldn’t be read"));
        assert_eq!(find(&list, RequirementKind::Rules).state, RequirementState::Unknown);
    }

    #[test]
    fn conflicts_behind_draft_hidden_closed_and_threads() {
        assert_eq!(find(&requirements(&pr(json!({ "mergeable": "CONFLICTING" })), &RulesStatus::Loading), RequirementKind::Conflicts).action, Some(RequirementAction::ShowConflicts));
        assert!(requirements(&pr(json!({ "mergeStateStatus": "BEHIND" })), &RulesStatus::Loading).iter().any(|r| r.kind == RequirementKind::Behind));
        assert_eq!(requirements(&pr(json!({ "isDraft": true })), &RulesStatus::Loading)[0].kind, RequirementKind::Draft);
        assert!(requirements(&pr(json!({})), &RulesStatus::Loaded(known())).iter().any(|r| r.kind == RequirementKind::OtherRules));
        assert!(requirements(&pr(json!({ "state": "MERGED" })), &RulesStatus::Loading).is_empty());
        let threads = pr(json!({ "reviewThreads": { "nodes": [{ "id": "t1", "isResolved": false, "isOutdated": false, "path": "a", "diffSide": "RIGHT", "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": { "nodes": [] } }] } }));
        assert_eq!(find(&requirements(&threads, &RulesStatus::Loaded(known())), RequirementKind::Conversations).state, RequirementState::Advisory);
        let strict = BranchRules { thread_resolution: true, ..known() };
        assert_eq!(find(&requirements(&threads, &RulesStatus::Loaded(strict)), RequirementKind::Conversations).state, RequirementState::Missing);
    }

    #[test]
    fn files_page_and_legacy_query() {
        let page: super::super::models::FileViewedPage = serde_json::from_value(json!({ "pageInfo": { "hasNextPage": true, "endCursor": "c1" }, "nodes": [{ "path": "a", "viewerViewedState": "VIEWED" }, { "path": "b", "viewerViewedState": "UNVIEWED" }, null] })).unwrap();
        assert_eq!(page.viewed_paths().into_iter().collect::<Vec<_>>(), vec!["a"]);
        assert_eq!(page.next_cursor().as_deref(), Some("c1"));
        let q = super::super::queries::pull_request();
        let legacy = super::super::queries::pull_request_legacy();
        assert!(q.contains("isRequired(pullRequestNumber: $number)"));
        assert!(!legacy.contains("isRequired") && !legacy.contains("asCodeOwner") && !legacy.contains("combinedSlug"));
    }
}
