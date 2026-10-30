use std::path::{Path, PathBuf};

use serde_json::Value;

pub fn session_file(id: &str, roots: &[PathBuf]) -> Option<PathBuf> {
    if id.is_empty() || id.contains('/') {
        return None;
    }
    for root in roots {
        let Ok(dirs) = std::fs::read_dir(root) else {
            continue;
        };
        for dir in dirs.flatten() {
            let file = dir.path().join(format!("{id}.jsonl"));
            if file.is_file() {
                return Some(file);
            }
        }
    }
    None
}

pub fn prompt_text(o: &Value) -> Option<String> {
    let flag = |k: &str| o.get(k).and_then(|v| v.as_bool()) == Some(true);
    if o.get("type").and_then(|t| t.as_str()) != Some("user") || flag("isSidechain") || flag("isMeta") || flag("isCompactSummary") {
        return None;
    }
    let content = o.get("message")?.get("content")?;
    if let Some(text) = content.as_str() {
        let clean = super::chat::clean_user_text(text);
        if super::chat::is_hidden_prompt(&clean) || clean.starts_with("<task-notification>") || clean.starts_with("[Request interrupted by user") {
            return None;
        }
        return Some(clean);
    }
    let blocks = content.as_array()?;
    if blocks.iter().any(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result")) {
        return None;
    }
    let texts: Vec<&str> = blocks
        .iter()
        .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
        .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
        .filter(|t| !t.starts_with('<'))
        .collect();
    if texts.is_empty() {
        return None;
    }
    let clean = super::chat::clean_user_text(&texts.join("\n"));
    if super::chat::is_hidden_prompt(&clean) || clean.starts_with("<task-notification>") || clean.starts_with("[Request interrupted by user") {
        return None;
    }
    Some(clean)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && hay.windows(needle.len()).any(|w| w == needle)
}

fn replace_all(line: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(line.len());
    let mut i = 0;
    while i < line.len() {
        if !from.is_empty() && line[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(line[i]);
            i += 1;
        }
    }
    out
}

pub fn cut_index(lines: &[&[u8]], text: &str, occurrence_from_end: usize) -> Option<usize> {
    let target = text.trim();
    let mut seen = 0;
    for i in (0..lines.len()).rev() {
        if !contains(lines[i], b"\"user\"") {
            continue;
        }
        let Ok(o) = serde_json::from_slice::<Value>(lines[i]) else {
            continue;
        };
        let Some(t) = prompt_text(&o) else { continue };
        if t.trim() != target {
            continue;
        }
        if seen == occurrence_from_end {
            return Some(i);
        }
        seen += 1;
    }
    None
}

pub fn fork_bytes(data: &[u8], old_id: &str, new_id: &str, text: &str, occurrence_from_end: usize) -> Result<Vec<u8>, String> {
    let lines: Vec<&[u8]> = data.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect();
    let cut = cut_index(&lines, text, occurrence_from_end).ok_or_else(|| "Couldn't find this message in the session file".to_string())?;
    let from = format!("\"sessionId\":\"{old_id}\"");
    let to = format!("\"sessionId\":\"{new_id}\"");
    let mut out = Vec::with_capacity(data.len());
    for line in &lines[..cut] {
        out.extend_from_slice(&replace_all(line, from.as_bytes(), to.as_bytes()));
        out.push(b'\n');
    }
    Ok(out)
}

pub fn fork(file: &Path, text: &str, occurrence_from_end: usize) -> Result<(String, PathBuf), String> {
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let old_id = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let new_id = uuid::Uuid::new_v4().to_string().to_lowercase();
    let out = fork_bytes(&data, &old_id, &new_id, text, occurrence_from_end)?;
    let dir = file.parent().ok_or_else(|| "Session folder not found".to_string())?;
    let target = dir.join(format!("{new_id}.jsonl"));
    let tmp = dir.join(format!(".{new_id}.jsonl.tmp"));
    std::fs::write(&tmp, &out).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &target).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })?;
    Ok((new_id, target))
}

#[cfg(test)]
mod tests {
    use super::*;

    const OLD: &str = "aaaa-1111";

