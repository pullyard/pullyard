use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use super::sidebar::{self, ui_activate};
use super::widgets::*;
use crate::api::models::{Route, SearchItem};
use crate::app::{self, Phase, PrFilter, Section};
use crate::{brand, settings, util};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Group {
    Link,
    GoTo,
    Items,
    Repos,
    Actions,
}

impl Group {
    pub const ALL: [Group; 5] = [Group::Link, Group::GoTo, Group::Items, Group::Repos, Group::Actions];

    pub fn title(&self) -> &'static str {
        match self {
            Group::Link => "Open link",
            Group::GoTo => "Go to",
            Group::Items => "Pull requests & issues",
            Group::Repos => "Repositories",
            Group::Actions => "Actions",
        }
    }

    fn limit(&self, searching: bool) -> usize {
        match self {
            Group::Link => 1,
            Group::GoTo => {
                if searching {
                    6
                } else {
                    20
                }
            }
            Group::Items => {
                if searching {
                    20
                } else {
                    6
                }
            }
            Group::Repos => {
                if searching {
                    12
                } else {
                    3
                }
            }
            Group::Actions => {
                if searching {
                    10
                } else {
                    40
                }
            }
        }
    }
}

#[derive(Clone)]
pub struct Command {
    pub group: Group,
    pub icon: &'static str,
    pub tint: &'static str,
    pub title: String,
    pub detail: String,
    pub shortcut: Option<&'static str>,
    pub keywords: String,
    pub run: Rc<dyn Fn()>,
}

impl Command {
    fn new(group: Group, icon: &'static str, tint: &'static str, title: impl Into<String>, run: impl Fn() + 'static) -> Self {
        Command { group, icon, tint, title: title.into(), detail: String::new(), shortcut: None, keywords: String::new(), run: Rc::new(run) }
    }

    fn detail(mut self, d: impl Into<String>) -> Self {
        self.detail = d.into();
        self
    }

    fn shortcut(mut self, s: &'static str) -> Self {
        self.shortcut = Some(s);
        self
    }

    fn keywords(mut self, k: impl Into<String>) -> Self {
        self.keywords = k.into();
        self
    }

    fn spoken(&self) -> String {
        let mut parts = vec![self.title.clone()];
        if !self.detail.is_empty() {
            parts.push(self.detail.clone());
        }
        parts.push(self.group.title().to_string());
        if let Some(s) = self.shortcut {
            parts.push(format!("shortcut {s}"));
        }
        parts.join(", ")
    }
}

pub fn score_text(text: &str, token: &str) -> Option<i64> {
    if token.is_empty() {
        return Some(0);
    }
    if text.starts_with(token) {
        return Some(1000);
    }
    if let Some(at) = text.find(token) {
        let start = text[..at].chars().count() as i64;
        let boundary = text[..at].chars().last().is_none_or(|c| !c.is_alphabetic());
        return Some(if boundary { 800 } else { 600 } - start.min(100));
    }
    let chars: Vec<char> = text.chars().collect();
    let mut index = 0;
    let mut gaps: i64 = 0;
    for ch in token.chars() {
        let found = chars[index..].iter().position(|c| *c == ch)?;
        gaps += found as i64;
        index += found + 1;
    }
    Some((300 - gaps * 4).max(1))
}

pub fn score(title: &str, extra: &str, tokens: &[String]) -> Option<i64> {
    let title = title.to_lowercase();
    let extra = extra.to_lowercase();
    let mut total = 0;
    for token in tokens {
        total += match score_text(&title, token) {
            Some(s) => s,
            None => score_text(&extra, token)? / 2,
        };
    }
    Some(total)
}

fn tokens(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().map(String::from).collect()
}

fn rank(all: Vec<Command>, tokens: &[String]) -> Vec<Command> {
    if tokens.is_empty() {
        return all;
    }
    let mut scored: Vec<(Command, i64, usize)> = all.into_iter().enumerate().filter_map(|(i, c)| score(&c.title, &format!("{} {}", c.detail, c.keywords), tokens).map(|s| (c, s, i))).collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then(a.2.cmp(&b.2)));
    scored.into_iter().map(|(c, _, _)| c).collect()
}

