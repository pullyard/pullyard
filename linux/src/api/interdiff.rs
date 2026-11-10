use chrono::DateTime;
use serde::Deserialize;

use super::models::{Date, PrFile, PullRequestDetail};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DiffScope {
    #[default]
    All,
    SinceReview,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewedCommit {
    pub oid: String,
    pub date: Option<Date>,
    pub commits_since: Option<usize>,
}

impl ReviewedCommit {
    pub fn rewritten(&self) -> bool {
        self.commits_since.is_none()
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct CompareResult {
    #[serde(default)]
    pub behind_by: Option<i64>,
    #[serde(default)]
    pub files: Option<Vec<PrFile>>,
}

pub fn last_reviewed(pr: &PullRequestDetail, viewer: &str) -> Option<ReviewedCommit> {
    if viewer.is_empty() {
        return None;
    }
    let me = viewer.to_lowercase();
    let past = DateTime::<chrono::Utc>::MIN_UTC;
    let mut best: Option<(String, Option<Date>)> = None;
    for item in &pr.timeline_items.nodes {
        if item.typename != "PullRequestReview" || item.state.as_deref() == Some("PENDING") {
            continue;
        }
        if item.author.as_ref().map(|a| a.login.to_lowercase()) != Some(me.clone()) {
            continue;
        }
        let Some(oid) = item.commit.as_ref().and_then(|c| c.oid.clone()) else { continue };
        if best.as_ref().is_none_or(|b| item.created_at.unwrap_or(past) >= b.1.unwrap_or(past)) {
            best = Some((oid, item.created_at));
        }
    }
    for r in &pr.latest_opinionated_reviews.nodes {
        if r.author.as_ref().map(|a| a.login.to_lowercase()) != Some(me.clone()) {
            continue;
        }
        let Some(oid) = r.commit.as_ref().map(|c| c.oid.clone()) else { continue };
        if best.as_ref().is_none_or(|b| r.submitted_at.unwrap_or(past) > b.1.unwrap_or(past)) {
            best = Some((oid, r.submitted_at));
        }
    }
    let (oid, date) = best?;
    if oid == pr.head_ref_oid {
        return None;
    }
    let oids: Vec<&str> = pr.all_commits.nodes.iter().map(|c| c.commit.oid.as_str()).collect();
    let commits_since = oids.iter().rposition(|o| *o == oid).map(|i| oids.len() - 1 - i);
    Some(ReviewedCommit { oid, date, commits_since })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{DiffFile, LineKind};
    use serde_json::{json, Value};

    fn pr(timeline: Vec<Value>, latest: Vec<Value>, commits: &[&str], head: &str) -> PullRequestDetail {
        let commits: Vec<Value> = commits.iter().map(|c| json!({ "commit": { "oid": c, "abbreviatedOid": c, "messageHeadline": "m", "committedDate": "2026-01-01T00:00:00Z", "url": "u" } })).collect();
        serde_json::from_value(json!({
            "id": "PR_1", "number": 1, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false,
            "mergeable": "MERGEABLE", "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z",
            "headRefName": "f", "baseRefName": "main", "headRefOid": head, "additions": 1, "deletions": 1, "changedFiles": 1,
            "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": { "nodes": [] }, "assignees": { "nodes": [] }, "reviewRequests": { "nodes": [] },
            "latestOpinionatedReviews": { "nodes": latest }, "lastCommit": { "nodes": [] },
            "allCommits": { "nodes": commits },
            "timelineItems": { "nodes": timeline }, "reviewThreads": { "nodes": [] }
        }))
        .unwrap()
    }

    fn with_timeline(timeline: Vec<Value>) -> PullRequestDetail {
        pr(timeline, vec![], &["c1", "c2", "c3"], "c3")
    }

    fn review(login: &str, oid: &str, date: &str, state: &str) -> Value {
        json!({ "__typename": "PullRequestReview", "state": state, "createdAt": date, "author": { "login": login, "avatarUrl": "" }, "commit": { "oid": oid } })
    }

    #[test]
    fn picks_viewers_latest_review_including_comments() {
        let p = with_timeline(vec![
            review("me", "c1", "2026-01-02T00:00:00Z", "APPROVED"),
            review("other", "c2", "2026-01-04T00:00:00Z", "COMMENTED"),
            review("Me", "c2", "2026-01-03T00:00:00Z", "COMMENTED"),
        ]);
        let r = last_reviewed(&p, "me").unwrap();
        assert_eq!(r.oid, "c2");
        assert_eq!(r.commits_since, Some(1));
        assert!(!r.rewritten());
    }

    #[test]
    fn falls_back_to_latest_opinionated_reviews() {
        let latest = vec![json!({ "state": "APPROVED", "submittedAt": "2026-01-02T00:00:00Z", "commit": { "oid": "c1" }, "author": { "login": "me", "avatarUrl": "" } })];
        let r = last_reviewed(&pr(vec![], latest, &["c1", "c2", "c3"], "c3"), "me").unwrap();
        assert_eq!(r.oid, "c1");
        assert_eq!(r.commits_since, Some(2));
    }

    #[test]
    fn nothing_when_reviewed_head_or_never_reviewed() {
        assert!(last_reviewed(&with_timeline(vec![review("me", "c3", "2026-01-02T00:00:00Z", "COMMENTED")]), "me").is_none());
        assert!(last_reviewed(&with_timeline(vec![review("other", "c1", "2026-01-02T00:00:00Z", "COMMENTED")]), "me").is_none());
        assert!(last_reviewed(&with_timeline(vec![review("me", "c1", "2026-01-02T00:00:00Z", "COMMENTED")]), "").is_none());
    }

    #[test]
    fn ignores_pending_reviews() {
        assert!(last_reviewed(&with_timeline(vec![review("me", "c1", "2026-01-02T00:00:00Z", "PENDING")]), "me").is_none());
    }

    #[test]
    fn force_pushed_commit_is_rewritten() {
        let r = last_reviewed(&with_timeline(vec![review("me", "gone", "2026-01-02T00:00:00Z", "COMMENTED")]), "me").unwrap();
        assert!(r.rewritten());
        assert_eq!(r.commits_since, None);
    }

    #[test]
    fn compare_result_decodes_snake_case() {
        let raw = r#"{"status":"diverged","ahead_by":2,"behind_by":3,"files":[{"filename":"a.swift","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1,2 @@\n a\n+b","previous_filename":null}]}"#;
        let r: CompareResult = serde_json::from_str(raw).unwrap();
        assert_eq!(r.behind_by, Some(3));
        let files = r.files.unwrap();
        assert_eq!(files.iter().map(|f| f.filename.as_str()).collect::<Vec<_>>(), vec!["a.swift"]);
        assert_eq!(DiffFile::new(&files[0]).lines.iter().filter(|l| l.kind == LineKind::Add).count(), 1);
    }

    #[test]
    fn timeline_query_carries_review_commit() {
        assert!(crate::api::queries::pull_request().contains("... on PullRequestReview { id author { login avatarUrl } state body bodyHTML createdAt url commit { oid } }"));
    }
}
