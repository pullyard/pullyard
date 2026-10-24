use std::cell::RefCell;
use std::sync::OnceLock;

use adw::prelude::*;
use gtk::gio;

use crate::host::{self, HostCmd};
use crate::ui::menu::Menu;
use crate::{settings, util};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Editor,
    Terminal,
    Files,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ExternalApp {
    pub id: &'static str,
    pub name: &'static str,
    pub kind: Kind,
    pub path: Option<String>,
    dir_args: &'static [&'static str],
}

struct Known {
    id: &'static str,
    name: &'static str,
    kind: Kind,
    binaries: &'static [&'static str],
    toolbox: &'static [&'static str],
    dir_args: &'static [&'static str],
}

const KNOWN: &[Known] = &[
    Known { id: "code", name: "VS Code", kind: Kind::Editor, binaries: &["code", "code-oss", "codium"], toolbox: &[], dir_args: &[] },
    Known { id: "cursor", name: "Cursor", kind: Kind::Editor, binaries: &["cursor"], toolbox: &[], dir_args: &[] },
    Known { id: "windsurf", name: "Windsurf", kind: Kind::Editor, binaries: &["windsurf"], toolbox: &[], dir_args: &[] },
    Known { id: "zed", name: "Zed", kind: Kind::Editor, binaries: &["zed", "zeditor", "zedit"], toolbox: &[], dir_args: &[] },
    Known { id: "subl", name: "Sublime Text", kind: Kind::Editor, binaries: &["subl"], toolbox: &[], dir_args: &[] },
    Known {
        id: "idea",
        name: "IntelliJ IDEA",
        kind: Kind::Editor,
        binaries: &["idea", "intellij-idea-ultimate", "intellij-idea-community", "idea.sh"],
        toolbox: &["idea", "idea-ultimate", "idea-community", "intellij-idea-ultimate", "intellij-idea-community"],
        dir_args: &[],
    },
    Known { id: "webstorm", name: "WebStorm", kind: Kind::Editor, binaries: &["webstorm", "webstorm.sh"], toolbox: &["webstorm"], dir_args: &[] },
    Known {
        id: "pycharm",
        name: "PyCharm",
        kind: Kind::Editor,
        binaries: &["pycharm", "pycharm-professional", "pycharm-community", "pycharm.sh"],
        toolbox: &["pycharm", "pycharm-professional", "pycharm-community"],
        dir_args: &[],
    },
    Known { id: "goland", name: "GoLand", kind: Kind::Editor, binaries: &["goland", "goland.sh"], toolbox: &["goland"], dir_args: &[] },
    Known { id: "rustrover", name: "RustRover", kind: Kind::Editor, binaries: &["rustrover", "rustrover.sh"], toolbox: &["rustrover"], dir_args: &[] },
    Known { id: "android-studio", name: "Android Studio", kind: Kind::Editor, binaries: &["android-studio", "studio", "studio.sh"], toolbox: &["studio", "android-studio"], dir_args: &[] },
    Known { id: "gnome-text-editor", name: "Text Editor", kind: Kind::Editor, binaries: &["gnome-text-editor"], toolbox: &[], dir_args: &[] },
    Known { id: "kgx", name: "Console", kind: Kind::Terminal, binaries: &["kgx"], toolbox: &[], dir_args: &["--working-directory={}"] },
    Known { id: "ptyxis", name: "Ptyxis", kind: Kind::Terminal, binaries: &["ptyxis"], toolbox: &[], dir_args: &["--new-window", "--working-directory={}"] },
    Known { id: "gnome-terminal", name: "GNOME Terminal", kind: Kind::Terminal, binaries: &["gnome-terminal"], toolbox: &[], dir_args: &["--working-directory={}"] },
    Known { id: "konsole", name: "Konsole", kind: Kind::Terminal, binaries: &["konsole"], toolbox: &[], dir_args: &["--workdir", "{}"] },
    Known { id: "xfce4-terminal", name: "Xfce Terminal", kind: Kind::Terminal, binaries: &["xfce4-terminal"], toolbox: &[], dir_args: &["--working-directory={}"] },
    Known { id: "tilix", name: "Tilix", kind: Kind::Terminal, binaries: &["tilix"], toolbox: &[], dir_args: &["--working-directory={}"] },
    Known { id: "ghostty", name: "Ghostty", kind: Kind::Terminal, binaries: &["ghostty"], toolbox: &[], dir_args: &["--working-directory={}"] },
    Known { id: "wezterm", name: "WezTerm", kind: Kind::Terminal, binaries: &["wezterm"], toolbox: &[], dir_args: &["start", "--cwd", "{}"] },
    Known { id: "alacritty", name: "Alacritty", kind: Kind::Terminal, binaries: &["alacritty"], toolbox: &[], dir_args: &["--working-directory", "{}"] },
    Known { id: "kitty", name: "kitty", kind: Kind::Terminal, binaries: &["kitty"], toolbox: &[], dir_args: &["--directory", "{}"] },
    Known { id: "xterm", name: "XTerm", kind: Kind::Terminal, binaries: &["xterm"], toolbox: &[], dir_args: &[] },
];