fn logged_in() -> bool {
    app::try_get().is_some_and(|a| a.state.borrow().phase == Phase::LoggedIn)
}

fn link_commands(query: &str) -> Vec<Command> {
    if !logged_in() || app::api().is_none() {
        return vec![];
    }
    let Some(route) = util::parse_github_url(query, true) else { return vec![] };
    let (icon, tint, title, detail) = match &route {
        Route::Pr(r) => ("sy-pr-symbolic", "green", format!("Open {}", r.title()), "Pull request"),
        Route::Issue(r) => ("sy-issue-symbolic", "green", format!("Open {}", r.title()), "Issue"),
        Route::Repo(r) => ("sy-repo-symbolic", "teal", format!("Open {}", r.full()), "Repository"),
        Route::Commit(r, sha) => ("sy-commit-symbolic", "muted", format!("Open {}@{}", r.full(), sha.chars().take(7).collect::<String>()), "Commit"),
        Route::Project(p) => ("sy-project-symbolic", "indigo", format!("Open {}", p.title), "Project"),
        Route::Forge(url) => ("sy-external-symbolic", "sky", format!("Open {url}"), "Link"),
    };
    let r = route.clone();
    vec![Command::new(Group::Link, icon, tint, title, move || app::open(r.clone(), false)).detail(detail).keywords(query.to_string())]
}

fn section_shortcut(s: Section) -> Option<&'static str> {
    match s {
        Section::Prs(PrFilter::ReviewRequested) => Some("Ctrl+1"),
        Section::Prs(PrFilter::Mine) => Some("Ctrl+2"),
        Section::Notifications => Some("Ctrl+3"),
        Section::Repos => Some("Ctrl+4"),
        Section::Projects => Some("Ctrl+5"),
        Section::Claude => Some("Ctrl+6"),
        _ => None,
    }
}

fn go_to_commands() -> Vec<Command> {
    let mut out = vec![];
    if logged_in() {
        for (group, items) in sidebar::groups() {
            for (section, title, icon, tint) in items {
                let mut c = Command::new(Group::GoTo, icon, tint, title, move || app::set_section(section)).detail(group.clone()).keywords("go open show");
                if let Some(s) = section_shortcut(section) {
                    c = c.shortcut(s);
                }
                out.push(c);
            }
        }
    }
    out.push(Command::new(Group::GoTo, "emblem-system-symbolic", "slate", "Preferences", || ui_activate("preferences")).detail(brand::APP_NAME).shortcut("Ctrl+,").keywords("settings options"));
    out
}

fn known_items(found: &[SearchItem]) -> Vec<SearchItem> {
    if !logged_in() {
        return vec![];
    }
    let a = app::get();
    let (rr, mine) = {
        let s = a.state.borrow();
        (s.review_requests.clone(), s.my_prs.clone())
    };
    let mut cached: Vec<SearchItem> = super::lists::cached_items();
    cached.extend(super::forge_list::cached_items());
    cached.sort_by_key(|x| std::cmp::Reverse(x.updated_at));
    let mut seen = HashSet::new();
    found.iter().cloned().chain(rr).chain(mine).chain(cached).filter(|i| seen.insert(i.url.clone())).collect()
}

fn item_commands(found: &[SearchItem]) -> Vec<Command> {
    let prefix = app::number_prefix();
    known_items(found)
        .into_iter()
        .map(|item| {
            let state = item.visual_state();
            let detail = format!("{}{prefix}{}", item.repository.name_with_owner, item.number);
            let keywords = format!("{} {} {} {}", item.number, item.author.as_ref().map(|a| a.login.as_str()).unwrap_or(""), if item.is_pr() { "pr pull request" } else { "issue" }, state.title());
            let route = item.route();
            Command::new(Group::Items, state.icon(), state.css(), item.title.clone(), move || app::open(route.clone(), false)).detail(detail).keywords(keywords)
        })
        .collect()
}

