use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use adw::prelude::*;

use super::indicator;
use crate::claude::sessions::{Project, SessionInfo};
use crate::claude::workspace::{Tab, Workspace};
use crate::claude::{prefs, session_index};
use crate::ui::widgets::*;
use crate::{app, util};

#[derive(Clone)]
pub enum Entry {
    Tab(Rc<Tab>),
    Session(SessionInfo, String),
    Match(SessionInfo, String, String),
    New(Project),
}

fn hit(q: &str, parts: &[Option<&str>]) -> bool {
    q.is_empty() || parts.iter().any(|p| p.map(|p| p.to_lowercase().contains(q)).unwrap_or(false))
}

pub fn entries(ws: &Workspace, query: &str, matches: &HashMap<PathBuf, String>) -> Vec<Entry> {
    let q = query.trim().to_lowercase();
    let tabs: Vec<Rc<Tab>> = ws.tabs.borrow().clone();
    let open: HashSet<String> = tabs.iter().map(|t| t.session_id.borrow().clone()).filter(|s| !s.is_empty()).collect();
    let mut out: Vec<Entry> = tabs.iter().filter(|t| hit(&q, &[Some(&t.title.borrow()), Some(&t.project_name())])).map(|t| Entry::Tab(t.clone())).collect();
    let projects = ws.projects.borrow();
    let (archived, titles) = prefs::read(|p| (p.archived.clone(), p.titles.clone()));
    let title_of = |s: &SessionInfo| {
        let mut c = s.clone();
        if let Some(t) = titles.get(&s.id) {
            c.title = t.clone();
        }
        c
    };
    let mut sessions: Vec<(SessionInfo, String)> = projects
        .iter()
        .flat_map(|p| p.sessions.iter().filter(|s| !s.archived && !archived.contains(&s.id) && !open.contains(&s.id)).map(move |s| (s, p.name())))
        .map(|(s, name)| (title_of(s), name))
        .filter(|(s, name)| hit(&q, &[Some(&s.title), Some(name), s.branch.as_deref()]))
        .collect();
    sessions.sort_by(|a, b| b.0.modified.cmp(&a.0.modified));
    sessions.truncate(if q.is_empty() { 12 } else { 40 });
    let shown: HashSet<String> = sessions.iter().map(|(s, _)| s.id.clone()).collect();
    out.extend(sessions.into_iter().map(|(s, n)| Entry::Session(s, n)));
    if q.chars().count() >= 3 {
        let mut found: Vec<(SessionInfo, String, String)> = vec![];
        for p in projects.iter() {
            for s in &p.sessions {
                if shown.contains(&s.id) {
                    continue;
                }
                if let Some(snip) = matches.get(&s.file) {
                    found.push((title_of(s), p.name(), snip.clone()));
                }
            }
        }
        found.sort_by(|a, b| b.0.modified.cmp(&a.0.modified));
        found.truncate(30);
        out.extend(found.into_iter().map(|(s, n, snip)| Entry::Match(s, n, snip)));
    }
    let limit = if q.is_empty() { 4 } else { 8 };
    out.extend(projects.iter().filter(|p| p.exists() && hit(&q, &[Some(&p.name()), Some("new")])).take(limit).map(|p| Entry::New(p.clone())));
    out
}

struct QuickOpen {
    dialog: adw::Dialog,
    entry: gtk::SearchEntry,
    list: gtk::ListBox,
    scroll: gtk::ScrolledWindow,
    lead: gtk::Stack,
    items: RefCell<Vec<Entry>>,
    matches: RefCell<HashMap<PathBuf, String>>,
    generation: Arc<AtomicU64>,
    selection: Cell<usize>,
}

thread_local! {
    static CURRENT: RefCell<Option<Rc<QuickOpen>>> = const { RefCell::new(None) };
}

fn caption(text: &str) -> gtk::Label {
    let l = ellipsized(text, &["sy-dim", "sy-small"]);
    l.set_hexpand(false);
    l
}

