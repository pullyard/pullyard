use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use crate::host::{self, HostCmd};
use crate::settings::{self, ClaudeProfile};
use crate::signal::Signal;
use crate::{demo, util};

pub const DEFAULT_ID: &str = "default";
const SHARED_ITEMS: &[&str] = &["settings.json", "CLAUDE.md", "RTK.md", "skills", "commands", "plugins", "agents", "output-styles", "keybindings.json"];

pub fn profiles() -> Vec<ClaudeProfile> {
    let mut list = settings::read(|s| s.claude_profiles.clone());
    if !list.iter().any(|p| p.id == DEFAULT_ID) {
        list.insert(0, ClaudeProfile { id: DEFAULT_ID.into(), label: "Main".into(), config_dir: None, email: None, plan: None, owner: None });
    }
    list
}

thread_local! {
    static SCOPE: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub fn scope() -> Option<String> {
    SCOPE.with(|s| s.borrow().clone())
}

pub fn set_scope(owner: Option<String>) {
    SCOPE.with(|s| *s.borrow_mut() = owner);
}

pub fn visible_in(list: Vec<ClaudeProfile>, scope: Option<&str>) -> Vec<ClaudeProfile> {
    match scope {
        Some(owner) => list.into_iter().filter(|p| p.owner.as_deref() == Some(owner)).collect(),
        None => list,
    }
}

pub fn visible() -> Vec<ClaudeProfile> {
    visible_in(profiles(), scope().as_deref())
}

pub fn is_visible(id: &str) -> bool {
    visible().iter().any(|p| p.id == id)
}

pub fn owns_main() -> bool {
    visible().iter().any(|p| p.is_default())
}

pub fn owned(owner: &str) -> Vec<ClaudeProfile> {
    visible_in(profiles(), Some(owner))
}

pub fn preferred_in(list: &[ClaudeProfile], owner: &str, remembered: Option<&str>, active: &str) -> Option<ClaudeProfile> {
    let mine: Vec<&ClaudeProfile> = list.iter().filter(|p| p.owner.as_deref() == Some(owner)).collect();
    mine.iter().find(|p| Some(p.id.as_str()) == remembered).or_else(|| mine.iter().find(|p| p.id == active)).or_else(|| mine.first()).map(|p| (*p).clone())
}

pub fn preferred(owner: &str) -> Option<ClaudeProfile> {
    let remembered = settings::read(|s| s.claude_active_by_owner.get(owner).cloned());
    preferred_in(&profiles(), owner, remembered.as_deref(), &active_id())
}

pub fn claim_in(list: &mut [ClaudeProfile], owner: &str) -> bool {
    let mut claimed = false;
    for p in list.iter_mut().filter(|p| p.owner.is_none()) {
        p.owner = Some(owner.to_string());
        claimed = true;
    }
    claimed
}

pub fn claim_unowned(owner: &str) -> bool {
    let mut list = profiles();
    if !claim_in(&mut list, owner) {
        return false;
    }
    save(list, active_id());
    true
}

pub fn release(id: &str) {
    let mut list = profiles();
    if let Some(p) = list.iter_mut().find(|p| p.id == id) {
        p.owner = None;
        p.email = None;
        p.plan = None;
    }
    save(list, active_id());
    forget_remembered(id);
}

fn forget_remembered(id: &str) {
    if settings::read(|s| s.claude_active_by_owner.values().any(|v| v == id)) {
        settings::update(|s| s.claude_active_by_owner.retain(|_, v| v != id));
    }
}

pub fn active_id() -> String {
    let id = settings::read(|s| s.claude_active_profile.clone());
    if profiles().iter().any(|p| p.id == id) {
        id
    } else {
        DEFAULT_ID.into()
    }
}

pub fn active() -> ClaudeProfile {
    let id = active_id();
    profiles().into_iter().find(|p| p.id == id).unwrap_or_else(|| profiles()[0].clone())
}

pub fn active_override() -> Option<String> {
    active().config_dir
}

pub fn default_config_dir() -> String {
    std::env::var("CLAUDE_CONFIG_DIR").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| format!("{}/.claude", host::home()))
}