fn repo_commands() -> Vec<Command> {
    if !logged_in() || app::api().is_none() || !app::provider().is_github() {
        return vec![];
    }
    let mut repos = super::repos::known_repos();
    repos.retain(|r| !r.is_archived);
    repos.sort_by_key(|r| std::cmp::Reverse(r.pushed_at));
    let mut seen = HashSet::new();
    let mut out = vec![];
    if let Some(Route::Repo(r)) = app::visible_route() {
        seen.insert(r.full().to_lowercase());
        let rr = r.clone();
        out.push(Command::new(Group::Repos, "sy-repo-symbolic", "teal", r.full(), move || app::open(Route::Repo(rr.clone()), false)).detail("Current").keywords(r.name.clone()));
    }
    for r in repos {
        let Some(repo) = r.repo() else { continue };
        if !seen.insert(repo.full().to_lowercase()) {
            continue;
        }
        let icon = if r.is_private { "sy-lock-symbolic" } else { "sy-repo-symbolic" };
        let rr = repo.clone();
        out.push(Command::new(Group::Repos, icon, "teal", repo.full(), move || app::open(Route::Repo(rr.clone()), false)).detail(r.description.clone().unwrap_or_default()).keywords(repo.name.clone()));
    }
    out
}

fn action_enabled(name: &str) -> bool {
    app::try_get().and_then(|a| a.gtk_app.lookup_action(name)).is_some_and(|a| a.is_enabled())
}

fn action_commands() -> Vec<Command> {
    let mut out = vec![];
    let ready = logged_in();
    if ready {
        out.push(Command::new(Group::Actions, "view-refresh-symbolic", "sky", "Refresh", || ui_activate("refresh")).shortcut("Ctrl+R").keywords("reload sync"));
        out.push(Command::new(Group::Actions, "sy-external-symbolic", "sky", "Open by Link…", || ui_activate("open-link")).shortcut("Ctrl+L").keywords("url paste"));
        if app::section_allowed(Section::Claude) {
            out.push(Command::new(Group::Actions, "sy-terminal-symbolic", "coral", "Go to Session…", || ui_activate("agents-quick-open")).detail("Agents").shortcut("Ctrl+Shift+K").keywords("agent session"));
            out.push(Command::new(Group::Actions, "list-add-symbolic", "coral", "New Agent Session", || ui_activate("agents-new-session")).detail("Agents").shortcut("Ctrl+N").keywords("agent session new"));
        }
        if app::visible_route().is_some() {
            out.push(Command::new(Group::Actions, "go-previous-symbolic", "muted", "Back", || ui_activate("back")).shortcut("Alt+Left"));
        }
        if action_enabled("copy-short-link") {
            let detail = app::visible_route().and_then(|r| r.short_link()).unwrap_or_default();
            out.push(Command::new(Group::Actions, "edit-copy-symbolic", "muted", "Copy Short Link", || ui_activate("copy-short-link")).detail(detail).shortcut("Ctrl+Shift+C").keywords("clipboard"));
        }
    }
    let current = settings::read(|s| s.appearance.clone());
    for (mode, title, icon) in [("auto", "Match system", "weather-clear-night-symbolic"), ("light", "Light", "weather-clear-symbolic"), ("dark", "Dark", "sy-moon-symbolic")] {
        let c = Command::new(Group::Actions, icon, "amber", format!("Appearance: {title}"), move || {
            settings::update(|s| s.appearance = mode.to_string());
            crate::theme::apply();
        })
        .keywords("theme mode light dark auto");
        out.push(if current == mode { c.detail("Current") } else { c });
    }
    let wrap = super::pr::diff_view::wrap();
    out.push(Command::new(Group::Actions, "format-justify-left-symbolic", "muted", if wrap { "Don't Wrap Diff Lines" } else { "Wrap Diff Lines" }, move || super::pr::diff_view::set_wrap(!wrap)).keywords("diff wrap lines code"));
    out.push(Command::new(Group::Actions, "zoom-in-symbolic", "muted", "Zoom In", || ui_activate("zoom-in")).shortcut("Ctrl++").keywords("text size bigger"));
    out.push(Command::new(Group::Actions, "zoom-out-symbolic", "muted", "Zoom Out", || ui_activate("zoom-out")).shortcut("Ctrl+-").keywords("text size smaller"));
    if (crate::text_zoom::scale() - 1.0).abs() > 0.001 {
        out.push(Command::new(Group::Actions, "zoom-original-symbolic", "muted", "Actual Size", || ui_activate("zoom-reset")).shortcut("Ctrl+0").keywords("text size zoom reset"));
    }
    out.push(Command::new(Group::Actions, "input-keyboard-symbolic", "muted", "Keyboard Shortcuts", || ui_activate("show-shortcuts")).shortcut("Ctrl+?").keywords("keys help"));
    out.push(Command::new(Group::Actions, "sy-download-symbolic", "sky", "Check for Updates…", || ui_activate("check-updates")).keywords("version upgrade"));
    out.push(Command::new(Group::Actions, "help-about-symbolic", "muted", format!("About {}", brand::APP_NAME), || ui_activate("about")).keywords("version"));
    out
}