pub const FILES_ID: &str = "files";

fn files_app() -> ExternalApp {
    ExternalApp { id: FILES_ID, name: "Files", kind: Kind::Files, path: None, dir_args: &[] }
}

fn locate(k: &Known) -> Option<String> {
    let h = host::home();
    for b in k.binaries {
        let candidates = vec![format!("/usr/bin/{b}"), format!("/usr/local/bin/{b}"), format!("{h}/.local/bin/{b}"), format!("/snap/bin/{b}"), format!("/var/lib/flatpak/exports/bin/{b}")];
        if let Some(p) = host::find(b, &candidates) {
            return Some(p);
        }
    }
    for t in k.toolbox {
        let p = format!("{h}/.local/share/JetBrains/Toolbox/scripts/{t}");
        if let Some(p) = host::find(&format!("toolbox-{t}"), &[p]).filter(|p| p.contains("/JetBrains/Toolbox/")) {
            return Some(p);
        }
    }
    None
}

pub fn detect() -> Vec<ExternalApp> {
    let mut out: Vec<ExternalApp> = KNOWN.iter().filter_map(|k| locate(k).map(|path| ExternalApp { id: k.id, name: k.name, kind: k.kind, path: Some(path), dir_args: k.dir_args })).collect();
    if !out.iter().any(|a| a.kind == Kind::Terminal) {
        if let Some((term, _)) = crate::claude::launcher::terminal_emulator() {
            out.push(ExternalApp { id: "x-terminal", name: "Terminal", kind: Kind::Terminal, path: Some(term), dir_args: &[] });
        }
    }
    out.push(files_app());
    out
}

static INSTALLED: OnceLock<Vec<ExternalApp>> = OnceLock::new();

thread_local! {
    static WAITING: RefCell<Vec<Box<dyn FnOnce()>>> = const { RefCell::new(vec![]) };
}

pub fn installed() -> Option<&'static Vec<ExternalApp>> {
    INSTALLED.get()
}

pub fn when_ready(f: impl FnOnce() + 'static) {
    if INSTALLED.get().is_some() {
        f();
        return;
    }
    let first = WAITING.with(|w| {
        let mut w = w.borrow_mut();
        w.push(Box::new(f));
        w.len() == 1
    });
    if !first {
        return;
    }
    crate::rt::spawn_local(async {
        let apps = crate::rt::blocking(detect).await;
        let _ = INSTALLED.set(apps);
        let pending = WAITING.with(|w| std::mem::take(&mut *w.borrow_mut()));
        for f in pending {
            f();
        }
    });
}

pub fn primary<'a>(apps: &'a [ExternalApp], preferred: &str) -> Option<&'a ExternalApp> {
    apps.iter().find(|a| a.id == preferred).or_else(|| apps.iter().find(|a| a.kind == Kind::Editor)).or_else(|| apps.first())
}

pub fn argv_for(app: &ExternalApp, folder: &str) -> Vec<String> {
    let mut v = vec![app.path.clone().unwrap_or_default()];
    if app.kind == Kind::Terminal {
        v.extend(app.dir_args.iter().map(|a| a.replace("{}", folder)));
    } else {
        v.push(folder.to_string());
    }
    v
}

