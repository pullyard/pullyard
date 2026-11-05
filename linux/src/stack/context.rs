use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::brand;

pub const MAX_FILES: usize = 200;
pub const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 3600);
const BODY_LIMIT: usize = 6000;
const LIST_LIMIT: usize = 300;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Requirement {
    pub state: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Check {
    pub name: String,
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Review {
    pub login: String,
    pub state: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Comment {
    pub author: String,
    pub body: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Thread {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
    pub resolved: bool,
    pub outdated: bool,
    pub comments: Vec<Comment>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct OwnerGroup {
    pub owners: Vec<String>,
    pub files: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub is_draft: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub base_ref: String,
    pub head_ref: String,
    pub head_oid: String,
    pub body: String,
    pub merge_status: String,
    pub requirements: Vec<Requirement>,
    pub checks: Vec<Check>,
    pub reviews: Vec<Review>,
    pub threads: Vec<Thread>,
    pub files: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code_owners: Option<Vec<OwnerGroup>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unowned_files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewed_oid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commits_since_review: Option<i64>,
    #[serde(serialize_with = "ser_date", deserialize_with = "de_date")]
    pub captured: DateTime<Utc>,
}

fn iso(d: &DateTime<Utc>) -> String {
    d.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn ser_date<S: Serializer>(d: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&iso(d))
}

fn de_date<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
    let s = String::deserialize(d)?;
    DateTime::parse_from_rfc3339(&s).map(|d| d.with_timezone(&Utc)).map_err(serde::de::Error::custom)
}

pub fn default_dir() -> PathBuf {
    crate::settings::data_dir().join("pr-context")
}

pub fn file_name(key: &str) -> String {
    let safe: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '_' }).collect();
    format!("{safe}.json")
}

pub fn write(snapshot: &Snapshot, key: &str, dir: &Path) -> std::io::Result<()> {
    super::mcp::create_dir(dir)?;
    let data = serde_json::to_vec(snapshot).map_err(std::io::Error::other)?;
    let tmp = dir.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    if let Err(e) = std::fs::write(&tmp, data) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    std::fs::rename(&tmp, dir.join(file_name(key))).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })?;
    prune(dir, SystemTime::now());
    Ok(())
}

pub fn read(key: &str, dir: &Path) -> Option<Snapshot> {
    let data = std::fs::read(dir.join(file_name(key))).ok()?;
    serde_json::from_slice(&data).ok()
}

pub fn prune(dir: &Path, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut dated: Vec<(PathBuf, SystemTime)> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .map(|p| {
            let modified = std::fs::metadata(&p).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
            (p, modified)
        })
        .collect();
    dated.sort_by(|a, b| b.1.cmp(&a.1));
    for (index, (path, modified)) in dated.iter().enumerate() {
        let old = now.duration_since(*modified).map(|age| age > MAX_AGE).unwrap_or(false);
        if index >= MAX_FILES || old {
            let _ = std::fs::remove_file(path);
        }
    }
}