pub fn results(query: &str, found: &[SearchItem]) -> Vec<Command> {
    let tokens = tokens(query);
    let searching = !tokens.is_empty();
    let mut out = vec![];
    for group in Group::ALL {
        let all = match group {
            Group::Link => link_commands(query.trim()),
            Group::GoTo => go_to_commands(),
            Group::Items => item_commands(found),
            Group::Repos => repo_commands(),
            Group::Actions => action_commands(),
        };
        let ranked = if group == Group::Link { all } else { rank(all, &tokens) };
        out.extend(ranked.into_iter().take(group.limit(searching)));
    }
    out
}

struct Palette {
    dialog: adw::Dialog,
    entry: gtk::SearchEntry,
    list: gtk::ListBox,
    scroll: gtk::ScrolledWindow,
    lead: gtk::Stack,
    items: RefCell<Vec<Command>>,
    rows: RefCell<Vec<i32>>,
    found: RefCell<Vec<SearchItem>>,
    generation: Cell<u64>,
    selection: Cell<usize>,
}

thread_local! {
    static CURRENT: RefCell<Option<Rc<Palette>>> = const { RefCell::new(None) };
    static CSS_DONE: Cell<bool> = const { Cell::new(false) };
}

fn ensure_css() {
    if CSS_DONE.with(|d| d.replace(true)) {
        return;
    }
    let Some(display) = gtk::gdk::Display::default() else { return };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(".palette-key { background-color: alpha(currentColor, 0.08); border-radius: 4px; padding: 0 5px; }\n.palette-section { padding: 8px 10px 2px 10px; }\n");
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 3);
}

fn row_for(c: &Command) -> gtk::Box {
    let b = hbox(10);
    margins(&b, 7, 10, 7, 10);
    let lead = colored_icon(c.icon, 14, c.tint);
    lead.set_size_request(18, -1);
    b.append(&lead);
    let title = ellipsized(&c.title, &["sy-text"]);
    title.set_hexpand(false);
    b.append(&title);
    if !c.detail.is_empty() {
        let d = ellipsized(&c.detail, &["sy-dim", "sy-small"]);
        d.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        d.set_hexpand(false);
        b.append(&d);
    }
    b.append(&spacer());
    if let Some(s) = c.shortcut {
        b.append(&label_with(s, &["sy-small", "monospace", "palette-key", "sy-muted"]));
    }
    b
}

fn hint(key: &str, text: &str) -> gtk::Box {
    let b = hbox(4);
    b.append(&label_with(key, &["sy-small", "monospace", "palette-key"]));
    b.append(&label_with(text, &["sy-dim", "sy-small"]));
    b
}

