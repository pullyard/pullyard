use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use adw::prelude::*;

use super::auth_view;
use super::indicator::{self, Dot};
use crate::claude::accounts::{self, Status};
use crate::claude::sessions::{build_tree, Project, SessionInfo, TreeNode};
use crate::claude::workspace::{Tab, Workspace, WsEvent};
use crate::claude::{desktop, memory, prefs, TabKind};
use crate::ui::dialogs;
use crate::ui::menu::{context_menu, Menu};
use crate::ui::widgets::*;
use crate::{app, util};

struct Column {
    list: gtk::Box,
    tabs_box: gtk::Box,
    query: RefCell<String>,
    expanded: RefCell<HashSet<String>>,
    collapsed_parents: RefCell<HashSet<String>>,
    show_archived: Cell<bool>,
    status: Rc<RefreshStatus>,
    open_folder: gtk::Button,
    initialized: Cell<bool>,
    tabs_key: RefCell<String>,
    tab_dots: RefCell<Vec<(u64, Dot)>>,
    session_dots: RefCell<Vec<(SessionInfo, Dot)>>,
    memory: RefCell<Option<(gtk::Label, gtk::Button)>>,
}

fn session_details(s: &SessionInfo) -> String {
    let mut parts = vec![format!("Updated {}", util::rel(Some(s.modified)))];
    if let Some(b) = &s.branch {
        parts.push(format!("Branch: {b}"));
    }
    if let Some(w) = s.worktree_name() {
        parts.push(format!("Worktree: {w}"));
    }
    if let Some(n) = s.pr_number {
        parts.push(format!("PR #{n}"));
    }
    if let (Some(a), Some(r)) = (s.lines_added, s.lines_removed) {
        if a + r > 0 {
            parts.push(format!("+{a} −{r}"));
        }
    }
    parts.join("\n")
}

struct RowOpts {
    open: bool,
    children: usize,
    collapsed: bool,
    depth: usize,
    last: bool,
}

fn session_row(s: &SessionInfo, opts: RowOpts, dot: &Dot, on_toggle: Option<Box<dyn Fn()>>) -> gtk::Box {
    let b = hbox(6);
    margins(&b, 7, 6, 7, 4);
    b.set_size_request(-1, 32);
    if opts.depth > 0 {
        b.append(&indicator::tree_guide(opts.last));
    }
    let title = ellipsized(&s.title, &[if opts.depth > 0 { "sy-muted" } else { "sy-text" }]);
    if opts.open {
        title.add_css_class("sy-bold");
    }
    title.set_hexpand(opts.children == 0);
    b.append(&title);
    if opts.children > 0 {
        let toggle = gtk::Button::new();
        toggle.set_icon_name(if opts.collapsed { "pan-end-symbolic" } else { "pan-down-symbolic" });
        toggle.add_css_class("flat");
        toggle.add_css_class("circular");
        toggle.set_valign(gtk::Align::Center);
        toggle.set_tooltip_text(Some(if opts.collapsed { "Show sub-sessions" } else { "Hide sub-sessions" }));
        set_label(&toggle, "Sub-sessions");
        set_expanded(&toggle, !opts.collapsed);
        if let Some(f) = on_toggle {
            toggle.connect_clicked(move |_| f());
        }
        b.append(&toggle);
        b.append(&spacer());
    }
    if s.pr_number.is_some() {
        b.append(&colored_icon("sy-pr-symbolic", 12, "violet"));
    }
    if opts.children > 0 {
        b.append(&label_with(&opts.children.to_string(), &["sy-dim", "sy-small"]));
    }
    b.append(&dot.area);
    b.set_tooltip_text(Some(&session_details(s)));
    b
}

fn tab_row(t: &Tab, selected: bool, dot: &Dot) -> gtk::Box {
    let b = hbox(8);
    margins(&b, 7, 6, 7, 4);
    b.set_size_request(-1, 32);
    let title = ellipsized(&t.title.borrow(), &["sy-text"]);
    title.set_hexpand(true);
    if selected {
        title.add_css_class("sy-bold");
    }
    b.append(&colored_icon(if t.kind == TabKind::Chat { "sy-comment-symbolic" } else { "sy-terminal-symbolic" }, 11, "muted"));
    b.append(&title);
    let project = ellipsized(&t.project_name(), &["sy-dim", "sy-small"]);
    project.set_hexpand(false);
    project.set_max_width_chars(16);
    b.append(&project);
    b.append(&dot.area);
    let mut tip = t.state().help().to_string();
    let mem = t.memory_bytes();
    if mem > 0 {
        tip.push_str(&format!(" — {}", memory::format(mem)));
    }
    b.set_tooltip_text(Some(&tip));
    b
}

