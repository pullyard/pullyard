use std::cell::RefCell;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::json;

use super::GitHubApi;

pub const TTL: Duration = Duration::from_secs(600);
pub const MAX_PER_QUERY: usize = 20;

pub fn valid(handle: &str) -> bool {
    !handle.is_empty() && handle.chars().count() <= 100 && handle.chars().all(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '/' | '.'))
}

pub fn query(handles: &[String]) -> (String, HashMap<String, String>) {
    let mut aliases = HashMap::new();
    let mut parts = Vec::new();
    for (i, h) in handles.iter().filter(|h| valid(h)).take(MAX_PER_QUERY).enumerate() {
        let alias = format!("r{i}");
        let qualifier = if h.contains('/') { format!("team-review-requested:{h}") } else { format!("review-requested:{h}") };
        parts.push(format!("{alias}: search(query: \"is:pr is:open archived:false {qualifier}\", type: ISSUE, first: 0) {{ issueCount }}"));
        aliases.insert(alias, h.clone());
    }
    (format!("query {{ {} }}", parts.join(" ")), aliases)
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub issue_count: u64,
}

pub fn parse(data: &HashMap<String, Option<Hit>>, aliases: &HashMap<String, String>) -> HashMap<String, u64> {
    aliases
        .iter()
        .filter_map(|(alias, handle)| data.get(alias).and_then(|h| h.as_ref()).map(|h| (handle.to_lowercase(), h.issue_count)))
        .collect()
}

pub fn label(count: u64) -> String {
    if count == 1 {
        "1 open review".to_string()
    } else {
        format!("{count} open reviews")
    }
}

pub fn busy(count: u64) -> bool {
    count >= 10
}

#[derive(Default)]
pub struct Cache {
    entries: HashMap<String, (u64, Instant)>,
}

impl Cache {
    pub fn get(&self, handle: &str, now: Instant) -> Option<u64> {
        self.entries.get(&handle.to_lowercase()).filter(|(_, at)| now.saturating_duration_since(*at) < TTL).map(|(n, _)| *n)
    }

    pub fn insert(&mut self, handle: &str, count: u64, now: Instant) {
        self.entries.insert(handle.to_lowercase(), (count, now));
    }

    pub fn split(&self, handles: &[String], now: Instant) -> (HashMap<String, u64>, Vec<String>) {
        let mut hits = HashMap::new();
        let mut missing: Vec<String> = Vec::new();
        for h in handles {
            if let Some(n) = self.get(h, now) {
                hits.insert(h.to_lowercase(), n);
            } else if valid(h) && !missing.iter().any(|m| m.eq_ignore_ascii_case(h)) {
                missing.push(h.clone());
            }
        }
        (hits, missing)
    }
}

thread_local! {
    static CACHE: RefCell<Cache> = RefCell::new(Cache::default());
}

pub async fn load(handles: Vec<String>, api: GitHubApi) -> HashMap<String, u64> {
    let (mut result, missing) = CACHE.with(|c| c.borrow().split(&handles, Instant::now()));
    for chunk in missing.chunks(MAX_PER_QUERY) {
        let (q, aliases) = query(chunk);
        let api = api.clone();
        let data = crate::rt::run(async move { api.graphql::<HashMap<String, Option<Hit>>>("reviewLoad", &q, json!({}), false).await }).await;
        let Ok(data) = data else { continue };
        let counts = parse(&data, &aliases);
        let now = Instant::now();
        CACHE.with(|c| {
            let mut c = c.borrow_mut();
            for (handle, n) in &counts {
                c.insert(handle, *n, now);
            }
        });
        result.extend(counts);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_uses_user_and_team_qualifiers() {
        let handles: Vec<String> = ["alice", "acme/core", "bad\"name", "bob"].iter().map(|s| s.to_string()).collect();
        let (q, aliases) = query(&handles);
        let expected: HashMap<String, String> = [("r0", "alice"), ("r1", "acme/core"), ("r2", "bob")].iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
        assert_eq!(aliases, expected);
        assert!(q.contains(r#"r0: search(query: "is:pr is:open archived:false review-requested:alice", type: ISSUE, first: 0) { issueCount }"#));
        assert!(q.contains("team-review-requested:acme/core"));
        assert!(!q.contains("bad"));
        assert!(q.starts_with("query { ") && q.ends_with(" }"));
        let many: Vec<String> = (0..30).map(|i| format!("u{i}")).collect();
        assert_eq!(query(&many).1.len(), MAX_PER_QUERY);
    }

    #[test]
    fn valid_handles() {
        assert!(valid("alice"));
        assert!(valid("acme/core-team.v2_x"));
        assert!(!valid(""));
        assert!(!valid("a b"));
        assert!(!valid("x:y"));
        assert!(!valid(&"a".repeat(101)));
        assert!(valid(&"a".repeat(100)));
    }

    #[test]
    fn parse_and_labels() {
        let data: HashMap<String, Option<Hit>> = serde_json::from_str(r#"{"r0":{"issueCount":3},"r1":{"issueCount":12},"r3":null}"#).unwrap();
        let aliases: HashMap<String, String> = [("r0", "Alice"), ("r1", "acme/Core"), ("r2", "bob"), ("r3", "carol")].iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
        let expected: HashMap<String, u64> = [("alice".to_string(), 3), ("acme/core".to_string(), 12)].into_iter().collect();
        assert_eq!(parse(&data, &aliases), expected);
        assert_eq!(label(1), "1 open review");
        assert_eq!(label(4), "4 open reviews");
        assert_eq!(label(0), "0 open reviews");
        assert!(busy(10));
        assert!(!busy(9));
    }

    #[test]
    fn cache_expires_and_splits() {
        let now = Instant::now();
        let mut cache = Cache::default();
        cache.insert("Alice", 5, now);
        assert_eq!(cache.get("alice", now + Duration::from_secs(599)), Some(5));
        assert_eq!(cache.get("ALICE", now + TTL), None);
        let handles: Vec<String> = ["alice", "Bob", "bob", "bad name"].iter().map(|s| s.to_string()).collect();
        let (hits, missing) = cache.split(&handles, now);
        assert_eq!(hits.get("alice"), Some(&5));
        assert_eq!(missing, vec!["Bob".to_string()]);
    }
}
