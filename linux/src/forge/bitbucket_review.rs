use std::collections::{HashMap, HashSet};

use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

use super::bitbucket::segment;
use super::{ForgeClient, Query};
use crate::api::models::{CommitDetailRest, CommitInner, CommitPerson, CommitStats, Date, ItemRef, PendingComment, PrDetailResponse, PrFile, PrLight, PullRequestDetail};
use crate::api::{ApiError, ApiResult};
use crate::markdown_html;

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Link {
    #[serde(default)]
    pub href: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Links {
    #[serde(default)]
    pub html: Option<Link>,
    #[serde(default)]
    pub avatar: Option<Link>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct User {
    #[serde(default)]
    pub uuid: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub nickname: Option<String>,
    #[serde(default)]
    pub links: Option<Links>,
}

impl User {
    pub fn login(&self) -> String {
        self.nickname.clone().or_else(|| self.display_name.clone()).or_else(|| self.uuid.clone()).unwrap_or_else(|| "unknown".into())
    }

    pub fn avatar(&self) -> Option<String> {
        self.links.as_ref().and_then(|l| l.avatar.as_ref()).and_then(|a| a.href.clone())
    }

    fn actor(&self) -> Value {
        json!({ "login": self.login(), "avatarUrl": self.avatar() })
    }
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Rendered {
    #[serde(default)]
    pub raw: Option<String>,
    #[serde(default)]
    pub html: Option<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Branch {
    pub name: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct CommitRef {
    pub hash: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct RepoName {
    #[serde(default)]
    pub full_name: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Endpoint {
    #[serde(default)]
    pub branch: Option<Branch>,
    #[serde(default)]
    pub commit: Option<CommitRef>,
    #[serde(default)]
    pub repository: Option<RepoName>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Participant {
    #[serde(default)]
    pub user: Option<User>,
    #[serde(default)]
    pub approved: Option<bool>,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub participated_on: Option<Date>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Detail {
    pub id: i64,
    pub title: String,
    pub state: String,
    #[serde(default)]
    pub draft: Option<bool>,
    #[serde(default)]
    pub summary: Option<Rendered>,
    pub created_on: Date,
    pub updated_on: Date,
    #[serde(default)]
    pub author: Option<User>,
    #[serde(default)]
    pub source: Option<Endpoint>,
    #[serde(default)]
    pub destination: Option<Endpoint>,
    #[serde(default)]
    pub close_source_branch: Option<bool>,
    #[serde(default)]
    pub links: Option<Links>,
    #[serde(default)]
    pub comment_count: Option<i64>,
    #[serde(default)]
    pub task_count: Option<i64>,
    #[serde(default)]
    pub participants: Option<Vec<Participant>>,
    #[serde(default)]
    pub reviewers: Option<Vec<User>>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Inline {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub from: Option<i64>,
    #[serde(default)]
    pub to: Option<i64>,
    #[serde(default)]
    pub outdated: Option<bool>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Parent {
    pub id: i64,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Comment {
    pub id: i64,
    #[serde(default)]
    pub content: Option<Rendered>,
    #[serde(default)]
    pub user: Option<User>,
    pub created_on: Date,
    #[serde(default)]
    pub inline: Option<Inline>,
    #[serde(default)]
    pub parent: Option<Parent>,
    #[serde(default)]
    pub deleted: Option<bool>,
    #[serde(default)]
    pub pending: Option<bool>,
    #[serde(default)]
    pub resolution: Option<Value>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct CommitAuthor {
    #[serde(default)]
    pub raw: Option<String>,
    #[serde(default)]
    pub user: Option<User>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct CommitInfo {
    pub hash: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub date: Option<Date>,
    #[serde(default)]
    pub author: Option<CommitAuthor>,
    #[serde(default)]
    pub links: Option<Links>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Status {
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    pub state: String,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub created_on: Option<Date>,
    #[serde(default)]
    pub updated_on: Option<Date>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct DiffPath {
    pub path: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct DiffStat {
    pub status: String,
    #[serde(default)]
    pub lines_added: Option<i64>,
    #[serde(default)]
    pub lines_removed: Option<i64>,
    #[serde(default)]
    pub old: Option<DiffPath>,
    #[serde(default)]
    pub new: Option<DiffPath>,
}

impl DiffStat {
    pub fn path(&self) -> String {
        self.new.as_ref().or(self.old.as_ref()).map(|p| p.path.clone()).unwrap_or_default()
    }
}

#[derive(Deserialize)]
struct Page<T> {
    #[serde(default = "Vec::new")]
    values: Vec<T>,
    #[serde(default)]
    next: Option<String>,
}

pub const CONFLICT_STATUSES: [&str; 7] = ["merge conflict", "local deleted", "remote deleted", "local and remote deleted", "rename conflict", "rename/delete conflict", "subrepo conflict"];

pub fn repo_path(repo: &str) -> String {
    format!("/repositories/{}", repo.split('/').map(segment).collect::<Vec<_>>().join("/"))
}

pub fn pull_path(repo: &str, id: i64) -> String {
    format!("{}/pullrequests/{id}", repo_path(repo))
}

async fn pages<T: DeserializeOwned>(c: &ForgeClient, path: &str, limit: usize) -> ApiResult<Vec<T>> {
    let query: Query = vec![("pagelen", "100".into())];
    let mut page: Page<T> = c.http().get(path, &query).await?;
    let mut all = std::mem::take(&mut page.values);
    let mut next = page.next;
    let mut count = 1;
    while let Some(url) = next.filter(|_| count < limit) {
        let mut page: Page<T> = c.http().get(&url, &[]).await?;
        all.append(&mut page.values);
        next = page.next;
        count += 1;
    }
    Ok(all)
}

pub async fn pull_request(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<Detail> {
    c.http().get(&pull_path(repo, id), &[]).await
}

pub async fn comments(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<Vec<Comment>> {
    pages(c, &format!("{}/comments", pull_path(repo, id)), 20).await
}

pub async fn commits(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<Vec<CommitInfo>> {
    pages(c, &format!("{}/commits", pull_path(repo, id)), 3).await
}

pub async fn statuses(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<Vec<Status>> {
    pages(c, &format!("{}/statuses", pull_path(repo, id)), 3).await
}

pub async fn diffstat(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<Vec<DiffStat>> {
    pages(c, &format!("{}/diffstat", pull_path(repo, id)), 30).await
}

pub async fn diff(c: &ForgeClient, repo: &str, id: i64) -> ApiResult<String> {
    c.http().text(&format!("{}/diff", pull_path(repo, id)), &[]).await
}

async fn add_comment(c: &ForgeClient, repo: &str, id: i64, body: &str, inline: Option<Value>, parent: Option<i64>) -> ApiResult<()> {
    let mut payload = json!({ "content": { "raw": body } });
    if let Some(inline) = inline {
        payload["inline"] = inline;
    }
    if let Some(parent) = parent {
        payload["parent"] = json!({ "id": parent });
    }
    c.http().send_json(Method::POST, &format!("{}/comments", pull_path(repo, id)), payload).await
}

fn toggle(on: bool) -> Method {
    if on {
        Method::POST
    } else {
        Method::DELETE
    }
}

async fn update(c: &ForgeClient, repo: &str, id: i64, fields: Value) -> ApiResult<()> {
    c.http().send_json(Method::PUT, &pull_path(repo, id), fields).await
}

pub async fn commit(c: &ForgeClient, repo: &str, sha: &str) -> ApiResult<CommitDetailRest> {
    let base = repo_path(repo);
    let detail_path = format!("{base}/commit/{sha}");
    let stat_path = format!("{base}/diffstat/{sha}");
    let diff_path = format!("{base}/diff/{sha}");
    let (detail, stats, text) = tokio::join!(c.http().get::<CommitInfo>(&detail_path, &[]), pages::<DiffStat>(c, &stat_path, 10), c.http().text(&diff_path, &[]));
    let detail = detail?;
    let files = files(&stats?, &text.unwrap_or_default());
    Ok(CommitDetailRest {
        html_url: detail.links.as_ref().and_then(|l| l.html.as_ref()).and_then(|h| h.href.clone()).unwrap_or_else(|| format!("https://bitbucket.org/{repo}/commits/{}", detail.hash)),
        commit: CommitInner { message: detail.message.clone().unwrap_or_default(), author: Some(CommitPerson { name: author_name(detail.author.as_ref()), date: detail.date }) },
        sha: detail.hash,
        author: None,
        stats: Some(CommitStats { additions: files.iter().map(|f| f.additions).sum(), deletions: files.iter().map(|f| f.deletions).sum() }),
        files: Some(files),
    })
}

pub struct Snapshot {
    pub repo: String,
    pub pr: Detail,
    pub comments: Vec<Comment>,
    pub commits: Vec<CommitInfo>,
    pub statuses: Vec<Status>,
    pub diffstat: Vec<DiffStat>,
    pub viewer: String,
}

pub fn state(raw: &str) -> &'static str {
    match raw {
        "MERGED" => "MERGED",
        "OPEN" => "OPEN",
        _ => "CLOSED",
    }
}

pub fn author_name(a: Option<&CommitAuthor>) -> Option<String> {
    let a = a?;
    if let Some(name) = a.user.as_ref().and_then(|u| u.display_name.clone()) {
        return Some(name);
    }
    let raw = a.raw.as_ref()?;
    Some(raw.split(" <").next().unwrap_or(raw).to_string())
}

pub fn pulse(pr: &Detail) -> String {
    let mut people: Vec<String> = pr
        .participants
        .as_deref()
        .unwrap_or_default()
        .iter()
        .map(|p| {
            let who = p.user.as_ref().and_then(|u| u.uuid.clone()).unwrap_or_default();
            let state = p.state.clone().unwrap_or_else(|| if p.approved == Some(true) { "approved".into() } else { String::new() });
            format!("{who}:{state}")
        })
        .collect();
    people.sort();
    [
        pr.updated_on.timestamp_millis().to_string(),
        pr.state.clone(),
        pr.draft.unwrap_or(false).to_string(),
        head_hash(pr),
        pr.comment_count.unwrap_or(0).to_string(),
        pr.task_count.unwrap_or(0).to_string(),
        people.join(","),
    ]
    .join("|")
}

fn head_hash(pr: &Detail) -> String {
    pr.source.as_ref().and_then(|s| s.commit.as_ref()).map(|c| c.hash.clone()).unwrap_or_default()
}

fn light_json(pr: &Detail) -> Value {
    json!({
        "lightUpdatedAt": pr.updated_on,
        "lightHeadOid": head_hash(pr),
        "lightState": state(&pr.state),
        "lightDraft": pr.draft.unwrap_or(false),
        "lightFingerprint": pulse(pr),
    })
}

pub fn light(pr: &Detail) -> PrLight {
    serde_json::from_value(light_json(pr)).unwrap_or_default()
}

pub fn checks(statuses: &[Status]) -> Vec<Value> {
    statuses
        .iter()
        .enumerate()
        .map(|(index, s)| {
            let (status, conclusion) = match s.state.as_str() {
                "INPROGRESS" => ("IN_PROGRESS", None),
                "SUCCESSFUL" => ("COMPLETED", Some("SUCCESS")),
                "FAILED" => ("COMPLETED", Some("FAILURE")),
                "STOPPED" => ("COMPLETED", Some("CANCELLED")),
                _ => ("QUEUED", None),
            };
            json!({
                "__typename": "BitbucketStatus",
                "databaseId": index + 1,
                "name": s.name.clone().or_else(|| s.key.clone()).unwrap_or_else(|| "Build".into()),
                "status": status,
                "conclusion": conclusion,
                "detailsUrl": s.url,
                "startedAt": s.created_on,
                "completedAt": if conclusion.is_some() { s.updated_on } else { None },
                "description": s.description,
            })
        })
        .collect()
}

pub fn rollup_state(statuses: &[Status]) -> Option<&'static str> {
    if statuses.is_empty() {
        return None;
    }
    let any = |st: &str| statuses.iter().any(|s| s.state == st);
    Some(if any("FAILED") {
        "FAILURE"
    } else if any("INPROGRESS") {
        "PENDING"
    } else if any("STOPPED") {
        "ERROR"
    } else {
        "SUCCESS"
    })
}

fn comment_html(c: &Comment, base: &str) -> String {
    match c.content.as_ref().and_then(|r| r.html.as_deref()).filter(|h| !h.is_empty()) {
        Some(h) => markdown_html::absolutize_html(h, base),
        None => markdown_html::render(c.content.as_ref().and_then(|r| r.raw.as_deref()).unwrap_or(""), Some(base)),
    }
}

fn raw(c: &Comment) -> String {
    c.content.as_ref().and_then(|r| r.raw.clone()).unwrap_or_default()
}

fn timeline(kind: &str, id: String, author: Option<Value>, body: Option<String>, html: Option<String>, date: Date, state: Option<&str>) -> Value {
    json!({ "__typename": kind, "id": id, "author": author, "body": body, "bodyHTML": html, "createdAt": date, "state": state })
}

pub fn conversation(comments: &[Comment], base: &str, head_paths: &HashSet<String>) -> (Vec<Value>, Vec<Value>) {
    let visible: Vec<&Comment> = comments.iter().filter(|c| c.deleted != Some(true) && c.pending != Some(true)).collect();
    let ids: HashSet<i64> = visible.iter().map(|c| c.id).collect();
    let mut children: HashMap<i64, Vec<&Comment>> = HashMap::new();
    let mut roots: Vec<&Comment> = vec![];
    for c in &visible {
        match c.parent.as_ref().map(|p| p.id).filter(|p| ids.contains(p)) {
            Some(parent) => children.entry(parent).or_default().push(c),
            None => roots.push(c),
        }
    }
    fn descendants<'a>(id: i64, children: &HashMap<i64, Vec<&'a Comment>>, out: &mut Vec<&'a Comment>) {
        let mut direct = children.get(&id).cloned().unwrap_or_default();
        direct.sort_by_key(|c| c.created_on);
        for c in direct {
            out.push(c);
            descendants(c.id, children, out);
        }
    }
    roots.sort_by_key(|c| c.created_on);
    let mut items = vec![];
    let mut threads = vec![];
    for root in roots {
        let mut replies = vec![];
        descendants(root.id, &children, &mut replies);
        if root.inline.is_none() && replies.is_empty() {
            items.push(timeline("IssueComment", format!("bb-c-{}", root.id), root.user.as_ref().map(User::actor), Some(raw(root)), Some(comment_html(root, base)), root.created_on, None));
            continue;
        }
        let review = format!("bb-t-{}", root.id);
        let inline = root.inline.as_ref();
        let line = inline.and_then(|i| i.to.or(i.from));
        let moved = inline.and_then(|i| i.path.as_ref()).is_some_and(|p| !head_paths.is_empty() && !head_paths.contains(p));
        let outdated = inline.and_then(|i| i.outdated) == Some(true) || moved;
        let resolved = root.resolution.is_some();
        let left = inline.is_some_and(|i| i.to.is_none() && i.from.is_some());
        let comments: Vec<Value> = std::iter::once(root)
            .chain(replies)
            .map(|c| {
                json!({
                    "id": c.id.to_string(),
                    "author": c.user.as_ref().map(User::actor),
                    "body": raw(c),
                    "bodyHTML": comment_html(c, base),
                    "createdAt": c.created_on,
                    "pullRequestReview": { "id": review },
                })
            })
            .collect();
        threads.push(json!({
            "id": root.id.to_string(),
            "isResolved": resolved,
            "isOutdated": outdated,
            "path": inline.and_then(|i| i.path.clone()).unwrap_or_default(),
            "line": if outdated { None } else { line },
            "originalLine": line,
            "diffSide": if left { "LEFT" } else { "RIGHT" },
            "viewerCanResolve": !resolved,
            "viewerCanUnresolve": resolved,
            "viewerCanReply": true,
            "comments": { "nodes": comments },
        }));
        items.push(timeline("PullRequestReview", review, root.user.as_ref().map(User::actor), None, None, root.created_on, Some("DISCUSSION")));
    }
    (items, threads)
}

pub fn review_decision(pr: &Detail) -> Option<&'static str> {
    let people = pr.participants.as_deref().unwrap_or_default();
    if people.iter().any(|p| p.state.as_deref() == Some("changes_requested")) {
        return Some("CHANGES_REQUESTED");
    }
    if people.iter().any(|p| p.approved == Some(true)) {
        return Some("APPROVED");
    }
    None
}

fn tasks(n: i64) -> String {
    if n == 1 {
        "1 open task".to_string()
    } else {
        format!("{n} open tasks")
    }
}

pub fn detail_json(s: &Snapshot) -> Value {
    let pr = &s.pr;
    let repo_name = pr.destination.as_ref().and_then(|d| d.repository.as_ref()).and_then(|r| r.full_name.clone()).unwrap_or_else(|| s.repo.clone());
    let base = format!("https://bitbucket.org/{repo_name}");
    let st = state(&pr.state);
    let draft = pr.draft.unwrap_or(false);
    let conflicted = s.diffstat.iter().any(|d| CONFLICT_STATUSES.contains(&d.status.as_str()));
    let failed = s.statuses.iter().any(|x| x.state == "FAILED");
    let participants = pr.participants.as_deref().unwrap_or_default();
    let changes_requested = participants.iter().any(|p| p.state.as_deref() == Some("changes_requested"));
    let open_tasks = pr.task_count.unwrap_or(0);
    let merge_state = if draft {
        "DRAFT"
    } else if conflicted {
        "DIRTY"
    } else if failed || changes_requested || open_tasks > 0 {
        "UNSTABLE"
    } else {
        "CLEAN"
    };
    let head = head_hash(pr);
    let paths: HashSet<String> = s.diffstat.iter().map(DiffStat::path).collect();
    let (items, threads) = conversation(&s.comments, &base, &paths);
    let commits: Vec<Value> = s
        .commits
        .iter()
        .rev()
        .map(|c| {
            let message = c.message.clone().unwrap_or_default();
            json!({ "commit": {
                "oid": c.hash,
                "abbreviatedOid": c.hash.chars().take(7).collect::<String>(),
                "messageHeadline": message.lines().next().unwrap_or(""),
                "committedDate": c.date.unwrap_or(pr.created_on),
                "url": c.links.as_ref().and_then(|l| l.html.as_ref()).and_then(|h| h.href.clone()).unwrap_or_else(|| format!("{base}/commits/{}", c.hash)),
                "author": { "name": author_name(c.author.as_ref()), "avatarUrl": c.author.as_ref().and_then(|a| a.user.as_ref()).and_then(User::avatar) },
            } })
        })
        .collect();
    let last_date = s.commits.first().and_then(|c| c.date);
    let contexts = checks(&s.statuses);
    let rollup = rollup_state(&s.statuses).map(|st| json!({ "state": st, "contexts": { "nodes": contexts, "totalCount": contexts.len() } }));
    let me = s.viewer.to_lowercase();
    let same = |u: Option<&User>| !me.is_empty() && u.and_then(|u| u.uuid.as_deref()).is_some_and(|id| id.to_lowercase() == me);
    let mine = participants.iter().find(|p| same(p.user.as_ref()));
    let is_author = same(pr.author.as_ref());
    let reviews: Vec<(String, Value)> = participants
        .iter()
        .filter_map(|p| {
            let user = p.user.as_ref()?;
            let verdict = if p.approved == Some(true) || p.state.as_deref() == Some("approved") {
                "APPROVED"
            } else if p.state.as_deref() == Some("changes_requested") {
                "CHANGES_REQUESTED"
            } else {
                return None;
            };
            Some((user.login(), json!({ "state": verdict, "submittedAt": p.participated_on, "author": user.actor() })))
        })
        .collect();
    let decided: HashSet<&str> = reviews.iter().map(|(login, _)| login.as_str()).collect();
    let pending: Vec<Value> = pr
        .reviewers
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|u| !decided.contains(u.login().as_str()))
        .map(|u| json!({ "requestedReviewer": { "__typename": "User", "login": u.login(), "avatarUrl": u.avatar(), "name": u.display_name } }))
        .collect();
    let additions: i64 = s.diffstat.iter().map(|d| d.lines_added.unwrap_or(0)).sum();
    let deletions: i64 = s.diffstat.iter().map(|d| d.lines_removed.unwrap_or(0)).sum();
    let blocker = if conflicted {
        None
    } else if changes_requested {
        Some("Changes requested".to_string())
    } else if failed {
        Some("A build failed".to_string())
    } else if open_tasks > 0 {
        Some(tasks(open_tasks))
    } else {
        None
    };
    let summary = pr.summary.as_ref();
    let body = summary.and_then(|r| r.raw.clone()).unwrap_or_default();
    let body_html = match summary.and_then(|r| r.html.as_deref()).filter(|h| !h.is_empty()) {
        Some(h) => markdown_html::absolutize_html(h, &base),
        None => markdown_html::render(&body, Some(&base)),
    };
    let source = pr.source.as_ref();
    let mut v = json!({
        "id": format!("bitbucket-pr-{repo_name}-{}", pr.id),
        "number": pr.id,
        "title": pr.title,
        "url": pr.links.as_ref().and_then(|l| l.html.as_ref()).and_then(|h| h.href.clone()).unwrap_or_else(|| format!("{base}/pull-requests/{}", pr.id)),
        "state": st,
        "isDraft": draft,
        "merged": st == "MERGED",
        "mergeable": if conflicted { "CONFLICTING" } else { "MERGEABLE" },
        "mergeStateStatus": merge_state,
        "body": body,
        "bodyHTML": body_html,
        "createdAt": pr.created_on,
        "author": pr.author.as_ref().map(User::actor),
        "headRefName": source.and_then(|e| e.branch.as_ref()).map(|b| b.name.clone()).unwrap_or_default(),
        "baseRefName": pr.destination.as_ref().and_then(|e| e.branch.as_ref()).map(|b| b.name.clone()).unwrap_or_default(),
        "headRefOid": head,
        "baseRef": pr.destination.as_ref().and_then(|e| e.commit.as_ref()).map(|c| json!({ "target": { "oid": c.hash } })),
        "headRepository": source.and_then(|e| e.repository.as_ref()).and_then(|r| r.full_name.clone()).map(|n| json!({ "nameWithOwner": n })),
        "headRef": if st == "OPEN" { source.and_then(|e| e.branch.as_ref()).map(|b| json!({ "name": b.name })) } else { None },
        "additions": additions,
        "deletions": deletions,
        "changedFiles": s.diffstat.len(),
        "reviewDecision": review_decision(pr),
        "viewerCanUpdate": true,
        "viewerDidAuthor": is_author,
        "autoMergeRequest": null,
        "labels": { "nodes": [] },
        "assignees": { "nodes": [] },
        "reviewRequests": { "nodes": pending },
        "latestOpinionatedReviews": { "nodes": reviews.into_iter().map(|(_, r)| r).collect::<Vec<_>>() },
        "lastCommit": { "nodes": [{ "commit": { "oid": head_hash(pr), "committedDate": last_date, "statusCheckRollup": rollup } }] },
        "allCommits": { "nodes": commits, "totalCount": commits.len() },
        "timelineItems": { "nodes": items },
        "reviewThreads": { "nodes": threads },
        "viewerCanApprove": !is_author,
        "viewerApproved": mine.and_then(|p| p.approved) == Some(true),
        "mergeBlocker": blocker,
        "forgeMerge": {
            "status": if draft { "draft" } else if conflicted { "conflict" } else { "open" },
            "openTasks": open_tasks,
            "provider": "bitbucket",
        },
    });
    if let (Some(obj), Value::Object(light)) = (v.as_object_mut(), light_json(pr)) {
        obj.extend(light);
    }
    v
}

pub fn repository_json(s: &Snapshot) -> Value {
    json!({
        "viewerPermission": "WRITE",
        "mergeCommitAllowed": true,
        "squashMergeAllowed": true,
        "rebaseMergeAllowed": false,
        "deleteBranchOnMerge": s.pr.close_source_branch.unwrap_or(false),
        "autoMergeAllowed": false,
        "viewerDefaultMergeMethod": "MERGE",
        "pullRequest": detail_json(s),
    })
}

pub fn response(s: &Snapshot) -> ApiResult<PrDetailResponse> {
    serde_json::from_value(json!({ "viewer": { "login": s.viewer }, "repository": repository_json(s) })).map_err(|e| ApiError::new(format!("Failed to read the pull request: {e}")))
}

pub fn files(stats: &[DiffStat], diff: &str) -> Vec<PrFile> {
    let patches = split_diff(diff);
    stats
        .iter()
        .map(|s| {
            let path = s.path();
            let status = match s.status.as_str() {
                "added" => "added",
                "removed" => "removed",
                "renamed" => "renamed",
                _ => "modified",
            };
            let patch = patches.get(&path).or_else(|| s.old.as_ref().and_then(|o| patches.get(&o.path))).cloned();
            PrFile {
                filename: path,
                status: status.into(),
                additions: s.lines_added.unwrap_or(0),
                deletions: s.lines_removed.unwrap_or(0),
                patch,
                previous_filename: if s.status == "renamed" { s.old.as_ref().map(|o| o.path.clone()) } else { None },
            }
        })
        .collect()
}

pub fn split_diff(diff: &str) -> HashMap<String, String> {
    let mut out: HashMap<String, String> = HashMap::new();
    let mut path: Option<String> = None;
    let mut old_path: Option<String> = None;
    let mut hunk: Vec<&str> = vec![];
    let flush = |path: &Option<String>, old_path: &Option<String>, hunk: &mut Vec<&str>, out: &mut HashMap<String, String>| {
        if let Some(key) = path.as_ref().or(old_path.as_ref()) {
            if !hunk.is_empty() {
                out.insert(key.clone(), hunk.join("\n").trim_matches(['\n', '\r']).to_string());
            }
        }
        hunk.clear();
    };
    for line in diff.split('\n') {
        if line.starts_with("diff --git ") {
            flush(&path, &old_path, &mut hunk, &mut out);
            old_path = None;
            path = line.rfind(" b/").map(|i| line[i + 3..].to_string());
            continue;
        }
        if hunk.is_empty() {
            if let Some(p) = line.strip_prefix("+++ ") {
                if p != "/dev/null" {
                    path = Some(p.strip_prefix("b/").unwrap_or(p).to_string());
                }
                continue;
            }
            if let Some(p) = line.strip_prefix("--- ") {
                if p != "/dev/null" {
                    old_path = Some(p.strip_prefix("a/").unwrap_or(p).to_string());
                }
                continue;
            }
            if !line.starts_with("@@") {
                continue;
            }
        }
        hunk.push(line);
    }
    flush(&path, &old_path, &mut hunk, &mut out);
    out
}

pub fn inline(comment: &PendingComment) -> Value {
    if comment.side == "LEFT" {
        json!({ "path": comment.path, "from": comment.line })
    } else {
        json!({ "path": comment.path, "to": comment.line })
    }
}

fn message(title: Option<String>, body: Option<String>, pr: &PullRequestDetail) -> Option<String> {
    if title.is_none() && body.is_none() {
        return None;
    }
    Some([Some(title.unwrap_or_else(|| pr.title.clone())), body].into_iter().flatten().collect::<Vec<_>>().join("\n\n"))
}

fn thread_id(thread: &str) -> ApiResult<i64> {
    thread.parse().map_err(|_| ApiError::new("Unknown comment thread"))
}

#[derive(Clone)]
pub struct BitbucketReview {
    client: ForgeClient,
}

impl BitbucketReview {
    pub fn new(client: ForgeClient) -> Self {
        BitbucketReview { client }
    }

    pub fn host(&self) -> String {
        "bitbucket.org".to_string()
    }

    pub async fn load(&self, r: &ItemRef) -> ApiResult<PrDetailResponse> {
        let c = &self.client;
        let repo = r.repo.full();
        let (pr, comments, commits, statuses, diffstat, viewer) =
            tokio::join!(pull_request(c, &repo, r.number), comments(c, &repo, r.number), commits(c, &repo, r.number), statuses(c, &repo, r.number), diffstat(c, &repo, r.number), c.user_id());
        let snapshot = Snapshot {
            repo,
            pr: pr?,
            comments: comments?,
            commits: commits.unwrap_or_default(),
            statuses: statuses.unwrap_or_default(),
            diffstat: diffstat.unwrap_or_default(),
            viewer: viewer.unwrap_or_default(),
        };
        response(&snapshot)
    }

    pub async fn pulse(&self, r: &ItemRef) -> ApiResult<Option<PrLight>> {
        Ok(Some(light(&pull_request(&self.client, &r.repo.full(), r.number).await?)))
    }

    pub async fn files(&self, r: &ItemRef) -> ApiResult<Vec<PrFile>> {
        let repo = r.repo.full();
        let (stats, text) = tokio::join!(diffstat(&self.client, &repo, r.number), diff(&self.client, &repo, r.number));
        Ok(files(&stats?, &text.unwrap_or_default()))
    }

    pub async fn comment(&self, r: &ItemRef, body: &str) -> ApiResult<()> {
        add_comment(&self.client, &r.repo.full(), r.number, body, None, None).await
    }

    pub async fn submit_review(&self, r: &ItemRef, event: &str, body: &str, comments: &[PendingComment]) -> ApiResult<()> {
        let repo = r.repo.full();
        for c in comments {
            add_comment(&self.client, &repo, r.number, &c.body, Some(inline(c)), None).await?;
        }
        let text = body.trim();
        if !text.is_empty() {
            add_comment(&self.client, &repo, r.number, text, None, None).await?;
        }
        match event {
            "APPROVE" => self.approve(r, true).await,
            "REQUEST_CHANGES" => self.request_changes(r, true).await,
            _ => Ok(()),
        }
    }

    pub async fn approve(&self, r: &ItemRef, on: bool) -> ApiResult<()> {
        self.client.http().post(toggle(on), &format!("{}/approve", pull_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn request_changes(&self, r: &ItemRef, on: bool) -> ApiResult<()> {
        self.client.http().post(toggle(on), &format!("{}/request-changes", pull_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn reply(&self, r: &ItemRef, thread: &str, body: &str) -> ApiResult<()> {
        add_comment(&self.client, &r.repo.full(), r.number, body, None, Some(thread_id(thread)?)).await
    }

    pub async fn set_resolved(&self, r: &ItemRef, thread: &str, resolved: bool) -> ApiResult<()> {
        let id = thread_id(thread)?;
        self.client.http().post(toggle(resolved), &format!("{}/comments/{id}/resolve", pull_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn merge(&self, r: &ItemRef, pr: &PullRequestDetail, method: &str, title: Option<String>, body: Option<String>, delete_branch: bool) -> ApiResult<()> {
        let mut payload = json!({
            "type": "pullrequest",
            "merge_strategy": if method == "SQUASH" { "squash" } else { "merge_commit" },
            "close_source_branch": delete_branch,
        });
        if let Some(m) = message(title, body, pr) {
            payload["message"] = json!(m);
        }
        self.client.http().send_json(Method::POST, &format!("{}/merge", pull_path(&r.repo.full(), r.number)), payload).await
    }

    pub async fn decline(&self, r: &ItemRef) -> ApiResult<()> {
        self.client.http().post(Method::POST, &format!("{}/decline", pull_path(&r.repo.full(), r.number)), &[]).await
    }

    pub async fn set_draft(&self, r: &ItemRef, draft: bool) -> ApiResult<()> {
        update(&self.client, &r.repo.full(), r.number, json!({ "draft": draft })).await
    }

    pub async fn edit(&self, r: &ItemRef, title: &str, body: &str) -> ApiResult<()> {
        update(&self.client, &r.repo.full(), r.number, json!({ "title": title, "description": body })).await
    }

    pub async fn commit(&self, repo: &str, sha: &str) -> ApiResult<CommitDetailRest> {
        commit(&self.client, repo, sha).await
    }
}

pub fn parse_url(url: &str) -> Option<ItemRef> {
    let u = url::Url::parse(url).ok()?;
    if !u.host_str()?.ends_with("bitbucket.org") {
        return None;
    }
    let path = u.path().trim_start_matches('/');
    let (repo, rest) = path.split_once("/pull-requests/")?;
    let number: i64 = rest.split(['/', '#', '?']).next()?.parse().ok()?;
    Some(ItemRef { repo: crate::api::models::RepoRef::from_full(repo)?, number })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::super::stub::Stub;
    use super::*;
    use crate::api::merge_readiness::{requirements, CapabilityState, RequirementKind, RequirementState, RulesStatus};
    use crate::api::models::{CheckOutcome, RepoRef};
    use crate::git_accounts::GitProvider;
    use crate::ui::pr::backend::{PrAction, PrBackend, PrFeatures};

    const DETAIL: &str = r#"{"id":5,"title":"Add billing","state":"OPEN","draft":false,
     "summary":{"raw":"Adds **billing**","html":"<p>Adds <strong>billing</strong> <a href=\"/acme/api/issues/2\">#2</a></p>"},
     "created_on":"2026-10-01T10:00:00.000000+00:00","updated_on":"2026-10-03T12:00:00.123456+00:00",
     "author":{"uuid":"{u-max}","display_name":"Max","nickname":"max","links":{"avatar":{"href":"https://a/max.png"}}},
     "source":{"branch":{"name":"feature/billing"},"commit":{"hash":"head2"},"repository":{"full_name":"acme/api"}},
     "destination":{"branch":{"name":"main"},"commit":{"hash":"base1"},"repository":{"full_name":"acme/api"}},
     "close_source_branch":true,"links":{"html":{"href":"https://bitbucket.org/acme/api/pull-requests/5"}},
     "comment_count":4,"task_count":1,
     "participants":[
       {"user":{"uuid":"{u-lea}","nickname":"lea"},"role":"REVIEWER","approved":true,"state":"approved","participated_on":"2026-10-02T10:00:00+00:00"},
       {"user":{"uuid":"{u-ivo}","nickname":"ivo"},"role":"REVIEWER","approved":false,"state":"changes_requested"},
       {"user":{"uuid":"{u-sofia}","nickname":"sofia"},"role":"REVIEWER","approved":false,"state":null}],
     "reviewers":[{"uuid":"{u-lea}","nickname":"lea"},{"uuid":"{u-ivo}","nickname":"ivo"},{"uuid":"{u-sofia}","nickname":"sofia"}]}"#;

    const COMMENTS: &str = r#"{"values":[
      {"id":10,"content":{"raw":"Looks good","html":"<p>Looks good</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T11:00:00+00:00"},
      {"id":20,"content":{"raw":"Rename this","html":"<p>Rename this</p>"},"user":{"nickname":"ivo"},"created_on":"2026-10-02T09:00:00+00:00","inline":{"path":"b.swift","from":null,"to":9}},
      {"id":21,"content":{"raw":"Done","html":"<p>Done</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T10:00:00+00:00","parent":{"id":20}},
      {"id":22,"content":{"raw":"Thanks","html":""},"user":{"nickname":"ivo"},"created_on":"2026-10-02T11:00:00+00:00","parent":{"id":21}},
      {"id":30,"content":{"raw":"Old","html":"<p>Old</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:00:00+00:00","inline":{"path":"a.swift","from":4,"to":null,"outdated":true},"resolution":{"type":"resolved"}},
      {"id":40,"content":{"raw":"Gone","html":""},"user":{"nickname":"lea"},"created_on":"2026-10-01T09:30:00+00:00","deleted":true},
      {"id":50,"content":{"raw":"Question?","html":"<p>Question?</p>"},"user":{"nickname":"lea"},"created_on":"2026-10-02T12:00:00+00:00"},
      {"id":51,"content":{"raw":"Answer","html":"<p>Answer</p>"},"user":{"nickname":"max"},"created_on":"2026-10-02T13:00:00+00:00","parent":{"id":50}}
    ],"next":null}"#;

    const DIFF: &str = "diff --git a/a.swift b/a.swift\nindex 1..2 100644\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n let b = 3\ndiff --git a/b.swift b/b.swift\nnew file mode 100644\n--- /dev/null\n+++ b/b.swift\n@@ -0,0 +1 @@\n+print(1)";

    fn r() -> ItemRef {
        ItemRef { repo: RepoRef::new("acme", "api"), number: 5 }
    }

    fn setup() -> (Arc<Stub>, PrBackend) {
        let stub = Arc::new(Stub::default());
        let routes: [(&str, u16, &str); 13] = [
            ("/pullrequests/5", 200, DETAIL),
            ("/pullrequests/5/comments", 200, COMMENTS),
            ("/pullrequests/5/commits", 200, r#"{"values":[{"hash":"head2abcdef","message":"Second\n\nbody","date":"2026-10-02T08:00:00+00:00","author":{"raw":"Max <max@x>"}},{"hash":"c1","message":"First","date":"2026-10-01T08:00:00+00:00","author":{"raw":"Max <max@x>","user":{"display_name":"Max M"}}}]}"#),
            ("/pullrequests/5/statuses", 200, r#"{"values":[{"key":"ci","name":"CI","state":"FAILED","url":"https://ci/1"},{"key":"lint","state":"SUCCESSFUL"},{"key":"e2e","name":"E2E","state":"INPROGRESS"}]}"#),
            ("/pullrequests/5/diffstat", 200, r#"{"values":[{"status":"modified","lines_added":1,"lines_removed":1,"old":{"path":"a.swift"},"new":{"path":"a.swift"}},{"status":"added","lines_added":1,"lines_removed":0,"old":null,"new":{"path":"b.swift"}}]}"#),
            ("/pullrequests/5/diff", 200, DIFF),
            ("/pullrequests/5/approve", 200, "{}"),
            ("/pullrequests/5/request-changes", 200, "{}"),
            ("/pullrequests/5/merge", 200, "{}"),
            ("/pullrequests/5/decline", 200, "{}"),
            ("/comments/20/resolve", 200, "{}"),
            ("/pullrequests/5/comments", 200, COMMENTS),
            ("/api/v4/user", 200, r#"{"uuid":"{u-sofia}","nickname":"sofia"}"#),
        ];
        for (k, s, b) in routes {
            stub.route(k, s, b);
        }
        let client = ForgeClient::stubbed(GitProvider::Bitbucket, "bitbucket.org", "sofia", stub.clone());
        (stub, PrBackend::Bitbucket(BitbucketReview::new(client)))
    }

    fn load(b: &PrBackend) -> (PrDetailResponse, PullRequestDetail) {
        let mut resp = crate::rt::block_on(b.load(&r())).unwrap();
        let pr = resp.repository.as_mut().and_then(|x| x.pull_request.take()).unwrap();
        (resp, pr)
    }

    #[test]
    fn load_maps_pull_request() {
        let (_, b) = setup();
        let (resp, pr) = load(&b);
        let repo = resp.repository.as_ref().unwrap();
        assert_eq!(resp.viewer.login, "{u-sofia}");
        assert_eq!(pr.state, "OPEN");
        assert_eq!(pr.mergeable, "MERGEABLE");
        assert_eq!(pr.merge_state_status.as_deref(), Some("UNSTABLE"));
        assert_eq!(pr.merge_blocker.as_deref(), Some("Changes requested"));
        assert_eq!(pr.review_decision.as_deref(), Some("CHANGES_REQUESTED"));
        assert_eq!(pr.head_ref_name, "feature/billing");
        assert_eq!(pr.head_ref_oid, "head2");
        assert_eq!((pr.additions, pr.deletions, pr.changed_files), (2, 1, 2));
        assert!(pr.body_html.contains(r#"href="https://bitbucket.org/acme/api/issues/2""#), "{}", pr.body_html);
        let reviews: HashSet<String> = pr.latest_opinionated_reviews.nodes.iter().map(|x| format!("{}:{}", x.author.as_ref().map(|a| a.login.as_str()).unwrap_or(""), x.state)).collect();
        assert_eq!(reviews, HashSet::from(["lea:APPROVED".to_string(), "ivo:CHANGES_REQUESTED".to_string()]));
        assert_eq!(pr.review_requests.nodes.iter().filter_map(|x| x.requested_reviewer.as_ref().map(|v| v.display())).collect::<Vec<_>>(), ["sofia"]);
        assert_eq!(pr.viewer_approved, Some(false));
        assert_eq!(pr.viewer_can_approve, Some(true));
        assert!(repo.delete_branch_on_merge);
        assert!(!repo.auto_merge_allowed);
        assert_eq!(pr.all_commits.nodes.iter().map(|c| c.commit.message_headline.as_str()).collect::<Vec<_>>(), ["First", "Second"]);
        assert_eq!(pr.all_commits.nodes[0].commit.author.as_ref().and_then(|a| a.name.as_deref()), Some("Max M"));
        assert_eq!(pr.all_commits.nodes[1].commit.abbreviated_oid, "head2ab");

        let checks = pr.checks();
        assert_eq!(checks.iter().map(|c| c.title()).collect::<Vec<_>>(), ["CI", "lint", "E2E"]);
        assert_eq!(checks.iter().map(|c| c.outcome()).collect::<Vec<_>>(), [CheckOutcome::Failure, CheckOutcome::Success, CheckOutcome::Pending]);
        assert_eq!(pr.rollup().map(|x| x.state.as_str()), Some("FAILURE"));

        let threads = &pr.review_threads.nodes;
        assert_eq!(threads.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["30", "20", "50"]);
        let inline = &threads[1];
        assert_eq!(inline.path, "b.swift");
        assert_eq!(inline.line, Some(9));
        assert_eq!(inline.diff_side, "RIGHT");
        assert!(!inline.is_resolved && inline.viewer_can_resolve);
        assert_eq!(inline.comments.nodes.iter().map(|c| c.body.as_str()).collect::<Vec<_>>(), ["Rename this", "Done", "Thanks"]);
        let old = &threads[0];
        assert!(old.is_resolved && old.is_outdated && old.viewer_can_unresolve);
        assert_eq!(old.line, None);
        assert_eq!(old.diff_side, "LEFT");
        let general = &threads[2];
        assert_eq!(general.path, "");
        assert_eq!(general.comments.nodes.len(), 2);
        let plain: Vec<&str> = pr.timeline_items.nodes.iter().filter(|i| i.typename == "IssueComment").filter_map(|i| i.id.as_deref()).collect();
        assert_eq!(plain, ["bb-c-10"]);
        assert!(!pr.timeline_items.nodes.iter().any(|i| i.id.as_deref() == Some("bb-c-40")));

        let same = crate::rt::block_on(b.pulse(&r())).unwrap().unwrap();
        assert!(pr.light.is_known());
        assert_eq!(pr.light.clone().normalized(), same.normalized());
    }

    #[test]
    fn requirements_are_advisory_except_conflicts() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        let reqs = requirements(&pr, &RulesStatus::Loading);
        let find = |list: &[crate::api::merge_readiness::MergeRequirement], k: RequirementKind| list.iter().find(|x| x.kind == k).cloned().unwrap();
        assert_eq!(find(&reqs, RequirementKind::Conflicts).state, RequirementState::Satisfied);
        assert_eq!(find(&reqs, RequirementKind::ChangesRequested).state, RequirementState::Advisory);
        assert_eq!(find(&reqs, RequirementKind::Approvals).title, "Approved");
        assert_eq!(find(&reqs, RequirementKind::Checks).title, "1 build failed");
        assert_eq!(find(&reqs, RequirementKind::Conversations).title, "1 open task");
        assert_eq!(reqs.last().map(|x| x.kind), Some(RequirementKind::OtherRules));
        assert!(!reqs.iter().any(|x| x.state == RequirementState::Missing));

        stub.route("/pullrequests/5", 200, &DETAIL.replace(r#""task_count":1"#, r#""task_count":0"#));
        stub.route("/pullrequests/5/diffstat", 200, r#"{"values":[{"status":"merge conflict","old":{"path":"a.swift"},"new":{"path":"a.swift"}}]}"#);
        let (_, bad) = load(&b);
        assert_eq!(bad.merge_state_status.as_deref(), Some("DIRTY"));
        assert_eq!(find(&requirements(&bad, &RulesStatus::Loading), RequirementKind::Conflicts).state, RequirementState::Missing);
    }

    #[test]
    fn files_split_unified_diff() {
        let (stub, b) = setup();
        let files = crate::rt::block_on(b.files(&r())).unwrap();
        assert_eq!(files.iter().map(|f| f.filename.as_str()).collect::<Vec<_>>(), ["a.swift", "b.swift"]);
        assert_eq!(files.iter().map(|f| f.status.as_str()).collect::<Vec<_>>(), ["modified", "added"]);
        assert_eq!(files[0].patch.as_deref(), Some("@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n let b = 3"));
        assert_eq!(files[1].patch.as_deref(), Some("@@ -0,0 +1 @@\n+print(1)"));
        assert!(split_diff("").is_empty());
        assert_eq!(stub.requests("GET", "/pullrequests/5/diff").len(), 1);
    }

    #[test]
    fn submit_review_posts_inline_comments_then_decision() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        let comment = |side: &str, body: &str| PendingComment { id: body.into(), path: "a.swift".into(), line: 1, side: side.into(), body: body.into() };
        stub.clear_requests();
        crate::rt::block_on(b.submit_review(&r(), &pr, "REQUEST_CHANGES", Some("Please fix".into()), &[comment("RIGHT", "nit"), comment("LEFT", "was this needed?")], &[])).unwrap();
        let posts: Vec<Value> = stub.requests("POST", "/pullrequests/5/comments").iter().map(|x| x.json()).collect();
        assert_eq!(posts.len(), 3);
        assert_eq!(posts[0]["inline"], json!({ "path": "a.swift", "to": 1 }));
        assert_eq!(posts[1]["inline"], json!({ "path": "a.swift", "from": 1 }));
        assert_eq!(posts[2]["content"]["raw"], "Please fix");
        assert_eq!(stub.requests("POST", "/request-changes").len(), 1);
        assert!(stub.requests("POST", "/approve").is_empty());

        crate::rt::block_on(b.submit_review(&r(), &pr, "APPROVE", None, &[], &[])).unwrap();
        assert_eq!(stub.requests("POST", "/approve").len(), 1);
        crate::rt::block_on(b.revoke_approval(&r())).unwrap();
        assert_eq!(stub.requests("DELETE", "/approve").len(), 1);
    }

    #[test]
    fn thread_actions_merge_and_state() {
        let (stub, b) = setup();
        let (_, pr) = load(&b);
        stub.clear_requests();
        crate::rt::block_on(b.reply(&r(), "20", "ok")).unwrap();
        assert_eq!(stub.requests("POST", "/pullrequests/5/comments")[0].json()["parent"]["id"], 20);
        crate::rt::block_on(b.set_resolved(&r(), "20", true)).unwrap();
        crate::rt::block_on(b.set_resolved(&r(), "20", false)).unwrap();
        assert_eq!(stub.requests("POST", "/comments/20/resolve").len(), 1);
        assert_eq!(stub.requests("DELETE", "/comments/20/resolve").len(), 1);

        crate::rt::block_on(b.merge(&r(), &pr, "SQUASH", Some("Billing".into()), None, true)).unwrap();
        let merge = stub.requests("POST", "/pullrequests/5/merge")[0].json();
        assert_eq!(merge["merge_strategy"], "squash");
        assert_eq!(merge["close_source_branch"], true);
        assert_eq!(merge["message"], "Billing");
        assert_eq!(merge["type"], "pullrequest");

        crate::rt::block_on(b.perform(PrAction::ConvertToDraft, &r(), &pr)).unwrap();
        assert_eq!(stub.requests("PUT", "/pullrequests/5").last().unwrap().json()["draft"], true);
        crate::rt::block_on(b.edit(&r(), &pr, "T", "B")).unwrap();
        assert_eq!(stub.requests("PUT", "/pullrequests/5").last().unwrap().json()["description"], "B");
        crate::rt::block_on(b.perform(PrAction::Close, &r(), &pr)).unwrap();
        assert_eq!(stub.requests("POST", "/decline").len(), 1);
        let e = crate::rt::block_on(b.perform(PrAction::Reopen, &r(), &pr)).unwrap_err();
        assert_eq!(e.message, "Not available for Bitbucket yet");
        assert!(crate::rt::block_on(b.enable_auto_merge(&r(), &pr, "MERGE")).is_err());
    }

    #[test]
    fn features_and_capabilities() {
        let f = PrFeatures::bitbucket();
        assert!(f.request_changes && f.revoke_approval && f.editing && f.draft_toggle);
        assert!(!f.reopen && !f.viewed_files && !f.update_branch);
        assert_eq!(f.checks_title(), "Builds");
        let caps = super::super::bitbucket::capabilities();
        assert_eq!(caps.pull_request_review, CapabilityState::Supported);
        assert_eq!(caps.merge_requirements, CapabilityState::Unavailable);
        let client = ForgeClient::stubbed(GitProvider::Bitbucket, "bitbucket.org", "sofia", Arc::new(Stub::default()));
        assert!(client.reviews());
    }

    #[test]
    fn commit_detail_and_urls() {
        let stub = Arc::new(Stub::default());
        stub.route("/commit/abc", 200, r#"{"hash":"abc","message":"Fix\n\nBody","date":"2026-10-01T08:00:00+00:00","author":{"raw":"Max <max@x>"},"links":{"html":{"href":"https://bitbucket.org/acme/api/commits/abc"}}}"#);
        stub.route("/diffstat/abc", 200, r#"{"values":[{"status":"added","lines_added":1,"lines_removed":0,"new":{"path":"a"}}]}"#);
        stub.route("/diff/abc", 200, "diff --git a/a b/a\nnew file mode 100644\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+x\n");
        let b = BitbucketReview::new(ForgeClient::stubbed(GitProvider::Bitbucket, "bitbucket.org", "sofia", stub));
        let c = crate::rt::block_on(b.commit("acme/api", "abc")).unwrap();
        assert_eq!(c.commit.message, "Fix\n\nBody");
        assert_eq!(c.commit.author.as_ref().and_then(|a| a.name.as_deref()), Some("Max"));
        assert_eq!(c.stats.as_ref().map(|s| s.additions), Some(1));
        let files = c.files.unwrap();
        assert_eq!(files[0].status, "added");
        assert_eq!(files[0].patch.as_deref(), Some("@@ -0,0 +1 @@\n+x"));
        assert_eq!(c.html_url, "https://bitbucket.org/acme/api/commits/abc");

        let parsed = parse_url("https://bitbucket.org/acme/api/pull-requests/12/overview").unwrap();
        assert_eq!((parsed.repo.full().as_str(), parsed.number), ("acme/api", 12));
        assert!(parse_url("https://gitlab.com/acme/api/pull-requests/12").is_none());
        assert_eq!(pull_path("my ws/repo", 3), "/repositories/my%20ws/repo/pullrequests/3");
    }
}