pub fn config_dir(profile: Option<&ClaudeProfile>) -> String {
    let p = profile.cloned().unwrap_or_else(active);
    p.config_dir.unwrap_or_else(default_config_dir)
}

fn save(list: Vec<ClaudeProfile>, active: String) {
    settings::update(|s| {
        s.claude_profiles = list;
        s.claude_active_profile = active;
    });
}

pub fn base_dir() -> std::path::PathBuf {
    if util::is_flatpak() {
        std::path::PathBuf::from(format!("{}/.local/share/{}/ClaudeAccounts", host::home(), crate::brand::BIN_NAME))
    } else {
        settings::data_dir().join("ClaudeAccounts")
    }
}

pub fn update_cached_info(email: Option<String>, plan: Option<String>) {
    let mut list = profiles();
    let id = active_id();
    if let Some(p) = list.iter_mut().find(|p| p.id == id) {
        if p.email != email || p.plan != plan {
            p.email = email;
            p.plan = plan;
            save(list, id);
        }
    }
}

pub fn add(label: &str, share: bool) -> Result<ClaudeProfile, String> {
    add_owned(label, share, scope())
}

pub fn add_owned(label: &str, share: bool, owner: Option<String>) -> Result<ClaudeProfile, String> {
    let id = uuid::Uuid::new_v4().to_string().to_lowercase();
    let dir = base_dir().join(&id);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if share {
        let source = std::path::PathBuf::from(default_config_dir());
        for item in SHARED_ITEMS {
            let src = source.join(item);
            if src.exists() {
                let _ = std::os::unix::fs::symlink(&src, dir.join(item));
            }
        }
    }
    let mut list = profiles();
    let name = label.trim();
    let p = ClaudeProfile {
        id,
        label: if name.is_empty() { format!("Account {}", list.len() + 1) } else { name.to_string() },
        config_dir: Some(dir.to_string_lossy().to_string()),
        email: None,
        plan: None,
        owner,
    };
    list.push(p.clone());
    save(list, active_id());
    Ok(p)
}

pub fn remove(id: &str) {
    if id == DEFAULT_ID {
        return;
    }
    let list: Vec<ClaudeProfile> = profiles().into_iter().filter(|p| p.id != id).collect();
    let active = if active_id() == id { DEFAULT_ID.to_string() } else { active_id() };
    save(list, active);
    forget_remembered(id);
}

pub fn set_active(id: &str) {
    let Some(p) = profiles().into_iter().find(|p| p.id == id) else { return };
    save(profiles(), id.to_string());
    if let Some(owner) = p.owner {
        if settings::read(|s| s.claude_active_by_owner.get(&owner).map(|v| v.as_str()) != Some(id)) {
            let id = id.to_string();
            settings::update(|s| {
                s.claude_active_by_owner.insert(owner, id);
            });
        }
    }
}

pub fn browser_command() -> String {
    let chosen = settings::read(|s| s.link_browser.clone());
    if chosen != "system" && !util::is_flatpak() {
        use gtk::prelude::*;
        if let Some(info) = gtk::gio::AppInfo::all_for_type("x-scheme-handler/https").into_iter().find(|i| i.id().map(|s| s.as_str() == chosen).unwrap_or(false)) {
            if let Some(exe) = info.executable().to_str() {
                if !exe.is_empty() {
                    return exe.to_string();
                }
            }
        }
    }
    "xdg-open".into()
}

pub struct Env {
    pub set: Vec<(String, String)>,
    pub unset: Vec<String>,
}

pub fn env(config_dir: Option<&str>, bin: &str) -> Env {
    let mut set = vec![("PATH".to_string(), host::path_with(bin)), ("BROWSER".to_string(), browser_command())];
    if let Some(d) = config_dir {
        set.push(("CLAUDE_CONFIG_DIR".into(), d.to_string()));
    }
    let mut unset = super::clean_env_keys();
    if config_dir.is_none() && util::is_flatpak() {
        unset.push("CLAUDE_CONFIG_DIR".into());
    }
    Env { set, unset }
}

