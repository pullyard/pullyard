use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::settings::{self, ClaudeProfile};
use crate::{secret, util};

pub const OPENROUTER_URL: &str = "https://openrouter.ai/api";
pub const OPENROUTER_KEYS_URL: &str = "https://openrouter.ai/settings/keys";
pub const OPENROUTER_ACTIVITY_URL: &str = "https://openrouter.ai/activity";
const STALE_AFTER: Duration = Duration::from_secs(600);

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    OpenRouter,
    Custom,
}

impl Kind {
    pub const ALL: [Kind; 2] = [Kind::OpenRouter, Kind::Custom];

    pub fn title(&self) -> &'static str {
        match self {
            Kind::OpenRouter => "OpenRouter",
            Kind::Custom => "Custom endpoint",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct AgentEndpoint {
    pub kind: Kind,
    pub base_url: String,
    #[serde(default)]
    pub model: Option<String>,
}

impl AgentEndpoint {
    pub fn host(&self) -> String {
        url::Url::parse(&self.base_url).ok().and_then(|u| u.host_str().map(|h| h.to_string())).unwrap_or_else(|| self.base_url.clone())
    }

    pub fn display_name(&self) -> String {
        match self.kind {
            Kind::OpenRouter => self.kind.title().to_string(),
            Kind::Custom => self.host(),
        }
    }

    pub fn model_name(&self) -> Option<String> {
        self.model.as_deref().map(str::trim).filter(|m| !m.is_empty()).map(|m| m.to_string())
    }

    pub fn environment(&self, token: &str) -> BTreeMap<String, String> {
        let mut env = BTreeMap::new();
        env.insert("ANTHROPIC_BASE_URL".to_string(), self.base_url.clone());
        env.insert("ANTHROPIC_AUTH_TOKEN".to_string(), token.to_string());
        env.insert("ANTHROPIC_API_KEY".to_string(), String::new());
        if let Some(model) = self.model_name() {
            env.insert("ANTHROPIC_MODEL".to_string(), model);
        }
        env
    }

    pub fn normalized(raw: &str) -> String {
        raw.trim().trim_end_matches('/').to_string()
    }

    pub fn problem(raw: &str) -> Option<&'static str> {
        let s = Self::normalized(raw);
        let parsed = url::Url::parse(&s).ok();
        let Some((scheme, host)) = parsed.as_ref().and_then(|u| u.host_str().filter(|h| !h.is_empty()).map(|h| (u.scheme().to_lowercase(), h.trim_matches(['[', ']']).to_lowercase()))) else {
            return Some("Enter the full address, e.g. https://openrouter.ai/api");
        };
        if scheme == "https" {
            return None;
        }
        if scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(&host.as_str()) {
            return None;
        }
        Some("Use https. Plain http is allowed only for localhost.")
    }

    pub fn secret_key(profile_id: &str) -> String {
        format!("agent-endpoint-{profile_id}")
    }
}

static KEYS: LazyLock<Mutex<HashMap<String, Option<String>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn cache_get(profile_id: &str) -> Option<Option<String>> {
    KEYS.lock().ok().and_then(|m| m.get(profile_id).cloned())
}

fn cache_set(profile_id: &str, key: Option<String>) {
    if let Ok(mut m) = KEYS.lock() {
        m.insert(profile_id.to_string(), key);
    }
}

pub fn endpoint_in(list: &[ClaudeProfile], config_dir: Option<&str>) -> Option<(String, AgentEndpoint)> {
    let dir = config_dir?;
    let p = list.iter().find(|p| p.config_dir.as_deref() == Some(dir))?;
    p.endpoint.clone().map(|e| (p.id.clone(), e))
}

pub fn endpoint(config_dir: Option<&str>) -> Option<(String, AgentEndpoint)> {
    endpoint_in(&super::accounts::profiles(), config_dir)
}

pub fn key(profile_id: &str) -> Option<String> {
    if let Some(cached) = cache_get(profile_id) {
        return cached;
    }
    if tokio::runtime::Handle::try_current().is_ok() {
        return None;
    }
    let loaded = crate::rt::block_on(crate::rt::run(secret::load(settings::config_dir(), AgentEndpoint::secret_key(profile_id))));
    cache_set(profile_id, loaded.clone());
    loaded
}

pub fn has_key(profile_id: &str) -> bool {
    key(profile_id).is_some_and(|k| !k.is_empty())
}

pub async fn preload() {
    let ids: Vec<String> = super::accounts::profiles().into_iter().filter(|p| p.endpoint.is_some()).map(|p| p.id).filter(|id| !matches!(cache_get(id), Some(Some(_)))).collect();
    for id in ids {
        let loaded = crate::rt::run(secret::load(settings::config_dir(), AgentEndpoint::secret_key(&id))).await;
        cache_set(&id, loaded);
    }
}

pub async fn store_key(profile_id: &str, key: &str) -> Result<(), String> {
    if secret::save(settings::config_dir(), AgentEndpoint::secret_key(profile_id), key.to_string()).await == secret::Saved::Failed {
        return Err("Could not save the API key. Check that the keyring is available.".into());
    }
    cache_set(profile_id, Some(key.to_string()));
    Ok(())
}

pub fn delete_key(profile_id: &str) {
    if let Ok(mut m) = KEYS.lock() {
        m.remove(profile_id);
    }
    let key = AgentEndpoint::secret_key(profile_id);
    crate::rt::spawn(secret::delete(settings::config_dir(), key));
}

pub fn environment(config_dir: Option<&str>) -> Option<BTreeMap<String, String>> {
    let (id, ep) = endpoint(config_dir)?;
    Some(ep.environment(&key(&id).unwrap_or_default()))
}

pub fn shell_prelude(config_dir: Option<&str>, directory: &Path) -> Result<String, String> {
    shell_prelude_env(environment(config_dir).as_ref(), directory)
}

pub fn shell_prelude_env(env: Option<&BTreeMap<String, String>>, directory: &Path) -> Result<String, String> {
    let Some(env) = env else { return Ok(String::new()) };
    sweep(directory, SystemTime::now());
    let id: String = uuid::Uuid::new_v4().simple().to_string().chars().take(8).collect();
    let file = directory.join(format!("env-{id}"));
    let body: String = env.iter().map(|(k, v)| format!("export {k}={}\n", util::shell_quote(v))).collect();
    let path = file.to_string_lossy().to_string();
    super::launcher::write_private(&path, &body, 0o600)?;
    let quoted = util::shell_quote(&path);
    Ok(format!(". {quoted}; rm -f {quoted}"))
}

pub fn sweep(directory: &Path, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(directory) else { return };
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with("env-") {
            continue;
        }
        let modified = entry.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
        if now.duration_since(modified).map(|d| d > STALE_AFTER).unwrap_or(false) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ep-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn environment_for_openrouter() {
        let ep = AgentEndpoint { kind: Kind::OpenRouter, base_url: OPENROUTER_URL.into(), model: Some(" anthropic/claude-sonnet-4.5 ".into()) };
        let env = ep.environment("sk-or-1");
        let expected: BTreeMap<String, String> = [
            ("ANTHROPIC_BASE_URL", "https://openrouter.ai/api"),
            ("ANTHROPIC_AUTH_TOKEN", "sk-or-1"),
            ("ANTHROPIC_API_KEY", ""),
            ("ANTHROPIC_MODEL", "anthropic/claude-sonnet-4.5"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        assert_eq!(env, expected);
        let no_model = AgentEndpoint { kind: Kind::Custom, base_url: "https://gw.example.com".into(), model: Some("  ".into()) };
        assert!(!no_model.environment("k").contains_key("ANTHROPIC_MODEL"));
        assert_eq!(no_model.host(), "gw.example.com");
        assert_eq!(no_model.display_name(), "gw.example.com");
        assert_eq!(ep.display_name(), "OpenRouter");
    }

    #[test]
    fn base_url_validation() {
        assert!(AgentEndpoint::problem("https://openrouter.ai/api/").is_none());
        assert!(AgentEndpoint::problem("http://localhost:4000").is_none());
        assert!(AgentEndpoint::problem("http://127.0.0.1:8080").is_none());
        assert!(AgentEndpoint::problem("http://[::1]:8080").is_none());
        assert!(AgentEndpoint::problem("http://gw.example.com").is_some());
        assert!(AgentEndpoint::problem("openrouter.ai/api").is_some());
        assert!(AgentEndpoint::problem("").is_some());
        assert_eq!(AgentEndpoint::normalized(" https://openrouter.ai/api// "), "https://openrouter.ai/api");
    }

    #[test]
    fn profile_decoding_keeps_old_data_and_finds_endpoint() {
        let old = r#"[{"id":"default","label":"Main"},{"id":"a","label":"Work","config_dir":"/x/a"}]"#;
        let list: Vec<ClaudeProfile> = serde_json::from_str(old).unwrap();
        assert!(endpoint_in(&list, Some("/x/a")).is_none());
        assert!(endpoint_in(&list, None).is_none());

        let ep = AgentEndpoint { kind: Kind::OpenRouter, base_url: OPENROUTER_URL.into(), model: None };
        let mut b = list[1].clone();
        b.id = "b".into();
        b.config_dir = Some("/x/b".into());
        b.endpoint = Some(ep.clone());
        let saved = serde_json::to_string(&vec![list[0].clone(), b]).unwrap();
        let list: Vec<ClaudeProfile> = serde_json::from_str(&saved).unwrap();
        let (id, found) = endpoint_in(&list, Some("/x/b")).unwrap();
        assert_eq!(id, "b");
        assert_eq!(found, ep);
        assert_eq!(AgentEndpoint::secret_key("b"), "agent-endpoint-b");
    }

    #[test]
    fn shell_prelude_writes_private_file_and_sources_it() {
        let dir = temp_dir();
        assert_eq!(shell_prelude_env(None, &dir).unwrap(), "");
        let env: BTreeMap<String, String> = [("ANTHROPIC_AUTH_TOKEN".to_string(), "it's secret".to_string()), ("ANTHROPIC_API_KEY".to_string(), String::new())].into_iter().collect();
        let line = shell_prelude_env(Some(&env), &dir).unwrap();
        let file = std::fs::read_dir(&dir).unwrap().flatten().find(|e| e.file_name().to_string_lossy().starts_with("env-")).unwrap().path();
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!line.contains("secret"));
        let out = std::process::Command::new("/bin/bash").arg("-c").arg(format!("{line}; printf '%s|%s' \"$ANTHROPIC_AUTH_TOKEN\" \"${{ANTHROPIC_API_KEY-unset}}\"")).env_remove("ANTHROPIC_API_KEY").output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout), "it's secret|");
        assert!(!file.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sweep_removes_stale_env_files() {
        let dir = temp_dir();
        let (stale, fresh, other) = (dir.join("env-old"), dir.join("env-new"), dir.join("prompt-1.md"));
        for f in [&stale, &fresh, &other] {
            std::fs::write(f, "").unwrap();
        }
        let old = SystemTime::now() - Duration::from_secs(3600);
        for f in [&stale, &other] {
            std::fs::File::options().write(true).open(f).unwrap().set_modified(old).unwrap();
        }
        sweep(&dir, SystemTime::now());
        assert!(!stale.exists());
        assert!(fresh.exists());
        assert!(other.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