fn project_header(p: &Project, expanded: bool, on_toggle: impl Fn() + 'static, on_new: impl Fn() + 'static) -> gtk::Box {
    let color = crate::theme::palette_for(&p.path);
    let b = hbox(7);
    margins(&b, 10, 8, 4, 8);
    b.append(&icon(if expanded { "pan-down-symbolic" } else { "pan-end-symbolic" }, 12));
    b.append(&icon_tile(if p.exists() { "sy-folder-symbolic" } else { "sy-attention-symbolic" }, if p.exists() { color } else { "slate" }, 22));
    let name = ellipsized(&p.name(), &["sy-bold", "sy-text"]);
    name.set_hexpand(false);
    b.append(&name);
    b.append(&label_with(&p.sessions.len().to_string(), &["sy-dim", "sy-small"]));
    b.append(&spacer());
    let new = icon_button("list-add-symbolic", "New session");
    new.add_css_class("fg-coral");
    new.set_sensitive(p.exists());
    new.connect_clicked(move |_| on_new());
    b.append(&new);
    if !p.exists() {
        b.set_opacity(0.6);
    }
    b.set_tooltip_text(Some(&util::tilde(&p.path)));
    b.set_accessible_role(gtk::AccessibleRole::Button);
    set_label(&b, &format!("{}, {} sessions", p.name(), p.sessions.len()));
    set_expanded(&b, expanded);
    on_click_widget(&b, on_toggle);
    b
}

fn section_header(icon_name: Option<&str>, title: &str) -> gtk::Box {
    let head = hbox(6);
    margins(&head, 12, 10, 4, 12);
    if let Some(i) = icon_name {
        head.append(&icon(i, 12));
    }
    head.append(&label_with(title, &["sy-dim", "sy-small", "sy-bold"]));
    head
}

fn after_prefs_change() {
    app::get().claude.emit(WsEvent::Projects);
}

fn rename(s: &SessionInfo) {
    let current = prefs::read(|p| p.title(s));
    let d = adw::AlertDialog::new(Some("Rename session"), Some(&format!("The new name is only shown in {}.", crate::brand::APP_NAME)));
    let entry = gtk::Entry::new();
    entry.set_text(&current);
    entry.set_activates_default(true);
    d.set_extra_child(Some(&entry));
    d.add_response("cancel", "Cancel");
    d.add_response("rename", "Rename");
    d.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("rename"));
    d.set_close_response("cancel");
    let id = s.id.clone();
    let e = entry.clone();
    d.connect_response(None, move |_, r| {
        if r != "rename" {
            return;
        }
        let text = e.text().to_string();
        prefs::update(|p| p.rename(&id, &text));
        let ws = app::get().claude.clone();
        if let Some(tab) = ws.tab_for_session(&id) {
            let fallback = ws.find_session(&id).map(|s| s.title).unwrap_or_default();
            let t = if text.trim().is_empty() { fallback } else { text.trim().to_string() };
            if !t.is_empty() {
                *tab.title.borrow_mut() = t;
            }
            ws.emit(WsEvent::Tabs);
        }
        after_prefs_change();
    });
    let w = app::main_window();
    d.present(w.as_ref());
    entry.grab_focus();
}

fn session_menu(s: &SessionInfo) -> Menu {
    let mut menu = Menu::ctx();
    let ws = app::get().claude.clone();
    let (pinned, archived) = prefs::read(|p| (p.is_pinned(&s.id), p.is_archived(s)));
    let id = s.id.clone();
    menu.item(if pinned { "Unpin" } else { "Pin to top" }, move || {
        prefs::update(|p| p.toggle_pin(&id));
        after_prefs_change();
    });
    let s0 = s.clone();
    menu.item("Rename…", move || rename(&s0));
    let id = s.id.clone();
    menu.item(if archived { "Unarchive" } else { "Archive" }, move || {
        prefs::update(|p| p.set_archived(&id, !archived));
        after_prefs_change();
    });
    menu.section(None);
    let (s1, w1) = (s.clone(), ws.clone());
    menu.item("Resume as chat", move || {
        w1.resume(&s1, false, Some(TabKind::Chat));
    });
    let (s2, w2) = (s.clone(), ws.clone());
    menu.item("Resume in terminal", move || {
        w2.resume(&s2, false, Some(TabKind::Terminal));
    });
    let (s3, w3) = (s.clone(), ws.clone());
    menu.item("Fork session", move || {
        w3.resume(&s3, true, None);
    });
    if let Some(local) = s.desktop_id.clone().filter(|_| desktop::can_open()) {
        menu.item("Open in Claude Desktop", move || desktop::open(&local));
    }
    menu.section(None);
    let id = s.id.clone();
    menu.item("Copy session ID", move || util::copy(&id));
    let cmd = format!("cd {} && claude --resume {}", util::shell_quote(&s.cwd), s.id);
    menu.item("Copy resume command", move || util::copy(&cmd));
    let file = s.file.to_string_lossy().to_string();
    menu.item("Show transcript in Files", move || util::reveal_path(&file));
    if let Some(pr) = s.pr_url.clone() {
        menu.item("Open PR", move || {
            if let Some(r) = util::parse_github_url(&pr, true) {
                app::open(r, false);
            }
        });
    }
    menu
}

