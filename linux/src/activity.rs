use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum NotifyKind {
    ReviewRequest,
    CiFailed,
    ReviewDecision,
    AgentInput,
    AgentFinished,
}

impl NotifyKind {
    pub const ALL: [NotifyKind; 5] = [NotifyKind::ReviewRequest, NotifyKind::CiFailed, NotifyKind::ReviewDecision, NotifyKind::AgentInput, NotifyKind::AgentFinished];

    pub fn title(&self) -> &'static str {
        match self {
            NotifyKind::ReviewRequest => "New review requests",
            NotifyKind::CiFailed => "Checks failed on my pull requests",
            NotifyKind::ReviewDecision => "My pull requests approved or changes requested",
            NotifyKind::AgentInput => "Agent needs permission or an answer",
            NotifyKind::AgentFinished => "Agent finished",
        }
    }

    pub fn is_agent(&self) -> bool {
        matches!(self, NotifyKind::AgentInput | NotifyKind::AgentFinished)
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ActivityItem {
    pub id: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub updated_at: i64,
    pub ci_state: Option<String>,
    pub review_decision: Option<String>,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ActivityEvent {
    ReviewRequested(ActivityItem),
    CiFailed(ActivityItem),
    Approved(ActivityItem),
    ChangesRequested(ActivityItem),
}

impl ActivityEvent {
    pub fn item(&self) -> &ActivityItem {
        match self {
            ActivityEvent::ReviewRequested(i) | ActivityEvent::CiFailed(i) | ActivityEvent::Approved(i) | ActivityEvent::ChangesRequested(i) => i,
        }
    }

    pub fn kind(&self) -> NotifyKind {
        match self {
            ActivityEvent::ReviewRequested(_) => NotifyKind::ReviewRequest,
            ActivityEvent::CiFailed(_) => NotifyKind::CiFailed,
            ActivityEvent::Approved(_) | ActivityEvent::ChangesRequested(_) => NotifyKind::ReviewDecision,
        }
    }

    pub fn key(&self) -> String {
        let tag = match self {
            ActivityEvent::ReviewRequested(_) => "rr",
            ActivityEvent::CiFailed(_) => "ci",
            ActivityEvent::Approved(_) => "approved",
            ActivityEvent::ChangesRequested(_) => "changes",
        };
        let item = self.item();
        format!("{tag}|{}|{}", item.id, item.updated_at)
    }

    pub fn headline(&self) -> &'static str {
        match self {
            ActivityEvent::ReviewRequested(_) => "Review requested",
            ActivityEvent::CiFailed(_) => "Checks failed",
            ActivityEvent::Approved(_) => "Approved",
            ActivityEvent::ChangesRequested(_) => "Changes requested",
        }
    }
}

fn is_failing(state: &str) -> bool {
    state == "FAILURE" || state == "ERROR"
}

#[derive(Default)]
pub struct ActivityTracker {
    reviews_primed: bool,
    mine_primed: bool,
    review_ids: HashSet<String>,
    review_total: i64,
    mine_ids: HashSet<String>,
    ci: HashMap<String, String>,
    decisions: HashMap<String, String>,
}

impl ActivityTracker {
    pub fn update(&mut self, reviews: Option<&[ActivityItem]>, review_total: i64, mine: Option<&[ActivityItem]>) -> Vec<ActivityEvent> {
        let mut events = vec![];
        if let Some(reviews) = reviews {
            if self.reviews_primed {
                let fresh: Vec<&ActivityItem> = reviews.iter().filter(|i| !self.review_ids.contains(&i.id)).collect();
                let take = if review_total > reviews.len() as i64 { (review_total - self.review_total).max(0) as usize } else { fresh.len() };
                events.extend(fresh.into_iter().take(take).cloned().map(ActivityEvent::ReviewRequested));
            }
            self.review_ids = reviews.iter().map(|i| i.id.clone()).collect();
            self.review_total = review_total;
            self.reviews_primed = true;
        }
        if let Some(mine) = mine {
            if self.mine_primed {
                for item in mine.iter().filter(|i| self.mine_ids.contains(&i.id)) {
                    if let Some(state) = item.ci_state.as_deref() {
                        if is_failing(state) && !self.ci.get(&item.id).is_some_and(|s| is_failing(s)) {
                            events.push(ActivityEvent::CiFailed(item.clone()));
                        }
                    }
                    if item.review_decision.as_ref() != self.decisions.get(&item.id) {
                        match item.review_decision.as_deref() {
                            Some("APPROVED") => events.push(ActivityEvent::Approved(item.clone())),
                            Some("CHANGES_REQUESTED") => events.push(ActivityEvent::ChangesRequested(item.clone())),
                            _ => {}
                        }
                    }
                }
            }
            self.mine_ids = mine.iter().map(|i| i.id.clone()).collect();
            self.ci.clear();
            self.decisions.clear();
            for item in mine {
                if let Some(s) = &item.ci_state {
                    self.ci.entry(item.id.clone()).or_insert_with(|| s.clone());
                }
                if let Some(d) = &item.review_decision {
                    self.decisions.entry(item.id.clone()).or_insert_with(|| d.clone());
                }
            }
            self.mine_primed = true;
        }
        events
    }
}

pub struct RecentEvents {
    keys: Vec<String>,
    limit: usize,
}

impl RecentEvents {
    pub const DEFAULT_LIMIT: usize = 300;

    pub fn new(keys: Vec<String>, limit: usize) -> Self {
        let skip = keys.len().saturating_sub(limit);
        RecentEvents { keys: keys.into_iter().skip(skip).collect(), limit }
    }

    pub fn keys(&self) -> &[String] {
        &self.keys
    }

    pub fn contains(&self, key: &str) -> bool {
        self.keys.iter().any(|k| k == key)
    }

    pub fn insert(&mut self, key: &str) -> bool {
        if self.contains(key) {
            return false;
        }
        self.keys.push(key.to_string());
        if self.keys.len() > self.limit {
            let extra = self.keys.len() - self.limit;
            self.keys.drain(..extra);
        }
        true
    }
}

pub fn target_value(account: &str, url: &str) -> String {
    format!("{account}\n{url}")
}

pub fn parse_target(value: &str) -> Option<(String, String)> {
    let (account, url) = value.split_once('\n')?;
    if url.is_empty() {
        return None;
    }
    Some((account.to_string(), url.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(n: i64, ci: Option<&str>, decision: Option<&str>, updated: i64) -> ActivityItem {
        ActivityItem {
            id: format!("https://github.com/o/r/pull/{n}"),
            repo: "o/r".into(),
            number: n,
            title: format!("PR {n}"),
            updated_at: updated,
            ci_state: ci.map(String::from),
            review_decision: decision.map(String::from),
        }
    }

    fn plain(n: i64) -> ActivityItem {
        item(n, None, None, 1000)
    }

    fn ci(n: i64, state: &str) -> ActivityItem {
        item(n, Some(state), None, 1000)
    }

    fn decided(n: i64, decision: &str) -> ActivityItem {
        item(n, None, Some(decision), 1000)
    }

    #[test]
    fn first_load_is_silent() {
        let mut t = ActivityTracker::default();
        assert_eq!(t.update(Some(&[plain(1), plain(2)]), 2, Some(&[item(3, Some("FAILURE"), Some("APPROVED"), 1000)])), vec![]);
    }

    #[test]
    fn new_review_request() {
        let mut t = ActivityTracker::default();
        t.update(Some(&[plain(1)]), 1, None);
        assert_eq!(t.update(Some(&[plain(2), plain(1)]), 2, None), vec![ActivityEvent::ReviewRequested(plain(2))]);
        assert_eq!(t.update(Some(&[plain(2), plain(1)]), 2, None), vec![]);
    }

    #[test]
    fn failed_fetch_does_not_prime() {
        let mut t = ActivityTracker::default();
        t.update(None, 0, None);
        assert_eq!(t.update(Some(&[plain(1)]), 1, None), vec![]);
        t.update(None, 0, None);
        assert_eq!(t.update(Some(&[plain(1), plain(2)]), 2, None), vec![ActivityEvent::ReviewRequested(plain(2))]);
    }

    #[test]
    fn truncated_list_only_counts_growth() {
        let mut t = ActivityTracker::default();
        t.update(Some(&[plain(1), plain(2)]), 15, None);
        assert_eq!(t.update(Some(&[plain(3), plain(1)]), 15, None), vec![]);
        assert_eq!(t.update(Some(&[plain(4), plain(5), plain(3)]), 16, None), vec![ActivityEvent::ReviewRequested(plain(4))]);
    }

    #[test]
    fn ci_failure_transition() {
        let mut t = ActivityTracker::default();
        t.update(None, 0, Some(&[ci(1, "PENDING"), ci(2, "FAILURE")]));
        let events = t.update(None, 0, Some(&[ci(1, "FAILURE"), ci(2, "ERROR")]));
        assert_eq!(events, vec![ActivityEvent::CiFailed(ci(1, "FAILURE"))]);
        assert_eq!(t.update(None, 0, Some(&[ci(1, "FAILURE")])), vec![]);
    }

    #[test]
    fn ci_failure_ignores_newly_seen_pr() {
        let mut t = ActivityTracker::default();
        t.update(None, 0, Some(&[]));
        assert_eq!(t.update(None, 0, Some(&[ci(1, "FAILURE")])), vec![]);
    }

    #[test]
    fn review_decision_transitions() {
        let mut t = ActivityTracker::default();
        t.update(None, 0, Some(&[decided(1, "REVIEW_REQUIRED"), plain(2)]));
        let events = t.update(None, 0, Some(&[decided(1, "APPROVED"), decided(2, "CHANGES_REQUESTED")]));
        assert_eq!(events, vec![ActivityEvent::Approved(decided(1, "APPROVED")), ActivityEvent::ChangesRequested(decided(2, "CHANGES_REQUESTED"))]);
        assert_eq!(t.update(None, 0, Some(&[decided(1, "APPROVED")])), vec![]);
    }

    #[test]
    fn event_keys_and_kinds() {
        let a = ActivityEvent::CiFailed(item(1, None, None, 10));
        assert_eq!(a.kind(), NotifyKind::CiFailed);
        assert_ne!(a.key(), ActivityEvent::CiFailed(item(1, None, None, 20)).key());
        assert_ne!(a.key(), ActivityEvent::ReviewRequested(item(1, None, None, 10)).key());
        assert_eq!(ActivityEvent::Approved(plain(1)).kind(), NotifyKind::ReviewDecision);
        assert!(NotifyKind::AgentInput.is_agent());
        assert!(!NotifyKind::CiFailed.is_agent());
    }

    #[test]
    fn recent_events_dedupes_and_caps() {
        let mut r = RecentEvents::new(vec![], 2);
        assert!(r.insert("a"));
        assert!(!r.insert("a"));
        assert!(r.insert("b"));
        assert!(r.insert("c"));
        assert_eq!(r.keys(), ["b".to_string(), "c".to_string()]);
        assert!(r.insert("a"));
        let r = RecentEvents::new(vec!["x".into(), "y".into(), "z".into()], 2);
        assert_eq!(r.keys(), ["y".to_string(), "z".to_string()]);
    }

    #[test]
    fn target_round_trip() {
        let v = target_value("acct", "https://github.com/o/r/pull/1");
        assert_eq!(parse_target(&v), Some(("acct".to_string(), "https://github.com/o/r/pull/1".to_string())));
        assert_eq!(parse_target(&target_value("", "https://x")), Some((String::new(), "https://x".to_string())));
        assert_eq!(parse_target("nothing"), None);
        assert_eq!(parse_target("acct\n"), None);
    }
}
