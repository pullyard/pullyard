use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use serde_json::Value;

const BLOB_BUDGET: usize = 48 * 1024 * 1024;

pub struct SessionIndex {
    dir: PathBuf,
    stamps: HashMap<String, String>,
    blobs: HashMap<String, (String, Arc<Vec<u8>>)>,
    blob_bytes: usize,
    loaded: bool,
}

static SHARED: LazyLock<Mutex<SessionIndex>> = LazyLock::new(|| Mutex::new(SessionIndex::new(crate::settings::cache_dir().join("session-index"))));

pub fn shared() -> &'static Mutex<SessionIndex> {
    &SHARED
}

pub fn key(file: &Path) -> String {
    let mut h: u64 = 1469598103934665603;
    for b in file.to_string_lossy().bytes() {
        h = (h ^ b as u64).wrapping_mul(1099511628211);
    }
    let mut g: u64 = 0x9e3779b97f4a7c15;
    for b in file.to_string_lossy().bytes().rev() {
        g = (g ^ b as u64).wrapping_mul(0x100000001b3).rotate_left(5);
    }
    format!("{h:016x}{:08x}", g as u32)
}

fn stamp(file: &Path) -> Option<String> {
    let m = std::fs::metadata(file).ok()?;
    let secs = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    Some(format!("{secs}-{}", m.len()))
}

pub fn snippet(data: &[u8], start: usize, end: usize) -> String {
    let from = start.saturating_sub(90);
    let to = (end + 140).min(data.len());
    let mut text = String::from_utf8_lossy(&data[from..to]).to_string();
    text = text.trim_matches('\u{FFFD}').replace('\n', " ");
    format!("{}{}{}", if from > 0 { "…" } else { "" }, text, if to < data.len() { "…" } else { "" })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    let first = needle[0];
    let last = haystack.len() - needle.len();
    let mut i = 0;
    while i <= last {
        match haystack[i..=last].iter().position(|b| *b == first) {
            Some(off) => {
                let at = i + off;
                if &haystack[at..at + needle.len()] == needle {
                    return Some(at);
                }
                i = at + 1;
            }
            None => return None,
        }
    }
    None
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    find(haystack, needle).is_some()
}

fn clean(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() || s.starts_with("<command-name>") || s.starts_with("<local-command") || s.starts_with("<task-notification>") || s.starts_with("Caveat:") || s.starts_with("[Request interrupted") || s.starts_with("<system-reminder>") {
        return None;
    }
    Some(s.to_string())
}

pub fn prompt_text(o: &Value) -> Option<String> {
    if o.get("type").and_then(|t| t.as_str()) != Some("user") {
        return None;
    }
    for flag in ["isSidechain", "isMeta", "isCompactSummary"] {
        if o.get(flag).and_then(|v| v.as_bool()) == Some(true) {
            return None;
        }
    }
    let content = o.get("message")?.get("content")?;
    if let Some(s) = content.as_str() {
        return clean(s);
    }
    let blocks = content.as_array()?;
    if blocks.iter().any(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result")) {
        return None;
    }
    let texts: Vec<&str> =
        blocks.iter().filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text")).filter_map(|b| b.get("text").and_then(|t| t.as_str())).filter(|t| !t.starts_with('<')).collect();
    if texts.is_empty() {
        return None;
    }
    clean(&texts.join("\n"))
}

pub fn extract(file: &Path) -> String {
    let Ok(data) = std::fs::read(file) else {
        return String::new();
    };
    extract_bytes(&data)
}

pub fn extract_bytes(data: &[u8]) -> String {
    let user = b"\"type\":\"user\"";
    let assistant = b"\"type\":\"assistant\"";
    let tool_result = b"\"tool_use_id\"";
    let mut parts: Vec<String> = vec![];
    for line in data.split(|b| *b == b'\n') {
        if line.is_empty() || line.len() >= 400_000 {
            continue;
        }
        let is_user = contains(line, user);
        if !is_user && !contains(line, assistant) {
            continue;
        }
        if is_user && contains(line, tool_result) {
            continue;
        }
        let Ok(o) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if is_user {
            if let Some(t) = prompt_text(&o) {
                parts.push(t);
            }
        } else if let Some(blocks) = o.get("message").and_then(|m| m.get("content")).and_then(|c| c.as_array()) {
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(t) = b.get("text").and_then(|t| t.as_str()).filter(|t| !t.is_empty()) {
                        parts.push(t.to_string());
                    }
                }
            }
        }
    }
    parts.join("\n").to_lowercase()
}

impl SessionIndex {
    pub fn new(dir: PathBuf) -> Self {
        SessionIndex { dir, stamps: HashMap::new(), blobs: HashMap::new(), blob_bytes: 0, loaded: false }
    }

    fn stamps_file(&self) -> PathBuf {
        self.dir.join("stamps.json")
    }

    fn load(&mut self) {
        if self.loaded {
            return;
        }
        self.loaded = true;
        let _ = std::fs::create_dir_all(&self.dir);
        if let Some(s) = std::fs::read(self.stamps_file()).ok().and_then(|d| serde_json::from_slice::<HashMap<String, String>>(&d).ok()) {
            self.stamps = s;
        }
    }