pub fn overview(s: &Snapshot) -> String {
    let mut out: Vec<String> = vec![];
    out.push(format!("{}#{}: {}", s.repo, s.number, s.title));
    let head: String = s.head_oid.chars().take(7).collect();
    let by = s.author.as_ref().map(|a| format!(" · by @{a}")).unwrap_or_default();
    out.push(format!("State: {}{} · {} → {} · head {head}{by}", if s.is_draft { "draft, " } else { "" }, s.state.to_lowercase(), s.head_ref, s.base_ref));
    out.push(format!("URL: {}", s.url));
    out.push(format!("Loaded by {}: {}", brand::APP_NAME, iso(&s.captured)));
    out.push(String::new());
    out.push(format!("Merge status: {}", s.merge_status));
    for r in &s.requirements {
        out.push(format!("- [{}] {}{}", r.state, r.title, r.detail.as_ref().map(|d| format!(" — {d}")).unwrap_or_default()));
    }
    if !s.reviews.is_empty() {
        out.push(String::new());
        let list: Vec<String> = s.reviews.iter().map(|r| format!("@{} ({})", r.login, r.state.to_lowercase().replace('_', " "))).collect();
        out.push(format!("Reviewers: {}", list.join(", ")));
    }
    if let Some(groups) = &s.code_owners {
        out.push(String::new());
        let text = if groups.is_empty() {
            "none of the changed files have owners".to_string()
        } else {
            groups.iter().map(|g| format!("{} ({} files)", g.owners.join(" "), g.files.len())).collect::<Vec<_>>().join("; ")
        };
        out.push(format!("Code owners: {text}"));
        if let Some(unowned) = s.unowned_files.as_ref().filter(|u| !u.is_empty()) {
            out.push(format!("Files without a code owner: {}", unowned.len()));
        }
    }
    if let Some(oid) = &s.reviewed_oid {
        out.push(String::new());
        let short: String = oid.chars().take(7).collect();
        let tail = match s.commits_since_review {
            Some(n) => format!(", {n} commit(s) ago."),
            None => "; the branch history was rewritten since.".to_string(),
        };
        out.push(format!("The user last reviewed commit {short}{tail}"));
    }
    let open = s.threads.iter().filter(|t| !t.resolved).count();
    let failing = s.checks.iter().filter(|c| c.outcome == "failure").count();
    out.push(String::new());
    out.push(format!("{open} unresolved review thread(s), {failing} failing check(s), {} changed file(s).", s.files.len()));
    let body = s.body.trim();
    if !body.is_empty() {
        out.push(String::new());
        out.push("Description:".to_string());
        if body.chars().count() > BODY_LIMIT {
            out.push(format!("{}\n…(truncated)", body.chars().take(BODY_LIMIT).collect::<String>()));
        } else {
            out.push(body.to_string());
        }
    }
    out.join("\n")
}

