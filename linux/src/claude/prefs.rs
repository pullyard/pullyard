use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::sessions::SessionInfo;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct AgentPrefs {
    pub pinned: Vec<String>,
    pub titles: HashMap<String, String>,
    pub archived: HashSet<String>,
    pub seen: HashMap<String, i64>,
    pub seen_baseline: i64,
}

impl AgentPrefs {
    pub fn is_pinned(&self, id: &str) -> bool {
        self.pinned.iter().any(|p| p == id)
    }

    pub fn toggle_pin(&mut self, id: &str) {
        if let Some(i) = self.pinned.iter().position(|p| p == id) {
            self.pinned.remove(i);
        } else {
            self.pinned.insert(0, id.to_string());
        }
    }

    pub fn title(&self, s: &SessionInfo) -> String {
        self.titles.get(&s.id).cloned().unwrap_or_else(|| s.title.clone())
    }

    pub fn rename(&mut self, id: &str, title: &str) {
        let t = title.trim();
        if t.is_empty() {
            self.titles.remove(id);
        } else {
            self.titles.insert(id.to_string(), t.to_string());
        }
    }

    pub fn is_archived(&self, s: &SessionInfo) -> bool {
        s.archived || self.archived.contains(&s.id)
    }

    pub fn set_archived(&mut self, id: &str, value: bool) {
        if value {
            self.archived.insert(id.to_string());
            self.pinned.retain(|p| p != id);
        } else {
            self.archived.remove(id);
        }
    }

    pub fn is_unread(&self, id: &str, modified: DateTime<Utc>) -> bool {
        let m = modified.timestamp_millis();
        let seen = self.seen.get(id).copied().unwrap_or(i64::MIN / 2);
        m > self.seen_baseline && m > seen + 2000
    }

    pub fn mark_seen(&mut self, id: &str, now: i64) -> bool {
        if id.is_empty() {
            return false;
        }
        if let Some(last) = self.seen.get(id) {
            if now - last < 1000 {
                return false;
            }
        }
        self.seen.insert(id.to_string(), now);
        if self.seen.len() > 600 {
            let mut entries: Vec<(String, i64)> = self.seen.iter().map(|(k, v)| (k.clone(), *v)).collect();
            entries.sort_by_key(|(_, v)| *v);
            let drop = entries.len() - 500;
            for (k, _) in entries.into_iter().take(drop) {
                self.seen.remove(&k);
            }
        }
        true
    }
}

thread_local! {
    static PREFS: RefCell<Option<AgentPrefs>> = const { RefCell::new(None) };
}

fn path() -> PathBuf {
    crate::settings::data_dir().join("agents.json")
}

fn load() -> AgentPrefs {
    let mut p: AgentPrefs = std::fs::read(path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
    if p.seen_baseline == 0 {
        p.seen_baseline = Utc::now().timestamp_millis();
        save(&p);
    }
    p
}

fn save(p: &AgentPrefs) {
    let file = path();
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(data) = serde_json::to_vec(p) {
        let tmp = file.with_extension("json.tmp");
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, &file);
        }
    }
}

pub fn read<T>(f: impl FnOnce(&AgentPrefs) -> T) -> T {
    PREFS.with(|p| {
        let mut p = p.borrow_mut();
        f(p.get_or_insert_with(load))
    })
}

pub fn update<T>(f: impl FnOnce(&mut AgentPrefs) -> T) -> T {
    PREFS.with(|p| {
        let mut p = p.borrow_mut();
        let prefs = p.get_or_insert_with(load);
        let out = f(prefs);
        save(prefs);
        out
    })
}

pub fn mark_seen(id: &str) {
    if id.is_empty() {
        return;
    }
    let now = Utc::now().timestamp_millis();
    PREFS.with(|p| {
        let mut p = p.borrow_mut();
        let prefs = p.get_or_insert_with(load);
        if prefs.mark_seen(id, now) {
            save(prefs);
        }
    });
}

pub fn retitled(s: &SessionInfo) -> SessionInfo {
    read(|p| match p.titles.get(&s.id) {
        Some(t) => {
            let mut c = s.clone();
            c.title = t.clone();
            c
        }
        None => s.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(id: &str, archived: bool) -> SessionInfo {
        SessionInfo {
            id: id.into(),
            file: PathBuf::from(format!("/tmp/{id}.jsonl")),
            cwd: "/tmp".into(),
            title: "Original".into(),
            branch: None,
            modified: Utc::now(),
            pr_url: None,
            pr_number: None,
            model: None,
            lines_added: None,
            lines_removed: None,
            parent_id: None,
            desktop_id: None,
            archived,
        }
    }

    #[test]
    fn pin_rename_archive() {
        let mut p = AgentPrefs::default();
        p.toggle_pin("a");
        p.toggle_pin("b");
        assert_eq!(p.pinned, vec!["b".to_string(), "a".to_string()]);
        p.toggle_pin("b");
        assert!(!p.is_pinned("b"));
        p.rename("a", "  Better  ");
        assert_eq!(p.title(&info("a", false)), "Better");
        p.rename("a", " ");
        assert_eq!(p.title(&info("a", false)), "Original");
        p.set_archived("a", true);
        assert!(p.is_archived(&info("a", false)));
        assert!(!p.is_pinned("a"));
        assert!(p.is_archived(&info("z", true)));
        p.set_archived("a", false);
        assert!(!p.is_archived(&info("a", false)));
    }

    #[test]
    fn unread_tracking() {
        let mut p = AgentPrefs { seen_baseline: 1_000, ..Default::default() };
        let old = DateTime::<Utc>::from_timestamp_millis(500).unwrap();
        assert!(!p.is_unread("x", old));
        let fresh = DateTime::<Utc>::from_timestamp_millis(10_000).unwrap();
        assert!(p.is_unread("x", fresh));
        assert!(p.mark_seen("x", 9_000));
        assert!(!p.is_unread("x", fresh));
        assert!(!p.mark_seen("x", 9_500));
        let later = DateTime::<Utc>::from_timestamp_millis(20_000).unwrap();
        assert!(p.is_unread("x", later));
        for i in 0..700 {
            p.mark_seen(&format!("s{i}"), 100_000 + i);
        }
        assert!(p.seen.len() <= 600);
    }
}
