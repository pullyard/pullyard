use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DraftComment {
    pub path: String,
    pub line: i64,
    pub side: String,
    pub body: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct ReviewDraft {
    pub pending: Vec<DraftComment>,
    pub composer: Option<DraftComment>,
    pub replies: HashMap<String, String>,
    pub comment: String,
    pub summary: String,
}

fn blank(s: &str) -> bool {
    s.trim().is_empty()
}

impl ReviewDraft {
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty() && self.composer.as_ref().is_none_or(|c| blank(&c.body)) && self.replies.values().all(|r| blank(r)) && blank(&self.comment) && blank(&self.summary)
    }
}

pub fn key(account: &str, host: &str, repo: &str, number: i64, kind: &str) -> String {
    format!("{kind}|{}|{host}|{repo}#{number}", if account.is_empty() { "-" } else { account })
}

pub fn file_name(key: &str) -> String {
    use base64::Engine;
    format!("{}.json", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key.as_bytes()))
}

pub struct Store {
    dir: Option<PathBuf>,
    memory: RefCell<HashMap<String, Vec<u8>>>,
}

impl Store {
    pub fn new(dir: Option<PathBuf>) -> Self {
        Store { dir, memory: RefCell::new(HashMap::new()) }
    }

    fn file(&self, key: &str) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join(file_name(key)))
    }

    fn read(&self, key: &str) -> Option<Vec<u8>> {
        match self.file(key) {
            Some(file) => std::fs::read(file).ok(),
            None => self.memory.borrow().get(key).cloned(),
        }
    }

    fn write(&self, data: Option<Vec<u8>>, key: &str) {
        let Some(file) = self.file(key) else {
            match data {
                Some(d) => {
                    self.memory.borrow_mut().insert(key.to_string(), d);
                }
                None => {
                    self.memory.borrow_mut().remove(key);
                }
            }
            return;
        };
        let Some(data) = data else {
            let _ = std::fs::remove_file(&file);
            return;
        };
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let tmp = file.with_extension("json.tmp");
        if std::fs::write(&tmp, &data).is_ok() {
            let _ = std::fs::rename(&tmp, &file);
        }
    }

    pub fn review(&self, key: &str) -> Option<ReviewDraft> {
        self.read(key).and_then(|d| serde_json::from_slice(&d).ok())
    }

    pub fn save(&self, draft: &ReviewDraft, key: &str) {
        let data = if draft.is_empty() { None } else { serde_json::to_vec(draft).ok() };
        self.write(data, key);
    }

    pub fn text(&self, key: &str) -> String {
        self.read(key).map(|d| String::from_utf8_lossy(&d).to_string()).unwrap_or_default()
    }

    pub fn set_text(&self, text: &str, key: &str) {
        self.write(if blank(text) { None } else { Some(text.as_bytes().to_vec()) }, key);
    }
}

thread_local! {
    static SHARED: Store = Store::new(Some(crate::settings::data_dir().join("drafts")));
}

pub fn with<T>(f: impl FnOnce(&Store) -> T) -> T {
    SHARED.with(|s| f(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn comment(body: &str) -> DraftComment {
        DraftComment { path: "src/a.rs".into(), line: 12, side: "RIGHT".into(), body: body.into() }
    }

    #[test]
    fn keys_separate_accounts_hosts_and_kinds() {
        assert_eq!(key("alice", "github.com", "a/b", 7, "pr"), "pr|alice|github.com|a/b#7");
        assert_eq!(key("", "github.com", "a/b", 7, "issue"), "issue|-|github.com|a/b#7");
        assert_ne!(key("alice", "github.com", "a/b", 7, "pr"), key("bob", "github.com", "a/b", 7, "pr"));
        assert_ne!(key("alice", "github.com", "a/b", 7, "pr"), key("alice", "ghe.corp", "a/b", 7, "pr"));
        let name = file_name(&key("alice", "github.com", "a/b", 7, "pr"));
        assert!(name.ends_with(".json"));
        assert!(!name.contains('/') && !name.contains('+') && !name.contains('|'));
    }

    #[test]
    fn empty_drafts_are_detected() {
        assert!(ReviewDraft::default().is_empty());
        let mut d = ReviewDraft { composer: Some(comment("  \n")), comment: " ".into(), summary: "\n".into(), ..Default::default() };
        d.replies.insert("t1".into(), "  ".into());
        assert!(d.is_empty());
        d.replies.insert("t2".into(), "reply".into());
        assert!(!d.is_empty());
        assert!(!ReviewDraft { pending: vec![comment("x")], ..Default::default() }.is_empty());
        assert!(!ReviewDraft { summary: "LGTM".into(), ..Default::default() }.is_empty());
    }

    #[test]
    fn memory_store_round_trips_and_removes_empty() {
        let store = Store::new(None);
        let k = key("alice", "github.com", "a/b", 7, "pr");
        assert_eq!(store.review(&k), None);
        let draft = ReviewDraft { pending: vec![comment("first")], composer: Some(comment("typing")), summary: "Looks good".into(), ..Default::default() };
        store.save(&draft, &k);
        assert_eq!(store.review(&k), Some(draft));
        store.save(&ReviewDraft::default(), &k);
        assert_eq!(store.review(&k), None);
        let issue = key("alice", "github.com", "a/b", 7, "issue");
        store.set_text("half a comment", &issue);
        assert_eq!(store.text(&issue), "half a comment");
        assert_eq!(store.review(&k), None);
        store.set_text("   ", &issue);
        assert_eq!(store.text(&issue), "");
    }

    #[test]
    fn disk_store_persists_between_instances() {
        let dir = std::env::temp_dir().join(format!("pullyard-drafts-{}", uuid::Uuid::new_v4()));
        let k = key("alice", "github.com", "a/b", 9, "pr");
        let draft = ReviewDraft { comment: "wip".into(), ..Default::default() };
        Store::new(Some(dir.clone())).save(&draft, &k);
        let reopened = Store::new(Some(dir.clone()));
        assert_eq!(reopened.review(&k), Some(draft));
        reopened.save(&ReviewDraft::default(), &k);
        assert!(!dir.join(file_name(&k)).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn older_files_without_new_fields_still_load() {
        let store = Store::new(None);
        store.write(Some(br#"{"pending":[{"path":"a","line":1,"side":"LEFT","body":"b"}]}"#.to_vec()), "k");
        let d = store.review("k").unwrap();
        assert_eq!(d.pending.len(), 1);
        assert!(d.composer.is_none() && d.summary.is_empty());
    }
}