pub fn threads(s: &Snapshot, include_resolved: bool) -> String {
    let list: Vec<&Thread> = s.threads.iter().filter(|t| include_resolved || !t.resolved).collect();
    if list.is_empty() {
        return if include_resolved { format!("No review threads on {}#{}.", s.repo, s.number) } else { format!("No unresolved review threads on {}#{}.", s.repo, s.number) };
    }
    list.iter()
        .enumerate()
        .map(|(index, t)| {
            let mut head = format!("{}. {}{}", index + 1, t.path, t.line.map(|l| format!(":{l}")).unwrap_or_default());
            let mut flags = vec![];
            if t.resolved {
                flags.push("resolved");
            }
            if t.outdated {
                flags.push("outdated");
            }
            if !flags.is_empty() {
                head.push_str(&format!(" ({})", flags.join(", ")));
            }
            let mut lines = vec![head];
            lines.extend(t.comments.iter().map(|c| format!("   @{}: {}", c.author, c.body.replace('\n', "\n   "))));
            lines.join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn rank(outcome: &str) -> u8 {
    match outcome {
        "failure" => 0,
        "pending" => 1,
        "neutral" => 2,
        "skipped" => 3,
        "success" => 4,
        _ => 5,
    }
}

pub fn checks(s: &Snapshot) -> String {
    if s.checks.is_empty() {
        return format!("No checks reported for the head commit of {}#{}.", s.repo, s.number);
    }
    let mut sorted: Vec<&Check> = s.checks.iter().collect();
    sorted.sort_by_key(|c| rank(&c.outcome));
    sorted
        .iter()
        .map(|c| {
            let req = match c.required {
                Some(true) => " · required",
                Some(false) => " · optional",
                None => "",
            };
            format!("- [{}] {}{req}{}", c.outcome, c.name, c.url.as_ref().map(|u| format!(" · {u}")).unwrap_or_default())
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn files(s: &Snapshot) -> String {
    if s.files.is_empty() {
        return format!("No changed files recorded for {}#{}.", s.repo, s.number);
    }
    let mut owner: HashMap<&str, String> = HashMap::new();
    for g in s.code_owners.iter().flatten() {
        for f in &g.files {
            owner.insert(f.as_str(), g.owners.join(" "));
        }
    }
    let mut lines: Vec<String> = s.files.iter().take(LIST_LIMIT).map(|f| owner.get(f.as_str()).map(|o| format!("{f} — {o}")).unwrap_or_else(|| f.clone())).collect();
    if s.files.len() > LIST_LIMIT {
        lines.push(format!("…and {} more", s.files.len() - LIST_LIMIT));
    }
    lines.join("\n")
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn sample() -> Snapshot {
        let req = |state: &str, title: &str, detail: Option<&str>| Requirement { state: state.into(), title: title.into(), detail: detail.map(String::from) };
        let thread = |path: &str, line: Option<i64>, resolved: bool, outdated: bool, body: &str| Thread {
            path: path.into(),
            line,
            resolved,
            outdated,
            comments: vec![Comment { author: "bob".into(), body: body.into() }],
        };
        Snapshot {
            repo: "o/r".into(),
            number: 7,
            title: "Fix login".into(),
            url: "https://github.com/o/r/pull/7".into(),
            state: "OPEN".into(),
            is_draft: false,
            author: Some("alice".into()),
            base_ref: "main".into(),
            head_ref: "fix".into(),
            head_oid: "abcdef1234".into(),
            body: "Body text".into(),
            merge_status: "1 required check failed".into(),
            requirements: vec![req("blocking", "1 required check failed", Some("build")), req("met", "No conflicts with main", None)],
            checks: vec![
                Check { name: "lint".into(), outcome: "success".into(), required: Some(false), url: None },
                Check { name: "CI / build".into(), outcome: "failure".into(), required: Some(true), url: Some("https://ci/1".into()) },
            ],
            reviews: vec![Review { login: "bob".into(), state: "CHANGES_REQUESTED".into() }],
            threads: vec![thread("a.swift", Some(3), false, false, "Rename this"), thread("b.swift", None, true, true, "Done")],
            files: vec!["a.swift".into(), "b.swift".into(), "README.md".into()],
            code_owners: Some(vec![OwnerGroup { owners: vec!["@core".into()], files: vec!["a.swift".into(), "b.swift".into()] }]),
            unowned_files: Some(vec!["README.md".into()]),
            reviewed_oid: Some("1111111aaa".into()),
            commits_since_review: Some(2),
            captured: DateTime::from_timestamp(0, 0).unwrap(),
        }
    }

    pub fn temp_dir() -> PathBuf {
        std::env::temp_dir().join(format!("prctx-{}", uuid::Uuid::new_v4().simple()))
    }

    #[test]
    fn store_round_trip_and_safe_file_name() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir();
        let key = super::super::notes::key_for("Me", "github.com", "O/R", 7);
        assert!(!file_name(&key).contains('/'));
        assert!(!file_name(&key).contains('|'));
        write(&sample(), &key, &dir).unwrap();
        assert_eq!(read(&key, &dir), Some(sample()));
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_shape_matches_other_platforms() {
        let v = serde_json::to_value(sample()).unwrap();
        assert_eq!(v["captured"], "1970-01-01T00:00:00Z");
        assert_eq!(v["isDraft"], false);
        assert_eq!(v["mergeStatus"], "1 required check failed");
        assert_eq!(v["commitsSinceReview"], 2);
        assert_eq!(v["codeOwners"][0]["owners"][0], "@core");
        assert!(v["threads"][1].get("line").is_none());
    }

    #[test]
    fn prune_drops_old_files() {
        let dir = temp_dir();
        write(&sample(), "k1", &dir).unwrap();
        prune(&dir, SystemTime::now() + Duration::from_secs(8 * 24 * 3600));
        assert!(read("k1", &dir).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