pub fn command(bin: &str, config_dir: Option<&str>) -> HostCmd {
    let e = env(config_dir, bin);
    let mut c = HostCmd::new(bin);
    for (k, v) in e.set {
        c = c.env(&k, &v);
    }
    for k in e.unset {
        c = c.unset(&k);
    }
    c
}

#[derive(Clone, Debug)]
pub struct AccountInfo {
    pub email: Option<String>,
    pub org_name: Option<String>,
    pub subscription: Option<String>,
    pub method: Option<String>,
    pub provider: Option<String>,
}

#[derive(Clone, Debug)]
pub enum Status {
    Unknown,
    Checking,
    NotInstalled,
    LoggedOut,
    LoggedIn(AccountInfo),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum LoginMethod {
    ClaudeAi,
    Console,
    Sso,
}

impl LoginMethod {
    pub const ALL: [LoginMethod; 3] = [LoginMethod::ClaudeAi, LoginMethod::Console, LoginMethod::Sso];

    pub fn title(&self) -> &'static str {
        match self {
            LoginMethod::ClaudeAi => "Claude subscription (Pro, Max, Team)",
            LoginMethod::Console => "Anthropic Console (API billing)",
            LoginMethod::Sso => "SSO",
        }
    }

    pub fn flag(&self) -> &'static str {
        match self {
            LoginMethod::ClaudeAi => "--claudeai",
            LoginMethod::Console => "--console",
            LoginMethod::Sso => "--sso",
        }
    }
}

pub struct AccountStore {
    pub status: RefCell<Status>,
    pub logging_in: Cell<bool>,
    pub login_error: RefCell<Option<String>>,
    login_generation: Cell<u64>,
    pub changed: Signal<()>,
}

thread_local! {
    static STORE: Rc<AccountStore> = Rc::new(AccountStore {
        status: RefCell::new(Status::Unknown),
        logging_in: Cell::new(false),
        login_error: RefCell::new(None),
        login_generation: Cell::new(0),
        changed: Signal::new(),
    });
}

const LOGIN_POLL_FIRST: Duration = Duration::from_secs(2);
const LOGIN_POLL_MAX: Duration = Duration::from_secs(15);
const LOGIN_POLL_LIMIT: Duration = Duration::from_secs(15 * 60);

pub fn next_poll_delay(current: Duration) -> Duration {
    (current.mul_f64(1.5)).min(LOGIN_POLL_MAX)
}

pub fn login_script(bin: &str, method: LoginMethod, email: &str, env: &Env) -> String {
    let mut lines = vec!["#!/bin/bash".to_string()];
    for (k, v) in &env.set {
        lines.push(format!("export {k}={}", util::shell_quote(v)));
    }
    let unset: Vec<String> = env.unset.iter().map(|k| util::shell_quote(k)).collect();
    if !unset.is_empty() {
        lines.push(format!("unset {}", unset.join(" ")));
    }
    lines.push("unset $(env | grep -o '^CLAUDE_CODE_[A-Z_]*') CLAUDECODE".to_string());
    lines.push(format!("unset {}", crate::brand::env_key("TOKEN")));
    lines.push("rm -f \"$0\"".to_string());
    lines.push("clear".to_string());
    let mut cmd = format!("{} auth login {}", util::shell_quote(bin), method.flag());
    let email = email.trim();
    if !email.is_empty() {
        cmd.push_str(&format!(" --email {}", util::shell_quote(email)));
    }
    lines.push(cmd);
    lines.push("echo".to_string());
    lines.push(format!("echo {}", util::shell_quote(&format!("You can close this window and return to {}.", crate::brand::APP_NAME))));
    lines.push("read -r -s -n 1 -t 600".to_string());
    lines.join("\n") + "\n"
}

pub fn store() -> Rc<AccountStore> {
    STORE.with(|s| s.clone())
}

impl AccountStore {
    pub fn is_logged_in(&self) -> bool {
        matches!(*self.status.borrow(), Status::LoggedIn(_))
    }

    fn set_status(&self, s: Status) {
        *self.status.borrow_mut() = s;
        self.changed.emit(&());
    }

