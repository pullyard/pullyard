use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::notes::{self, NoteKind, StackNote};
use crate::brand;

pub const FLAG: &str = "--mcp-stack-notes";
pub const SERVER_NAME: &str = "pullyard";
pub const SOURCE: &str = "Claude";
const VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_CHARS: usize = 4000;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Entry {
    pub key: String,
    pub kind: NoteKind,
    pub text: String,
    pub created: DateTime<Utc>,
}

impl Entry {
    pub fn note(&self) -> StackNote {
        StackNote { updated: self.created, source: Some(SOURCE.to_string()), ..StackNote::new(self.kind, &self.text) }
    }
}

pub fn inbox_dir() -> PathBuf {
    crate::settings::data_dir().join("stack-notes-inbox")
}

pub fn notes_file() -> PathBuf {
    crate::settings::data_dir().join("stack-notes.json")
}

fn create_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    Ok(())
}

pub fn drop_entry(dir: &Path, entry: &Entry) -> std::io::Result<()> {
    create_dir(dir)?;
    let data = serde_json::to_vec(entry).map_err(std::io::Error::other)?;
    let tmp = dir.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    if let Err(e) = std::fs::write(&tmp, data) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    let target = dir.join(format!("{}.json", uuid::Uuid::new_v4()));
    std::fs::rename(&tmp, target).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

fn json_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "json")).collect()).unwrap_or_default()
}

fn decode(path: &Path) -> Option<Entry> {
    std::fs::read(path).ok().and_then(|d| serde_json::from_slice(&d).ok())
}

pub fn peek(dir: &Path) -> Vec<Entry> {
    let mut out: Vec<Entry> = json_files(dir).iter().filter_map(|p| decode(p)).collect();
    out.sort_by(|a, b| a.created.cmp(&b.created));
    out
}

pub fn drain(dir: &Path) -> Vec<Entry> {
    let mut out = vec![];
    for file in json_files(dir) {
        if let Some(e) = decode(&file) {
            out.push(e);
        }
        let _ = std::fs::remove_file(&file);
    }
    out.sort_by(|a, b| a.created.cmp(&b.created));
    out
}

pub fn read(file: &Path, dir: &Path, key: &str) -> Vec<StackNote> {
    let mut saved = notes::NotesStore::open(file.to_path_buf()).notes(key);
    saved.extend(peek(dir).into_iter().filter(|e| e.key == key).map(|e| e.note()));
    saved
}

pub struct Server {
    pub account: Option<String>,
    pub host: String,
    pub file: PathBuf,
    pub inbox: PathBuf,
}

fn value_after(args: &[String], name: &str) -> Option<String> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).cloned()
}

impl Server {
    pub fn from_args(args: &[String]) -> Self {
        Server { account: value_after(args, "--account"), host: value_after(args, "--host").unwrap_or_else(|| "github.com".into()), file: notes_file(), inbox: inbox_dir() }
    }