pub fn open(app: &ExternalApp, folder: &str) {
    if app.kind == Kind::Files {
        util::open_path(folder);
        return;
    }
    let argv = argv_for(app, folder);
    let cmd = HostCmd::new(&argv[0]).args(argv[1..].iter().cloned()).cwd(folder);
    let full = cmd.argv();
    let launcher = gio::SubprocessLauncher::new(gio::SubprocessFlags::STDOUT_SILENCE | gio::SubprocessFlags::STDERR_SILENCE);
    if !util::is_flatpak() {
        launcher.set_cwd(folder);
        for k in crate::claude::clean_env_keys() {
            launcher.unsetenv(k);
        }
    }
    let refs: Vec<&std::ffi::OsStr> = full.iter().map(std::ffi::OsStr::new).collect();
    if let Err(e) = launcher.spawn(&refs) {
        crate::ui::dialogs::error(&format!("Couldn't open {}: {e}", app.name));
    }
}

fn choose(app: &ExternalApp, folder: &str) {
    let id = app.id.to_string();
    settings::update(|s| s.agents_open_in = id);
    open(app, folder);
}

fn fill(button: &adw::SplitButton, folder: &str, apps: &[ExternalApp]) {
    let preferred = settings::read(|s| s.agents_open_in.clone());
    let Some(main) = primary(apps, &preferred).cloned() else {
        return;
    };
    let content = adw::ButtonContent::new();
    content.set_icon_name("document-open-symbolic");
    content.set_label(&format!("Open in {}", main.name));
    content.set_use_underline(false);
    button.set_child(Some(&content));
    button.set_tooltip_text(Some(&format!("Open the project in {} — use the arrow for more", main.name)));
    button.set_dropdown_tooltip("Open in another app");
    let mut menu = Menu::new();
    for (title, kind) in [("Editors", Kind::Editor), ("Terminals", Kind::Terminal)] {
        let list: Vec<&ExternalApp> = apps.iter().filter(|a| a.kind == kind).collect();
        if list.is_empty() {
            continue;
        }
        menu.section(Some(title));
        for a in list {
            let (a, f) = (a.clone(), folder.to_string());
            let label = if a.id == main.id { format!("✓ {}", a.name) } else { a.name.to_string() };
            menu.item(&label, move || choose(&a, &f));
        }
    }
    menu.section(None);
    let files = files_app();
    let f = folder.to_string();
    menu.item(if main.id == FILES_ID { "✓ Files" } else { "Files" }, move || choose(&files, &f));
    button.set_menu_model(Some(&menu.model));
    menu.attach(button);
    let f = folder.to_string();
    button.connect_clicked(move |_| {
        let preferred = settings::read(|s| s.agents_open_in.clone());
        if let Some(a) = installed().and_then(|apps| primary(apps, &preferred).cloned()) {
            open(&a, &f);
        }
    });
}

pub fn button(folder: &str) -> adw::SplitButton {
    let b = adw::SplitButton::new();
    b.add_css_class("flat");
    let content = adw::ButtonContent::new();
    content.set_icon_name("document-open-symbolic");
    content.set_label("Open in…");
    b.set_child(Some(&content));
    b.set_sensitive(std::path::Path::new(folder).is_dir());
    let weak = b.downgrade();
    let f = folder.to_string();
    when_ready(move || {
        if let (Some(b), Some(apps)) = (weak.upgrade(), installed()) {
            fill(&b, &f, apps);
        }
    });
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &'static str, kind: Kind, dir_args: &'static [&'static str]) -> ExternalApp {
        ExternalApp { id, name: id, kind, path: Some(format!("/usr/bin/{id}")), dir_args }
    }

    #[test]
    fn picks_primary_and_builds_argv() {
        let apps = vec![app("kgx", Kind::Terminal, &["--working-directory={}"]), app("zed", Kind::Editor, &[]), files_app()];
        assert_eq!(primary(&apps, "").map(|a| a.id), Some("zed"));
        assert_eq!(primary(&apps, "kgx").map(|a| a.id), Some("kgx"));
        assert_eq!(primary(&apps, "missing").map(|a| a.id), Some("zed"));
        assert_eq!(argv_for(&apps[0], "/p"), vec!["/usr/bin/kgx".to_string(), "--working-directory=/p".to_string()]);
        assert_eq!(argv_for(&apps[1], "/p"), vec!["/usr/bin/zed".to_string(), "/p".to_string()]);
        assert!(primary(&[], "").is_none());
    }

    #[test]
    fn known_ids_are_unique() {
        let mut ids: Vec<&str> = KNOWN.iter().map(|k| k.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), KNOWN.len());
    }
}
