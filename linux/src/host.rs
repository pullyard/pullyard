use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{LazyLock, Mutex};

use crate::util;

#[derive(Clone, Default)]
pub struct HostCmd {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub unset: Vec<String>,
    pub cwd: Option<String>,
}

impl HostCmd {
    pub fn new(program: &str) -> Self {
        HostCmd { program: program.to_string(), ..Default::default() }
    }

    pub fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }

    pub fn args<I: IntoIterator<Item = S>, S: Into<String>>(mut self, a: I) -> Self {
        self.args.extend(a.into_iter().map(Into::into));
        self
    }

    pub fn env(mut self, k: &str, v: &str) -> Self {
        self.env.push((k.to_string(), v.to_string()));
        self
    }

    pub fn unset(mut self, k: &str) -> Self {
        self.unset.push(k.to_string());
        self
    }

    pub fn cwd(mut self, dir: &str) -> Self {
        self.cwd = Some(dir.to_string());
        self
    }

    pub fn argv(&self) -> Vec<String> {
        if util::is_flatpak() {
            self.sandboxed_argv(shared_runtime_dir().as_deref())
        } else {
            let mut v = vec![self.program.clone()];
            v.extend(self.args.iter().cloned());
            v
        }
    }

    fn sandboxed_argv(&self, secret_dir: Option<&Path>) -> Vec<String> {
        let mut v = vec!["flatpak-spawn".to_string(), "--host".to_string(), "--watch-bus".to_string()];
        if let Some(dir) = &self.cwd {
            v.push(format!("--directory={dir}"));
        }
        let (secret, plain): (Vec<_>, Vec<_>) = self.env.iter().partition(|(k, _)| SECRET_ENV.contains(&k.as_str()));
        for (k, val) in &plain {
            v.push(format!("--env={k}={val}"));
        }
        for k in &self.unset {
            v.push(format!("--unset-env={k}"));
        }
        let file = secret_dir.filter(|_| !secret.is_empty()).and_then(|dir| write_secret_env(dir, &secret));
        match file {
            Some(path) => {
                v.extend(["/bin/sh".to_string(), "-c".to_string(), ". \"$0\"; rm -f \"$0\"; exec \"$@\"".to_string(), path]);
            }
            None => {
                for (k, val) in &secret {
                    v.push(format!("--env={k}={val}"));
                }
            }
        }
        v.push(self.program.clone());
        v.extend(self.args.iter().cloned());
        v
    }

    pub fn command(&self) -> Command {
        let argv = self.argv();
        let mut c = Command::new(&argv[0]);
        c.args(&argv[1..]);
        if !util::is_flatpak() {
            for k in &self.unset {
                c.env_remove(k);
            }
            for (k, v) in &self.env {
                c.env(k, v);
            }
            if let Some(dir) = &self.cwd {
                c.current_dir(dir);
            }
        }
        c
    }

    pub fn output(&self) -> (String, String, bool) {
        let mut c = self.command();
        c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        match c.output() {
            Ok(out) => (String::from_utf8_lossy(&out.stdout).to_string(), String::from_utf8_lossy(&out.stderr).to_string(), out.status.success()),
            Err(e) => (String::new(), e.to_string(), false),
        }
    }
}

const SECRET_ENV: &[&str] = &["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"];

fn shared_runtime_dir() -> Option<std::path::PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok().filter(|s| !s.is_empty())?;
    let app = std::env::var("FLATPAK_ID").ok().filter(|s| !s.is_empty())?;
    let dir = Path::new(&runtime).join("app").join(app);
    dir.is_dir().then_some(dir)
}

fn write_secret_env(dir: &Path, vars: &[&(String, String)]) -> Option<String> {
    crate::claude::endpoint::sweep(dir, std::time::SystemTime::now());
    let id: String = uuid::Uuid::new_v4().simple().to_string().chars().take(8).collect();
    let path = dir.join(format!("env-{id}")).to_string_lossy().to_string();
    let body: String = vars.iter().map(|(k, v)| format!("export {k}={}\n", util::shell_quote(v))).collect();
    crate::claude::launcher::write_private(&path, &body, 0o600).ok()?;
    Some(path)
}