    pub fn handle(&self, message: &Value) -> Option<Value> {
        let id = message.get("id")?.clone();
        let empty = json!({});
        let params = message.get("params").filter(|p| p.is_object()).unwrap_or(&empty);
        match message.get("method").and_then(|m| m.as_str()) {
            Some("initialize") => {
                let asked = params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or("");
                let version = if VERSIONS.contains(&asked) { asked } else { VERSIONS[0] };
                Some(result(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": { "tools": {} },
                        "serverInfo": { "name": SERVER_NAME, "version": "1.0" },
                        "instructions": format!("{} stack notes. Use add_stack_note when the user asks you to leave a note, question or decision on a pull request in their stack, or when you finish work on a stacked PR and something is worth remembering for the reviewer. Notes stay on the user's computer and are never posted to GitHub.", brand::APP_NAME),
                    }),
                ))
            }
            Some("ping") => Some(result(id, json!({}))),
            Some("tools/list") => Some(result(id, json!({ "tools": tools() }))),
            Some("tools/call") => {
                let name = params.get("name").and_then(|v| v.as_str());
                let args = params.get("arguments").filter(|a| a.is_object()).cloned().unwrap_or_else(|| json!({}));
                Some(self.call(id, name, &args))
            }
            _ => Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } })),
        }
    }

    fn call(&self, id: Value, name: Option<&str>, args: &Value) -> Value {
        let repo = args.get("repo").and_then(|v| v.as_str()).unwrap_or("");
        let number = args.get("pr").and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))).unwrap_or(0);
        let valid_repo = repo.split('/').count() == 2 && repo.split('/').all(|p| !p.is_empty());
        if !valid_repo || number <= 0 {
            return text(id, "Pass repo as \"owner/name\" and pr as the pull request number.", true);
        }
        let key = notes::key_for(self.account.as_deref().unwrap_or(""), &self.host, repo, number);
        match name {
            Some("add_stack_note") => {
                let body = args.get("text").and_then(|v| v.as_str()).unwrap_or("").trim();
                if body.is_empty() {
                    return text(id, "text is empty", true);
                }
                if body.chars().count() > MAX_CHARS {
                    return text(id, "Keep notes under 4000 characters.", true);
                }
                let kind = args.get("kind").and_then(|v| serde_json::from_value::<NoteKind>(v.clone()).ok()).unwrap_or_default();
                let entry = Entry { key, kind, text: body.to_string(), created: Utc::now() };
                match drop_entry(&self.inbox, &entry) {
                    Ok(()) => text(id, &format!("Added a {} to {repo}#{number}. It shows on the PR's card in {}'s Stack tab.", kind_name(kind), brand::APP_NAME), false),
                    Err(e) => text(id, &format!("Couldn't save the note: {e}"), true),
                }
            }
            Some("list_stack_notes") => {
                let list = read(&self.file, &self.inbox, &key);
                if list.is_empty() {
                    return text(id, &format!("No notes on {repo}#{number}."), false);
                }
                let lines: Vec<String> = list.iter().map(|n| format!("- [{}] {}", kind_name(n.kind), n.text)).collect();
                text(id, &lines.join("\n"), false)
            }
            _ => text(id, "Unknown tool", true),
        }
    }
}

fn kind_name(kind: NoteKind) -> &'static str {
    match kind {
        NoteKind::Note => "note",
        NoteKind::Question => "question",
        NoteKind::Decision => "decision",
    }
}

fn result(id: Value, value: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": value })
}

fn text(id: Value, s: &str, error: bool) -> Value {
    result(id, json!({ "content": [{ "type": "text", "text": s }], "isError": error }))
}

pub fn tools() -> Value {
    let target = json!({
        "repo": { "type": "string", "description": "Repository as owner/name, e.g. pullyard/pullyard" },
        "pr": { "type": "integer", "description": "Pull request number" },
    });
    let mut add = target.clone();
    add["kind"] = json!({ "type": "string", "enum": ["note", "question", "decision"], "description": "note (default), question or decision" });
    add["text"] = json!({ "type": "string", "description": "The note text, plain text or short Markdown" });
    json!([
        {
            "name": "add_stack_note",
            "description": format!("Add a note, question or decision to a pull request card in the user's {} Stack view. Local to the user's computer, never posted to GitHub.", brand::APP_NAME),
            "inputSchema": { "type": "object", "properties": add, "required": ["repo", "pr", "text"] },
        },
        {
            "name": "list_stack_notes",
            "description": format!("List the {} stack notes on a pull request.", brand::APP_NAME),
            "inputSchema": { "type": "object", "properties": target, "required": ["repo", "pr"] },
            "annotations": { "readOnlyHint": true },
        },
    ])
}

pub fn run(args: &[String]) -> i32 {
    let server = Server::from_args(args);
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(line) else { continue };
        if !message.is_object() {
            continue;
        }
        if let Some(reply) = server.handle(&message) {
            if writeln!(out, "{reply}").and_then(|_| out.flush()).is_err() {
                break;
            }
        }
    }
    0
}

pub fn command(host: &str, account: &str) -> Option<(String, Vec<String>)> {
    let mut args = vec![];
    let program = if crate::util::is_flatpak() {
        let app_id = std::env::var("FLATPAK_ID").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| brand::APP_ID.to_string());
        args.push("run".to_string());
        args.push(format!("--command={}", brand::BIN_NAME));
        args.push(app_id);
        "flatpak".to_string()
    } else {
        std::env::current_exe().ok()?.to_string_lossy().trim_end_matches(" (deleted)").to_string()
    };
    args.extend([FLAG.to_string(), "--host".to_string(), host.to_string(), "--account".to_string(), account.to_string()]);
    Some((program, args))
}

