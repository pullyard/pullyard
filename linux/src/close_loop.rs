use std::collections::HashSet;

use chrono::{DateTime, Utc};

use crate::api::models::PullRequestDetail;

#[derive(Debug, Clone, PartialEq)]
pub struct ReviewFixLaunch {
    pub thread_ids: Vec<String>,
    pub head_oid: String,
    pub at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pending {
    pub threads: Vec<String>,
    pub new_commits: usize,
}

pub fn pending(launch: Option<&ReviewFixLaunch>, pr: &PullRequestDetail) -> Option<Pending> {
    let launch = launch?;
    if !pr.is_open() || pr.head_ref_oid.is_empty() || pr.head_ref_oid == launch.head_oid {
        return None;
    }
    let open: HashSet<&str> = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved).map(|t| t.id.as_str()).collect();
    let threads: Vec<String> = launch.thread_ids.iter().filter(|id| open.contains(id.as_str())).cloned().collect();
    if threads.is_empty() {
        return None;
    }
    let oids: Vec<&str> = pr.all_commits.nodes.iter().map(|c| c.commit.oid.as_str()).collect();
    let new_commits = oids.iter().position(|o| *o == launch.head_oid).map(|i| oids.len() - i - 1).unwrap_or(1);
    Some(Pending { threads, new_commits: new_commits.max(1) })
}

pub fn default_reply(head: &str) -> String {
    if head.is_empty() {
        "Fixed.".to_string()
    } else {
        format!("Fixed in {}.", head.chars().take(7).collect::<String>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn thread(id: &str, resolved: bool) -> Value {
        json!({ "id": id, "isResolved": resolved, "isOutdated": false, "path": "a.rs", "line": 3, "diffSide": "RIGHT",
            "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true, "comments": { "nodes": [] } })
    }

    fn pr(head: &str, commits: &[&str], threads: Vec<Value>, state: &str) -> PullRequestDetail {
        let mut value = json!({
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": state, "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main",
            "headRefOid": head, "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false
        });
        let nodes: Vec<Value> = commits
            .iter()
            .map(|c| json!({ "commit": { "oid": c, "abbreviatedOid": c, "messageHeadline": "m", "committedDate": "2026-01-01T00:00:00Z", "url": "u" } }))
            .collect();
        value["allCommits"] = json!({ "totalCount": commits.len(), "nodes": nodes });
        value["reviewThreads"] = json!({ "nodes": threads });
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn pending_needs_new_commits_and_open_threads() {
        let launch = ReviewFixLaunch { thread_ids: vec!["t1".into(), "t2".into(), "t3".into()], head_oid: "c1".into(), at: Utc::now() };
        let same = pr("c1", &["c0", "c1"], vec![thread("t1", false)], "OPEN");
        assert_eq!(pending(Some(&launch), &same), None);
        let pushed = pr("c3", &["c0", "c1", "c2", "c3"], vec![thread("t1", false), thread("t2", true), thread("t9", false)], "OPEN");
        assert_eq!(pending(Some(&launch), &pushed), Some(Pending { threads: vec!["t1".into()], new_commits: 2 }));
        let rewritten = pr("x9", &["x8", "x9"], vec![thread("t3", false)], "OPEN");
        assert_eq!(pending(Some(&launch), &rewritten).map(|p| p.new_commits), Some(1));
        let done = pr("c3", &["c1", "c3"], vec![thread("t1", true)], "OPEN");
        assert_eq!(pending(Some(&launch), &done), None);
        let merged = pr("c3", &["c1", "c3"], vec![thread("t1", false)], "MERGED");
        assert_eq!(pending(Some(&launch), &merged), None);
        assert_eq!(pending(None, &pushed), None);
    }

    #[test]
    fn default_reply_uses_short_head() {
        assert_eq!(default_reply("abcdef123456"), "Fixed in abcdef1.");
        assert_eq!(default_reply(""), "Fixed.");
    }
}