fn tabs_key(tabs: &[Rc<Tab>], selected: Option<u64>) -> String {
    format!("{:?}|{}", selected, tabs.iter().map(|t| format!("{}:{}:{}:{}", t.id, t.title.borrow(), t.kind.key(), t.session_id.borrow())).collect::<Vec<_>>().join(";"))
}

impl Column {
    fn render(self: &Rc<Self>) {
        clear(&self.list);
        self.session_dots.borrow_mut().clear();
        self.tabs_key.borrow_mut().clear();
        let store = accounts::store();
        let status = store.status.borrow().clone();
        let ws = app::get().claude.clone();
        self.open_folder.set_sensitive(store.is_logged_in());
        self.status.update(ws.projects_updated.get(), ws.loading_projects.get(), None);
        match &status {
            Status::LoggedIn(info) => {
                let c = auth_view::account_card(info, true);
                margins(&c, 6, 8, 4, 8);
                self.list.append(&c);
            }
            Status::LoggedOut => {
                let l = hbox(6);
                margins(&l, 8, 10, 8, 10);
                l.append(&colored_icon("sy-person-symbolic", 14, "amber"));
                l.append(&wrap_label("Not signed in to Claude — sign in on the right", &["fg-amber"]));
                self.list.append(&l);
                if accounts::visible().len() > 1 {
                    self.list.append(&auth_view::profile_switcher());
                }
            }
            Status::NotInstalled => {
                let l = hbox(6);
                margins(&l, 8, 10, 8, 10);
                l.append(&colored_icon("sy-attention-symbolic", 14, "amber"));
                l.append(&wrap_label("claude CLI not found — see the right side", &["fg-amber"]));
                self.list.append(&l);
            }
            _ => {}
        }
        match status {
            Status::LoggedIn(_) => {}
            Status::Unknown | Status::Checking => {
                let s = spinner(16);
                s.set_halign(gtk::Align::Center);
                s.set_margin_top(20);
                self.list.append(&s);
                return;
            }
            _ => {
                let b = vbox(6);
                margins(&b, 8, 12, 8, 12);
                b.append(&icon("sy-lock-symbolic", 18));
                b.append(&wrap_label("Session history and projects appear after you sign in to Claude.", &["sy-muted"]));
                self.list.append(&b);
                return;
            }
        }
        self.list.append(&self.tabs_box);
        self.render_tabs();
        self.render_projects();
    }

