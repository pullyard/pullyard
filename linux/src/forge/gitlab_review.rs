use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock, Mutex};

use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use regex::Regex;
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

use super::{label, lock, FlexLabel, ForgeClient, Query};
use crate::api::code_owners::{CodeOwners, CodeOwnersFlavor, GITLAB_CODE_OWNERS_PATHS};
use crate::api::models::{CheckContext, CheckOutcome, CommitDetailRest, CommitInner, CommitPerson, CommitStats, Date, ItemRef, MergeQueueEntry, PendingComment, PrDetailResponse, PrFile, PrLight, PullRequestDetail};
use crate::api::{ApiError, ApiResult};
use crate::diff::{DiffFile, LineKind};
use crate::markdown_html;

#[derive(Deserialize, Clone, Debug)]
pub struct User {
    pub username: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub avatar_url: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct DiffRefs {
    #[serde(default)]
    pub base_sha: Option<String>,
    #[serde(default)]
    pub head_sha: Option<String>,
    #[serde(default)]
    pub start_sha: Option<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Pipeline {
    pub id: i64,
    #[serde(default)]
    pub project_id: Option<i64>,
    pub status: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Permissions {
    #[serde(default)]
    pub can_merge: Option<bool>,
}

#[derive(Deserialize)]
pub struct Detail {
    pub id: i64,
    pub iid: i64,
    #[serde(default)]
    pub source_project_id: Option<i64>,
    #[serde(default)]
    pub target_project_id: Option<i64>,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub description_html: Option<String>,
    pub state: String,
    #[serde(default)]
    pub draft: Option<bool>,
    #[serde(default)]
    pub work_in_progress: Option<bool>,
    pub web_url: String,
    pub created_at: Date,
    pub updated_at: Date,
    #[serde(default)]
    pub author: Option<User>,
    #[serde(default)]
    pub assignees: Option<Vec<User>>,
    #[serde(default)]
    pub reviewers: Option<Vec<User>>,
    pub source_branch: String,
    pub target_branch: String,
    #[serde(default)]
    pub sha: Option<String>,
    #[serde(default)]
    pub diff_refs: Option<DiffRefs>,
    #[serde(default)]
    pub detailed_merge_status: Option<String>,
    #[serde(default)]
    pub merge_status: Option<String>,
    #[serde(default)]
    pub blocking_discussions_resolved: Option<bool>,
    #[serde(default)]
    pub labels: Option<Vec<FlexLabel>>,
    #[serde(default)]
    pub head_pipeline: Option<Pipeline>,
    #[serde(default)]
    pub changes_count: Option<String>,
    #[serde(default)]
    pub user_notes_count: Option<i64>,
    #[serde(default)]
    pub squash: Option<bool>,
    #[serde(default)]
    pub squash_on_merge: Option<bool>,
    #[serde(default)]
    pub merge_when_pipeline_succeeds: Option<bool>,
    #[serde(default)]
    pub user: Option<Permissions>,
}

impl Detail {
    pub fn is_draft(&self) -> bool {
        self.draft.or(self.work_in_progress).unwrap_or(false)
    }
}

#[derive(Deserialize, Clone, Debug)]
pub struct Approver {
    pub user: User,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Approvals {
    #[serde(default)]
    pub approvals_required: Option<i64>,
    #[serde(default)]
    pub approvals_left: Option<i64>,
    #[serde(default)]
    pub approved_by: Option<Vec<Approver>>,
    #[serde(default)]
    pub user_has_approved: Option<bool>,
    #[serde(default)]
    pub user_can_approve: Option<bool>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Position {
    #[serde(default)]
    pub head_sha: Option<String>,
    #[serde(default)]
    pub old_path: Option<String>,
    #[serde(default)]
    pub new_path: Option<String>,
    #[serde(default)]
    pub old_line: Option<i64>,
    #[serde(default)]
    pub new_line: Option<i64>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Note {
    pub id: i64,
    pub body: String,
    #[serde(default)]
    pub author: Option<User>,
    pub created_at: Date,
    #[serde(default)]
    pub system: bool,
    #[serde(default)]
    pub resolvable: Option<bool>,
    #[serde(default)]
    pub resolved: Option<bool>,
    #[serde(default)]
    pub position: Option<Position>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Discussion {
    pub id: String,
    #[serde(default)]
    pub individual_note: bool,
    #[serde(default)]
    pub notes: Vec<Note>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Stats {
    pub additions: i64,
    pub deletions: i64,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Commit {
    pub id: String,
    pub short_id: String,
    pub title: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub author_name: Option<String>,
    #[serde(default)]
    pub authored_date: Option<Date>,
    #[serde(default)]
    pub committed_date: Option<Date>,
    #[serde(default)]
    pub web_url: Option<String>,
    #[serde(default)]
    pub stats: Option<Stats>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Job {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub stage: Option<String>,
    pub status: String,
    #[serde(default)]
    pub web_url: Option<String>,
    #[serde(default)]
    pub started_at: Option<Date>,
    #[serde(default)]
    pub finished_at: Option<Date>,
    #[serde(default)]
    pub allow_failure: Option<bool>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Diff {
    pub old_path: String,
    pub new_path: String,
    #[serde(default)]
    pub diff: Option<String>,
    #[serde(default)]
    pub new_file: bool,
    #[serde(default)]
    pub renamed_file: bool,
    #[serde(default)]
    pub deleted_file: bool,
    #[serde(default)]
    pub too_large: Option<bool>,
}

#[derive(Deserialize)]
struct Changes {
    changes: Vec<Diff>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Project {
    #[serde(default)]
    pub squash_option: Option<String>,
    #[serde(default)]
    pub merge_trains_enabled: Option<bool>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct TrainCar {
    pub status: String,
    #[serde(default)]
    pub pipeline: Option<Pipeline>,
}

pub fn train_entry(car: Option<&TrainCar>) -> Option<MergeQueueEntry> {
    let car = car?;
    let running = matches!(car.pipeline.as_ref().map(|p| p.status.as_str()), Some("created" | "pending" | "running" | "waiting_for_resource" | "preparing"));
    let state = match car.status.as_str() {
        "merging" => "MERGEABLE",
        "stale" => "AWAITING_CHECKS",
        "idle" | "fresh" if running => "AWAITING_CHECKS",
        "idle" | "fresh" => "QUEUED",
        _ => return None,
    };
    Some(MergeQueueEntry { state: Some(state.into()), ..Default::default() })
}

const PATH_SEGMENT: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

pub fn project_path(project: &str) -> String {
    format!("/projects/{}", utf8_percent_encode(project, PATH_SEGMENT))
}

fn mr_path(project: &str, iid: i64) -> String {
    format!("{}/merge_requests/{iid}", project_path(project))
}

async fn pages<T: DeserializeOwned>(c: &ForgeClient, path: &str, query: Query, limit: usize) -> ApiResult<Vec<T>> {
    let mut all = vec![];
    for page in 1..=limit {
        let mut q = query.clone();
        q.push(("per_page", "100".into()));
        q.push(("page", page.to_string()));
        let batch: Vec<T> = c.http().get(path, &q).await?;
        let n = batch.len();
        all.extend(batch);
        if n < 100 {
            break;
        }
    }
    Ok(all)
}

pub async fn merge_request(c: &ForgeClient, project: &str, iid: i64, html: bool) -> ApiResult<Detail> {
    let query: Query = if html { vec![("render_html", "true".into())] } else { vec![] };
    c.http().get(&mr_path(project, iid), &query).await
}

pub async fn approvals(c: &ForgeClient, project: &str, iid: i64) -> ApiResult<Approvals> {
    c.http().get(&format!("{}/approvals", mr_path(project, iid)), &[]).await
}

pub async fn discussions(c: &ForgeClient, project: &str, iid: i64) -> ApiResult<Vec<Discussion>> {
    pages(c, &format!("{}/discussions", mr_path(project, iid)), vec![], 10).await
}

pub async fn commits(c: &ForgeClient, project: &str, iid: i64) -> ApiResult<Vec<Commit>> {
    pages(c, &format!("{}/commits", mr_path(project, iid)), vec![], 3).await
}

pub async fn jobs(c: &ForgeClient, project: &str, pipeline: i64) -> ApiResult<Vec<Job>> {
    pages(c, &format!("{}/pipelines/{pipeline}/jobs", project_path(project)), vec![], 3).await
}

pub async fn job_trace(c: &ForgeClient, project: &str, job: i64) -> ApiResult<String> {
    c.http().text(&format!("{}/jobs/{job}/trace", project_path(project)), &[]).await
}

static SECTION_MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"section_(start|end):\d+:[A-Za-z0-9_.\-\[\]=,]+\r?(\x1b\[0K)?").expect("section marker"));

pub fn clean_trace(raw: &str) -> String {
    let markers = SECTION_MARKER.replace_all(raw, "");
    let lines: Vec<&str> = markers
        .split('\n')
        .map(|line| {
            let line = line.strip_suffix('\r').unwrap_or(line);
            line.rsplit('\r').next().unwrap_or(line)
        })
        .collect();
    crate::ci_fix::clean_text(&lines.join("\n"))
}

pub async fn raw_file(c: &ForgeClient, project: &str, path: &str, rev: &str) -> ApiResult<Option<String>> {
    let target = format!("{}/repository/files/{}/raw", project_path(project), utf8_percent_encode(path, PATH_SEGMENT));
    match c.http().text(&target, &[("ref", rev.to_string())]).await {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.status == 404 => Ok(None),
        Err(e) => Err(e),
    }
}

pub async fn train_car(c: &ForgeClient, project: &str, iid: i64) -> ApiResult<TrainCar> {
    c.http().get(&format!("{}/merge_trains/merge_requests/{iid}", project_path(project)), &[]).await
}

pub async fn project(c: &ForgeClient, project: &str) -> ApiResult<Project> {
    c.http().get(&project_path(project), &[]).await
}

pub async fn diffs(c: &ForgeClient, project: &str, iid: i64) -> ApiResult<Vec<Diff>> {
    match pages(c, &format!("{}/diffs", mr_path(project, iid)), vec![], 30).await {
        Err(e) if e.status == 404 => {
            let changes: Changes = c.http().get(&format!("{}/changes", mr_path(project, iid)), &[]).await?;
            Ok(changes.changes)
        }
        other => other,
    }
}

pub async fn commit(c: &ForgeClient, project: &str, sha: &str) -> ApiResult<CommitDetailRest> {
    let path = format!("{}/repository/commits/{sha}", project_path(project));
    let detail_path = path.clone();
    let diff_path = format!("{path}/diff");
    let (detail, files) = tokio::join!(c.http().get::<Commit>(&detail_path, &[]), pages::<Diff>(c, &diff_path, vec![], 10));
    let detail = detail?;
    let files = files?;
    Ok(CommitDetailRest {
        html_url: detail.web_url.clone().unwrap_or_else(|| format!("https://{}/{project}/-/commit/{}", c.host(), detail.id)),
        sha: detail.id,
        commit: CommitInner { message: detail.message.unwrap_or(detail.title), author: Some(CommitPerson { name: detail.author_name, date: detail.authored_date.or(detail.committed_date) }) },
        author: None,
        stats: detail.stats.map(|s| CommitStats { additions: s.additions, deletions: s.deletions }),
        files: Some(files.iter().map(file).collect()),
    })
}

async fn add_note(c: &ForgeClient, project: &str, iid: i64, body: &str) -> ApiResult<()> {
    c.http().send_json(Method::POST, &format!("{}/notes", mr_path(project, iid)), json!({ "body": body })).await
}

async fn add_discussion(c: &ForgeClient, project: &str, iid: i64, body: &str, position: Value) -> ApiResult<()> {
    c.http().send_json(Method::POST, &format!("{}/discussions", mr_path(project, iid)), json!({ "body": body, "position": position })).await
}

async fn update(c: &ForgeClient, project: &str, iid: i64, fields: Value) -> ApiResult<()> {
    c.http().send_json(Method::PUT, &mr_path(project, iid), fields).await
}

async fn merge_call(c: &ForgeClient, project: &str, iid: i64, squash: bool, remove_branch: bool, message: Option<String>, sha: Option<String>, auto: bool) -> ApiResult<()> {
    let mut body = json!({ "squash": squash, "should_remove_source_branch": remove_branch });
    if let Some(sha) = sha {
        body["sha"] = json!(sha);
    }
    if let Some(message) = message {
        body[if squash { "squash_commit_message" } else { "merge_commit_message" }] = json!(message);
    }
    if auto {
        body["auto_merge"] = json!(true);
        body["merge_when_pipeline_succeeds"] = json!(true);
    }
    c.http().send_json(Method::PUT, &format!("{}/merge", mr_path(project, iid)), body).await
}

pub struct Snapshot {
    pub project: String,
    pub mr: Detail,
    pub approvals: Option<Approvals>,
    pub discussions: Vec<Discussion>,
    pub commits: Vec<Commit>,
    pub jobs: Vec<Job>,
    pub settings: Option<Project>,
    pub viewer: String,
    pub train: Option<TrainCar>,
}

pub struct MergeState {
    pub mergeable: &'static str,
    pub status: &'static str,
    pub blocker: Option<String>,
}

pub fn state(raw: &str) -> &'static str {
    match raw {
        "merged" => "MERGED",
        "opened" | "locked" => "OPEN",
        _ => "CLOSED",
    }
}

fn legacy_status(status: Option<&str>) -> &'static str {
    match status {
        Some("can_be_merged") => "mergeable",
        Some("cannot_be_merged") => "conflict",
        _ => "checking",
    }
}

fn detailed(mr: &Detail) -> String {
    mr.detailed_merge_status.clone().unwrap_or_else(|| legacy_status(mr.merge_status.as_deref()).to_string())
}

fn titled(raw: &str) -> String {
    raw.split('_')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn merge_state(mr: &Detail) -> MergeState {
    let blocked = |text: Option<&str>| MergeState { mergeable: "MERGEABLE", status: "BLOCKED", blocker: text.map(str::to_string) };
    let plain = |mergeable: &'static str, status: &'static str| MergeState { mergeable, status, blocker: None };
    let status = detailed(mr);
    match status.as_str() {
        "mergeable" => plain("MERGEABLE", "CLEAN"),
        "conflict" | "broken_status" => plain("CONFLICTING", "DIRTY"),
        "need_rebase" => plain("MERGEABLE", "BEHIND"),
        "checking" | "unchecked" | "preparing" | "approvals_syncing" | "not_open" => plain("UNKNOWN", "UNKNOWN"),
        "draft_status" => plain("MERGEABLE", "DRAFT"),
        "not_approved" | "requested_changes" => blocked(None),
        "ci_must_pass" => blocked(Some(if mr.head_pipeline.is_none() { "A pipeline must run and succeed" } else { "Pipeline must succeed" })),
        "ci_still_running" => blocked(Some("Pipeline is still running")),
        "discussions_not_resolved" => blocked(Some("All threads must be resolved")),
        "blocked_status" | "merge_request_blocked" => blocked(Some("Blocked by another merge request")),
        "external_status_checks" => blocked(Some("External status checks must pass")),
        "jira_association_missing" => blocked(Some("Title or description must reference a Jira issue")),
        "security_policy_violations" | "security_policy_pipeline_check" => blocked(Some("Blocked by a security policy")),
        "locked_paths" | "locked_lfs_files" => blocked(Some("Changed files are locked")),
        "title_regex" => blocked(Some("Title doesn't match the project's required pattern")),
        "commits_status" => blocked(Some("Commits don't pass the project's push rules")),
        "merge_time" => blocked(Some("Can't be merged before the scheduled time")),
        other => blocked(Some(&titled(other))),
    }
}

pub fn review_decision(mr: &Detail, approvals: Option<&Approvals>) -> Option<&'static str> {
    if mr.detailed_merge_status.as_deref() == Some("requested_changes") {
        return Some("CHANGES_REQUESTED");
    }
    let approvals = approvals?;
    if approvals.approvals_left.unwrap_or(0) > 0 {
        return Some("REVIEW_REQUIRED");
    }
    if !approvals.approved_by.as_deref().unwrap_or_default().is_empty() {
        return Some("APPROVED");
    }
    None
}

pub fn pulse(mr: &Detail, approvals: Option<&Approvals>) -> String {
    let mut approvers: Vec<&str> = approvals.and_then(|a| a.approved_by.as_ref()).map(|v| v.iter().map(|a| a.user.username.as_str()).collect()).unwrap_or_default();
    approvers.sort();
    [
        mr.updated_at.timestamp_millis().to_string(),
        mr.sha.clone().unwrap_or_default(),
        mr.state.clone(),
        mr.head_pipeline.as_ref().map(|p| format!("{}:{}", p.id, p.status)).unwrap_or_default(),
        mr.detailed_merge_status.clone().or_else(|| mr.merge_status.clone()).unwrap_or_default(),
        mr.user_notes_count.unwrap_or(0).to_string(),
        mr.blocking_discussions_resolved.unwrap_or(true).to_string(),
        approvers.join(","),
    ]
    .join("|")
}

fn light_json(mr: &Detail, approvals: Option<&Approvals>) -> Value {
    let merge = merge_state(mr);
    json!({
        "lightUpdatedAt": mr.updated_at,
        "lightHeadOid": mr.diff_refs.as_ref().and_then(|r| r.head_sha.clone()).or_else(|| mr.sha.clone()).unwrap_or_default(),
        "lightState": state(&mr.state),
        "lightDraft": mr.is_draft(),
        "lightMergeable": merge.mergeable,
        "lightMergeState": merge.status,
        "lightFingerprint": pulse(mr, approvals),
    })
}

pub fn light(mr: &Detail, approvals: Option<&Approvals>) -> PrLight {
    serde_json::from_value(light_json(mr, approvals)).unwrap_or_default()
}

pub fn checks(jobs: &[Job]) -> Vec<Value> {
    jobs.iter()
        .map(|job| {
            let status = match job.status.as_str() {
                "running" => "IN_PROGRESS",
                "created" | "pending" | "waiting_for_resource" | "preparing" | "scheduled" | "waiting_for_callback" => "QUEUED",
                _ => "COMPLETED",
            };
            let allowed = job.allow_failure == Some(true);
            let (conclusion, note) = match job.status.as_str() {
                "success" => (Some("SUCCESS"), None),
                "failed" if allowed => (Some("NEUTRAL"), Some("Allowed to fail")),
                "failed" => (Some("FAILURE"), None),
                "canceled" | "canceling" => (Some("CANCELLED"), None),
                "skipped" => (Some("SKIPPED"), None),
                "manual" => (Some("SKIPPED"), Some("Manual")),
                _ => (None, None),
            };
            json!({
                "__typename": "GitLabJob",
                "databaseId": job.id,
                "name": job.name,
                "status": status,
                "conclusion": conclusion,
                "detailsUrl": job.web_url,
                "startedAt": job.started_at,
                "completedAt": job.finished_at,
                "checkSuite": job.stage.as_ref().map(|s| json!({ "workflowRun": { "databaseId": null, "workflow": { "name": s } } })),
                "description": note,
            })
        })
        .collect()
}

fn rollup_state(pipeline: Option<&Pipeline>) -> Option<&'static str> {
    Some(match pipeline?.status.as_str() {
        "success" => "SUCCESS",
        "failed" => "FAILURE",
        "canceled" | "skipped" => "ERROR",
        _ => "PENDING",
    })
}

pub fn project_url(web_url: &str) -> String {
    web_url.split("/-/").next().unwrap_or(web_url).to_string()
}

fn actor(u: &User) -> Value {
    json!({ "login": u.username, "avatarUrl": u.avatar_url })
}

fn label_json(l: &FlexLabel) -> Value {
    let info = match l {
        FlexLabel::Detailed { name, color } => label(name.clone(), color.clone()),
        FlexLabel::Name(name) => label(name.clone(), None),
    };
    json!({ "name": info.name, "color": info.color })
}

fn timeline(kind: &str, id: String, author: Option<Value>, actor: Option<Value>, body: Option<&str>, html: Option<String>, date: Date, state: Option<&str>) -> Value {
    json!({ "__typename": kind, "id": id, "author": author, "actor": actor, "body": body, "bodyHTML": html, "createdAt": date, "state": state })
}

pub fn conversation(discussions: &[Discussion], head_sha: Option<&str>, base: &str, viewer: &str, moderator: bool) -> (Vec<Value>, Vec<Value>) {
    let mut items = vec![];
    let mut threads = vec![];
    let mut ordered: Vec<&Discussion> = discussions.iter().collect();
    ordered.sort_by_key(|d| d.notes.first().map(|n| n.created_at));
    for d in ordered {
        let Some(first) = d.notes.first() else { continue };
        if first.system {
            for n in &d.notes {
                items.push(timeline("SystemNote", format!("gl-n-{}", n.id), None, n.author.as_ref().map(actor), Some(n.body.as_str()), None, n.created_at, None));
            }
            continue;
        }
        let notes: Vec<&Note> = d.notes.iter().filter(|n| !n.system).collect();
        if d.individual_note && first.position.is_none() {
            items.push(timeline("IssueComment", format!("gl-n-{}", first.id), first.author.as_ref().map(actor), None, Some(first.body.as_str()), Some(markdown_html::render(&first.body, Some(base))), first.created_at, None));
            continue;
        }
        let review = format!("gl-d-{}", d.id);
        let resolvable: Vec<&&Note> = notes.iter().filter(|n| n.resolvable == Some(true)).collect();
        let resolved = !resolvable.is_empty() && resolvable.iter().all(|n| n.resolved == Some(true));
        let starter = first.author.as_ref().is_some_and(|a| a.username.to_lowercase() == viewer);
        let can_resolve = !resolvable.is_empty() && (moderator || starter);
        let position = first.position.as_ref();
        let outdated = matches!((position.and_then(|p| p.head_sha.as_deref()), head_sha), (Some(p), Some(h)) if p != h);
        let line = position.and_then(|p| p.new_line.or(p.old_line));
        let left = position.is_some_and(|p| p.new_line.is_none() && p.old_line.is_some());
        let comments: Vec<Value> = notes
            .iter()
            .map(|n| {
                json!({
                    "id": n.id.to_string(),
                    "author": n.author.as_ref().map(actor),
                    "body": n.body,
                    "bodyHTML": markdown_html::render(&n.body, Some(base)),
                    "createdAt": n.created_at,
                    "pullRequestReview": { "id": review },
                })
            })
            .collect();
        threads.push(json!({
            "id": d.id,
            "isResolved": resolved,
            "isOutdated": outdated,
            "path": position.map(|p| p.new_path.clone().or_else(|| p.old_path.clone()).unwrap_or_default()).unwrap_or_default(),
            "line": if outdated { None } else { line },
            "originalLine": line,
            "diffSide": if left { "LEFT" } else { "RIGHT" },
            "viewerCanResolve": can_resolve && !resolved,
            "viewerCanUnresolve": can_resolve && resolved,
            "viewerCanReply": true,
            "comments": { "nodes": comments },
        }));
        items.push(timeline("PullRequestReview", review, first.author.as_ref().map(actor), None, None, None, first.created_at, Some("DISCUSSION")));
    }
    (items, threads)
}

pub fn detail_json(s: &Snapshot) -> Value {
    let mr = &s.mr;
    let base = project_url(&mr.web_url);
    let merge = merge_state(mr);
    let me = s.viewer.to_lowercase();
    let is_author = !me.is_empty() && mr.author.as_ref().is_some_and(|a| a.username.to_lowercase() == me);
    let can_merge = mr.user.as_ref().and_then(|u| u.can_merge) == Some(true);
    let head = mr.diff_refs.as_ref().and_then(|r| r.head_sha.clone()).or_else(|| mr.sha.clone());
    let (items, threads) = conversation(&s.discussions, head.as_deref(), &base, &me, can_merge || is_author);
    let commits: Vec<Value> = s
        .commits
        .iter()
        .rev()
        .map(|c| {
            json!({ "commit": {
                "oid": c.id,
                "abbreviatedOid": c.short_id,
                "messageHeadline": c.title,
                "committedDate": c.committed_date.or(c.authored_date).unwrap_or(mr.created_at),
                "url": c.web_url.clone().unwrap_or_else(|| format!("{base}/-/commit/{}", c.id)),
                "author": { "name": c.author_name },
            } })
        })
        .collect();
    let last_date = s.commits.first().and_then(|c| c.committed_date.or(c.authored_date)).unwrap_or(mr.created_at);
    let contexts = checks(&s.jobs);
    let rollup = rollup_state(mr.head_pipeline.as_ref()).map(|st| json!({ "state": st, "contexts": { "nodes": contexts, "totalCount": contexts.len() } }));
    let approvers: Vec<&User> = s.approvals.as_ref().and_then(|a| a.approved_by.as_ref()).map(|v| v.iter().map(|a| &a.user).collect()).unwrap_or_default();
    let approved: HashSet<&str> = approvers.iter().map(|u| u.username.as_str()).collect();
    let pending: Vec<Value> = mr
        .reviewers
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|u| !approved.contains(u.username.as_str()))
        .map(|u| json!({ "requestedReviewer": { "__typename": "User", "login": u.username, "avatarUrl": u.avatar_url, "name": u.name } }))
        .collect();
    let changed = mr.changes_count.as_deref().map(|c| c.chars().take_while(|ch| ch.is_ascii_digit()).collect::<String>()).and_then(|d| d.parse::<i64>().ok()).unwrap_or(0);
    let same_place = mr.source_project_id.is_none() || mr.source_project_id == mr.target_project_id;
    let st = state(&mr.state);
    let body_html = match &mr.description_html {
        Some(h) => markdown_html::absolutize_html(h, &base),
        None => markdown_html::render(mr.description.as_deref().unwrap_or(""), Some(&base)),
    };
    let mut v = json!({
        "id": format!("gitlab-mr-{}", mr.id),
        "number": mr.iid,
        "title": mr.title,
        "url": mr.web_url,
        "state": st,
        "isDraft": mr.is_draft(),
        "merged": st == "MERGED",
        "mergeable": merge.mergeable,
        "mergeStateStatus": merge.status,
        "body": mr.description.clone().unwrap_or_default(),
        "bodyHTML": body_html,
        "createdAt": mr.created_at,
        "author": mr.author.as_ref().map(actor),
        "headRefName": mr.source_branch,
        "baseRefName": mr.target_branch,
        "headRefOid": head.clone().unwrap_or_default(),
        "baseRef": mr.diff_refs.as_ref().and_then(|r| r.base_sha.clone()).map(|oid| json!({ "target": { "oid": oid } })),
        "headRepository": if same_place { Some(json!({ "nameWithOwner": s.project })) } else { None },
        "headRef": if st == "OPEN" { Some(json!({ "name": mr.source_branch })) } else { None },
        "additions": 0,
        "deletions": 0,
        "changedFiles": changed,
        "reviewDecision": review_decision(mr, s.approvals.as_ref()),
        "viewerCanUpdate": can_merge || is_author,
        "viewerDidAuthor": is_author,
        "autoMergeRequest": if mr.merge_when_pipeline_succeeds == Some(true) { Some(json!({})) } else { None },
        "labels": { "nodes": mr.labels.as_deref().unwrap_or_default().iter().map(label_json).collect::<Vec<_>>() },
        "assignees": { "nodes": mr.assignees.as_deref().unwrap_or_default().iter().map(actor).collect::<Vec<_>>() },
        "reviewRequests": { "nodes": pending },
        "latestOpinionatedReviews": { "nodes": approvers.iter().map(|u| json!({ "state": "APPROVED", "author": actor(u) })).collect::<Vec<_>>() },
        "lastCommit": { "nodes": [{ "commit": { "oid": head.unwrap_or_default(), "committedDate": last_date, "statusCheckRollup": rollup } }] },
        "allCommits": { "nodes": commits, "totalCount": commits.len() },
        "timelineItems": { "nodes": items },
        "reviewThreads": { "nodes": threads },
        "viewerCanApprove": s.approvals.as_ref().and_then(|a| a.user_can_approve),
        "viewerApproved": s.approvals.as_ref().and_then(|a| a.user_has_approved),
        "mergeBlocker": merge.blocker,
        "forgeMerge": {
            "status": detailed(mr),
            "approvalsRequired": s.approvals.as_ref().and_then(|a| a.approvals_required),
            "approvalsLeft": s.approvals.as_ref().and_then(|a| a.approvals_left),
        },
    });
    v["isMergeQueueEnabled"] = json!(s.settings.as_ref().and_then(|p| p.merge_trains_enabled));
    v["mergeQueueEntry"] = json!(train_entry(s.train.as_ref()).map(|e| json!({ "position": e.position, "state": e.state })));
    if let (Some(obj), Value::Object(light)) = (v.as_object_mut(), light_json(mr, s.approvals.as_ref())) {
        obj.extend(light);
    }
    v
}

pub fn repository_json(s: &Snapshot) -> Value {
    let squash = s.settings.as_ref().and_then(|p| p.squash_option.clone()).unwrap_or_else(|| "default_off".into());
    let prefers = squash == "always" || squash == "default_on" || s.mr.squash == Some(true) || s.mr.squash_on_merge == Some(true);
    let can_merge = s.mr.user.as_ref().and_then(|u| u.can_merge) == Some(true);
    json!({
        "viewerPermission": if can_merge { "WRITE" } else { "READ" },
        "mergeCommitAllowed": squash != "always",
        "squashMergeAllowed": squash != "never",
        "rebaseMergeAllowed": false,
        "deleteBranchOnMerge": false,
        "autoMergeAllowed": s.mr.head_pipeline.is_some(),
        "viewerDefaultMergeMethod": if prefers && squash != "never" { "SQUASH" } else { "MERGE" },
        "pullRequest": detail_json(s),
    })
}

pub fn response(s: &Snapshot) -> ApiResult<PrDetailResponse> {
    serde_json::from_value(json!({ "viewer": { "login": s.viewer }, "repository": repository_json(s) })).map_err(|e| ApiError::new(format!("Failed to read the merge request: {e}")))
}

pub fn file(d: &Diff) -> PrFile {
    let patch = d.diff.clone().filter(|p| !p.is_empty() && d.too_large != Some(true));
    let mut additions = 0;
    let mut deletions = 0;
    for line in patch.as_deref().unwrap_or("").lines() {
        if line.starts_with('+') {
            additions += 1;
        } else if line.starts_with('-') {
            deletions += 1;
        }
    }
    let status = if d.new_file {
        "added"
    } else if d.deleted_file {
        "removed"
    } else if d.renamed_file {
        "renamed"
    } else {
        "modified"
    };
    PrFile { filename: d.new_path.clone(), status: status.into(), additions, deletions, patch, previous_filename: if d.renamed_file { Some(d.old_path.clone()) } else { None } }
}

pub fn position(comment: &PendingComment, files: &[DiffFile], refs: Option<&DiffRefs>) -> Option<Value> {
    let refs = refs?;
    let base = refs.base_sha.clone()?;
    let head = refs.head_sha.clone()?;
    let file = files.iter().find(|f| f.id == comment.path);
    let mut p = json!({
        "position_type": "text",
        "base_sha": base,
        "start_sha": refs.start_sha.clone().unwrap_or_else(|| base.clone()),
        "head_sha": head,
        "new_path": comment.path,
        "old_path": file.and_then(|f| f.previous_filename.clone()).unwrap_or_else(|| comment.path.clone()),
    });
    let left = comment.side == "LEFT";
    let line = file.and_then(|f| f.lines.iter().find(|l| if left { l.old_line == Some(comment.line) && l.kind != LineKind::Add } else { l.new_line == Some(comment.line) && l.kind != LineKind::Del }));
    p[if left { "old_line" } else { "new_line" }] = json!(comment.line);
    if let Some(l) = line.filter(|l| l.kind == LineKind::Context) {
        if let Some(o) = l.old_line {
            p["old_line"] = json!(o);
        }
        if let Some(n) = l.new_line {
            p["new_line"] = json!(n);
        }
    }
    Some(p)
}

static DRAFT_PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\s*(\[draft\]|\(draft\)|draft:|draft\s*-|wip:|\[wip\])\s*").expect("regex"));

pub fn undrafted(title: &str) -> String {
    DRAFT_PREFIX.replace(title, "").into_owned()
}

fn message(title: Option<String>, body: Option<String>, pr: &PullRequestDetail) -> Option<String> {
    if title.is_none() && body.is_none() {
        return None;
    }
    Some([Some(title.unwrap_or_else(|| pr.title.clone())), body].into_iter().flatten().collect::<Vec<_>>().join("\n\n"))
}

fn head_sha(pr: &PullRequestDetail) -> Option<String> {
    Some(pr.head_ref_oid.clone()).filter(|s| !s.is_empty())
}

#[derive(Clone)]
pub struct GitLabReview {
    client: ForgeClient,
    settings: Arc<Mutex<HashMap<String, Option<Project>>>>,
    refs: Arc<Mutex<HashMap<ItemRef, DiffRefs>>>,
    job_projects: Arc<Mutex<HashMap<ItemRef, String>>>,
}

impl GitLabReview {
    pub fn new(client: ForgeClient) -> Self {
        GitLabReview { client, settings: Arc::new(Mutex::new(HashMap::new())), refs: Arc::new(Mutex::new(HashMap::new())), job_projects: Arc::new(Mutex::new(HashMap::new())) }
    }

    pub fn host(&self) -> String {
        self.client.host()
    }

    async fn project_settings(&self, name: &str) -> Option<Project> {
        let hit = lock(&self.settings).get(name).cloned();
        if let Some(hit) = hit {
            return hit;
        }
        let fresh = project(&self.client, name).await.ok();
        lock(&self.settings).insert(name.to_string(), fresh.clone());
        fresh
    }

    pub async fn load(&self, r: &ItemRef) -> ApiResult<PrDetailResponse> {
        let c = &self.client;
        let name = r.repo.full();
        let (mr, approvals, discussions, commits, settings, viewer) = tokio::join!(
            merge_request(c, &name, r.number, true),
            approvals(c, &name, r.number),
            discussions(c, &name, r.number),
            commits(c, &name, r.number),
            self.project_settings(&name),
            c.login()
        );
        let mr = mr?;
        let jobs = match &mr.head_pipeline {
            Some(p) => {
                let owner = p.project_id.map(|id| id.to_string()).unwrap_or_else(|| name.clone());
                lock(&self.job_projects).insert(r.clone(), owner.clone());
                jobs(c, &owner, p.id).await.unwrap_or_default()
            }
            None => vec![],
        };
        if let Some(refs) = mr.diff_refs.clone() {
            lock(&self.refs).insert(r.clone(), refs);
        }
        let train = if settings.as_ref().and_then(|p| p.merge_trains_enabled) == Some(true) && mr.state == "opened" { train_car(c, &name, r.number).await.ok() } else { None };
        let snapshot = Snapshot { project: name, mr, approvals: approvals.ok(), discussions: discussions?, commits: commits?, jobs, settings, viewer: viewer.unwrap_or_default(), train };
        response(&snapshot)
    }

    pub async fn pulse(&self, r: &ItemRef) -> ApiResult<Option<PrLight>> {
        let name = r.repo.full();
        let (mr, approvals) = tokio::join!(merge_request(&self.client, &name, r.number, false), approvals(&self.client, &name, r.number));
        Ok(Some(light(&mr?, approvals.ok().as_ref())))
    }

    pub async fn files(&self, r: &ItemRef) -> ApiResult<Vec<PrFile>> {
        Ok(diffs(&self.client, &r.repo.full(), r.number).await?.iter().map(file).collect())
    }

    pub fn can_show_log(check: &CheckContext) -> bool {
        check.typename == "GitLabJob" && check.database_id.is_some() && !matches!(check.outcome(), CheckOutcome::Pending | CheckOutcome::Skipped)
    }

    pub async fn code_owners(&self, r: &ItemRef, base: &str) -> ApiResult<Option<CodeOwners>> {
        let project = r.repo.full();
        for path in GITLAB_CODE_OWNERS_PATHS {
            if let Some(text) = raw_file(&self.client, &project, path, base).await? {
                return Ok(Some(CodeOwners::parse_flavored(&text, path, CodeOwnersFlavor::GitLab)));
            }
        }
        Ok(None)
    }

    pub async fn job_log(&self, r: &ItemRef, check: &CheckContext) -> ApiResult<String> {
        let Some(id) = check.database_id else { return Err(ApiError::new("This job has no log")) };
        let project = lock(&self.job_projects).get(r).cloned().unwrap_or_else(|| r.repo.full());
        let raw = job_trace(&self.client, &project, id).await?;
        Ok(clean_trace(&raw))
    }

    pub async fn comment(&self, r: &ItemRef, body: &str) -> ApiResult<()> {
        add_note(&self.client, &r.repo.full(), r.number, body).await
    }

    pub async fn submit_review(&self, r: &ItemRef, pr: &PullRequestDetail, event: &str, body: &str, comments: &[PendingComment], files: &[DiffFile]) -> ApiResult<()> {
        let name = r.repo.full();
        let refs = lock(&self.refs).get(r).cloned();
        for c in comments {
            let Some(p) = position(c, files, refs.as_ref()) else {
                return Err(ApiError::new("Reload the merge request and try again: its diff version is unknown"));
            };
            add_discussion(&self.client, &name, r.number, &c.body, p).await?;
        }
        let text = body.trim();
        if !text.is_empty() {
            add_note(&self.client, &name, r.number, text).await?;
        }
        if event == "APPROVE" {
            let body = head_sha(pr).map(|sha| json!({ "sha": sha })).unwrap_or_else(|| json!({}));
            self.client.http().send_json(Method::POST, &format!("{}/approve", mr_path(&name, r.number)), body).await?;
        }
        Ok(())
    }

    pub async fn reply(&self, r: &ItemRef, thread: &str, body: &str) -> ApiResult<()> {
        self.client.http().send_json(Method::POST, &format!("{}/discussions/{thread}/notes", mr_path(&r.repo.full(), r.number)), json!({ "body": body })).await
    }

    pub async fn set_resolved(&self, r: &ItemRef, thread: &str, resolved: bool) -> ApiResult<()> {
        self.client.http().send_json(Method::PUT, &format!("{}/discussions/{thread}", mr_path(&r.repo.full(), r.number)), json!({ "resolved": resolved })).await
    }

    pub async fn merge(&self, r: &ItemRef, pr: &PullRequestDetail, method: &str, title: Option<String>, body: Option<String>, delete_branch: bool) -> ApiResult<()> {
        merge_call(&self.client, &r.repo.full(), r.number, method == "SQUASH", delete_branch, message(title, body, pr), head_sha(pr), false).await
    }

    pub async fn enable_auto_merge(&self, r: &ItemRef, pr: &PullRequestDetail, method: &str) -> ApiResult<()> {
        merge_call(&self.client, &r.repo.full(), r.number, method == "SQUASH", false, None, head_sha(pr), true).await
    }

    pub async fn close(&self, r: &ItemRef, open: bool) -> ApiResult<()> {
        update(&self.client, &r.repo.full(), r.number, json!({ "state_event": if open { "reopen" } else { "close" } })).await
    }

    pub async fn set_draft(&self, r: &ItemRef, pr: &PullRequestDetail, draft: bool) -> ApiResult<()> {
        let clean = undrafted(&pr.title);
        let title = if draft { format!("Draft: {clean}") } else { clean };
        update(&self.client, &r.repo.full(), r.number, json!({ "title": title })).await
    }

    pub async fn rebase(&self, r: &ItemRef) -> ApiResult<()> {
        self.client.http().post(Method::PUT, &format!("{}/rebase", mr_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn cancel_auto_merge(&self, r: &ItemRef) -> ApiResult<()> {
        self.client.http().post(Method::POST, &format!("{}/cancel_merge_when_pipeline_succeeds", mr_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn edit(&self, r: &ItemRef, title: &str, body: &str) -> ApiResult<()> {
        update(&self.client, &r.repo.full(), r.number, json!({ "title": title, "description": body })).await
    }

    pub async fn revoke_approval(&self, r: &ItemRef) -> ApiResult<()> {
        self.client.http().post(Method::POST, &format!("{}/unapprove", mr_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn commit(&self, project: &str, sha: &str) -> ApiResult<CommitDetailRest> {
        commit(&self.client, project, sha).await
    }
}

pub fn parse_url(url: &str) -> Option<ItemRef> {
    let u = url::Url::parse(url).ok()?;
    let path = u.path().trim_start_matches('/');
    let (project, rest) = path.split_once("/-/merge_requests/")?;
    let number: i64 = rest.split(['/', '#', '?']).next()?.parse().ok()?;
    Some(ItemRef { repo: crate::api::models::RepoRef::from_full(project)?, number })
}

#[cfg(test)]
mod tests {
    use super::super::stub::Stub;
    use super::*;
    use crate::api::models::{CheckOutcome, RepoRef};
    use crate::git_accounts::GitProvider;

    const DETAIL: &str = r#"{"id":901,"iid":7,"project_id":42,"source_project_id":42,"target_project_id":42,"title":"Add login","description":"Adds **login**",
     "description_html":"<p>Adds <strong>login</strong> <img data-src=\"/group/sub/app/uploads/a.png\" src=\"data:image/gif;base64,R0lG\"> <a href=\"/group/sub/app/-/issues/3\">#3</a></p>",
     "state":"opened","draft":false,"web_url":"https://gitlab.example.com/group/sub/app/-/merge_requests/7",
     "created_at":"2026-10-01T10:00:00.000Z","updated_at":"2026-10-03T12:00:00.000Z",
     "author":{"id":1,"username":"max","name":"Max","avatar_url":"https://a/max.png"},
     "assignees":[{"id":1,"username":"max","avatar_url":null}],
     "reviewers":[{"id":2,"username":"sofia","avatar_url":null},{"id":3,"username":"lea","avatar_url":null}],
     "source_branch":"feature/login","target_branch":"main","sha":"head2",
     "diff_refs":{"base_sha":"base1","head_sha":"head2","start_sha":"start1"},
     "detailed_merge_status":"discussions_not_resolved","has_conflicts":false,"blocking_discussions_resolved":false,
     "labels":["backend"],"head_pipeline":{"id":55,"project_id":42,"status":"failed","web_url":"https://gitlab.example.com/p/55"},
     "changes_count":"3","user_notes_count":4,"squash":false,"merge_when_pipeline_succeeds":false,
     "user":{"can_merge":true},"references":{"full":"group/sub/app!7"}}"#;

    const DISCUSSIONS: &str = r#"[
     {"id":"d3","individual_note":false,"notes":[
       {"id":31,"type":"DiffNote","body":"Old remark","author":{"username":"lea"},"created_at":"2026-10-02T09:00:00Z","system":false,"resolvable":true,"resolved":true,
        "position":{"base_sha":"base0","start_sha":"base0","head_sha":"head1","old_path":"a.swift","new_path":"a.swift","old_line":null,"new_line":4,"position_type":"text"}}]},
     {"id":"d1","individual_note":true,"notes":[
       {"id":11,"type":null,"body":"approved this merge request","author":{"username":"lea"},"created_at":"2026-10-01T11:00:00Z","system":true}]},
     {"id":"d2","individual_note":true,"notes":[
       {"id":21,"type":null,"body":"Looks **good**","author":{"username":"lea","avatar_url":"https://a/lea.png"},"created_at":"2026-10-01T12:00:00Z","system":false}]},
     {"id":"d4","individual_note":false,"notes":[
       {"id":41,"type":"DiffNote","body":"Rename this","author":{"username":"sofia"},"created_at":"2026-10-02T10:00:00Z","system":false,"resolvable":true,"resolved":false,
        "position":{"base_sha":"base1","start_sha":"start1","head_sha":"head2","old_path":"b.swift","new_path":"b.swift","old_line":9,"new_line":null,"position_type":"text"}},
       {"id":42,"type":"DiffNote","body":"Done","author":{"username":"max"},"created_at":"2026-10-02T11:00:00Z","system":false,"resolvable":true,"resolved":false}]},
     {"id":"d5","individual_note":false,"notes":[
       {"id":51,"type":"DiscussionNote","body":"General question","author":{"username":"lea"},"created_at":"2026-10-02T12:00:00Z","system":false,"resolvable":true,"resolved":false}]}
    ]"#;

    fn r() -> ItemRef {
        ItemRef { repo: RepoRef::new("group", "sub/app"), number: 7 }
    }

    fn setup() -> (Arc<Stub>, GitLabReview) {
        let stub = Arc::new(Stub::default());
        let routes: [(&str, u16, &str); 15] = [
            ("/merge_requests/7", 200, DETAIL),
            ("/merge_requests/7/approvals", 200, r#"{"approved":false,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":3,"username":"lea","avatar_url":"https://a/lea.png"}}],"user_has_approved":false,"user_can_approve":true}"#),
            ("/merge_requests/7/discussions", 200, DISCUSSIONS),
            ("/merge_requests/7/commits", 200, r#"[{"id":"c2","short_id":"c2","title":"Second","author_name":"Max","committed_date":"2026-10-02T08:00:00Z"},{"id":"c1","short_id":"c1","title":"First","author_name":"Max","committed_date":"2026-10-01T08:00:00Z"}]"#),
            ("/pipelines/55/jobs", 200, r#"[{"id":1,"name":"build","stage":"build","status":"success","started_at":"2026-10-02T08:00:00Z","finished_at":"2026-10-02T08:01:30Z"},{"id":2,"name":"lint","stage":"test","status":"failed","allow_failure":true},{"id":3,"name":"unit","stage":"test","status":"failed"},{"id":4,"name":"deploy","stage":"deploy","status":"manual"},{"id":5,"name":"e2e","stage":"test","status":"running"}]"#),
            ("/projects/group/sub/app", 200, r#"{"id":42,"path_with_namespace":"group/sub/app","merge_method":"merge","squash_option":"default_on"}"#),
            ("/merge_requests/7/notes", 201, "{}"),
            ("/merge_requests/7/discussions/d4", 200, "{}"),
            ("/merge_requests/7/discussions/d4/notes", 201, "{}"),
            ("/merge_requests/7/approve", 201, "{}"),
            ("/merge_requests/7/unapprove", 201, "{}"),
            ("/merge_requests/7/merge", 200, "{}"),
            ("/merge_requests/7/cancel_merge_when_pipeline_succeeds", 201, "{}"),
            ("/merge_requests/7/rebase", 202, "{}"),
            ("/api/v4/user", 200, r#"{"id":2,"username":"sofia","name":"Sofia"}"#),
        ];
        for (k, s, b) in routes {
            stub.route(k, s, b);
        }
        let client = ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "sofia", stub.clone());
        (stub, GitLabReview::new(client))
    }

    fn load(b: &GitLabReview) -> (PrDetailResponse, PullRequestDetail) {
        let mut resp = crate::rt::block_on(b.load(&r())).unwrap();
        let pr = resp.repository.as_mut().and_then(|x| x.pull_request.take()).unwrap();
        (resp, pr)
    }

    #[test]
    fn load_maps_merge_request() {
        let (stub, b) = setup();
        let (resp, pr) = load(&b);
        let repo = resp.repository.as_ref().unwrap();
        assert_eq!(resp.viewer.login, "sofia");
        assert!(repo.can_write());
        assert!(repo.squash_merge_allowed);
        assert!(!repo.rebase_merge_allowed);
        assert_eq!(repo.viewer_default_merge_method, "SQUASH");
        assert_eq!(pr.number, 7);
        assert_eq!(pr.state, "OPEN");
        assert_eq!(pr.head_ref_name, "feature/login");
        assert_eq!(pr.base_ref_name, "main");
        assert_eq!(pr.head_ref_oid, "head2");
        assert_eq!(pr.changed_files, 3);
        assert_eq!(pr.merge_state_status.as_deref(), Some("BLOCKED"));
        assert_eq!(pr.merge_blocker.as_deref(), Some("All threads must be resolved"));
        assert_eq!(pr.review_decision.as_deref(), Some("REVIEW_REQUIRED"));
        assert!(!pr.viewer_did_author);
        assert_eq!(pr.viewer_can_approve, Some(true));
        assert_eq!(pr.viewer_approved, Some(false));
        assert_eq!(pr.labels.nodes.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), ["backend"]);
        assert_eq!(pr.latest_opinionated_reviews.nodes.iter().filter_map(|x| x.author.as_ref().map(|a| a.login.as_str())).collect::<Vec<_>>(), ["lea"]);
        assert_eq!(pr.review_requests.nodes.iter().filter_map(|x| x.requested_reviewer.as_ref().map(|v| v.display())).collect::<Vec<_>>(), ["sofia"]);
        assert!(pr.body_html.contains(r#"src="https://gitlab.example.com/group/sub/app/uploads/a.png""#), "{}", pr.body_html);
        assert!(pr.body_html.contains(r#"href="https://gitlab.example.com/group/sub/app/-/issues/3""#), "{}", pr.body_html);
        assert!(!pr.body_html.contains("data:image"));
        assert_eq!(pr.all_commits.nodes.iter().map(|c| c.commit.oid.as_str()).collect::<Vec<_>>(), ["c1", "c2"]);

        let checks: HashMap<String, CheckOutcome> = pr.checks().iter().map(|c| (c.title(), c.outcome())).collect();
        assert_eq!(checks["build"], CheckOutcome::Success);
        assert_eq!(checks["lint"], CheckOutcome::Neutral);
        assert_eq!(checks["unit"], CheckOutcome::Failure);
        assert_eq!(checks["deploy"], CheckOutcome::Skipped);
        assert_eq!(checks["e2e"], CheckOutcome::Pending);
        assert_eq!(pr.checks()[0].workflow_name().as_deref(), Some("build"));
        assert_eq!(pr.checks()[0].duration().as_deref(), Some("1m 30s"));
        assert_eq!(pr.rollup().map(|x| x.state.as_str()), Some("FAILURE"));

        let threads: HashMap<String, _> = pr.review_threads.nodes.iter().map(|t| (t.id.clone(), t.clone())).collect();
        assert_eq!(threads.len(), 3);
        let current = &threads["d4"];
        assert_eq!(current.path, "b.swift");
        assert_eq!(current.line, Some(9));
        assert_eq!(current.diff_side, "LEFT");
        assert!(!current.is_outdated && !current.is_resolved && current.viewer_can_resolve);
        assert_eq!(current.comments.nodes.iter().map(|c| c.body.as_str()).collect::<Vec<_>>(), ["Rename this", "Done"]);
        let old = &threads["d3"];
        assert!(old.is_outdated && old.is_resolved && old.viewer_can_unresolve);
        assert_eq!(old.line, None);
        assert_eq!(old.original_line, Some(4));
        let general = &threads["d5"];
        assert_eq!(general.path, "");
        assert_eq!(general.line, None);

        assert_eq!(pr.timeline_items.nodes.iter().map(|i| i.typename.as_str()).collect::<Vec<_>>(), ["SystemNote", "IssueComment", "PullRequestReview", "PullRequestReview", "PullRequestReview"]);
        let comment = pr.timeline_items.nodes.iter().find(|i| i.typename == "IssueComment").unwrap();
        assert_eq!(comment.body_html.as_deref(), Some("<p>Looks <strong>good</strong></p>"));

        let detail = stub.requests("GET", "/merge_requests/7").into_iter().next().unwrap();
        assert!(detail.url.contains("/api/v4/projects/group%2Fsub%2Fapp/merge_requests/7?render_html=true"), "{}", detail.url);

        let html = crate::conversation_html::render_pr(&pr, crate::conversation_html::Look { dark: false, brand: false });
        assert!(html.contains("started a thread"));
        assert!(html.contains("approved this merge request"));
        assert!(!html.contains("data-a=\"file\" data-id=\"\""));
    }

    #[test]
    fn pulse_tracks_approvals() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        let same = crate::rt::block_on(b.pulse(&r())).unwrap().unwrap();
        assert!(pr.light.is_known());
        assert_eq!(pr.light.clone().normalized(), same.normalized());
        stub.route("/merge_requests/7/approvals", 200, r#"{"approved_by":[{"user":{"username":"lea"}},{"user":{"username":"sofia"}}],"user_has_approved":true}"#);
        let changed = crate::rt::block_on(b.pulse(&r())).unwrap().unwrap();
        assert_ne!(pr.light.normalized(), changed.normalized());
        assert!(!stub.requests("GET", "/merge_requests/7").last().unwrap().url.contains("render_html"));
    }

    #[test]
    fn files_map_diffs_and_fall_back_to_changes() {
        let (stub, b) = setup();
        stub.route(
            "/merge_requests/7/diffs",
            200,
            r#"[{"old_path":"a.swift","new_path":"a.swift","diff":"@@ -1,2 +1,3 @@\n line\n-old\n+new\n+more\n","new_file":false,"renamed_file":false,"deleted_file":false},
                {"old_path":"old.swift","new_path":"new.swift","diff":"","new_file":false,"renamed_file":true,"deleted_file":false},
                {"old_path":"big.json","new_path":"big.json","diff":"@@ -1 +1 @@\n-a\n+b\n","new_file":true,"renamed_file":false,"deleted_file":false,"too_large":true}]"#,
        );
        let files = crate::rt::block_on(b.files(&r())).unwrap();
        assert_eq!(files.iter().map(|f| f.filename.as_str()).collect::<Vec<_>>(), ["a.swift", "new.swift", "big.json"]);
        assert_eq!(files[0].status, "modified");
        assert_eq!((files[0].additions, files[0].deletions), (2, 1));
        assert_eq!(DiffFile::new(&files[0]).lines.len(), 5);
        assert_eq!(files[1].status, "renamed");
        assert_eq!(files[1].previous_filename.as_deref(), Some("old.swift"));
        assert!(files[1].patch.is_none());
        assert_eq!(files[2].status, "added");
        assert!(files[2].patch.is_none());

        stub.remove("/merge_requests/7/diffs");
        stub.route("/merge_requests/7/changes", 200, r#"{"changes":[{"old_path":"x","new_path":"x","diff":"@@ -0,0 +1 @@\n+x\n","new_file":true,"renamed_file":false,"deleted_file":true}]}"#);
        let legacy = crate::rt::block_on(b.files(&r())).unwrap();
        assert_eq!(legacy.iter().map(|f| f.status.as_str()).collect::<Vec<_>>(), ["added"]);
    }

    #[test]
    fn submit_review_posts_positioned_threads_then_approves() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        let file = DiffFile::new(&PrFile { filename: "a.swift".into(), status: "renamed".into(), additions: 1, deletions: 1, patch: Some("@@ -10,3 +12,3 @@\n keep\n-old\n+new\n".into()), previous_filename: Some("z.swift".into()) });
        let comment = |line: i64, side: &str, body: &str| PendingComment { id: body.into(), path: "a.swift".into(), line, side: side.into(), body: body.into() };
        stub.clear_requests();
        crate::rt::block_on(b.submit_review(&r(), &pr, "APPROVE", " Summary ", &[comment(12, "RIGHT", "On context"), comment(11, "LEFT", "On removed")], &[file])).unwrap();

        let threads: Vec<Value> = stub.requests("POST", "/merge_requests/7/discussions").iter().map(|x| x.json()).collect();
        assert_eq!(threads.len(), 2);
        let first = &threads[0]["position"];
        assert_eq!(threads[0]["body"], "On context");
        assert_eq!(first["position_type"], "text");
        assert_eq!(first["base_sha"], "base1");
        assert_eq!(first["start_sha"], "start1");
        assert_eq!(first["head_sha"], "head2");
        assert_eq!(first["new_path"], "a.swift");
        assert_eq!(first["old_path"], "z.swift");
        assert_eq!(first["new_line"], 12);
        assert_eq!(first["old_line"], 10);
        let second = &threads[1]["position"];
        assert_eq!(second["old_line"], 11);
        assert!(second.get("new_line").is_none());

        assert_eq!(stub.requests("POST", "/merge_requests/7/notes")[0].json()["body"], "Summary");
        assert_eq!(stub.requests("POST", "/merge_requests/7/approve")[0].json()["sha"], "head2");
        assert_eq!(stub.all().iter().map(|x| x.last_segment()).collect::<Vec<_>>(), ["discussions", "discussions", "notes", "approve"]);
    }

    #[test]
    fn thread_actions_merge_and_state_changes() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        stub.clear_requests();
        let run = |f: std::pin::Pin<Box<dyn std::future::Future<Output = ApiResult<()>> + '_>>| crate::rt::block_on(f).unwrap();

        run(Box::pin(b.reply(&r(), "d4", "Fixed")));
        assert_eq!(stub.requests("POST", "/merge_requests/7/discussions/d4/notes")[0].json()["body"], "Fixed");
        run(Box::pin(b.set_resolved(&r(), "d4", true)));
        assert_eq!(stub.requests("PUT", "/merge_requests/7/discussions/d4")[0].json()["resolved"], true);
        run(Box::pin(b.comment(&r(), "Hello")));
        assert_eq!(stub.requests("POST", "/merge_requests/7/notes")[0].json()["body"], "Hello");
        run(Box::pin(b.revoke_approval(&r())));
        assert_eq!(stub.requests("POST", "/merge_requests/7/unapprove").len(), 1);

        run(Box::pin(b.merge(&r(), &pr, "SQUASH", Some("Add login".into()), Some("Details".into()), true)));
        let merge = stub.requests("PUT", "/merge_requests/7/merge")[0].json();
        assert_eq!(merge["squash"], true);
        assert_eq!(merge["should_remove_source_branch"], true);
        assert_eq!(merge["sha"], "head2");
        assert_eq!(merge["squash_commit_message"], "Add login\n\nDetails");
        assert!(merge.get("merge_commit_message").is_none());
        assert!(merge.get("auto_merge").is_none());

        run(Box::pin(b.enable_auto_merge(&r(), &pr, "MERGE")));
        let auto = stub.requests("PUT", "/merge_requests/7/merge").last().unwrap().json();
        assert_eq!(auto["auto_merge"], true);
        assert_eq!(auto["merge_when_pipeline_succeeds"], true);
        assert_eq!(auto["squash"], false);

        run(Box::pin(b.cancel_auto_merge(&r())));
        assert_eq!(stub.requests("POST", "/merge_requests/7/cancel_merge_when_pipeline_succeeds").len(), 1);
        run(Box::pin(b.rebase(&r())));
        assert_eq!(stub.requests("PUT", "/merge_requests/7/rebase").len(), 1);
        run(Box::pin(b.close(&r(), false)));
        assert_eq!(stub.requests("PUT", "/merge_requests/7").last().unwrap().json()["state_event"], "close");
        run(Box::pin(b.set_draft(&r(), &pr, true)));
        assert_eq!(stub.requests("PUT", "/merge_requests/7").last().unwrap().json()["title"], "Draft: Add login");
        assert_eq!(undrafted("Draft: Add login"), "Add login");
        assert_eq!(undrafted("[WIP] Add login"), "Add login");
    }

    #[test]
    fn merge_errors_are_readable() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        stub.route("/merge_requests/7/merge", 405, r#"{"message":"405 Method Not Allowed"}"#);
        stub.route("/merge_requests/7/discussions/d4", 400, r#"{"message":{"base":["Discussion is not resolvable"]}}"#);
        let e = crate::rt::block_on(b.merge(&r(), &pr, "MERGE", None, None, false)).unwrap_err();
        assert_eq!(e.message, "GitLab 405: 405 Method Not Allowed");
        let e = crate::rt::block_on(b.set_resolved(&r(), "d4", true)).unwrap_err();
        assert_eq!(e.message, "GitLab 400: Discussion is not resolvable");
        stub.route("/merge_requests/7/notes", 400, r#"{"message":{"note":["can't be blank","is too short"]}}"#);
        assert_eq!(crate::rt::block_on(b.comment(&r(), "x")).unwrap_err().message, "GitLab 400: note can't be blank, is too short");
    }

    #[test]
    fn job_log_uses_pipeline_project() {
        let (stub, b) = setup();
        stub.route("/projects/42/jobs/3/trace", 200, "section_start:1:build\r\u{1b}[0Kok\r\nsection_end:2:build\r\u{1b}[0K");
        crate::rt::block_on(b.load(&r())).unwrap();
        let check: CheckContext = serde_json::from_value(json!({ "__typename": "GitLabJob", "databaseId": 3, "status": "COMPLETED", "conclusion": "FAILURE" })).unwrap();
        assert_eq!(crate::rt::block_on(b.job_log(&r(), &check)).unwrap(), "ok\n");
        assert_eq!(stub.requests("GET", "/jobs/3/trace").len(), 1);
    }

    #[test]
    fn commit_detail() {
        let stub = Arc::new(Stub::default());
        stub.route("/repository/commits/abc", 200, r#"{"id":"abc","short_id":"abc","title":"Fix","message":"Fix\n\nBody","author_name":"Max","authored_date":"2026-10-01T08:00:00Z","web_url":"https://gitlab.example.com/g/p/-/commit/abc","stats":{"additions":1,"deletions":0}}"#);
        stub.route("/repository/commits/abc/diff", 200, r#"[{"old_path":"a","new_path":"a","diff":"@@ -0,0 +1 @@\n+x\n","new_file":true,"renamed_file":false,"deleted_file":false}]"#);
        let b = GitLabReview::new(ForgeClient::stubbed(GitProvider::Gitlab, "gitlab.example.com", "sofia", stub));
        let c = crate::rt::block_on(b.commit("g/p", "abc")).unwrap();
        assert_eq!(c.commit.message, "Fix\n\nBody");
        assert_eq!(c.commit.author.as_ref().and_then(|a| a.name.as_deref()), Some("Max"));
        assert_eq!(c.stats.as_ref().map(|s| s.additions), Some(1));
        assert_eq!(c.files.as_ref().unwrap()[0].status, "added");
        assert_eq!(c.html_url, "https://gitlab.example.com/g/p/-/commit/abc");
    }

    #[test]
    fn merge_status_mapping() {
        let status = |detailed: Option<&str>, legacy: Option<&str>, pipeline: bool| {
            let mut v = json!({ "id": 1, "iid": 1, "title": "t", "state": "opened", "web_url": "https://g/x/-/merge_requests/1",
                "created_at": "2026-10-01T10:00:00Z", "updated_at": "2026-10-01T10:00:00Z", "source_branch": "a", "target_branch": "b" });
            if let Some(d) = detailed {
                v["detailed_merge_status"] = json!(d);
            }
            if let Some(l) = legacy {
                v["merge_status"] = json!(l);
            }
            if pipeline {
                v["head_pipeline"] = json!({ "id": 1, "status": "running" });
            }
            let mr: Detail = serde_json::from_value(v).unwrap();
            let s = merge_state(&mr);
            (s.mergeable, s.status, s.blocker)
        };
        assert_eq!(status(Some("mergeable"), None, true).1, "CLEAN");
        assert_eq!(status(Some("conflict"), None, true).0, "CONFLICTING");
        assert_eq!(status(Some("need_rebase"), None, true).1, "BEHIND");
        assert_eq!(status(Some("checking"), None, true).1, "UNKNOWN");
        assert_eq!(status(Some("ci_still_running"), None, true).2.as_deref(), Some("Pipeline is still running"));
        assert_eq!(status(Some("ci_must_pass"), None, false).2.as_deref(), Some("A pipeline must run and succeed"));
        assert_eq!(status(Some("not_approved"), None, true).2, None);
        assert_eq!(status(Some("some_new_check"), None, true).2.as_deref(), Some("Some New Check"));
        assert_eq!(status(None, Some("can_be_merged"), true).1, "CLEAN");
        assert_eq!(status(None, Some("cannot_be_merged"), true).1, "DIRTY");
    }

    #[test]
    fn parses_merge_request_urls() {
        let r = parse_url("https://gitlab.example.com/group/sub/app/-/merge_requests/12#note_5").unwrap();
        assert_eq!(r.repo.full(), "group/sub/app");
        assert_eq!(r.number, 12);
        assert!(parse_url("https://gitlab.example.com/group/app/-/issues/3").is_none());
    }
}
