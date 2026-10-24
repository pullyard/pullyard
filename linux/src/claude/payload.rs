use serde_json::{Map, Value};

pub const MAX_RESULT_LENGTH: usize = 64_000;

pub fn is_auth_error(text: &str) -> bool {
    let s = text.to_lowercase();
    ["/login", "log in", "logged in", "not logged", "authentication", "invalid api key", "api key", "oauth", "401", "credential", "token has expired", "token expired"]
        .iter()
        .any(|k| s.contains(k))
}

fn prefix_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn human_size(bytes: usize) -> String {
    if bytes >= 1_000_000 {
        format!("{:.1} MB", bytes as f64 / 1_000_000.0)
    } else {
        format!("{} KB", bytes.div_ceil(1000))
    }
}

pub fn cap_text(text: String) -> String {
    if text.len() <= MAX_RESULT_LENGTH {
        return text;
    }
    format!("{}\n… output truncated ({} total)", prefix_bytes(&text, MAX_RESULT_LENGTH), human_size(text.len()))
}

pub fn trimmed(structured: Option<Map<String, Value>>) -> Option<Map<String, Value>> {
    let mut s = structured?;
    s.remove("originalFile");
    for key in ["stdout", "stderr", "content"] {
        if let Some(Value::String(v)) = s.get_mut(key) {
            if v.len() > MAX_RESULT_LENGTH {
                *v = prefix_bytes(v, MAX_RESULT_LENGTH).to_string();
            }
        }
    }
    if let Some(Value::Object(file)) = s.get_mut("file") {
        if let Some(Value::String(c)) = file.get_mut("content") {
            if c.len() > MAX_RESULT_LENGTH {
                *c = prefix_bytes(c, MAX_RESULT_LENGTH).to_string();
            }
        }
    }
    Some(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn detects_auth_errors() {
        assert!(is_auth_error("OAuth token has expired. Please run /login"));
        assert!(is_auth_error("Invalid API key · Please run /login"));
        assert!(is_auth_error("API Error: 401 {\"type\":\"error\"}"));
        assert!(!is_auth_error("Claude exited with code 1"));
        assert!(!is_auth_error("Rate limit reached"));
    }

    #[test]
    fn caps_long_text() {
        let short = "hello".to_string();
        assert_eq!(cap_text(short.clone()), short);
        let long = "é".repeat(MAX_RESULT_LENGTH);
        let capped = cap_text(long);
        assert!(capped.contains("output truncated"));
        assert!(capped.len() < MAX_RESULT_LENGTH + 100);
    }

    #[test]
    fn trims_structured_payload() {
        let big = "x".repeat(MAX_RESULT_LENGTH + 10);
        let input = json!({
            "originalFile": "whole file",
            "stdout": big,
            "stderr": "warn",
            "file": { "content": big, "filePath": "/a" },
            "structuredPatch": []
        });
        let out = trimmed(input.as_object().cloned()).unwrap();
        assert!(!out.contains_key("originalFile"));
        assert_eq!(out["stdout"].as_str().unwrap().len(), MAX_RESULT_LENGTH);
        assert_eq!(out["stderr"], "warn");
        assert_eq!(out["file"]["content"].as_str().unwrap().len(), MAX_RESULT_LENGTH);
        assert_eq!(out["file"]["filePath"], "/a");
        assert!(out.contains_key("structuredPatch"));
        assert!(trimmed(None).is_none());
    }
}