    pub async fn refresh(self: Rc<Self>) {
        let bin = crate::rt::blocking(host::claude_binary).await;
        let Some(bin) = bin else {
            self.set_status(Status::NotInstalled);
            return;
        };
        if matches!(*self.status.borrow(), Status::Unknown) {
            self.set_status(Status::Checking);
        }
        let cmd = command(&bin, active_override().as_deref()).args(["auth", "status"]);
        let (out, _, _) = crate::rt::blocking(move || cmd.output()).await;
        let json: Option<serde_json::Value> = serde_json::from_str(out.trim()).ok();
        let Some(json) = json else {
            self.set_status(Status::LoggedOut);
            return;
        };
        if json.get("loggedIn").and_then(|v| v.as_bool()) == Some(true) {
            let s = |k: &str| json.get(k).and_then(|v| v.as_str()).map(|s| s.to_string());
            let capitalize = |v: String| {
                let mut c = v.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase()).unwrap_or_default()
            };
            let plan = s("subscriptionType").map(capitalize);
            if !demo::is_on() {
                update_cached_info(s("email"), plan.clone());
            }
            self.set_status(Status::LoggedIn(AccountInfo {
                email: if demo::is_on() { Some(demo::EMAIL.into()) } else { s("email") },
                org_name: if demo::is_on() { None } else { s("orgName") },
                subscription: plan,
                method: s("authMethod"),
                provider: s("apiProvider"),
            }));
        } else {
            self.set_status(Status::LoggedOut);
        }
    }

    pub fn login_in_terminal(self: &Rc<Self>, method: LoginMethod, email: &str) {
        *self.login_error.borrow_mut() = None;
        let generation = self.login_generation.get() + 1;
        self.login_generation.set(generation);
        match spawn_terminal_login(method, email) {
            Ok(()) => self.logging_in.set(true),
            Err(e) => {
                self.logging_in.set(false);
                *self.login_error.borrow_mut() = Some(e);
            }
        }
        self.changed.emit(&());
        if !self.logging_in.get() {
            return;
        }
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let started = Instant::now();
            let mut delay = LOGIN_POLL_FIRST;
            loop {
                crate::rt::sleep(delay).await;
                if me.login_generation.get() != generation || !me.logging_in.get() {
                    return;
                }
                me.clone().refresh().await;
                if me.login_generation.get() != generation {
                    return;
                }
                if me.is_logged_in() {
                    me.logging_in.set(false);
                    me.changed.emit(&());
                    return;
                }
                if started.elapsed() >= LOGIN_POLL_LIMIT {
                    me.logging_in.set(false);
                    *me.login_error.borrow_mut() = Some("Still not signed in. Finish the sign-in in the terminal, then press “Check again”.".into());
                    me.changed.emit(&());
                    return;
                }
                delay = next_poll_delay(delay);
            }
        });
    }

    pub fn check_login_now(self: &Rc<Self>) {
        let me = self.clone();
        crate::rt::spawn_local(async move {
            me.clone().refresh().await;
            if me.is_logged_in() && me.logging_in.get() {
                me.logging_in.set(false);
                me.changed.emit(&());
            }
        });
    }

    pub fn cancel_login(&self) {
        self.login_generation.set(self.login_generation.get() + 1);
        self.logging_in.set(false);
        self.changed.emit(&());
    }

    pub async fn logout(self: Rc<Self>, config_dir: Option<String>) {
        let Some(bin) = crate::rt::blocking(host::claude_binary).await else { return };
        let dir = config_dir.or_else(active_override);
        let cmd = command(&bin, dir.as_deref()).args(["auth", "logout"]);
        crate::rt::blocking(move || cmd.output()).await;
        self.refresh().await;
    }

    pub async fn logout_profiles(self: Rc<Self>, list: Vec<ClaudeProfile>) {
        if list.is_empty() {
            return;
        }
        let Some(bin) = crate::rt::blocking(host::claude_binary).await else { return };
        let cmds: Vec<HostCmd> = list.iter().map(|p| command(&bin, p.config_dir.as_deref()).args(["auth", "logout"])).collect();
        crate::rt::blocking(move || {
            for cmd in cmds {
                cmd.output();
            }
        })
        .await;
        self.refresh().await;
    }
}

