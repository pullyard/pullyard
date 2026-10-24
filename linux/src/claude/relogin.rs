use std::path::Path;
use std::time::{Duration, SystemTime};

use super::{accounts, launcher};
use crate::host::{self, HostCmd};
use crate::util;

pub const MAX_ATTEMPTS: u32 = 90;

pub fn poll_delay(attempt: u32) -> Duration {
    Duration::from_secs((3 + attempt as u64).min(10))
}

pub fn parse_logged_in(out: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(out.trim()).ok().and_then(|v| v.get("loggedIn").and_then(|b| b.as_bool())).unwrap_or(false)
}

pub fn login_script(bin: &str, path: &str, browser: &str, config_dir: Option<&str>, unset: &[String]) -> String {
    let mut s = String::new();
    if !unset.is_empty() {
        s.push_str(&format!("unset {}\n", unset.iter().map(|k| util::shell_quote(k)).collect::<Vec<_>>().join(" ")));
    }
    s.push_str(&format!("export PATH={}\n", util::shell_quote(path)));
    s.push_str(&format!("export BROWSER={}\n", util::shell_quote(browser)));
    if let Some(d) = config_dir {
        s.push_str(&format!("export CLAUDE_CONFIG_DIR={}\n", util::shell_quote(d)));
    }
    s.push_str(&format!(
        "clear\n{} auth login\nstatus=$?\necho\nif [ $status -eq 0 ]; then echo 'Signed in. You can close this window.'; else echo 'Sign-in did not finish.'; fi\nread -r -p 'Press Enter to close' _\n",
        util::shell_quote(bin)
    ));
    s
}

fn open_terminal_login(config_dir: Option<&str>) -> Result<(), String> {
    let bin = host::claude_binary().ok_or_else(|| "claude CLI not found".to_string())?;
    let (term, term_args) = launcher::terminal_emulator().ok_or_else(|| "No terminal emulator found".to_string())?;
    let env = accounts::env(config_dir, &bin);
    let get = |k: &str| env.set.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()).unwrap_or_default();
    let script = login_script(&bin, &get("PATH"), &get("BROWSER"), config_dir, &env.unset);
    let mut cmd = HostCmd::new(&term).cwd(&host::home());
    for a in term_args {
        cmd = cmd.arg(a);
    }
    cmd = cmd.arg("/bin/bash").arg("-c").arg(script);
    cmd.command().spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn credentials_stamp(dir: &str) -> Option<SystemTime> {
    std::fs::metadata(Path::new(dir).join(".credentials.json")).and_then(|m| m.modified()).ok()
}

async fn logged_in(config_dir: Option<String>) -> bool {
    let Some(bin) = crate::rt::blocking(host::claude_binary).await else {
        return false;
    };
    let cmd = accounts::command(&bin, config_dir.as_deref()).args(["auth", "status"]);
    let (out, _, _) = crate::rt::blocking(move || cmd.output()).await;
    parse_logged_in(&out)
}

pub fn sign_in_again(config_dir: Option<String>, on_done: impl FnOnce(Result<(), String>) + 'static) {
    let dir = config_dir.clone().unwrap_or_else(|| accounts::config_dir(None));
    let start = credentials_stamp(&dir);
    if let Err(e) = open_terminal_login(config_dir.as_deref()) {
        if host::claude_binary().is_none() {
            on_done(Err(e));
            return;
        }
        accounts::store().login(accounts::LoginMethod::ClaudeAi, "");
    }
    crate::rt::spawn_local(async move {
        for attempt in 0..MAX_ATTEMPTS {
            crate::rt::sleep(poll_delay(attempt)).await;
            let now = credentials_stamp(&dir);
            if (now != start || now.is_none()) && logged_in(config_dir.clone()).await {
                crate::rt::spawn_local(async { accounts::store().refresh().await });
                on_done(Ok(()));
                return;
            }
        }
        on_done(Err("Sign-in timed out".into()));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn poll_backs_off_to_ten_seconds() {
        assert_eq!(poll_delay(0), Duration::from_secs(3));
        assert_eq!(poll_delay(4), Duration::from_secs(7));
        assert_eq!(poll_delay(50), Duration::from_secs(10));
    }

    #[test]
    fn parses_auth_status() {
        assert!(parse_logged_in("{\"loggedIn\": true, \"email\": \"a@b\"}\n"));
        assert!(!parse_logged_in("{\"loggedIn\": false}"));
        assert!(!parse_logged_in("Not logged in"));
    }

    #[test]
    fn script_exports_profile_and_runs_login() {
        let s = login_script("/opt/claude bin/claude", "/usr/bin", "xdg-open", Some("/home/u/.claude-work"), &["CLAUDECODE".to_string()]);
        assert!(s.starts_with("unset 'CLAUDECODE'\n") || s.starts_with("unset CLAUDECODE\n"));
        assert!(s.contains("CLAUDE_CONFIG_DIR="));
        assert!(s.contains("auth login"));
        assert!(s.contains("'/opt/claude bin/claude'"));
        let plain = login_script("/usr/bin/claude", "/usr/bin", "xdg-open", None, &[]);
        assert!(!plain.contains("CLAUDE_CONFIG_DIR"));
        assert!(!plain.contains("unset"));
    }
}