static FOUND: LazyLock<Mutex<HashMap<String, Option<String>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn executable(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

pub fn find(name: &str, candidates: &[String]) -> Option<String> {
    if let Some(hit) = FOUND.lock().ok().and_then(|m| m.get(name).cloned()) {
        if hit.as_deref().map(|p| util::is_flatpak() || executable(p)).unwrap_or(false) {
            return hit;
        }
    }
    let found = if util::is_flatpak() {
        let mut script = String::new();
        for c in candidates {
            script.push_str(&format!("[ -x {} ] && {{ echo {}; exit 0; }}; ", util::shell_quote(c), util::shell_quote(c)));
        }
        script.push_str(&format!("command -v {} 2>/dev/null", util::shell_quote(name)));
        let (out, _, _) = HostCmd::new("sh").arg("-lc").arg(script).output();
        out.lines().map(|l| l.trim().to_string()).find(|l| l.starts_with('/'))
    } else {
        candidates
            .iter()
            .find(|c| executable(c))
            .cloned()
            .or_else(|| gtk::glib::find_program_in_path(name).map(|p| p.to_string_lossy().to_string()))
    };
    if let Ok(mut m) = FOUND.lock() {
        m.insert(name.to_string(), found.clone());
    }
    found
}

pub fn forget(name: &str) {
    if let Ok(mut m) = FOUND.lock() {
        m.remove(name);
    }
}

pub fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| util::home())
}

pub fn gh_binary() -> Option<String> {
    let h = home();
    find(
        "gh",
        &[
            "/usr/bin/gh".into(),
            "/usr/local/bin/gh".into(),
            "/home/linuxbrew/.linuxbrew/bin/gh".into(),
            format!("{h}/.local/bin/gh"),
            "/snap/bin/gh".into(),
        ],
    )
}

pub fn glab_binary() -> Option<String> {
    let h = home();
    find(
        "glab",
        &[
            "/usr/bin/glab".into(),
            "/usr/local/bin/glab".into(),
            "/home/linuxbrew/.linuxbrew/bin/glab".into(),
            format!("{h}/.local/bin/glab"),
            "/snap/bin/glab".into(),
        ],
    )
}

pub fn claude_binary() -> Option<String> {
    let h = home();
    find(
        "claude",
        &[
            format!("{h}/.local/bin/claude"),
            format!("{h}/.claude/local/claude"),
            "/usr/local/bin/claude".into(),
            "/usr/bin/claude".into(),
            format!("{h}/.npm-global/bin/claude"),
            "/home/linuxbrew/.linuxbrew/bin/claude".into(),
        ],
    )
}

pub fn git_binary() -> String {
    find("git", &["/usr/bin/git".into(), "/usr/local/bin/git".into()]).unwrap_or_else(|| "git".into())
}

pub fn path_with(bin: &str) -> String {
    let h = home();
    let dir = Path::new(bin).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    let base = std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into());
    let base = if util::is_flatpak() { "/usr/local/bin:/usr/bin:/bin".to_string() } else { base };
    [dir, format!("{h}/.local/bin"), "/home/linuxbrew/.linuxbrew/bin".into(), "/usr/local/bin".into(), base].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(":")
}

pub fn user_shell() -> String {
    if util::is_flatpak() {
        let (out, _, ok) = HostCmd::new("sh").arg("-c").arg("getent passwd \"$(id -un)\" | cut -d: -f7").output();
        let s = out.trim().to_string();
        if ok && s.starts_with('/') {
            return s;
        }
        return "/bin/bash".into();
    }
    std::env::var("SHELL").ok().filter(|s| executable(s)).unwrap_or_else(|| if executable("/bin/bash") { "/bin/bash".into() } else { "/bin/sh".into() })
}

#[cfg(test)]
mod secret_env_tests {
    use super::*;

    #[test]
    fn sandboxed_secrets_go_through_private_file() {
        let dir = std::env::temp_dir().join(format!("hostcmd-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let cmd = HostCmd::new("claude").arg("-p").env("ANTHROPIC_AUTH_TOKEN", "sk-or-secret").env("ANTHROPIC_BASE_URL", "https://openrouter.ai/api").cwd("/w");
        let argv = cmd.sandboxed_argv(Some(&dir));
        assert!(!argv.iter().any(|a| a.contains("sk-or-secret")));
        assert!(argv.contains(&"--env=ANTHROPIC_BASE_URL=https://openrouter.ai/api".to_string()));
        let at = argv.iter().position(|a| a == "/bin/sh").unwrap();
        let file = argv[at + 3].clone();
        assert_eq!(&argv[at + 4..], &["claude".to_string(), "-p".to_string()]);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let out = Command::new(&argv[at]).args(&argv[at + 1..at + 4]).args(["printenv", "ANTHROPIC_AUTH_TOKEN"]).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "sk-or-secret");
        assert!(!Path::new(&file).exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sandboxed_without_secret_dir_falls_back_to_env_flags() {
        let argv = HostCmd::new("claude").env("ANTHROPIC_AUTH_TOKEN", "k").sandboxed_argv(None);
        assert!(argv.contains(&"--env=ANTHROPIC_AUTH_TOKEN=k".to_string()));
        assert!(!argv.contains(&"/bin/sh".to_string()));
        let plain = HostCmd::new("git").env("PATH", "/bin").sandboxed_argv(Some(Path::new("/nonexistent")));
        assert!(!plain.contains(&"/bin/sh".to_string()));
    }
}