    fn render_tabs(self: &Rc<Self>) {
        clear(&self.tabs_box);
        self.tab_dots.borrow_mut().clear();
        *self.memory.borrow_mut() = None;
        if !accounts::store().is_logged_in() {
            return;
        }
        let ws = app::get().claude.clone();
        let tabs: Vec<Rc<Tab>> = ws.tabs.borrow().clone();
        let selected = ws.selected.get();
        *self.tabs_key.borrow_mut() = tabs_key(&tabs, selected);
        if tabs.is_empty() {
            return;
        }
        let head = section_header(None, "OPEN");
        head.append(&spacer());
        head.append(&icon("sy-memory-symbolic", 12));
        let mem = label_with("", &["sy-muted", "sy-small"]);
        head.append(&mem);
        let sleep = link_button("Sleep all");
        sleep.set_tooltip_text(Some("Stop idle processes and free memory"));
        let w = ws.clone();
        sleep.connect_clicked(move |_| w.sleep_all());
        head.append(&sleep);
        head.set_tooltip_text(Some("Memory used by running Claude processes"));
        self.tabs_box.append(&head);
        *self.memory.borrow_mut() = Some((mem, sleep));
        self.update_memory();
        let lb = gtk::ListBox::new();
        lb.add_css_class("sy-sidebar-list");
        for t in &tabs {
            let row = gtk::ListBoxRow::new();
            let dot = Dot::new(t.indicator());
            row.set_child(Some(&tab_row(t, selected == Some(t.id), &dot)));
            self.tab_dots.borrow_mut().push((t.id, dot));
            let tt = t.clone();
            context_menu(&row, move || {
                let m = Menu::ctx();
                let ws = app::get().claude.clone();
                let t2 = tt.clone();
                if tt.running() {
                    let busy = matches!(tt.state(), crate::claude::TabState::Working | crate::claude::TabState::Waiting);
                    if busy {
                        m.disabled("Free memory (sleep)");
                    } else {
                        m.item("Free memory (sleep)", move || t2.sleep_now());
                    }
                } else {
                    let w = ws.clone();
                    m.item("Wake up", move || w.restart(&t2));
                }
                let t3 = tt.clone();
                m.item("Close", move || ws.close(&t3));
                m
            });
            lb.append(&row);
            if selected == Some(t.id) {
                lb.select_row(Some(&row));
            }
        }
        let ids: Vec<u64> = tabs.iter().map(|t| t.id).collect();
        lb.connect_row_activated(move |_, row| {
            if let Some(id) = ids.get(row.index().max(0) as usize) {
                app::get().claude.select(*id);
            }
        });
        self.tabs_box.append(&lb);
        let sep = line();
        margins(&sep, 8, 10, 0, 10);
        self.tabs_box.append(&sep);
    }

    fn update_memory(&self) {
        let ws = app::get().claude.clone();
        if let Some((label, sleep)) = self.memory.borrow().as_ref() {
            let total = ws.total_memory();
            label.set_text(&if total > 0 { memory::format(total) } else { "0 MB".into() });
            sleep.set_visible(ws.running_count() > 0);
        }
    }

    fn refresh_live(self: &Rc<Self>) {
        if !accounts::store().is_logged_in() {
            return;
        }
        let ws = app::get().claude.clone();
        let tabs: Vec<Rc<Tab>> = ws.tabs.borrow().clone();
        if *self.tabs_key.borrow() != tabs_key(&tabs, ws.selected.get()) {
            self.render_tabs();
        } else {
            for (id, dot) in self.tab_dots.borrow().iter() {
                if let Some(t) = tabs.iter().find(|t| t.id == *id) {
                    let k = t.indicator();
                    if dot.kind() != k {
                        dot.set(k);
                    }
                }
            }
            self.update_memory();
        }
        for (s, dot) in self.session_dots.borrow().iter() {
            let k = ws.indicator_for(s);
            if dot.kind() != k {
                dot.set(k);
            }
        }
    }

    fn session_list(self: &Rc<Self>, ws: &Rc<Workspace>, nodes: Vec<TreeNode>) -> gtk::ListBox {
        let lb = gtk::ListBox::new();
        lb.add_css_class("sy-sidebar-list");
        lb.set_selection_mode(gtk::SelectionMode::None);
        let mut order: Vec<SessionInfo> = vec![];
        for node in nodes {
            let parent_id = node.session.id.clone();
            let collapsed = self.collapsed_parents.borrow().contains(&parent_id);
            let toggle: Option<Box<dyn Fn()>> = if node.children.is_empty() {
                None
            } else {
                let w = Rc::downgrade(self);
                let pid = parent_id.clone();
                Some(Box::new(move || {
                    if let Some(me) = w.upgrade() {
                        {
                            let mut c = me.collapsed_parents.borrow_mut();
                            if !c.remove(&pid) {
                                c.insert(pid.clone());
                            }
                        }
                        me.render();
                    }
                }))
            };
            self.append_session(ws, &lb, &mut order, &node.session, RowOpts { open: false, children: node.children.len(), collapsed, depth: 0, last: false }, toggle);
            if !collapsed {
                let n = node.children.len();
                for (i, child) in node.children.iter().enumerate() {
                    self.append_session(ws, &lb, &mut order, child, RowOpts { open: false, children: 0, collapsed: false, depth: 1, last: i + 1 == n }, None);
                }
            }
        }
        lb.connect_row_activated(move |_, row| {
            if let Some(s) = order.get(row.index().max(0) as usize) {
                app::get().claude.resume(s, false, None);
            }
        });
        lb
    }