pub fn config(host: &str, account: &str) -> Option<String> {
    let (program, args) = command(host, account)?;
    let server = json!({ "type": "stdio", "command": program, "args": args });
    serde_json::to_string(&json!({ "mcpServers": { SERVER_NAME: server } })).ok()
}

pub fn chat_args() -> Vec<String> {
    let Some(api) = crate::app::api() else { return vec![] };
    match config(api.host(), &crate::app::cache_account()) {
        Some(json) => vec!["--mcp-config".to_string(), json],
        None => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server() -> Server {
        let base = std::env::temp_dir().join(format!("pullyard-mcp-{}", uuid::Uuid::new_v4().simple()));
        Server { account: Some("Me".into()), host: "github.com".into(), file: base.join("stack-notes.json"), inbox: base.join("inbox") }
    }

    fn call(s: &Server, name: &str, args: Value) -> Value {
        s.handle(&json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": { "name": name, "arguments": args } })).unwrap()
    }

    fn reply_text(v: &Value) -> String {
        v["result"]["content"][0]["text"].as_str().unwrap_or_default().to_string()
    }

    #[test]
    fn initialize_negotiates_version() {
        let s = server();
        let r = s.handle(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-03-26" } })).unwrap();
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["serverInfo"]["name"], SERVER_NAME);
        let r = s.handle(&json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": { "protocolVersion": "1999-01-01" } })).unwrap();
        assert_eq!(r["result"]["protocolVersion"], VERSIONS[0]);
        assert!(s.handle(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })).is_none());
        let r = s.handle(&json!({ "jsonrpc": "2.0", "id": "x", "method": "nope" })).unwrap();
        assert_eq!(r["error"]["code"], -32601);
    }

    #[test]
    fn tools_list_matches_schema() {
        let s = server();
        let r = s.handle(&json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" })).unwrap();
        let tools = r["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 2);
        assert_eq!(tools[0]["name"], "add_stack_note");
        assert_eq!(tools[0]["inputSchema"]["required"], json!(["repo", "pr", "text"]));
        assert_eq!(tools[1]["annotations"]["readOnlyHint"], true);
    }

    #[test]
    fn add_then_list_and_drain() {
        let s = server();
        let r = call(&s, "add_stack_note", json!({ "repo": "Acme/App", "pr": "7", "kind": "decision", "text": "  Merge API first " }));
        assert_eq!(r["result"]["isError"], false);
        let listed = call(&s, "list_stack_notes", json!({ "repo": "acme/app", "pr": 7 }));
        assert_eq!(reply_text(&listed), "- [decision] Merge API first");
        let entries = drain(&s.inbox);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].key, "me|github.com|acme/app#7");
        assert_eq!(entries[0].note().source.as_deref(), Some(SOURCE));
        assert!(peek(&s.inbox).is_empty());
        let _ = std::fs::remove_dir_all(s.inbox.parent().unwrap());
    }

    #[test]
    fn rejects_bad_arguments() {
        let s = server();
        assert_eq!(call(&s, "add_stack_note", json!({ "repo": "acme", "pr": 1, "text": "x" }))["result"]["isError"], true);
        assert_eq!(call(&s, "add_stack_note", json!({ "repo": "acme/app", "pr": 0, "text": "x" }))["result"]["isError"], true);
        assert_eq!(call(&s, "add_stack_note", json!({ "repo": "acme/app", "pr": 1, "text": "  " }))["result"]["isError"], true);
        assert_eq!(call(&s, "add_stack_note", json!({ "repo": "acme/app", "pr": 1, "text": "x".repeat(MAX_CHARS + 1) }))["result"]["isError"], true);
        assert_eq!(reply_text(&call(&s, "list_stack_notes", json!({ "repo": "acme/app", "pr": 2 }))), "No notes on acme/app#2.");
        assert_eq!(call(&s, "other", json!({ "repo": "acme/app", "pr": 2 }))["result"]["isError"], true);
    }

    #[test]
    fn config_points_at_this_binary() {
        let json = config("github.com", "me").unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        let server = &v["mcpServers"][SERVER_NAME];
        assert_eq!(server["type"], "stdio");
        let args: Vec<String> = server["args"].as_array().unwrap().iter().map(|a| a.as_str().unwrap().to_string()).collect();
        assert!(args.ends_with(&[FLAG.into(), "--host".into(), "github.com".into(), "--account".into(), "me".into()]));
    }
}