fn row_for(ws: &Rc<Workspace>, e: &Entry) -> gtk::Widget {
    let b = hbox(10);
    margins(&b, 8, 10, 8, 10);
    let lead = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    lead.set_size_request(16, -1);
    lead.set_valign(gtk::Align::Center);
    b.append(&lead);
    match e {
        Entry::Tab(t) => {
            lead.append(&indicator::dot(t.indicator()));
            let title = ellipsized(&t.title.borrow(), &["sy-text"]);
            title.set_hexpand(true);
            b.append(&title);
            b.append(&caption(&format!("open · {}", t.project_name())));
        }
        Entry::Session(s, project) => {
            lead.append(&indicator::dot(ws.indicator_for(s)));
            let title = ellipsized(&s.title, &["sy-text"]);
            title.set_hexpand(true);
            b.append(&title);
            b.append(&caption(&format!("{project} · {}", util::rel(Some(s.modified)))));
        }
        Entry::Match(s, project, snippet) => {
            lead.append(&colored_icon("system-search-symbolic", 14, "violet"));
            let col = vbox(2);
            col.set_hexpand(true);
            let top = hbox(8);
            let title = ellipsized(&s.title, &["sy-text"]);
            title.set_hexpand(true);
            top.append(&title);
            top.append(&caption(&format!("{project} · {}", util::rel(Some(s.modified)))));
            col.append(&top);
            let snip = ellipsized(snippet, &["sy-muted", "sy-small"]);
            snip.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            col.append(&snip);
            b.append(&col);
        }
        Entry::New(p) => {
            lead.append(&colored_icon("list-add-symbolic", 14, "violet"));
            let l = gtk::Label::new(None);
            l.set_markup(&format!("<span alpha=\"65%\">New session in </span>{}", util::markup_esc(&p.name())));
            l.set_xalign(0.0);
            l.set_ellipsize(gtk::pango::EllipsizeMode::End);
            l.set_hexpand(true);
            b.append(&l);
        }
    }
    b.upcast()
}

impl QuickOpen {
    fn render(self: &Rc<Self>) {
        let ws = app::get().claude.clone();
        let list = entries(&ws, &self.entry.text(), &self.matches.borrow());
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        for e in &list {
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&row_for(&ws, e)));
            self.list.append(&row);
        }
        if list.is_empty() {
            let row = gtk::ListBoxRow::new();
            row.set_activatable(false);
            row.set_selectable(false);
            let l = label_with(&format!("Nothing matches “{}”", self.entry.text()), &["sy-muted"]);
            pad(&l, 16);
            row.set_child(Some(&l));
            self.list.append(&row);
        }
        *self.items.borrow_mut() = list;
        self.select(self.selection.get().min(self.items.borrow().len().saturating_sub(1)));
    }

    fn select(&self, i: usize) {
        self.selection.set(i);
        let Some(row) = self.list.row_at_index(i as i32) else {
            return;
        };
        if !row.is_selectable() {
            return;
        }
        self.list.select_row(Some(&row));
        let scroll = self.scroll.clone();
        let list = self.list.clone();
        gtk::glib::idle_add_local_once(move || {
            let Some(bounds) = row.compute_bounds(&list) else {
                return;
            };
            let adj = scroll.vadjustment();
            let (y, h) = (bounds.y() as f64, bounds.height() as f64);
            if y < adj.value() {
                adj.set_value(y);
            } else if y + h > adj.value() + adj.page_size() {
                adj.set_value(y + h - adj.page_size());
            }
        });
    }

    fn step(&self, delta: i64) {
        let n = self.items.borrow().len() as i64;
        if n == 0 {
            return;
        }
        let i = (self.selection.get() as i64 + delta).rem_euclid(n);
        self.select(i as usize);
    }

    fn open(&self, i: usize) {
        let Some(e) = self.items.borrow().get(i).cloned() else {
            return;
        };
        let ws = app::get().claude.clone();
        app::set_section(app::Section::Claude);
        match e {
            Entry::Tab(t) => ws.select(t.id),
            Entry::Session(s, _) | Entry::Match(s, _, _) => {
                ws.resume(&s, false, None);
            }
            Entry::New(p) => {
                ws.new_session(&p.path, None, None, None, None);
            }
        }
        self.generation.fetch_add(1, Ordering::Relaxed);
        self.dialog.close();
    }

    fn query_changed(self: &Rc<Self>) {
        self.selection.set(0);
        let id = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let q = self.entry.text().trim().to_string();
        if q.chars().count() < 3 {
            self.matches.borrow_mut().clear();
            self.lead.set_visible_child_name("icon");
            self.render();
            return;
        }
        self.render();
        let w = Rc::downgrade(self);
        crate::rt::spawn_local(async move {
            crate::rt::sleep(Duration::from_millis(250)).await;
            let Some(me) = w.upgrade() else { return };
            if me.generation.load(Ordering::Relaxed) != id {
                return;
            }
            me.lead.set_visible_child_name("busy");
            let files = app::get().claude.all_session_files();
            let generation = me.generation.clone();
            drop(me);
            let found = crate::rt::blocking(move || match session_index::shared().lock() {
                Ok(mut index) => index.search(&q, &files, &generation, id),
                Err(_) => HashMap::new(),
            })
            .await;
            let Some(me) = w.upgrade() else { return };
            if me.generation.load(Ordering::Relaxed) != id {
                return;
            }
            *me.matches.borrow_mut() = found;
            me.lead.set_visible_child_name("icon");
            me.render();
        });
    }
}