    fn append_session(&self, ws: &Rc<Workspace>, lb: &gtk::ListBox, order: &mut Vec<SessionInfo>, s: &SessionInfo, mut opts: RowOpts, toggle: Option<Box<dyn Fn()>>) {
        let shown = prefs::retitled(s);
        opts.open = ws.tab_for_session(&s.id).is_some();
        let dot = Dot::new(ws.indicator_for(s));
        let row = gtk::ListBoxRow::new();
        row.set_child(Some(&session_row(&shown, opts, &dot, toggle)));
        let ss = shown.clone();
        context_menu(&row, move || session_menu(&ss));
        lb.append(&row);
        self.session_dots.borrow_mut().push((s.clone(), dot));
        order.push(shown);
    }

    fn render_projects(self: &Rc<Self>) {
        let ws = app::get().claude.clone();
        let query = self.query.borrow().to_lowercase();
        let (pinned_ids, archived_ids, titles) = prefs::read(|p| (p.pinned.clone(), p.archived.clone(), p.titles.clone()));
        let show_archived = self.show_archived.get();
        let matches = |s: &SessionInfo| {
            let title = titles.get(&s.id).unwrap_or(&s.title).to_lowercase();
            title.contains(&query) || s.branch.as_deref().unwrap_or("").to_lowercase().contains(&query)
        };
        let projects: Vec<Project> = ws
            .projects
            .borrow()
            .iter()
            .filter_map(|p| {
                if query.is_empty() || p.name().to_lowercase().contains(&query) {
                    return Some(p.clone());
                }
                let s: Vec<SessionInfo> = p.sessions.iter().filter(|s| matches(s)).cloned().collect();
                if s.is_empty() {
                    None
                } else {
                    Some(Project { id: p.id.clone(), path: p.path.clone(), sessions: s })
                }
            })
            .collect();
        if !self.initialized.get() {
            if let Some(first) = projects.first() {
                self.expanded.borrow_mut().insert(first.id.clone());
                self.initialized.set(true);
            }
        }
        let pinned: Vec<SessionInfo> = pinned_ids.iter().filter_map(|id| projects.iter().flat_map(|p| p.sessions.iter()).find(|s| s.id == *id).cloned()).collect();
        if !pinned.is_empty() {
            self.list.append(&section_header(Some("view-pin-symbolic"), "PINNED"));
            let nodes: Vec<TreeNode> = pinned.into_iter().map(|s| TreeNode { session: s, children: vec![] }).collect();
            let lb = self.session_list(&ws, nodes);
            self.list.append(&lb);
            let sep = line();
            margins(&sep, 8, 10, 0, 10);
            self.list.append(&sep);
        }
        let archived_count: usize = ws.projects.borrow().iter().flat_map(|p| p.sessions.iter()).filter(|s| s.archived || archived_ids.contains(&s.id)).count();
        for p in projects {
            let expanded = self.expanded.borrow().contains(&p.id) || !query.is_empty();
            let w = Rc::downgrade(self);
            let id = p.id.clone();
            let path = p.path.clone();
            self.list.append(&project_header(
                &p,
                expanded,
                move || {
                    if let Some(me) = w.upgrade() {
                        {
                            let mut e = me.expanded.borrow_mut();
                            if !e.remove(&id) {
                                e.insert(id.clone());
                            }
                        }
                        me.render();
                    }
                },
                move || {
                    app::get().claude.new_session(&path, None, None, None, None);
                },
            ));
            if expanded {
                let limit = if query.is_empty() { 40 } else { 200 };
                let visible: Vec<SessionInfo> = p.sessions.iter().filter(|s| (show_archived || !(s.archived || archived_ids.contains(&s.id))) && !pinned_ids.contains(&s.id)).take(limit).cloned().collect();
                if visible.is_empty() {
                    continue;
                }
                let lb = self.session_list(&ws, build_tree(visible));
                margins(&lb, 0, 0, 4, 0);
                self.list.append(&lb);
            }
        }
        if ws.projects.borrow().is_empty() && ws.tabs.borrow().is_empty() && !ws.loading_projects.get() {
            let l = label_with("No Claude Code sessions yet", &["sy-muted"]);
            margins(&l, 10, 12, 10, 12);
            self.list.append(&l);
        } else if archived_count > 0 || show_archived {
            let toggle = link_button(if show_archived { "Hide archived sessions" } else { "Show archived sessions" });
            toggle.add_css_class("sy-small");
            toggle.set_halign(gtk::Align::Start);
            margins(&toggle, 10, 10, 12, 10);
            let w = Rc::downgrade(self);
            toggle.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.show_archived.set(!me.show_archived.get());
                    me.render();
                }
            });
            self.list.append(&toggle);
        }
    }
}

