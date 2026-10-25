use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use base64::Engine;
use chrono::{DateTime, Utc};
use regex::Regex;
use serde_json::{json, Value};

use crate::api::{http_client, probed_get, ApiError, ApiResult};
use crate::signal::Signal;
use crate::{secret, settings};

pub const TOKEN_KEY: &str = "jira-token";
pub const TOKEN_URL: &str = "https://id.atlassian.com/manage-profile/security/api-tokens";
const CACHE_TTL: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq)]
pub struct JiraIssue {
    pub key: String,
    pub summary: String,
    pub status: String,
    pub status_category: String,
    pub kind: Option<String>,
    pub priority: Option<String>,
    pub assignee: Option<String>,
    pub assignee_avatar: Option<String>,
    pub reporter: Option<String>,
    pub description: String,
    pub url: String,
    pub updated: Option<DateTime<Utc>>,
    pub parent_key: Option<String>,
    pub parent_summary: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct JiraTransition {
    pub id: String,
    pub name: String,
    pub to: String,
    pub to_category: String,
}

impl JiraTransition {
    pub fn title(&self) -> String {
        if self.name == self.to {
            self.name.clone()
        } else {
            format!("{} → {}", self.name, self.to)
        }
    }
}

const IGNORED: [&str; 16] = ["UTF", "SHA", "ISO", "RFC", "CVE", "GPT", "TLS", "SSL", "HTTP", "MD", "X", "COVID", "ES", "IPV", "AES", "RSA"];

static KEY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^([A-Z][A-Z0-9_]{1,9})-([1-9][0-9]{0,6})").expect("jira key regex"));

pub fn extract(texts: &[&str]) -> Vec<String> {
    let mut seen: Vec<String> = vec![];
    for text in texts {
        let mut prev: Option<char> = None;
        for (i, c) in text.char_indices() {
            let boundary = prev.is_none_or(|p| !p.is_ascii_alphanumeric());
            prev = Some(c);
            if !boundary || !c.is_ascii_uppercase() {
                continue;
            }
            let Some(m) = KEY.captures(&text[i..]) else { continue };
            let whole = m.get(0).map(|x| x.as_str()).unwrap_or_default();
            if text[i + whole.len()..].chars().next().is_some_and(|n| n.is_ascii_alphanumeric()) {
                continue;
            }
            let project = m.get(1).map(|x| x.as_str()).unwrap_or_default();
            if IGNORED.contains(&project) {
                continue;
            }
            if !seen.iter().any(|k| k == whole) {
                seen.push(whole.to_string());
            }
        }
    }
    seen
}

pub fn detected(title: &str, branch: &str, body: &str) -> Vec<String> {
    let branch = branch.to_uppercase();
    let mut out: Vec<String> = vec![];
    for k in extract(&[title]).into_iter().chain(extract(&[&branch])).chain(extract(&[body])) {
        if !out.contains(&k) {
            out.push(k);
        }
    }
    out
}

pub fn authorization(email: &str, token: &str) -> String {
    if email.is_empty() {
        format!("Bearer {token}")
    } else {
        format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(format!("{email}:{token}")))
    }
}

pub fn base_url(site: &str) -> Option<String> {
    let mut s = site.trim().to_string();
    if s.is_empty() {
        return None;
    }
    if !s.to_lowercase().starts_with("http") {
        s = format!("https://{s}");
    }
    let url = url::Url::parse(&s).ok()?;
    let host = url.host_str().filter(|h| !h.is_empty())?;
    if url.scheme() != "https" {
        return None;
    }
    let mut path = url.path().to_string();
    if host.to_lowercase().ends_with(".atlassian.net") {
        path.clear();
    } else {
        for marker in ["/browse/", "/secure/", "/projects/", "/issues/", "/rest/", "/plugins/", "/servicedesk/"] {
            if let Some(i) = path.find(marker) {
                path.truncate(i);
            }
        }
    }
    while path.ends_with('/') {
        path.pop();
    }
    let authority = match url.port() {
        Some(p) => format!("{host}:{p}"),
        None => host.to_string(),
    };
    Some(format!("https://{authority}{path}"))
}

