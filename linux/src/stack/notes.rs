use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use gtk::gio;
use gtk::gio::prelude::*;

use crate::api::models::RepoRef;
use crate::signal::Signal;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NoteKind {
    #[default]
    Note,
    Question,
    Decision,
}

impl NoteKind {
    pub const ALL: [NoteKind; 3] = [NoteKind::Note, NoteKind::Question, NoteKind::Decision];

    pub fn title(&self) -> &'static str {
        match self {
            NoteKind::Note => "Note",
            NoteKind::Question => "Question",
            NoteKind::Decision => "Decision",
        }
    }

    pub fn color(&self) -> &'static str {
        match self {
            NoteKind::Note => "amber",
            NoteKind::Question => "sky",
            NoteKind::Decision => "green",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StackNote {
    pub id: String,
    pub kind: NoteKind,
    pub text: String,
    pub updated: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

impl StackNote {
    pub fn new(kind: NoteKind, text: &str) -> Self {
        StackNote { id: uuid::Uuid::new_v4().to_string(), kind, text: text.to_string(), updated: Utc::now(), source: None }
    }

    fn blank(&self) -> bool {
        self.text.trim().is_empty()
    }
}

pub fn key(account: &str, host: &str, repo: &RepoRef, number: i64) -> String {
    key_for(account, host, &repo.full(), number)
}

pub fn key_for(account: &str, host: &str, repo: &str, number: i64) -> String {
    format!("{}|{host}|{}#{number}", account.to_lowercase(), repo.to_lowercase())
}

pub struct NotesStore {
    by_pr: RefCell<HashMap<String, Vec<StackNote>>>,
    file: PathBuf,
}

impl NotesStore {
    pub fn open(file: PathBuf) -> Self {
        let by_pr = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice::<HashMap<String, Vec<StackNote>>>(&d).ok()).unwrap_or_default();
        NotesStore { by_pr: RefCell::new(by_pr), file }
    }

    pub fn notes(&self, key: &str) -> Vec<StackNote> {
        self.by_pr.borrow().get(key).cloned().unwrap_or_default()
    }

    pub fn count(&self, key: &str) -> usize {
        self.by_pr.borrow().get(key).map(|v| v.len()).unwrap_or(0)
    }

    pub fn has_notes(&self, key: &str) -> bool {
        self.by_pr.borrow().get(key).is_some_and(|v| v.iter().any(|n| !n.blank()))
    }

    pub fn replace(&self, key: &str, drafts: &[StackNote]) -> bool {
        let old: HashMap<String, StackNote> = self.notes(key).into_iter().map(|n| (n.id.clone(), n)).collect();
        let kept: Vec<StackNote> = drafts
            .iter()
            .filter(|d| !d.blank())
            .map(|d| match old.get(&d.id) {
                Some(o) if o.text == d.text && o.kind == d.kind => o.clone(),
                _ => StackNote { updated: Utc::now(), ..d.clone() },
            })
            .collect();
        let mut by_pr = self.by_pr.borrow_mut();
        if kept == by_pr.get(key).cloned().unwrap_or_default() {
            return false;
        }
        if kept.is_empty() {
            by_pr.remove(key);
        } else {
            by_pr.insert(key.to_string(), kept);
        }
        true
    }

    pub fn import(&self, entries: &[super::mcp::Entry]) -> Vec<String> {
        let mut keys: Vec<String> = vec![];
        let mut by_pr = self.by_pr.borrow_mut();
        for e in entries {
            by_pr.entry(e.key.clone()).or_default().push(e.note());
            if !keys.contains(&e.key) {
                keys.push(e.key.clone());
            }
        }
        keys
    }

    fn snapshot(&self) -> Option<Vec<u8>> {
        let by_pr = self.by_pr.borrow();
        let kept: HashMap<&String, &Vec<StackNote>> = by_pr.iter().filter(|(_, v)| !v.is_empty()).collect();
        serde_json::to_vec(&kept).ok()
    }

    pub fn flush_blocking(&self) -> std::io::Result<()> {
        match self.snapshot() {
            Some(data) => write_file(&self.file, &data),
            None => Ok(()),
        }
    }

    pub fn flush(&self) {
        let Some(data) = self.snapshot() else { return };
        let file = self.file.clone();
        crate::rt::runtime().spawn_blocking(move || {
            let _ = write_file(&file, &data);
        });
    }
}

fn write_file(file: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = file.with_extension(format!("json.{}.tmp", uuid::Uuid::new_v4().simple()));
    let written = std::fs::File::create(&tmp).and_then(|mut f| {
        std::io::Write::write_all(&mut f, data)?;
        f.sync_all()
    });
    match written.and_then(|_| std::fs::rename(&tmp, file)) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

thread_local! {
    static SHARED: Rc<NotesStore> = Rc::new(NotesStore::open(super::mcp::notes_file()));
    static SAVE: RefCell<Option<gtk::glib::SourceId>> = const { RefCell::new(None) };
    static CHANGED: Signal<String> = const { Signal::new() };
    static INBOX: RefCell<Option<gio::FileMonitor>> = const { RefCell::new(None) };
    static IMPORT: RefCell<Option<gtk::glib::SourceId>> = const { RefCell::new(None) };
}

pub fn shared() -> Rc<NotesStore> {
    SHARED.with(|s| s.clone())
}

pub fn on_change(f: impl Fn(&String) -> bool + 'static) {
    CHANGED.with(|s| s.connect(f));
}

pub fn commit(key: &str, drafts: &[StackNote]) {
    if !shared().replace(key, drafts) {
        return;
    }
    CHANGED.with(|s| s.emit(&key.to_string()));
    schedule_save();
}

pub fn import_inbox() {
    let entries = super::mcp::drain(&super::mcp::inbox_dir());
    if entries.is_empty() {
        return;
    }
    for key in shared().import(&entries) {
        CHANGED.with(|s| s.emit(&key));
    }
    schedule_save();
}

pub fn watch_inbox() {
    if INBOX.with(|m| m.borrow().is_some()) {
        return;
    }
    let dir = super::mcp::inbox_dir();
    let _ = std::fs::create_dir_all(&dir);
    import_inbox();
    let Ok(monitor) = gio::File::for_path(&dir).monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE) else { return };
    monitor.connect_changed(|_, _, _, _| {
        IMPORT.with(|s| {
            if let Some(id) = s.borrow_mut().take() {
                id.remove();
            }
            let id = gtk::glib::timeout_add_local_once(Duration::from_millis(300), || {
                IMPORT.with(|s| s.borrow_mut().take());
                import_inbox();
            });
            *s.borrow_mut() = Some(id);
        });
    });
    INBOX.with(|m| *m.borrow_mut() = Some(monitor));
}

fn schedule_save() {
    SAVE.with(|s| {
        if let Some(id) = s.borrow_mut().take() {
            id.remove();
        }
        let id = gtk::glib::timeout_add_local_once(Duration::from_millis(400), || {
            SAVE.with(|s| s.borrow_mut().take());
            shared().flush();
        });
        *s.borrow_mut() = Some(id);
    });
}

pub fn flush() {
    let pending = SAVE.with(|s| s.borrow_mut().take());
    if let Some(id) = pending {
        id.remove();
        shared().flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file() -> PathBuf {
        std::env::temp_dir().join(format!("pullyard-stack-notes-{}.json", uuid::Uuid::new_v4().simple()))
    }

    #[test]
    fn notes_survive_reload() {
        let file = temp_file();
        let store = NotesStore::open(file.clone());
        let k = key("me", "github.com", &RepoRef::new("Acme", "App"), 7);
        assert!(store.replace(&k, &[StackNote::new(NoteKind::Decision, "Merge API first")]));
        store.flush_blocking().unwrap();
        let reloaded = NotesStore::open(file.clone());
        assert_eq!(reloaded.notes(&k).iter().map(|n| n.text.clone()).collect::<Vec<_>>(), vec!["Merge API first"]);
        assert_eq!(reloaded.notes(&k)[0].kind, NoteKind::Decision);
        assert!(reloaded.has_notes(&k));
        let _ = std::fs::remove_file(file);
    }

    #[test]
    fn empty_drafts_are_not_stored() {
        let store = NotesStore::open(temp_file());
        assert!(!store.replace("k", &[StackNote::new(NoteKind::Note, ""), StackNote::new(NoteKind::Note, "  \n")]));
        assert!(store.notes("k").is_empty());
        assert!(!store.has_notes("k"));
    }

    #[test]
    fn key_separates_accounts() {
        assert_ne!(key("alice", "github.com", &RepoRef::new("acme", "app"), 1), key("bob", "github.com", &RepoRef::new("acme", "app"), 1));
    }

    #[test]
    fn sourced_notes_round_trip_and_old_files_still_load() {
        let file = temp_file();
        let store = NotesStore::open(file.clone());
        let entry = super::super::mcp::Entry { key: "k".into(), kind: NoteKind::Question, text: "Why?".into(), created: Utc::now() };
        assert_eq!(store.import(std::slice::from_ref(&entry)), vec!["k".to_string()]);
        store.flush_blocking().unwrap();
        let reloaded = NotesStore::open(file.clone());
        assert_eq!(reloaded.notes("k")[0].source.as_deref(), Some("Claude"));
        let _ = std::fs::remove_file(&file);
        std::fs::write(&file, r#"{"k":[{"id":"a","kind":"note","text":"old","updated":"2024-01-01T00:00:00Z"}]}"#).unwrap();
        assert_eq!(NotesStore::open(file.clone()).notes("k")[0].source, None);
        let _ = std::fs::remove_file(file);
    }

    #[test]
    fn key_ignores_repo_case() {
        assert_eq!(key("me", "github.com", &RepoRef::new("Acme", "App"), 1), key("me", "github.com", &RepoRef::new("acme", "app"), 1));
    }

    #[test]
    fn replace_keeps_unchanged_timestamp_and_drops_removed() {
        let store = NotesStore::open(temp_file());
        let old = DateTime::<Utc>::from_timestamp(1, 0).unwrap();
        let a = StackNote { updated: old, ..StackNote::new(NoteKind::Note, "one") };
        let b = StackNote { updated: old, ..StackNote::new(NoteKind::Note, "two") };
        store.replace("k", &[a, b]);
        let stamped = store.notes("k")[0].updated;
        let mut edited = store.notes("k")[1].clone();
        edited.text = "two!".into();
        store.replace("k", &[store.notes("k")[0].clone(), edited]);
        assert_eq!(store.notes("k")[0].updated, stamped);
        assert_eq!(store.notes("k")[1].text, "two!");
        assert!(!store.replace("k", &store.notes("k")));
        store.replace("k", &[store.notes("k")[1].clone()]);
        assert_eq!(store.notes("k").iter().map(|n| n.text.clone()).collect::<Vec<_>>(), vec!["two!"]);
    }
}
