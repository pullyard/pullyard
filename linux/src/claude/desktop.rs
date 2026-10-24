use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::SystemTime;

use serde::Deserialize;

#[derive(Clone, Debug, PartialEq)]
struct Record {
    local: String,
    cli: String,
    parent_local: Option<String>,
    title: Option<String>,
    archived: bool,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Link {
    pub local: Option<String>,
    pub parent: Option<String>,
    pub title: Option<String>,
    pub archived: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Spawned {
    session_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fields {
    session_id: Option<String>,
    cli_session_id: Option<String>,
    spawned_from: Option<Spawned>,
    forked_from_session_id: Option<String>,
    title: Option<String>,
    is_archived: Option<bool>,
}

type Cache = HashMap<PathBuf, (SystemTime, Option<Record>)>;

static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(|| Mutex::new(HashMap::new()));

pub fn directory() -> PathBuf {
    gtk::glib::user_config_dir().join("Claude").join("claude-code-sessions")
}

fn record(file: &Path) -> Option<Record> {
    let mtime = std::fs::metadata(file).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
    if let Ok(cache) = CACHE.lock() {
        if let Some((t, r)) = cache.get(file) {
            if *t == mtime {
                return r.clone();
            }
        }
    }
    let r = std::fs::read(file).ok().and_then(|d| serde_json::from_slice::<Fields>(&d).ok()).and_then(|f| {
        let local = f.session_id?;
        let cli = f.cli_session_id?;
        Some(Record { local, cli, parent_local: f.spawned_from.and_then(|s| s.session_id).or(f.forked_from_session_id), title: f.title, archived: f.is_archived.unwrap_or(false) })
    });
    if let Ok(mut cache) = CACHE.lock() {
        cache.insert(file.to_path_buf(), (mtime, r.clone()));
    }
    r
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()).unwrap_or_default()
}

pub fn load() -> HashMap<String, Link> {
    load_from(&directory())
}

pub fn load_from(dir: &Path) -> HashMap<String, Link> {
    let mut records: Vec<Record> = vec![];
    let mut seen: HashSet<PathBuf> = HashSet::new();
    if dir.is_dir() {
        for account in subdirs(dir) {
            for org in subdirs(&account) {
                let Ok(files) = std::fs::read_dir(&org) else {
                    continue;
                };
                for f in files.flatten() {
                    let p = f.path();
                    if p.extension().map(|e| e == "json").unwrap_or(false) {
                        seen.insert(p.clone());
                        if let Some(r) = record(&p) {
                            records.push(r);
                        }
                    }
                }
            }
        }
    }
    if let Ok(mut cache) = CACHE.lock() {
        cache.retain(|k, _| !k.starts_with(dir) || seen.contains(k));
    }
    let mut cli_by_local: HashMap<String, String> = HashMap::new();
    for r in &records {
        cli_by_local.entry(r.local.clone()).or_insert_with(|| r.cli.clone());
    }
    let mut out = HashMap::new();
    for r in records {
        let parent = r.parent_local.as_ref().and_then(|p| cli_by_local.get(p).cloned());
        out.insert(r.cli, Link { local: Some(r.local), parent, title: r.title, archived: r.archived });
    }
    out
}

pub fn can_open() -> bool {
    gtk::gio::AppInfo::default_for_uri_scheme("claude").is_some()
}

pub fn open(local_id: &str) {
    let mut url = url::Url::parse("claude://code/continue").expect("url");
    url.query_pairs_mut().append_pair("session", local_id);
    let _ = gtk::gio::AppInfo::launch_default_for_uri(url.as_str(), None::<&gtk::gio::AppLaunchContext>);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_children_to_parents() {
        let dir = std::env::temp_dir().join(format!("sy-desktop-{}", uuid::Uuid::new_v4()));
        let org = dir.join("acct").join("org");
        std::fs::create_dir_all(&org).unwrap();
        std::fs::write(org.join("a.json"), r#"{"sessionId":"local_a","cliSessionId":"cli-a","title":"Parent"}"#).unwrap();
        std::fs::write(org.join("b.json"), r#"{"sessionId":"local_b","cliSessionId":"cli-b","spawnedFrom":{"sessionId":"local_a"},"isArchived":true}"#).unwrap();
        std::fs::write(org.join("c.json"), r#"{"sessionId":"local_c","cliSessionId":"cli-c","forkedFromSessionId":"local_missing"}"#).unwrap();
        std::fs::write(org.join("bad.json"), "not json").unwrap();
        let map = load_from(&dir);
        assert_eq!(map.len(), 3);
        assert_eq!(map["cli-a"].title.as_deref(), Some("Parent"));
        assert_eq!(map["cli-b"].parent.as_deref(), Some("cli-a"));
        assert!(map["cli-b"].archived);
        assert_eq!(map["cli-c"].parent, None);
        assert_eq!(map["cli-a"].local.as_deref(), Some("local_a"));
        assert!(load_from(&dir.join("missing")).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }
}