pub fn plain_text(html: &str) -> String {
    static RULES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
        [(r"(?i)<br\s*/?>", "\n"), (r"(?i)</(p|div|h[1-6]|tr|table|blockquote|pre)>", "\n"), (r"(?i)<li[^>]*>", "\n• "), (r"(?i)</t[dh]>", " · "), (r"(?i)<[^>]+>", "")]
            .into_iter()
            .map(|(p, r)| (Regex::new(p).expect("jira html regex"), r))
            .collect()
    });
    static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t\x{00A0}]+").expect("spaces regex"));
    let mut s = collapse_whitespace(html);
    for (re, with) in RULES.iter() {
        s = re.replace_all(&s, *with).into_owned();
    }
    for (entity, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
        s = s.replace(entity, c);
    }
    let mut out: Vec<String> = vec![];
    for line in s.split('\n') {
        let mut l = SPACES.replace_all(line, " ").trim_matches(is_inline_space).to_string();
        while let Some(rest) = l.strip_suffix('·') {
            l = rest.trim_matches(is_inline_space).to_string();
        }
        while let Some(rest) = l.strip_prefix('·') {
            l = rest.trim_matches(is_inline_space).to_string();
        }
        if l.is_empty() && out.last().is_none_or(|p| p.is_empty()) {
            continue;
        }
        out.push(l);
    }
    out.join("\n").replace('\u{1}', "\n").trim().to_string()
}

fn is_inline_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
}

fn collapse_whitespace(html: &str) -> String {
    static PRE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?is)<pre[^>]*>.*?</pre>").expect("pre regex"));
    static WS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("whitespace regex"));
    let mut out = String::new();
    let mut last = 0;
    for m in PRE.find_iter(html) {
        out.push_str(&WS.replace_all(&html[last..m.start()], " "));
        out.push_str(&m.as_str().replace('\n', "\u{1}"));
        last = m.end();
    }
    out.push_str(&WS.replace_all(&html[last..], " "));
    out
}

fn s(v: &Value, path: &[&str]) -> Option<String> {
    let mut cur = v;
    for p in path {
        cur = cur.get(p)?;
    }
    cur.as_str().map(str::to_string)
}

fn parse_date(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f%z").or_else(|_| DateTime::parse_from_rfc3339(raw)).ok().map(|d| d.with_timezone(&Utc))
}

pub fn parse_issue(o: &Value, base: &str) -> JiraIssue {
    let key = s(o, &["key"]).unwrap_or_default();
    let f = o.get("fields").cloned().unwrap_or(Value::Null);
    let rendered = s(o, &["renderedFields", "description"]);
    JiraIssue {
        summary: s(&f, &["summary"]).unwrap_or_default(),
        status: s(&f, &["status", "name"]).unwrap_or_default(),
        status_category: s(&f, &["status", "statusCategory", "key"]).unwrap_or_default(),
        kind: s(&f, &["issuetype", "name"]),
        priority: s(&f, &["priority", "name"]),
        assignee: s(&f, &["assignee", "displayName"]),
        assignee_avatar: s(&f, &["assignee", "avatarUrls", "48x48"]),
        reporter: s(&f, &["reporter", "displayName"]),
        description: rendered.map(|h| plain_text(&h)).unwrap_or_else(|| s(&f, &["description"]).unwrap_or_default()),
        url: format!("{base}/browse/{key}"),
        updated: s(&f, &["updated"]).and_then(|u| parse_date(&u)),
        parent_key: s(&f, &["parent", "key"]),
        parent_summary: s(&f, &["parent", "fields", "summary"]),
        key,
    }
}