pub fn new_session_here(ws: &Rc<Workspace>) {
    if let Some(tab) = ws.selected_tab() {
        if std::path::Path::new(&tab.folder).is_dir() {
            ws.new_session(&tab.folder, None, None, None, None);
            return;
        }
    }
    let first = ws.projects.borrow().iter().find(|p| p.exists()).map(|p| p.path.clone());
    match first {
        Some(path) => {
            ws.new_session(&path, None, None, None, None);
        }
        None => open_folder(),
    }
}

pub fn open_folder() {
    dialogs::choose_folder("New session in folder", |path| {
        app::get().claude.new_session(&path, None, None, None, None);
    });
}

pub fn build() -> gtk::Widget {
    let list = vbox(0);
    let scroll = scrolled(&list);
    let open = icon_button("sy-folder-symbolic", "New session in folder…");
    open.connect_clicked(|_| open_folder());
    let holder: Rc<RefCell<Option<std::rc::Weak<Column>>>> = Rc::new(RefCell::new(None));
    let status = RefreshStatus::new(false, || {
        let ws = app::get().claude.clone();
        crate::rt::spawn_local(async move { ws.reload_projects().await });
    });
    let me = Rc::new(Column {
        list,
        tabs_box: vbox(0),
        query: RefCell::new(String::new()),
        expanded: RefCell::new(HashSet::new()),
        collapsed_parents: RefCell::new(HashSet::new()),
        show_archived: Cell::new(false),
        status,
        open_folder: open.clone(),
        initialized: Cell::new(false),
        tabs_key: RefCell::new(String::new()),
        tab_dots: RefCell::new(vec![]),
        session_dots: RefCell::new(vec![]),
        memory: RefCell::new(None),
    });
    *holder.borrow_mut() = Some(Rc::downgrade(&me));
    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("Search sessions"));
    let w = Rc::downgrade(&me);
    search.connect_search_changed(move |e| {
        if let Some(me) = w.upgrade() {
            *me.query.borrow_mut() = e.text().trim().to_string();
            me.render();
        }
    });
    let search_bar = gtk::SearchBar::new();
    search_bar.set_child(Some(&search));
    search_bar.connect_entry(&search);
    let search_btn = gtk::ToggleButton::new();
    search_btn.set_icon_name("system-search-symbolic");
    search_btn.set_tooltip_text(Some("Search sessions"));
    set_label(&search_btn, "Search sessions");
    search_btn.bind_property("active", &search_bar, "search-mode-enabled").bidirectional().build();
    let content = vbox(0);
    content.append(&scroll);
    content.append(&footer(&me.status));
    let tv = adw::ToolbarView::new();
    let hb = adw::HeaderBar::new();
    hb.set_show_end_title_buttons(false);
    hb.set_title_widget(Some(&adw::WindowTitle::new("Agents", "")));
    hb.pack_start(&search_btn);
    hb.pack_end(&open);
    tv.add_top_bar(&hb);
    tv.add_top_bar(&search_bar);
    tv.set_content(Some(&content));
    let w = Rc::downgrade(&me);
    app::get().claude.changed.connect(move |e| match w.upgrade() {
        Some(me) => {
            match e {
                WsEvent::TabState | WsEvent::Selection => me.refresh_live(),
                WsEvent::Loading => {
                    let ws = app::get().claude.clone();
                    me.status.update(ws.projects_updated.get(), ws.loading_projects.get(), None);
                }
                _ => me.render(),
            }
            true
        }
        None => false,
    });
    let w = Rc::downgrade(&me);
    accounts::store().changed.connect(move |_| match w.upgrade() {
        Some(me) => {
            me.render();
            true
        }
        None => false,
    });
    let w = Rc::downgrade(&me);
    app::on_refresh(move |_| match w.upgrade() {
        Some(_) => {
            let ws = app::get().claude.clone();
            crate::rt::spawn_local(async move { ws.reload_projects().await });
            true
        }
        None => false,
    });
    me.render();
    let ws = app::get().claude.clone();
    crate::rt::spawn_local(async move {
        accounts::store().refresh().await;
        ws.reload_projects().await;
    });
    keep_alive(&tv, me);
    tv.upcast()
}