    fn save(&self) {
        if let Ok(data) = serde_json::to_vec(&self.stamps) {
            let tmp = self.dir.join("stamps.json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, self.stamps_file());
            }
        }
    }

    pub fn update(&mut self, files: &[PathBuf]) {
        self.load();
        let mut changed = false;
        for file in files {
            let path = file.to_string_lossy().to_string();
            let Some(st) = stamp(file) else { continue };
            if self.stamps.get(&path) == Some(&st) {
                continue;
            }
            let text = extract(file);
            if std::fs::write(self.dir.join(format!("{}.txt", key(file))), text.as_bytes()).is_ok() {
                self.stamps.insert(path.clone(), st);
                if let Some((_, old)) = self.blobs.remove(&path) {
                    self.blob_bytes = self.blob_bytes.saturating_sub(old.len());
                }
                changed = true;
            }
        }
        if changed {
            self.save();
        }
    }

    pub fn missing(&mut self, files: &[PathBuf]) -> Vec<PathBuf> {
        self.load();
        files.iter().filter(|f| !self.stamps.contains_key(&*f.to_string_lossy())).cloned().collect()
    }

    fn blob(&mut self, file: &Path) -> Option<Arc<Vec<u8>>> {
        let path = file.to_string_lossy().to_string();
        let st = self.stamps.get(&path)?.clone();
        if let Some((s, data)) = self.blobs.get(&path) {
            if *s == st {
                return Some(data.clone());
            }
        }
        let data = Arc::new(std::fs::read(self.dir.join(format!("{}.txt", key(file)))).ok()?);
        if self.blob_bytes + data.len() > BLOB_BUDGET {
            self.blobs.clear();
            self.blob_bytes = 0;
        }
        self.blob_bytes += data.len();
        if let Some((_, old)) = self.blobs.insert(path, (st, data.clone())) {
            self.blob_bytes = self.blob_bytes.saturating_sub(old.len());
        }
        Some(data)
    }

    pub fn search(&mut self, query: &str, files: &[PathBuf], generation: &AtomicU64, id: u64) -> HashMap<PathBuf, String> {
        self.load();
        let missing = self.missing(files);
        let stale: Vec<PathBuf> = files.iter().filter(|f| self.stamps.get(&*f.to_string_lossy()).is_some_and(|s| Some(s) != stamp(f).as_ref())).cloned().collect();
        let mut todo = missing;
        if stale.len() <= 6 {
            todo.extend(stale);
        }
        for chunk in todo.chunks(10) {
            if generation.load(Ordering::Relaxed) != id {
                return HashMap::new();
            }
            self.update(chunk);
        }
        let needle = query.to_lowercase().into_bytes();
        let mut out = HashMap::new();
        for (i, file) in files.iter().enumerate() {
            if i % 32 == 0 && generation.load(Ordering::Relaxed) != id {
                return out;
            }
            let Some(data) = self.blob(file) else {
                continue;
            };
            if let Some(at) = find(&data, &needle) {
                out.insert(file.clone(), snippet(&data, at, at + needle.len()));
            }
        }
        out
    }

    pub fn release(&mut self) {
        self.blobs.clear();
        self.blob_bytes = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_prompts_and_answers() {
        let data = concat!(
            "{\"type\":\"user\",\"message\":{\"content\":\"Fix The Parser\"}}\n",
            "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"meta noise\"}}\n",
            "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"tool noise\"}]}}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Done with the Lexer\"},{\"type\":\"tool_use\",\"name\":\"Bash\"}]}}\n",
            "{\"type\":\"user\",\"message\":{\"content\":\"<command-name>/clear</command-name>\"}}\n",
            "{\"type\":\"summary\",\"summary\":\"skip me\"}\n"
        );
        let text = extract_bytes(data.as_bytes());
        assert_eq!(text, "fix the parser\ndone with the lexer");
    }

    #[test]
    fn searches_with_snippets_and_cache() {
        let root = std::env::temp_dir().join(format!("sy-index-{}", uuid::Uuid::new_v4()));
        let sessions = root.join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let a = sessions.join("a.jsonl");
        let b = sessions.join("b.jsonl");
        std::fs::write(&a, "{\"type\":\"user\",\"message\":{\"content\":\"please migrate the database schema\"}}\n").unwrap();
        std::fs::write(&b, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"unrelated answer\"}]}}\n").unwrap();
        let mut index = SessionIndex::new(root.join("cache"));
        let generation = AtomicU64::new(1);
        let files = vec![a.clone(), b.clone()];
        let hits = index.search("Database", &files, &generation, 1);
        assert_eq!(hits.len(), 1);
        assert!(hits[&a].contains("database schema"));
        assert!(index.missing(&files).is_empty());
        let mut reopened = SessionIndex::new(root.join("cache"));
        assert!(reopened.missing(&files).is_empty());
        generation.store(2, Ordering::Relaxed);
        assert!(reopened.search("database", &files, &generation, 1).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn snippet_bounds() {
        let data = b"short text here";
        assert_eq!(snippet(data, 6, 10), "short text here");
        let long = vec![b'a'; 400];
        let s = snippet(&long, 200, 201);
        assert!(s.starts_with('…') && s.ends_with('…'));
        assert_eq!(find(b"abcabd", b"abd"), Some(3));
        assert_eq!(find(b"ab", b"abc"), None);
    }
}