pub fn parse_transitions(o: &Value) -> Vec<JiraTransition> {
    o.get("transitions")
        .and_then(|t| t.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|t| {
                    let id = s(t, &["id"])?;
                    let name = s(t, &["name"])?;
                    Some(JiraTransition { to: s(t, &["to", "name"]).unwrap_or_else(|| name.clone()), to_category: s(t, &["to", "statusCategory", "key"]).unwrap_or_default(), id, name })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn error_message(status: u16, body: &[u8]) -> String {
    let obj: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let message = obj.get("errorMessages").and_then(|m| m.as_array()).and_then(|m| m.first()).and_then(|m| m.as_str()).map(str::to_string).or_else(|| s(&obj, &["message"]));
    match status {
        401 => "Jira rejected the credentials (401). Check the email and API token.".into(),
        403 => message.unwrap_or_else(|| "No permission in Jira (403)".into()),
        404 => message.unwrap_or_else(|| "Not found in Jira (404)".into()),
        _ => format!("Jira {status}: {}", message.unwrap_or_else(|| reqwest::StatusCode::from_u16(status).ok().and_then(|c| c.canonical_reason()).unwrap_or("error").to_string())),
    }
}

#[derive(Clone, Debug)]
pub struct Client {
    pub base: String,
    authorization: String,
}

impl Client {
    pub fn new(base: String, authorization: String) -> Self {
        Client { base, authorization }
    }

    async fn request(&self, path: &str, method: reqwest::Method, body: Option<Value>) -> ApiResult<Vec<u8>> {
        let full = format!("{}{path}", self.base);
        let base_host = url::Url::parse(&self.base).ok().and_then(|u| u.host_str().map(str::to_string));
        let parsed = url::Url::parse(&full).map_err(|_| ApiError::new("Invalid Jira address"))?;
        if parsed.scheme() != "https" || parsed.host_str().map(str::to_string) != base_host {
            return Err(ApiError::new("Invalid Jira address"));
        }
        let mut probe = crate::diagnostics::begin_rest(method.as_str(), &full);
        let mut req = http_client()
            .request(method, parsed)
            .timeout(Duration::from_secs(30))
            .header("Authorization", &self.authorization)
            .header("Accept", "application/json")
            .header("X-Atlassian-Token", "no-check");
        if let Some(body) = body {
            req = req.json(&body);
        }
        let (status, bytes) = probed_get(&mut probe, req).await?;
        if !status.is_success() {
            return probe.track(Err(ApiError::with_status(error_message(status.as_u16(), &bytes), status.as_u16())));
        }
        Ok(bytes)
    }

    async fn json(&self, path: &str) -> ApiResult<Value> {
        let bytes = self.request(path, reqwest::Method::GET, None).await?;
        serde_json::from_slice::<Value>(&bytes).ok().filter(|v| v.is_object()).ok_or_else(|| ApiError::new("Jira sent a web page instead of data. Check the address: it should be just your site, like acme.atlassian.net."))
    }

    pub async fn myself(&self) -> ApiResult<String> {
        let o = self.json("/rest/api/2/myself").await?;
        Ok(s(&o, &["displayName"]).or_else(|| s(&o, &["name"])).unwrap_or_else(|| "Jira".into()))
    }

    pub async fn issue(&self, key: &str) -> ApiResult<JiraIssue> {
        let o = self.json(&format!("/rest/api/2/issue/{key}?fields=summary,status,issuetype,priority,assignee,reporter,description,updated,parent&expand=renderedFields")).await?;
        Ok(parse_issue(&o, &self.base))
    }

    pub async fn transitions(&self, key: &str) -> ApiResult<Vec<JiraTransition>> {
        let o = self.json(&format!("/rest/api/2/issue/{key}/transitions")).await?;
        Ok(parse_transitions(&o))
    }

    pub async fn transition(&self, key: &str, id: &str) -> ApiResult<()> {
        self.request(&format!("/rest/api/2/issue/{key}/transitions"), reqwest::Method::POST, Some(json!({ "transition": { "id": id } }))).await.map(|_| ())
    }
}

thread_local! {
    static TOKEN: RefCell<Option<String>> = const { RefCell::new(None) };
    static CACHE: RefCell<HashMap<String, (JiraIssue, Instant)>> = RefCell::new(HashMap::new());
    static CHANGED: Signal<()> = const { Signal::new() };
}

pub fn on_change(f: impl Fn(&()) -> bool + 'static) {
    CHANGED.with(|s| s.connect(f));
}

pub fn changed() {
    CHANGED.with(|s| s.emit(&()));
}

pub fn site() -> String {
    settings::read(|s| s.jira_site.clone())
}

pub fn email() -> String {
    settings::read(|s| s.jira_email.clone())
}

pub fn display_name() -> Option<String> {
    settings::read(|s| s.jira_name.clone())
}

pub fn is_configured() -> bool {
    settings::read(|s| s.jira_has_token) && base_url(&site()).is_some()
}

pub fn host() -> String {
    base_url(&site()).and_then(|b| url::Url::parse(&b).ok()).and_then(|u| u.host_str().map(str::to_string)).unwrap_or_default()
}

pub async fn connect(site: String, email: String, token: String) -> ApiResult<()> {
    let email = email.trim().to_string();
    let token = token.trim().to_string();
    let site = site.trim().to_string();
    settings::update(|s| {
        s.jira_site = site.clone();
        s.jira_email = email.clone();
    });
    let Some(base) = base_url(&site) else { return Err(ApiError::new("Enter your Jira address, for example acme.atlassian.net")) };
    let client = Client::new(base, authorization(&email, &token));
    let name = crate::rt::run(async move { client.myself().await }).await?;
    if crate::rt::run(secret::save(settings::config_dir(), TOKEN_KEY.into(), token.clone())).await == secret::Saved::Failed {
        return Err(ApiError::new("Couldn't store the Jira token"));
    }
    TOKEN.with(|t| *t.borrow_mut() = Some(token));
    CACHE.with(|c| c.borrow_mut().clear());
    settings::update(|s| {
        s.jira_has_token = true;
        s.jira_name = Some(name);
    });
    changed();
    Ok(())
}

pub fn disconnect() {
    TOKEN.with(|t| t.borrow_mut().take());
    CACHE.with(|c| c.borrow_mut().clear());
    settings::update(|s| {
        s.jira_has_token = false;
        s.jira_name = None;
    });
    crate::rt::spawn_local(async { crate::rt::run(secret::delete(settings::config_dir(), TOKEN_KEY.into())).await });
    changed();
}

pub async fn client() -> Option<Client> {
    if !settings::read(|s| s.jira_has_token) {
        return None;
    }
    let base = base_url(&site())?;
    let token = match TOKEN.with(|t| t.borrow().clone()) {
        Some(t) => t,
        None => {
            let t = crate::rt::run(secret::load(settings::config_dir(), TOKEN_KEY.into())).await?;
            TOKEN.with(|c| *c.borrow_mut() = Some(t.clone()));
            t
        }
    };
    Some(Client::new(base, authorization(&email(), &token)))
}

pub fn cached(key: &str) -> Option<JiraIssue> {
    CACHE.with(|c| c.borrow().get(key).filter(|(_, at)| at.elapsed() < CACHE_TTL).map(|(i, _)| i.clone()))
}

pub fn clear_cache() {
    CACHE.with(|c| c.borrow_mut().clear());
}

pub fn browse_url(key: &str) -> Option<String> {
    base_url(&site()).map(|b| format!("{b}/browse/{key}"))
}

pub fn remember(issue: &JiraIssue) {
    CACHE.with(|c| c.borrow_mut().insert(issue.key.clone(), (issue.clone(), Instant::now())));
}

pub fn linked(pr_url: &str) -> Vec<String> {
    settings::read(|s| s.jira_links.get(pr_url).cloned().unwrap_or_default())
}

pub fn set_linked(pr_url: &str, keys: Vec<String>) {
    settings::update(|s| {
        if keys.is_empty() {
            s.jira_links.remove(pr_url);
        } else {
            s.jira_links.insert(pr_url.to_string(), keys);
        }
    });
}

pub fn hidden(pr_url: &str) -> Vec<String> {
    settings::read(|s| s.jira_hidden.get(pr_url).cloned().unwrap_or_default())
}

pub fn set_hidden(pr_url: &str, keys: Vec<String>) {
    settings::update(|s| {
        if keys.is_empty() {
            s.jira_hidden.remove(pr_url);
        } else {
            s.jira_hidden.insert(pr_url.to_string(), keys);
        }
    });
}

pub fn hide(pr_url: &str, key: &str) {
    let mut keys = hidden(pr_url);
    if !keys.iter().any(|k| k == key) {
        keys.push(key.to_string());
    }
    set_hidden(pr_url, keys);
}

pub fn parse_key(raw: &str) -> Option<String> {
    extract(&[&raw.trim().to_uppercase()]).into_iter().next()
}

pub fn link(pr_url: &str, raw: &str) -> Option<String> {
    let key = parse_key(raw)?;
    let mut keys = linked(pr_url);
    if !keys.contains(&key) {
        keys.insert(0, key.clone());
    }
    set_linked(pr_url, keys);
    set_hidden(pr_url, hidden(pr_url).into_iter().filter(|k| *k != key).collect());
    Some(key)
}

pub fn unlink(pr_url: &str, key: &str) {
    set_linked(pr_url, linked(pr_url).into_iter().filter(|k| k != key).collect());
}

pub fn keys_for(pr_url: &str, title: &str, branch: &str, body: &str) -> Vec<String> {
    merge_keys(linked(pr_url), detected(title, branch, body), &hidden(pr_url))
}

fn merge_keys(linked: Vec<String>, detected: Vec<String>, hidden: &[String]) -> Vec<String> {
    let mut out = linked;
    for k in detected {
        if !out.contains(&k) && !hidden.contains(&k) {
            out.push(k);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_keys_with_boundaries_and_ignore_list() {
        assert_eq!(extract(&["Fix ABC-123 and XY-9, again ABC-123"]), vec!["ABC-123", "XY-9"]);
        assert!(extract(&["UTF-8 SHA-256 RFC-2119 COVID-19 HTTP-2"]).is_empty());
        assert!(extract(&["aABC-12 ABC-12x ABC-0 A-1"]).is_empty());
        assert_eq!(extract(&["xAB_CD-12"]), vec!["CD-12"]);
        assert_eq!(extract(&["(PROJ_2-45)"]), vec!["PROJ_2-45"]);
        assert_eq!(extract(&["ABC-1234567 ABC-12345678"]), vec!["ABC-1234567"]);
    }

    #[test]
    fn detects_title_then_branch_then_body() {
        assert_eq!(detected("Add login", "feature/web-42-login", "Closes OPS-7 and WEB-42"), vec!["WEB-42", "OPS-7"]);
    }

    #[test]
    fn hidden_keys_drop_detected_tickets_but_keep_linked_ones() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(merge_keys(v(&["OPS-1"]), v(&["WEB-2", "OPS-1", "WEB-3"]), &v(&["WEB-2", "OPS-1"])), v(&["OPS-1", "WEB-3"]));
    }

    #[test]
    fn authorization_uses_basic_with_email_and_bearer_without() {
        assert_eq!(authorization("", "tok"), "Bearer tok");
        assert_eq!(authorization("a@b.c", "tok"), format!("Basic {}", base64::engine::general_purpose::STANDARD.encode("a@b.c:tok")));
    }

    #[test]
    fn base_urls_are_https_only() {
        assert_eq!(base_url(" acme.atlassian.net/ ").as_deref(), Some("https://acme.atlassian.net"));
        assert_eq!(base_url("https://jira.corp/").as_deref(), Some("https://jira.corp"));
        assert_eq!(base_url("http://jira.corp"), None);
        assert_eq!(base_url("https://minitok.atlassian.net/jira/software/c/projects/COM/list?jql=project%20%3D%20COM").as_deref(), Some("https://minitok.atlassian.net"));
        assert_eq!(base_url("https://jira.corp/jira/browse/PAY-1").as_deref(), Some("https://jira.corp/jira"));
        assert_eq!(base_url(""), None);
    }

    #[test]
    fn html_descriptions_become_plain_text() {
        assert_eq!(plain_text("<p>Hello&nbsp;<b>world</b></p><ul><li>one</li><li>two &amp; three</li></ul><br/><br/><br/>"), "Hello world\n\n• one\n• two & three");
        assert_eq!(plain_text("<p>Webhooks fail &amp; never retry.</p><ul><li>Add backoff</li></ul>"), "Webhooks fail & never retry.\n\n• Add backoff");
    }

    #[test]
    fn tables_and_panels_become_readable_text() {
        let html = "<p>PR 2 of 2 for</p><div class=\"table-wrap\"><table><tbody><tr><td>\n  <a href=\"x\">COM-1563</a>\n</td><td>\n\n DONE \n</td></tr></tbody></table></div><p>&nbsp;</p><p>Next</p>";
        assert_eq!(plain_text(html), "PR 2 of 2 for\nCOM-1563 · DONE\n\nNext");
    }

    #[test]
    fn preformatted_blocks_keep_their_lines() {
        assert_eq!(plain_text("<p>Run   this:</p><pre>cargo   build\ncargo test</pre><p>Done</p>"), "Run this:\ncargo build\ncargo test\nDone");
    }

    #[test]
    fn parses_issue_and_transitions() {
        let o = json!({
            "key": "WEB-42",
            "fields": {
                "summary": "Login page",
                "status": { "name": "In Progress", "statusCategory": { "key": "indeterminate" } },
                "issuetype": { "name": "Story" },
                "priority": { "name": "High" },
                "assignee": { "displayName": "Ann", "avatarUrls": { "48x48": "https://a/48.png" } },
                "description": "raw",
                "updated": "2024-05-01T10:20:30.000+0200",
                "parent": { "key": "WEB-1", "fields": { "summary": "Accounts epic" } }
            },
            "renderedFields": { "description": "<p>Rendered</p>" }
        });
        let i = parse_issue(&o, "https://acme.atlassian.net");
        assert_eq!(i.url, "https://acme.atlassian.net/browse/WEB-42");
        assert_eq!(i.status_category, "indeterminate");
        assert_eq!(i.description, "Rendered");
        assert_eq!(i.parent_key.as_deref(), Some("WEB-1"));
        assert_eq!(i.parent_summary.as_deref(), Some("Accounts epic"));
        assert_eq!(parse_issue(&json!({ "key": "WEB-2", "fields": { "summary": "x" } }), "https://acme.atlassian.net").parent_key, None);
        assert_eq!(i.assignee_avatar.as_deref(), Some("https://a/48.png"));
        assert_eq!(i.updated.map(|d| d.to_rfc3339()), Some("2024-05-01T08:20:30+00:00".into()));
        let t = parse_transitions(&json!({ "transitions": [{ "id": "31", "name": "Done", "to": { "name": "Done", "statusCategory": { "key": "done" } } }, { "id": "21", "name": "Start", "to": { "name": "In Progress" } }] }));
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].title(), "Done");
        assert_eq!(t[1].title(), "Start → In Progress");
        assert_eq!(t[0].to_category, "done");
    }

    #[test]
    fn errors_prefer_jira_messages() {
        assert!(error_message(401, b"{}").contains("credentials"));
        assert_eq!(error_message(404, br#"{"errorMessages":["Issue does not exist"]}"#), "Issue does not exist");
        assert_eq!(error_message(500, b""), "Jira 500: Internal Server Error");
    }
}