impl Palette {
    fn render(&self) {
        let list = results(&self.entry.text(), &self.found.borrow());
        self.list.remove_all();
        let mut rows = vec![];
        let mut last: Option<Group> = None;
        for c in &list {
            if last != Some(c.group) {
                let header = gtk::ListBoxRow::new();
                header.set_activatable(false);
                header.set_selectable(false);
                header.set_focusable(false);
                let l = label_with(c.group.title(), &["sy-dim", "sy-small", "sy-bold", "palette-section"]);
                l.set_accessible_role(gtk::AccessibleRole::Heading);
                header.set_child(Some(&l));
                self.list.append(&header);
                last = Some(c.group);
            }
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&row_for(c)));
            row.update_property(&[gtk::accessible::Property::Label(&c.spoken())]);
            self.list.append(&row);
            rows.push(row.index());
        }
        if list.is_empty() {
            let row = gtk::ListBoxRow::new();
            row.set_activatable(false);
            row.set_selectable(false);
            let l = label_with("No results", &["sy-muted"]);
            pad(&l, 16);
            row.set_child(Some(&l));
            self.list.append(&row);
        }
        *self.items.borrow_mut() = list;
        *self.rows.borrow_mut() = rows;
        let n = self.items.borrow().len();
        self.select(self.selection.get().min(n.saturating_sub(1)), false);
    }

    fn select(&self, i: usize, announce: bool) {
        self.selection.set(i);
        let Some(index) = self.rows.borrow().get(i).copied() else { return };
        let Some(row) = self.list.row_at_index(index) else { return };
        self.list.select_row(Some(&row));
        if announce {
            if let Some(c) = self.items.borrow().get(i) {
                self.entry.announce(&c.spoken(), gtk::AccessibleAnnouncementPriority::Medium);
            }
        }
        let scroll = self.scroll.clone();
        let list = self.list.clone();
        let header = if i == 0 || self.items.borrow().get(i - 1).map(|c| c.group) != self.items.borrow().get(i).map(|c| c.group) { list.row_at_index(index - 1) } else { None };
        glib::idle_add_local_once(move || {
            let top = header.as_ref().and_then(|h| h.compute_bounds(&list)).map(|b| b.y() as f64);
            let Some(bounds) = row.compute_bounds(&list) else { return };
            let adj = scroll.vadjustment();
            let (y, h) = (top.unwrap_or(bounds.y() as f64), bounds.y() as f64 + bounds.height() as f64);
            if y < adj.value() {
                adj.set_value(y);
            } else if h > adj.value() + adj.page_size() {
                adj.set_value(h - adj.page_size());
            }
        });
    }

    fn step(&self, delta: i64) {
        let n = self.items.borrow().len() as i64;
        if n == 0 {
            return;
        }
        let i = (self.selection.get() as i64 + delta).rem_euclid(n);
        self.select(i as usize, true);
    }

    fn run(&self, i: usize) {
        let Some(c) = self.items.borrow().get(i).cloned() else { return };
        self.generation.set(self.generation.get() + 1);
        self.dialog.close();
        glib::idle_add_local_once(move || (c.run)());
    }

    fn query_changed(self: &Rc<Self>) {
        self.selection.set(0);
        let id = self.generation.get() + 1;
        self.generation.set(id);
        let q = self.entry.text().trim().to_string();
        let searchable = q.chars().count() >= 3 && util::parse_github_url(&q, true).is_none() && app::api().is_some() && app::provider().is_github() && logged_in();
        if !searchable {
            self.found.borrow_mut().clear();
            self.lead.set_visible_child_name("icon");
            self.render();
            return;
        }
        self.render();
        let w = Rc::downgrade(self);
        crate::rt::spawn_local(async move {
            crate::rt::sleep(Duration::from_millis(350)).await;
            let Some(me) = w.upgrade() else { return };
            if me.generation.get() != id {
                return;
            }
            let Some(api) = app::api() else { return };
            me.lead.set_visible_child_name("busy");
            drop(me);
            let query = crate::demo::query(&format!("{q} involves:@me sort:updated-desc"));
            let res = crate::rt::run(async move { api.search(&query, None).await }).await;
            let Some(me) = w.upgrade() else { return };
            if me.generation.get() != id {
                return;
            }
            me.lead.set_visible_child_name("icon");
            *me.found.borrow_mut() = res.map(|r| r.nodes).unwrap_or_default();
            me.render();
        });
    }
}