fn hint(key: &str, text: &str) -> gtk::Box {
    let b = hbox(4);
    let k = label_with(key, &["sy-small", "monospace", "quick-open-key"]);
    b.append(&k);
    b.append(&label_with(text, &["sy-dim", "sy-small"]));
    b
}

fn ensure_css() {
    thread_local! {
        static DONE: Cell<bool> = const { Cell::new(false) };
    }
    if DONE.with(|d| d.replace(true)) {
        return;
    }
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(".quick-open-key { background-color: alpha(currentColor, 0.08); border-radius: 4px; padding: 0 5px; }");
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 3);
}

pub fn set_query(text: &str) {
    if let Some(me) = CURRENT.with(|c| c.borrow().clone()) {
        me.entry.set_text(text);
    }
}

pub fn close() {
    if let Some(me) = CURRENT.with(|c| c.borrow().clone()) {
        me.dialog.close();
    }
}

pub fn is_open() -> bool {
    CURRENT.with(|c| c.borrow().is_some())
}

pub fn shown_count() -> usize {
    CURRENT.with(|c| c.borrow().as_ref().map(|m| m.items.borrow().len()).unwrap_or(0))
}

pub fn show() {
    ensure_css();
    if let Some(existing) = CURRENT.with(|c| c.borrow().clone()) {
        existing.entry.grab_focus();
        return;
    }
    let dialog = adw::Dialog::new();
    dialog.set_title("Go to session");
    dialog.set_content_width(560);
    dialog.set_content_height(440);
    let root = vbox(0);
    let top = hbox(10);
    margins(&top, 12, 16, 12, 16);
    let lead = gtk::Stack::new();
    lead.add_named(&icon("system-search-symbolic", 16), Some("icon"));
    lead.add_named(&spinner(16), Some("busy"));
    lead.set_visible_child_name("icon");
    top.append(&lead);
    let entry = gtk::SearchEntry::new();
    entry.set_placeholder_text(Some("Go to a session, search conversations, or start one in a project…"));
    entry.set_hexpand(true);
    entry.set_search_delay(120);
    top.append(&entry);
    root.append(&top);
    root.append(&line());
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    list.add_css_class("navigation-sidebar");
    margins(&list, 6, 6, 6, 6);
    let scroll = scrolled(&list);
    scroll.set_vexpand(true);
    root.append(&scroll);
    root.append(&line());
    let footer = hbox(14);
    margins(&footer, 8, 16, 8, 16);
    footer.append(&hint("↑↓", "select"));
    footer.append(&hint("↵", "open"));
    footer.append(&hint("esc", "close"));
    root.append(&footer);
    dialog.set_child(Some(&root));
    let me = Rc::new(QuickOpen {
        dialog: dialog.clone(),
        entry: entry.clone(),
        list: list.clone(),
        scroll,
        lead,
        items: RefCell::new(vec![]),
        matches: RefCell::new(HashMap::new()),
        generation: Arc::new(AtomicU64::new(0)),
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
            me.open(me.selection.get());
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
        let Some(me) = w.upgrade() else {
            return gtk::glib::Propagation::Proceed;
        };
        match key {
            gtk::gdk::Key::Down | gtk::gdk::Key::KP_Down => {
                me.step(1);
                gtk::glib::Propagation::Stop
            }
            gtk::gdk::Key::Up | gtk::gdk::Key::KP_Up => {
                me.step(-1);
                gtk::glib::Propagation::Stop
            }
            _ => gtk::glib::Propagation::Proceed,
        }
    });
    entry.add_controller(keys);
    let w = Rc::downgrade(&me);
    list.connect_row_activated(move |_, row| {
        if let Some(me) = w.upgrade() {
            me.open(row.index().max(0) as usize);
        }
    });
    let w = Rc::downgrade(&me);
    dialog.connect_closed(move |_| {
        if let Some(me) = w.upgrade() {
            me.generation.fetch_add(1, Ordering::Relaxed);
        }
        let gone = CURRENT.with(|c| c.borrow_mut().take());
        if let Some(gone) = gone {
            gtk::glib::idle_add_local_once(move || drop(gone));
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
    fn matches_any_part() {
        assert!(hit("", &[None]));
        assert!(hit("abc", &[None, Some("xxABCxx")]));
        assert!(!hit("abc", &[Some("ab"), None]));
    }
}