fn spawn_terminal_login(method: LoginMethod, email: &str) -> Result<(), String> {
    let bin = host::claude_binary().ok_or_else(|| "Claude Code isn't installed".to_string())?;
    let (term, term_args) = super::launcher::terminal_emulator().ok_or_else(|| "No terminal emulator found".to_string())?;
    let dir = format!("{}/.cache/{}/claude", host::home(), crate::brand::BIN_NAME);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    let id: String = uuid::Uuid::new_v4().to_string().chars().take(8).collect();
    let script_path = format!("{dir}/login-{id}.sh");
    let script = login_script(&bin, method, email, &env(active_override().as_deref(), &bin));
    super::launcher::write_private(&script_path, &script, 0o700)?;
    let home = host::home();
    let mut cmd = HostCmd::new(&term).cwd(&home);
    for a in term_args {
        cmd = cmd.arg(a);
    }
    cmd = cmd.arg("/bin/bash").arg(script_path.clone());
    cmd.command().spawn().map(|_| ()).map_err(|e| {
        let _ = std::fs::remove_file(&script_path);
        e.to_string()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_script_runs_auth_login_with_method() {
        let e = Env { set: vec![("CLAUDE_CONFIG_DIR".into(), "/p/work dir".into())], unset: vec!["CLAUDECODE".into()] };
        let script = login_script("/usr/bin/claude", LoginMethod::Console, " me@x.io ", &e);
        assert!(script.starts_with("#!/bin/bash\n"));
        assert!(script.contains("export CLAUDE_CONFIG_DIR='/p/work dir'"));
        assert!(script.contains("'/usr/bin/claude' auth login --console --email 'me@x.io'\n"));
        let sso = login_script("claude", LoginMethod::Sso, "", &Env { set: vec![], unset: vec![] });
        assert!(sso.contains("auth login --sso\n"));
        assert!(!sso.contains("--email"));
        assert!(login_script("claude", LoginMethod::ClaudeAi, "", &Env { set: vec![], unset: vec![] }).contains("auth login --claudeai\n"));
    }

    #[test]
    fn login_poll_backs_off_to_a_cap() {
        let mut d = LOGIN_POLL_FIRST;
        let mut seen = vec![d];
        for _ in 0..10 {
            d = next_poll_delay(d);
            seen.push(d);
        }
        assert!(seen.windows(2).all(|w| w[1] >= w[0]));
        assert_eq!(*seen.last().unwrap(), LOGIN_POLL_MAX);
        assert_eq!(next_poll_delay(LOGIN_POLL_FIRST), Duration::from_secs(3));
    }

    fn profile(id: &str, owner: Option<&str>) -> ClaudeProfile {
        ClaudeProfile { id: id.into(), label: id.into(), config_dir: if id == DEFAULT_ID { None } else { Some(format!("/p/{id}")) }, email: None, plan: None, owner: owner.map(|o| o.into()) }
    }

    #[test]
    fn first_account_claims_unowned_profiles() {
        let mut list = vec![profile(DEFAULT_ID, None), profile("work", None), profile("other", Some("b"))];
        assert!(claim_in(&mut list, "a"));
        assert_eq!(visible_in(list.clone(), Some("a")).len(), 2);
        assert!(!claim_in(&mut list, "c"));
        assert_eq!(visible_in(list.clone(), Some("b"))[0].id, "other");
        assert_eq!(visible_in(list, None).len(), 3);
    }

    #[test]
    fn preferred_profile_per_account() {
        let list = vec![profile(DEFAULT_ID, Some("a")), profile("work", Some("a")), profile("b1", Some("b"))];
        assert_eq!(preferred_in(&list, "a", Some("work"), DEFAULT_ID).unwrap().id, "work");
        assert_eq!(preferred_in(&list, "a", Some("b1"), DEFAULT_ID).unwrap().id, DEFAULT_ID);
        assert_eq!(preferred_in(&list, "b", None, DEFAULT_ID).unwrap().id, "b1");
        assert!(preferred_in(&list, "z", None, DEFAULT_ID).is_none());
    }
}