pub fn show() {
    ensure_css();
    if let Some(existing) = CURRENT.with(|c| c.borrow().clone()) {
        existing.entry.grab_focus();
        return;
    }
    let dialog = adw::Dialog::new();
    dialog.set_title("Command palette");
    dialog.set_content_width(560);
    dialog.set_content_height(460);
    let root = vbox(0);
    let top = hbox(10);
    margins(&top, 12, 16, 12, 16);
    let lead = gtk::Stack::new();
    lead.add_named(&icon("system-search-symbolic", 16), Some("icon"));
    lead.add_named(&spinner(16), Some("busy"));
    lead.set_visible_child_name("icon");
    top.append(&lead);
    let entry = gtk::SearchEntry::new();
    entry.set_placeholder_text(Some("Search commands, pull requests, repositories, or paste a link…"));
    entry.set_hexpand(true);
    entry.set_search_delay(80);
    entry.update_property(&[
        gtk::accessible::Property::Label("Command palette"),
        gtk::accessible::Property::Description("Type to filter. Use the up and down arrow keys to choose, Enter to run, Escape to close."),
    ]);
    top.append(&entry);
    root.append(&top);
    root.append(&line());
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    list.add_css_class("navigation-sidebar");
    list.update_property(&[gtk::accessible::Property::Label("Results")]);
    margins(&list, 6, 6, 6, 6);
    let scroll = scrolled(&list);
    scroll.set_vexpand(true);
    root.append(&scroll);
    root.append(&line());
    let footer = hbox(14);
    margins(&footer, 8, 16, 8, 16);
    footer.append(&hint("↑↓", "select"));
    footer.append(&hint("↵", "run"));
    footer.append(&hint("esc", "close"));
    footer.set_accessible_role(gtk::AccessibleRole::Presentation);
    root.append(&footer);
    dialog.set_child(Some(&root));
    let me = Rc::new(Palette {
        dialog: dialog.clone(),
        entry: entry.clone(),
        list: list.clone(),
        scroll,
        lead,
        items: RefCell::new(vec![]),
        rows: RefCell::new(vec![]),
        found: RefCell::new(vec![]),
        generation: Cell::new(0),
        selection: Cell::new(0),
    });
    CURRENT.with(|c| *c.borrow_mut() = Some(me.clone()));
    let w = Rc::downgrade(&me);
    entry.connect_search_changed(move |_| {
        if let Some(me) = w.upgrade() {
            me.query_changed();
        }
    });
    let w = Rc::downgrade(&me);
    entry.connect_activate(move |_| {
        if let Some(me) = w.upgrade() {
            me.run(me.selection.get());
        }
    });
    let d = dialog.clone();
    entry.connect_stop_search(move |_| {
        d.close();
    });
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let w = Rc::downgrade(&me);
    keys.connect_key_pressed(move |_, key, _, _| {
        let Some(me) = w.upgrade() else { return glib::Propagation::Proceed };
        match key {
            gtk::gdk::Key::Down | gtk::gdk::Key::KP_Down => {
                me.step(1);
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Up | gtk::gdk::Key::KP_Up => {
                me.step(-1);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    entry.add_controller(keys);
    let w = Rc::downgrade(&me);
    list.connect_row_activated(move |_, row| {
        let Some(me) = w.upgrade() else { return };
        let index = row.index();
        let pos = me.rows.borrow().iter().position(|r| *r == index);
        if let Some(i) = pos {
            me.run(i);
        }
    });
    let w = Rc::downgrade(&me);
    dialog.connect_closed(move |_| {
        if let Some(me) = w.upgrade() {
            me.generation.set(me.generation.get() + 1);
        }
        let gone = CURRENT.with(|c| c.borrow_mut().take());
        if let Some(gone) = gone {
            glib::idle_add_local_once(move || drop(gone));
        }
    });
    me.render();
    let win = app::main_window();
    dialog.present(win.as_ref());
    entry.grab_focus();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_beats_substring_beats_fuzzy() {
        let prefix = score_text("refresh", "ref").unwrap();
        let boundary = score_text("open by link", "link").unwrap();
        let inner = score_text("unlinked", "link").unwrap();
        let fuzzy = score_text("refresh", "rfs").unwrap();
        assert_eq!(prefix, 1000);
        assert!(prefix > boundary && boundary > inner && inner > fuzzy);
        assert!(score_text("refresh", "xyz").is_none());
    }

    #[test]
    fn every_token_must_match_title_or_extra() {
        let t = vec!["zoom".to_string(), "bigger".to_string()];
        assert!(score("Zoom In", "text size bigger", &t).is_some());
        assert!(score("Zoom In", "text size", &t).is_none());
        assert_eq!(score("Zoom In", "", &[]), Some(0));
        assert!(score("Zoom In", "", &["zoom".to_string()]).unwrap() > score("Actual Size", "zoom", &["zoom".to_string()]).unwrap());
    }

    #[test]
    fn tokens_split_on_whitespace_and_lowercase() {
        assert_eq!(tokens("  Open  PR "), vec!["open".to_string(), "pr".to_string()]);
    }
}