    fn session() -> String {
        [
            format!(r#"{{"type":"summary","summary":"x","sessionId":"{OLD}"}}"#),
            format!(r#"{{"type":"user","sessionId":"{OLD}","uuid":"u1","message":{{"role":"user","content":"Fix the bug"}}}}"#),
            format!(r#"{{"type":"assistant","sessionId":"{OLD}","uuid":"a1","message":{{"content":[{{"type":"text","text":"Done"}}]}}}}"#),
            format!(r#"{{"type":"user","sessionId":"{OLD}","uuid":"t1","message":{{"content":[{{"type":"tool_result","tool_use_id":"x","content":"Fix the bug"}}]}}}}"#),
            format!(r#"{{"type":"user","sessionId":"{OLD}","uuid":"u2","message":{{"content":[{{"type":"text","text":"Fix the bug"}}]}}}}"#),
            format!(r#"{{"type":"assistant","sessionId":"{OLD}","uuid":"a2","message":{{"content":[{{"type":"text","text":"Again"}}]}}}}"#),
            format!(r#"{{"type":"user","sessionId":"{OLD}","uuid":"u3","isMeta":true,"message":{{"content":"Fix the bug"}}}}"#),
        ]
        .join("\n")
            + "\n"
    }

    #[test]
    fn prompt_text_skips_meta_and_tool_results() {
        let user: Value = serde_json::from_str(r#"{"type":"user","message":{"content":"  hi  "}}"#).unwrap();
        assert_eq!(prompt_text(&user).as_deref(), Some("hi"));
        let meta: Value = serde_json::from_str(r#"{"type":"user","isMeta":true,"message":{"content":"hi"}}"#).unwrap();
        assert_eq!(prompt_text(&meta), None);
        let cmd: Value = serde_json::from_str(r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#).unwrap();
        assert_eq!(prompt_text(&cmd), None);
        let blocks: Value =
            serde_json::from_str(r#"{"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"<ide>x</ide>"},{"type":"text","text":"b"}]}}"#).unwrap();
        assert_eq!(prompt_text(&blocks).as_deref(), Some("a\nb"));
    }

    #[test]
    fn forks_before_latest_occurrence() {
        let data = session();
        let out = String::from_utf8(fork_bytes(data.as_bytes(), OLD, "bbbb-2222", "Fix the bug", 0).unwrap()).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 4);
        assert!(lines.iter().all(|l| l.contains("\"sessionId\":\"bbbb-2222\"")));
        assert!(!out.contains(OLD));
        assert!(lines[3].contains("\"t1\""));
    }

    #[test]
    fn forks_before_earlier_occurrence() {
        let data = session();
        let out = String::from_utf8(fork_bytes(data.as_bytes(), OLD, "new", " Fix the bug\n", 1).unwrap()).unwrap();
        assert_eq!(out.lines().count(), 1);
        assert!(out.contains("\"summary\""));
    }

    #[test]
    fn missing_prompt_is_an_error() {
        let data = session();
        assert!(fork_bytes(data.as_bytes(), OLD, "new", "Something else", 0).is_err());
        assert!(fork_bytes(data.as_bytes(), OLD, "new", "Fix the bug", 2).is_err());
    }

    #[test]
    fn fork_writes_new_file_next_to_original() {
        let dir = std::env::temp_dir().join(format!("rewind-test-{}", uuid::Uuid::new_v4()));
        let project = dir.join("proj");
        std::fs::create_dir_all(&project).unwrap();
        let file = project.join(format!("{OLD}.jsonl"));
        std::fs::write(&file, session()).unwrap();
        assert_eq!(session_file(OLD, std::slice::from_ref(&dir)).as_deref(), Some(file.as_path()));
        let (id, target) = fork(&file, "Fix the bug", 0).unwrap();
        assert_eq!(target, project.join(format!("{id}.jsonl")));
        let written = std::fs::read_to_string(&target).unwrap();
        assert!(written.contains(&format!("\"sessionId\":\"{id}\"")));
        assert_eq!(session_file(&id, std::slice::from_ref(&dir)).as_deref(), Some(target.as_path()));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
