use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use super::menu::{context_menu, Menu};
use super::pr::model::{Change, PrModel};
use super::widgets::*;
use crate::api::ApiError;
use crate::jira::{self, JiraIssue, JiraTransition};
use crate::{rt, util};

const DESCRIPTION_LINES: i32 = 6;

fn panel() -> gtk::Box {
    let c = vbox(10);
    c.add_css_class("jira-panel");
    c.set_hexpand(true);
    c
}

pub fn status_color(category: &str) -> &'static str {
    match category {
        "done" => "green",
        "indeterminate" => "sky",
        _ => "muted",
    }
}

fn type_icon(kind: Option<&str>) -> (&'static str, &'static str) {
    let t = kind.unwrap_or("").to_lowercase();
    if t.contains("bug") {
        ("sy-attention-symbolic", "red")
    } else if t.contains("epic") {
        ("sy-bolt-symbolic", "violet")
    } else if t.contains("story") {
        ("sy-tag-symbolic", "green")
    } else if t.contains("sub") {
        ("sy-checklist-symbolic", "sky")
    } else {
        ("sy-check-circle-symbolic", "sky")
    }
}

fn priority_color(priority: &str) -> &'static str {
    match priority.to_lowercase().as_str() {
        "highest" | "blocker" | "critical" => "red",
        "high" | "major" => "coral",
        "medium" => "amber",
        _ => "muted",
    }
}

fn is_long_description(text: &str) -> bool {
    text.chars().count() > 320 || text.split('\n').filter(|l| !l.is_empty()).count() > DESCRIPTION_LINES as usize
}

fn clamp_lines(l: &gtk::Label, clamped: bool) {
    l.set_lines(if clamped { DESCRIPTION_LINES } else { -1 });
    l.set_ellipsize(if clamped { gtk::pango::EllipsizeMode::End } else { gtk::pango::EllipsizeMode::None });
}

struct Pill {
    widget: gtk::Box,
    dot: gtk::Box,
    busy: Loader,
}

fn status_pill(status: &str, category: &str, chevron: bool) -> Pill {
    let widget = hbox(5);
    widget.add_css_class("jira-status");
    widget.add_css_class(status_color(category));
    widget.set_valign(gtk::Align::Center);
    let dot = fixed_box(&["jira-dot"], 6, 6);
    let busy = spinner(10);
    busy.set_visible(false);
    widget.append(&dot);
    widget.append(&busy);
    widget.append(&gtk::Label::new(Some(&status.to_uppercase())));
    if chevron {
        widget.append(&icon("pan-down-symbolic", 10));
    }
    Pill { widget, dot, busy }
}

fn meta_chip<W: IsA<gtk::Widget>>(leading: &W, text: &str, tip: &str) -> gtk::Box {
    let b = hbox(5);
    b.add_css_class("jira-chip");
    b.add_css_class("sy-muted");
    b.add_css_class("sy-small");
    b.set_tooltip_text(Some(tip));
    leading.as_ref().set_valign(gtk::Align::Center);
    b.append(leading);
    let l = ellipsized(text, &[]);
    l.set_max_width_chars(32);
    b.append(&l);
    b
}

fn icon_text_button(icon_name: &str, text: &str) -> gtk::Button {
    let b = gtk::Button::new();
    b.set_child(Some(&icon_label_content(icon_name, text)));
    b
}

fn loading_panel(key: &str) -> gtk::Box {
    let p = panel();
    let row = hbox(10);
    row.append(&spinner(12));
    row.append(&label_with(key, &["sy-mono", "sy-muted"]));
    p.append(&row);
    p
}

fn link_field() -> (gtk::Box, gtk::Entry, gtk::Button) {
    let row = hbox(8);
    row.add_css_class("jira-link-panel");
    let glyph = colored_icon("insert-link-symbolic", 14, "muted");
    glyph.set_valign(gtk::Align::Center);
    row.append(&glyph);
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some("Ticket key, e.g. ABC-123"));
    entry.set_width_chars(22);
    entry.set_max_width_chars(22);
    entry.set_valign(gtk::Align::Center);
    row.append(&entry);
    let go = suggested("Link");
    go.set_sensitive(false);
    go.set_valign(gtk::Align::Center);
    let g = go.clone();
    entry.connect_changed(move |e| g.set_sensitive(jira::parse_key(&e.text()).is_some()));
    row.append(&go);
    let note = ellipsized("Saved for this pull request on this computer.", &["sy-dim", "sy-small"]);
    note.set_hexpand(true);
    note.set_valign(gtk::Align::Center);
    row.append(&note);
    (row, entry, go)
}

fn busy_button(label: &str) -> (gtk::Button, gtk::Stack) {
    let b = suggested(label);
    let stack = gtk::Stack::new();
    stack.add_named(&gtk::Label::new(Some(label)), Some("label"));
    stack.add_named(&spinner(12), Some("busy"));
    b.set_child(Some(&stack));
    (b, stack)
}

#[derive(Clone, PartialEq)]
enum FormMode {
    List,
    Adding,
    Editing(String),
}

thread_local! {
    static REFRESHING: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
}

pub fn connect_form() -> gtk::Box {
    let root = vbox(12);
    let mode = Rc::new(RefCell::new(FormMode::List));
    let holder: Rc<RefCell<Option<Rc<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    let weak = root.downgrade();
    let (m, h) = (mode.clone(), holder.clone());
    let fill: Rc<dyn Fn()> = Rc::new(move || {
        let Some(root) = weak.upgrade() else { return };
        let Some(refill) = h.borrow().clone() else { return };
        clear(&root);
        build_form(&root, &m, refill);
    });
    *holder.borrow_mut() = Some(fill.clone());
    fill();
    let weak = root.downgrade();
    let f = fill.clone();
    jira::on_change(move |_| {
        if weak.upgrade().is_none() {
            return false;
        }
        f();
        true
    });
    root
}

fn build_form(root: &gtk::Box, mode: &Rc<RefCell<FormMode>>, refill: Rc<dyn Fn()>) {
    let list = jira::connections();
    let current = mode.borrow().clone();
    let set_mode = {
        let (mode, refill) = (mode.clone(), refill.clone());
        Rc::new(move |m: FormMode| {
            *mode.borrow_mut() = m;
            refill();
        })
    };
    if list.is_empty() && current != FormMode::Adding {
        root.append(&connection_editor(None, Rc::new(|| {})));
        return;
    }
    for c in &list {
        if current == FormMode::Editing(c.id.clone()) {
            let s = set_mode.clone();
            root.append(&connection_editor(Some(c.clone()), Rc::new(move || s(FormMode::List))));
        } else {
            root.append(&connection_row(c, set_mode.clone(), refill.clone()));
        }
    }
    if current == FormMode::Adding {
        let s = set_mode.clone();
        root.append(&connection_editor(None, Rc::new(move || s(FormMode::List))));
    } else {
        let add = gtk::Button::new();
        add.set_child(Some(&icon_label_content("list-add-symbolic", "Add Jira connection")));
        add.set_halign(gtk::Align::Start);
        let s = set_mode.clone();
        add.connect_clicked(move |_| s(FormMode::Adding));
        root.append(&add);
    }
    if jira::has_several() || !jira::org_overrides().is_empty() || !jira::repo_overrides().is_empty() {
        root.append(&routing_rules());
    }
}

fn refresh_connection(id: String, refill: Rc<dyn Fn()>) {
    REFRESHING.with(|r| r.borrow_mut().insert(id.clone()));
    refill();
    rt::spawn_local(async move {
        jira::refresh_projects(&id).await;
        REFRESHING.with(|r| r.borrow_mut().remove(&id));
        refill();
    });
}

fn connection_row(c: &jira::JiraConnection, set_mode: Rc<dyn Fn(FormMode)>, refill: Rc<dyn Fn()>) -> gtk::Box {
    let row = hbox(10);
    let missing = jira::known_token(&c.id) == Some(false);
    if jira::known_token(&c.id).is_none() {
        let (id, refill) = (c.id.clone(), refill.clone());
        rt::spawn_local(async move {
            if jira::token(&id).await.is_none() {
                refill();
            }
        });
    }
    let status = if missing { colored_icon("sy-attention-symbolic", 18, "amber") } else { colored_icon("sy-check-circle-symbolic", 18, "green") };
    status.set_tooltip_text(Some(if missing { "No API token saved for this connection" } else { "Connected" }));
    row.append(&status);
    let texts = vbox(1);
    texts.set_hexpand(true);
    let top = hbox(6);
    top.append(&ellipsized(&c.name, &["sy-text"]));
    if let Some(me) = &c.display_name {
        top.append(&ellipsized(me, &["sy-muted", "sy-small"]));
    }
    texts.append(&top);
    let sub = ellipsized(&c.subtitle(), &["sy-muted", "sy-small"]);
    if !c.project_keys.is_empty() {
        sub.set_tooltip_text(Some(&c.project_keys.join(", ")));
    }
    texts.append(&sub);
    row.append(&texts);
    if REFRESHING.with(|r| r.borrow().contains(&c.id)) {
        row.append(&wake_spinner(14));
    }
    let mut menu = Menu::new();
    let (s, id) = (set_mode.clone(), c.id.clone());
    menu.item("Edit…", move || s(FormMode::Editing(id.clone())));
    let (s, id) = (set_mode.clone(), c.id.clone());
    menu.item("Reconnect with a new token…", move || s(FormMode::Editing(id.clone())));
    let (id, r) = (c.id.clone(), refill.clone());
    menu.item("Refresh projects", move || refresh_connection(id.clone(), r.clone()));
    menu.section(None);
    let (id, name) = (c.id.clone(), c.name.clone());
    menu.item("Remove…", move || {
        let id = id.clone();
        crate::ui::dialogs::confirm(&format!("Remove {name}?"), Some("Its API token is deleted from the system keyring. Rules that point to it are removed too."), "Remove", true, move || jira::remove(&id));
    });
    let more = menu.button("view-more-symbolic", &format!("Actions for {}", c.name));
    more.add_css_class("flat");
    more.set_valign(gtk::Align::Center);
    row.append(&more);
    row
}

fn connection_editor(existing: Option<jira::JiraConnection>, done: Rc<dyn Fn()>) -> gtk::Box {
    let configured = jira::is_configured();
    let framed = existing.is_some() || configured;
    let root = vbox(10);
    if framed {
        root.add_css_class("sy-card-flat");
        pad(&root, 12);
    }
    if existing.is_none() {
        let text = if configured {
            "Add another Jira site. PullYard picks the right one for each ticket by its project key."
        } else {
            "Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in the system keyring."
        };
        root.append(&wrap_label(text, &["sy-muted"]));
    }
    let name = gtk::Entry::new();
    name.set_placeholder_text(Some("Name — e.g. Work A"));
    root.append(&name);
    let site = gtk::Entry::new();
    site.set_placeholder_text(Some("Jira address — acme.atlassian.net"));
    site.set_input_purpose(gtk::InputPurpose::Url);
    root.append(&site);
    let email = gtk::Entry::new();
    email.set_placeholder_text(Some("Atlassian account email (empty for a Data Center token)"));
    email.set_input_purpose(gtk::InputPurpose::Email);
    root.append(&email);
    if let Some(c) = &existing {
        name.set_text(&c.name);
        site.set_text(&c.site);
        email.set_text(&c.email);
    }
    let row = hbox(8);
    let token = gtk::PasswordEntry::new();
    token.set_show_peek_icon(true);
    token.set_hexpand(true);
    token.set_property("placeholder-text", if existing.is_none() { "API token" } else { "New API token (leave empty to keep the current one)" });
    let (connect, connect_stack) = busy_button(if existing.is_none() { "Connect" } else { "Save" });
    row.append(&token);
    row.append(&connect);
    if framed {
        let cancel = button("Cancel");
        let d = done.clone();
        cancel.connect_clicked(move |_| d());
        row.append(&cancel);
    }
    root.append(&row);
    let create = link_button("Create an API token at id.atlassian.com");
    create.set_halign(gtk::Align::Start);
    create.connect_clicked(|_| util::open_url(jira::TOKEN_URL));
    root.append(&create);
    let error = wrap_label("", &["fg-red", "sy-small"]);
    error.set_selectable(true);
    error.set_visible(false);
    root.append(&error);
    let editing = existing.is_some();
    let sync = {
        let (site, token, connect) = (site.clone(), token.clone(), connect.clone());
        move || connect.set_sensitive(!site.text().trim().is_empty() && (editing || !token.text().trim().is_empty()))
    };
    sync();
    let s = sync.clone();
    site.connect_changed(move |_| s());
    let s = sync.clone();
    token.connect_changed(move |_| s());
    let busy = Rc::new(Cell::new(false));
    let token_entry = token.clone();
    let id = existing.map(|c| c.id);
    let submit = Rc::new(move || {
        if busy.get() || site.text().trim().is_empty() || (id.is_none() && token.text().trim().is_empty()) {
            return;
        }
        busy.set(true);
        connect_stack.set_visible_child_name("busy");
        error.set_visible(false);
        let (name_v, site_v, email_v, token_v) = (name.text().to_string(), site.text().to_string(), email.text().to_string(), token.text().to_string());
        let (busy, stack, error, token, done, id) = (busy.clone(), connect_stack.clone(), error.clone(), token.clone(), done.clone(), id.clone());
        rt::spawn_local(async move {
            let result = match &id {
                Some(id) => jira::update(id, &name_v, &site_v, &email_v, Some(token_v)).await,
                None => jira::add(&name_v, &site_v, &email_v, &token_v).await.map(|_| ()),
            };
            busy.set(false);
            stack.set_visible_child_name("label");
            match result {
                Ok(()) => {
                    token.set_text("");
                    done();
                }
                Err(e) => {
                    error.set_text(&e.message);
                    error.set_visible(true);
                }
            }
        });
    });
    let s = submit.clone();
    connect.connect_clicked(move |_| s());
    let s = submit.clone();
    token_entry.connect_activate(move |_| s());
    root
}

fn routing_rules() -> gtk::Box {
    let root = vbox(8);
    root.set_margin_top(6);
    root.append(&label_with("Rules", &["sy-dim", "sy-small", "sy-bold"]));
    root.append(&wrap_label("Tickets go to the site that owns their project key. A rule wins over that: a repository rule first, then an organization rule.", &["sy-muted", "sy-small"]));
    let mut rules: Vec<(String, String, bool)> = vec![];
    let mut repos: Vec<(String, String)> = jira::repo_overrides().into_iter().collect();
    repos.sort();
    rules.extend(repos.into_iter().map(|(k, v)| (k, v, true)));
    let mut orgs: Vec<(String, String)> = jira::org_overrides().into_iter().collect();
    orgs.sort();
    rules.extend(orgs.into_iter().map(|(k, v)| (k, v, false)));
    for (key, id, is_repo) in rules {
        let row = hbox(8);
        row.append(&colored_icon(if is_repo { "sy-repo-symbolic" } else { "sy-project-symbolic" }, 14, "muted"));
        row.append(&label_with(&if is_repo { key.clone() } else { format!("{key}/*") }, &["sy-mono", "sy-text"]));
        row.append(&label_with("→", &["sy-dim"]));
        let target = label_with(&jira::connection(Some(&id)).map(|c| c.name).unwrap_or_else(|| "—".into()), &["sy-text"]);
        target.set_hexpand(true);
        target.set_xalign(0.0);
        row.append(&target);
        let remove = icon_button("list-remove-symbolic", &format!("Remove rule for {key}"));
        remove.set_tooltip_text(Some("Remove this rule"));
        remove.connect_clicked(move |_| {
            if is_repo {
                if let Some(repo) = crate::api::models::RepoRef::from_full(&key) {
                    jira::set_repo_override(None, &repo);
                }
            } else {
                jira::set_org_override(None, &key);
            }
        });
        row.append(&remove);
        root.append(&row);
    }
    let list = jira::connections();
    let add_row = hbox(8);
    let org = gtk::Entry::new();
    org.set_placeholder_text(Some("GitHub organization"));
    org.set_width_chars(18);
    add_row.append(&org);
    let names: Vec<&str> = list.iter().map(|c| c.name.as_str()).collect();
    let picker = gtk::DropDown::from_strings(&names);
    picker.set_tooltip_text(Some("Jira connection"));
    add_row.append(&picker);
    let add = button("Add rule");
    add_row.append(&add);
    let sync = {
        let (org, add) = (org.clone(), add.clone());
        move || add.set_sensitive(!org.text().trim().is_empty())
    };
    sync();
    let s = sync.clone();
    org.connect_changed(move |_| s());
    let ids: Vec<String> = list.iter().map(|c| c.id.clone()).collect();
    let submit = {
        let (org, picker) = (org.clone(), picker.clone());
        Rc::new(move || {
            let name = org.text().trim().trim_matches(|c| c == '@' || c == '/' || c == '*').to_string();
            let Some(id) = ids.get(picker.selected() as usize).cloned() else { return };
            if name.is_empty() {
                return;
            }
            jira::set_org_override(Some(id), &name);
        })
    };
    let s = submit.clone();
    add.connect_clicked(move |_| s());
    let s = submit.clone();
    org.connect_activate(move |_| s());
    root.append(&add_row);
    root
}

pub fn repo_chip(repo: &crate::api::models::RepoRef) -> gtk::Box {
    let holder = hbox(0);
    let weak = holder.downgrade();
    let repo = repo.clone();
    let fill = Rc::new(move || {
        let Some(holder) = weak.upgrade() else { return };
        clear(&holder);
        holder.set_visible(jira::is_configured());
        if jira::is_configured() {
            holder.append(&repo_chip_button(&repo));
        }
    });
    fill();
    let weak = holder.downgrade();
    jira::on_change(move |_| {
        if weak.upgrade().is_none() {
            return false;
        }
        fill();
        true
    });
    holder
}

fn repo_chip_button(repo: &crate::api::models::RepoRef) -> gtk::MenuButton {
    let (by_repo, by_org) = jira::override_for(repo);
    let several = jira::has_several();
    let list = jira::connections();
    let mark = |on: bool, text: &str| format!("{}{text}", if on { "✓ " } else { "" });
    let automatic = match jira::connection(by_org.as_deref()) {
        Some(c) => format!("Same as {} ({})", repo.owner, c.name),
        None if several => "Automatic — by project key".to_string(),
        None => "Automatic".to_string(),
    };
    let mut menu = Menu::new();
    menu.section(Some(&format!("Jira for {}", repo.full())));
    let r = repo.clone();
    menu.item(&mark(by_repo.is_none(), &automatic), move || jira::set_repo_override(None, &r));
    for c in &list {
        let (r, id) = (repo.clone(), c.id.clone());
        menu.item(&mark(by_repo.as_deref() == Some(c.id.as_str()), &c.name), move || jira::set_repo_override(Some(id.clone()), &r));
    }
    if several {
        menu.section(Some(&format!("All of {}", repo.owner)));
        let owner = repo.owner.clone();
        menu.item(&mark(by_org.is_none(), "By project key"), move || jira::set_org_override(None, &owner));
        for c in &list {
            let (owner, id) = (repo.owner.clone(), c.id.clone());
            menu.item(&mark(by_org.as_deref() == Some(c.id.as_str()), &c.name), move || jira::set_org_override(Some(id.clone()), &owner));
        }
    }
    let title = jira::connection(jira::connection_for_repo(repo).as_deref()).map(|c| c.name).unwrap_or_else(|| "Jira: by key".into());
    let b = gtk::MenuButton::new();
    b.add_css_class("flat");
    b.add_css_class("chip-button");
    b.set_child(Some(&chip(&title, "sky", Some("sy-ticket-symbolic"), false)));
    b.set_tooltip_text(Some("Which Jira this repository's tickets come from"));
    b.set_valign(gtk::Align::Center);
    menu.apply_to(&b);
    b
}

pub fn repo_badge(full: &str) -> Option<gtk::Box> {
    if !jira::has_several() {
        return None;
    }
    let repo = crate::api::models::RepoRef::from_full(full)?;
    let c = jira::connection(jira::connection_for_repo(&repo).as_deref())?;
    let b = hbox(3);
    b.append(&colored_icon("sy-ticket-symbolic", 10, "sky"));
    b.append(&label_with(&c.name, &["fg-sky", "sy-tiny"]));
    b.set_tooltip_text(Some(&format!("Jira tickets come from {}", c.name)));
    b.set_valign(gtk::Align::Center);
    Some(b)
}

pub struct JiraTab {
    pub widget: gtk::ScrolledWindow,
    model: Rc<PrModel>,
    content: gtk::Box,
    link_panel: gtk::Box,
    link_entry: gtk::Entry,
    issues: RefCell<HashMap<String, JiraIssue>>,
    errors: RefCell<HashMap<String, String>>,
    signature: RefCell<String>,
    pending: Cell<usize>,
    linking: Cell<bool>,
    open: RefCell<HashSet<String>>,
    expanded: RefCell<HashSet<String>>,
}

pub fn keys(model: &PrModel) -> Vec<String> {
    let pr = model.pr.borrow();
    match pr.as_ref() {
        Some(pr) => jira::keys_for(&pr.url, &pr.title, &pr.head_ref_name, &pr.body),
        None => vec![],
    }
}

impl JiraTab {
    pub fn new(model: Rc<PrModel>) -> Rc<Self> {
        let content = vbox(16);
        pad(&content, 20);
        let clamp = adw::Clamp::new();
        clamp.set_maximum_size(860);
        clamp.set_child(Some(&content));
        let widget = scrolled(&clamp);
        let (link_panel, link_entry, link_go) = link_field();
        let me = Rc::new(JiraTab {
            widget,
            model,
            content,
            link_panel,
            link_entry,
            issues: RefCell::new(HashMap::new()),
            errors: RefCell::new(HashMap::new()),
            signature: RefCell::new(String::new()),
            pending: Cell::new(0),
            linking: Cell::new(false),
            open: RefCell::new(HashSet::new()),
            expanded: RefCell::new(HashSet::new()),
        });
        let w = Rc::downgrade(&me);
        link_go.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.link();
            }
        });
        let w = Rc::downgrade(&me);
        me.link_entry.connect_activate(move |_| {
            if let Some(me) = w.upgrade() {
                me.link();
            }
        });
        let esc = gtk::EventControllerKey::new();
        let w = Rc::downgrade(&me);
        esc.connect_key_pressed(move |_, key, _, _| {
            if key != gtk::gdk::Key::Escape {
                return glib::Propagation::Proceed;
            }
            if let Some(me) = w.upgrade() {
                me.set_linking(false);
            }
            glib::Propagation::Stop
        });
        me.link_entry.add_controller(esc);
        let w = Rc::downgrade(&me);
        jira::on_change(move |_| match w.upgrade() {
            Some(me) => {
                me.issues.borrow_mut().clear();
                me.errors.borrow_mut().clear();
                me.signature.borrow_mut().clear();
                me.update();
                true
            }
            None => false,
        });
        me.update();
        me
    }

    fn pr_url(&self) -> String {
        self.model.pr.borrow().as_ref().map(|p| p.url.clone()).unwrap_or_default()
    }

    pub fn update(self: &Rc<Self>) {
        let keys = keys(&self.model);
        let signature = format!("{}|{}", jira::is_configured(), keys.join(","));
        if *self.signature.borrow() == signature {
            return;
        }
        *self.signature.borrow_mut() = signature;
        self.load(keys);
    }

    fn refresh(self: &Rc<Self>) {
        self.signature.borrow_mut().clear();
        self.update();
    }

    fn reload(self: &Rc<Self>) {
        self.issues.borrow_mut().clear();
        self.errors.borrow_mut().clear();
        jira::clear_cache();
        self.refresh();
    }

    fn set_linking(self: &Rc<Self>, on: bool) {
        self.linking.set(on);
        self.render();
        if on {
            self.link_entry.grab_focus();
        }
    }

    fn link(self: &Rc<Self>) {
        let url = self.pr_url();
        if url.is_empty() || jira::link(&url, &self.link_entry.text()).is_none() {
            return;
        }
        self.link_entry.set_text("");
        self.linking.set(false);
        self.refresh();
        self.model.emit(Change::Pr);
    }

    fn hide(self: &Rc<Self>, key: &str) {
        jira::hide(&self.pr_url(), key);
        self.issues.borrow_mut().remove(key);
        self.open.borrow_mut().remove(key);
        self.refresh();
        self.model.emit(Change::Pr);
    }

    fn show_hidden(self: &Rc<Self>) {
        jira::set_hidden(&self.pr_url(), vec![]);
        self.refresh();
        self.model.emit(Change::Pr);
    }

    fn unlink(self: &Rc<Self>, key: &str) {
        jira::unlink(&self.pr_url(), key);
        self.issues.borrow_mut().remove(key);
        self.errors.borrow_mut().remove(key);
        self.open.borrow_mut().remove(key);
        self.refresh();
        self.model.emit(Change::Pr);
    }

    fn load(self: &Rc<Self>, keys: Vec<String>) {
        if !jira::is_configured() {
            self.render();
            return;
        }
        let mut missing = vec![];
        for key in keys {
            if self.issues.borrow().contains_key(&key) || self.errors.borrow().contains_key(&key) {
                continue;
            }
            match jira::cached(&key, Some(&self.model.r.repo)) {
                Some(hit) => {
                    self.issues.borrow_mut().insert(key, hit);
                }
                None => missing.push(key),
            }
        }
        self.pending.set(self.pending.get() + missing.len());
        self.render();
        if missing.is_empty() {
            return;
        }
        let weak = Rc::downgrade(self);
        let repo = self.model.r.repo.clone();
        rt::spawn_local(async move {
            for key in missing {
                let weak = weak.clone();
                let repo = repo.clone();
                rt::spawn_local(async move {
                    let result = jira::fetch_issue(&key, Some(&repo)).await;
                    let Some(me) = weak.upgrade() else { return };
                    me.pending.set(me.pending.get().saturating_sub(1));
                    match result {
                        Ok(issue) => {
                            me.errors.borrow_mut().remove(&key);
                            me.issues.borrow_mut().insert(key, issue);
                        }
                        Err(e) => {
                            me.errors.borrow_mut().insert(key, e.message);
                        }
                    }
                    me.render();
                });
            }
        });
    }

    fn render(self: &Rc<Self>) {
        clear(&self.content);
        if !jira::is_configured() {
            let p = panel();
            p.append(&connect_form());
            self.content.append(&p);
            return;
        }
        let keys = keys(&self.model);
        let linked = jira::linked(&self.pr_url());
        self.content.append(&self.header(keys.len()));
        if self.linking.get() {
            self.content.append(&self.link_panel);
        }
        if keys.is_empty() {
            self.content.append(&self.empty_state());
        }
        for (index, key) in keys.iter().enumerate() {
            let manual = linked.contains(key);
            let issue = self.issues.borrow().get(key).cloned();
            let error = self.errors.borrow().get(key).cloned();
            let entry: gtk::Widget = match (issue, error) {
                (Some(issue), _) if index == 0 || self.open.borrow().contains(key) => self.issue_card(issue, manual, index != 0).upcast(),
                (Some(issue), _) => self.issue_row(&issue, manual).upcast(),
                (None, Some(e)) => self.error_panel(key, &e, manual).upcast(),
                (None, None) => loading_panel(key).upcast(),
            };
            self.content.append(&entry);
        }
        let hidden = jira::hidden(&self.pr_url()).len();
        if hidden > 0 {
            let show = link_button(&if hidden == 1 { "Show 1 hidden ticket".to_string() } else { format!("Show {hidden} hidden tickets") });
            show.add_css_class("sy-small");
            show.set_halign(gtk::Align::Start);
            let w = Rc::downgrade(self);
            show.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.show_hidden();
                }
            });
            self.content.append(&show);
        }
    }

    fn header(self: &Rc<Self>, count: usize) -> gtk::Box {
        let row = hbox(10);
        row.append(&icon_tile("sy-ticket-symbolic", "sky", 26));
        let texts = vbox(1);
        texts.set_hexpand(true);
        texts.set_valign(gtk::Align::Center);
        let title = if count == 1 { "1 linked ticket".to_string() } else { format!("{count} linked tickets") };
        texts.append(&ellipsized(&title, &["sy-heading", "sy-text"]));
        let loaded: Vec<JiraIssue> = keys(&self.model).iter().filter_map(|k| self.issues.borrow().get(k).cloned()).collect();
        let subtitle = jira::header_subtitle(&loaded);
        if !subtitle.is_empty() {
            texts.append(&ellipsized(&subtitle, &["sy-muted", "sy-small"]));
        }
        row.append(&texts);
        if self.pending.get() > 0 {
            row.append(&spinner(14));
        }
        let toggle = gtk::ToggleButton::new();
        if self.linking.get() {
            toggle.set_label("Cancel");
        } else {
            toggle.set_child(Some(&icon_label_content("list-add-symbolic", "Link ticket")));
        }
        toggle.set_active(self.linking.get());
        toggle.set_valign(gtk::Align::Center);
        let w = Rc::downgrade(self);
        toggle.connect_toggled(move |t| {
            if let Some(me) = w.upgrade() {
                me.set_linking(t.is_active());
            }
        });
        row.append(&toggle);
        let reload = icon_button("view-refresh-symbolic", "Reload from Jira");
        reload.set_valign(gtk::Align::Center);
        let w = Rc::downgrade(self);
        reload.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.reload();
            }
        });
        row.append(&reload);
        row
    }

    fn empty_state(self: &Rc<Self>) -> gtk::Box {
        let b = vbox(10);
        b.add_css_class("jira-empty");
        b.set_hexpand(true);
        let glyph = icon("sy-ticket-symbolic", 30);
        glyph.add_css_class("sy-dim");
        b.append(&glyph);
        let title = label_with("No Jira ticket on this pull request", &["sy-heading", "sy-text"]);
        title.set_xalign(0.5);
        b.append(&title);
        let note = wrap_label("PullYard looks for keys like ABC-123 in the title, branch name and description.", &["sy-muted"]);
        note.set_xalign(0.5);
        note.set_justify(gtk::Justification::Center);
        b.append(&note);
        if !self.linking.get() {
            let go = button("Link a ticket");
            go.set_halign(gtk::Align::Center);
            let w = Rc::downgrade(self);
            go.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.set_linking(true);
                }
            });
            b.append(&go);
        }
        b
    }

    fn unlink_button(self: &Rc<Self>, key: &str) -> gtk::Button {
        let b = icon_text_button("sy-x-symbolic", "Unlink");
        b.add_css_class("flat");
        b.add_css_class("fg-red");
        b.set_valign(gtk::Align::Center);
        let w = Rc::downgrade(self);
        let key = key.to_string();
        b.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.unlink(&key);
            }
        });
        b
    }

    fn error_panel(self: &Rc<Self>, key: &str, error: &str, manual: bool) -> gtk::Box {
        let p = panel();
        let row = hbox(8);
        row.append(&colored_icon("sy-attention-symbolic", 14, "amber"));
        row.append(&label_with(key, &["sy-mono", "sy-bold", "sy-text"]));
        let l = wrap_label(error, &["sy-muted"]);
        l.set_lines(2);
        l.set_ellipsize(gtk::pango::EllipsizeMode::End);
        l.set_selectable(true);
        l.set_hexpand(true);
        row.append(&l);
        if manual {
            row.append(&self.unlink_button(key));
        }
        p.append(&row);
        p
    }

    fn issue_row(self: &Rc<Self>, issue: &JiraIssue, manual: bool) -> gtk::Button {
        let b = gtk::Button::new();
        b.add_css_class("jira-row");
        b.set_tooltip_text(Some("Show details"));
        let row = hbox(10);
        let (icon_name, color) = type_icon(issue.kind.as_deref());
        row.append(&colored_icon(icon_name, 14, color));
        row.append(&label_with(&issue.key, &["sy-mono", "sy-bold", "sy-text"]));
        let summary = ellipsized(&issue.summary, &["sy-muted"]);
        summary.set_hexpand(true);
        row.append(&summary);
        row.append(&status_pill(&issue.status, &issue.status_category, false).widget);
        let chevron = icon("pan-end-symbolic", 12);
        chevron.add_css_class("sy-dim");
        row.append(&chevron);
        b.set_child(Some(&row));
        let w = Rc::downgrade(self);
        let key = issue.key.clone();
        b.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.open.borrow_mut().insert(key.clone());
                me.render();
            }
        });
        let (w, key, url) = (Rc::downgrade(self), issue.key.clone(), issue.url.clone());
        context_menu(&b, move || {
            let menu = Menu::ctx();
            let url = url.clone();
            menu.item("Open in Jira", move || util::open_url(&url));
            if !manual {
                let (w, key) = (w.clone(), key.clone());
                menu.item("Hide on this pull request", move || {
                    if let Some(me) = w.upgrade() {
                        me.hide(&key);
                    }
                });
            }
            menu
        });
        b
    }

    fn issue_card(self: &Rc<Self>, issue: JiraIssue, manual: bool, collapsible: bool) -> gtk::Box {
        let c = vbox(14);
        c.add_css_class("jira-card");
        c.set_hexpand(true);
        if let Some(parent) = &issue.parent_key {
            let line = hbox(5);
            line.append(&label_with("↑", &["sy-small"]));
            line.append(&label_with(parent, &["sy-mono", "sy-bold", "sy-small"]));
            if let Some(summary) = &issue.parent_summary {
                line.append(&ellipsized(summary, &["sy-small"]));
            }
            let b = gtk::Button::new();
            b.add_css_class("flat");
            b.add_css_class("jira-parent");
            b.add_css_class("sy-muted");
            b.set_halign(gtk::Align::Start);
            b.set_tooltip_text(Some("Parent ticket — open in Jira"));
            b.set_child(Some(&line));
            let url = format!("{}/browse/{parent}", issue.site_base());
            b.connect_clicked(move |_| util::open_url(&url));
            c.append(&b);
        }
        let error_label = wrap_label("", &["fg-red", "sy-small"]);
        error_label.set_selectable(true);
        error_label.set_hexpand(true);
        let error_row = hbox(6);
        let warn = colored_icon("sy-attention-symbolic", 12, "red");
        warn.set_valign(gtk::Align::Start);
        error_row.append(&warn);
        error_row.append(&error_label);
        error_row.set_visible(false);
        let show_error: Rc<dyn Fn(Option<String>)> = {
            let (row, label) = (error_row.clone(), error_label.clone());
            Rc::new(move |e: Option<String>| {
                label.set_text(e.as_deref().unwrap_or_default());
                row.set_visible(e.is_some());
            })
        };
        let head = hbox(10);
        let (icon_name, color) = type_icon(issue.kind.as_deref());
        head.append(&icon_tile(icon_name, color, 24));
        head.append(&label_with(&issue.key, &["sy-mono", "sy-bold", "sy-text"]));
        if let Some(t) = &issue.kind {
            head.append(&ellipsized(t, &["sy-muted", "sy-small"]));
        }
        if let Some(c) = jira::connection(issue.connection_id.as_deref()).filter(|_| jira::has_several()) {
            let tag = chip(&c.name, "sky", None, false);
            tag.set_tooltip_text(Some(&format!("From {}", c.host())));
            head.append(&tag);
        }
        head.append(&spacer());
        head.append(&self.status_menu(&issue, show_error));
        if collapsible {
            let collapse = icon_button("pan-up-symbolic", "Collapse");
            set_expanded(&collapse, true);
            collapse.set_valign(gtk::Align::Center);
            let w = Rc::downgrade(self);
            let key = issue.key.clone();
            collapse.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.open.borrow_mut().remove(&key);
                    me.render();
                }
            });
            head.append(&collapse);
        }
        c.append(&head);
        let summary = wrap_label(&issue.summary, &["sy-text", "jira-summary"]);
        summary.set_selectable(true);
        c.append(&summary);
        c.append(&meta(&issue));
        if !issue.description.is_empty() {
            c.append(&self.description(&issue));
        }
        c.append(&error_row);
        c.append(&line());
        let foot = hbox(8);
        let open = icon_text_button("sy-external-symbolic", "Open in Jira");
        let url = issue.url.clone();
        open.connect_clicked(move |_| util::open_url(&url));
        foot.append(&open);
        let copy = icon_text_button("edit-copy-symbolic", "Copy link");
        let url = issue.url.clone();
        copy.connect_clicked(move |b| {
            util::copy(&url);
            b.set_child(Some(&icon_label_content("sy-check-symbolic", "Copied")));
            let weak = b.downgrade();
            glib::timeout_add_local_once(Duration::from_millis(1200), move || {
                if let Some(b) = weak.upgrade() {
                    b.set_child(Some(&icon_label_content("edit-copy-symbolic", "Copy link")));
                }
            });
        });
        foot.append(&copy);
        foot.append(&spacer());
        if manual {
            foot.append(&self.unlink_button(&issue.key));
        } else {
            let hide = icon_text_button("sy-eye-symbolic", "Hide");
            hide.add_css_class("flat");
            hide.set_tooltip_text(Some("Hide this ticket on this pull request"));
            let w = Rc::downgrade(self);
            let key = issue.key.clone();
            hide.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.hide(&key);
                }
            });
            foot.append(&hide);
        }
        c.append(&foot);
        c
    }

    fn description(self: &Rc<Self>, issue: &JiraIssue) -> gtk::Box {
        let b = vbox(6);
        b.add_css_class("jira-desc");
        b.append(&label_with("Description", &["sy-dim", "sy-small", "sy-bold"]));
        let text = wrap_label(&issue.description, &["sy-text"]);
        text.set_selectable(true);
        text.set_opacity(0.9);
        b.append(&text);
        if is_long_description(&issue.description) {
            let expanded = self.expanded.borrow().contains(&issue.key);
            clamp_lines(&text, !expanded);
            let more = link_button(if expanded { "Show less" } else { "Show more" });
            more.add_css_class("sy-small");
            more.set_halign(gtk::Align::Start);
            let w = Rc::downgrade(self);
            let key = issue.key.clone();
            more.connect_clicked(move |b| {
                let Some(me) = w.upgrade() else { return };
                let now = {
                    let mut set = me.expanded.borrow_mut();
                    if set.remove(&key) {
                        false
                    } else {
                        set.insert(key.clone());
                        true
                    }
                };
                clamp_lines(&text, !now);
                b.set_label(if now { "Show less" } else { "Show more" });
            });
            b.append(&more);
        }
        b
    }

    fn status_menu(self: &Rc<Self>, issue: &JiraIssue, show_error: Rc<dyn Fn(Option<String>)>) -> gtk::MenuButton {
        let mb = gtk::MenuButton::new();
        mb.add_css_class("flat");
        mb.add_css_class("jira-status-menu");
        mb.set_valign(gtk::Align::Center);
        mb.set_tooltip_text(Some("Change status"));
        set_label(&mb, &format!("Status: {}, change status", issue.status));
        mb.set_always_show_arrow(false);
        let pill = Rc::new(status_pill(&issue.status, &issue.status_category, true));
        mb.set_child(Some(&pill.widget));
        let placeholder = Menu::new();
        placeholder.disabled("Loading…");
        let popover = gtk::PopoverMenu::from_model(Some(&placeholder.model));
        placeholder.attach(&mb);
        mb.set_popover(Some(&popover));
        let mover: Rc<dyn Fn(String)> = {
            let (key, weak, mb_weak, conn) = (issue.key.clone(), Rc::downgrade(self), mb.downgrade(), issue.connection_id.clone());
            Rc::new(move |id: String| {
                let Some(mb) = mb_weak.upgrade() else { return };
                mb.set_sensitive(false);
                pill.dot.set_visible(false);
                pill.busy.set_visible(true);
                show_error(None);
                let (key, weak, mb_weak, pill, show_error, conn) = (key.clone(), weak.clone(), mb_weak.clone(), pill.clone(), show_error.clone(), conn.clone());
                rt::spawn_local(async move {
                    let result = match jira::client(conn.as_deref()).await {
                        Some(client) => {
                            let k = key.clone();
                            rt::run(async move {
                                client.transition(&k, &id).await?;
                                client.issue(&k).await
                            })
                            .await
                        }
                        None => Err(ApiError::new("Jira isn't connected")),
                    };
                    if let Some(mb) = mb_weak.upgrade() {
                        mb.set_sensitive(true);
                    }
                    pill.busy.set_visible(false);
                    pill.dot.set_visible(true);
                    match result {
                        Ok(mut issue) => {
                            issue.connection_id = conn;
                            jira::remember(&issue);
                            if let Some(me) = weak.upgrade() {
                                me.issues.borrow_mut().insert(issue.key.clone(), issue);
                                me.render();
                            }
                        }
                        Err(e) => show_error(Some(e.message)),
                    }
                });
            })
        };
        let state = Rc::new(Cell::new(false));
        let (key, mb_weak, conn) = (issue.key.clone(), mb.downgrade(), issue.connection_id.clone());
        popover.connect_show(move |p| {
            if state.replace(true) {
                return;
            }
            let (key, mb_weak, popover, mover, state, conn) = (key.clone(), mb_weak.clone(), p.clone(), mover.clone(), state.clone(), conn.clone());
            rt::spawn_local(async move {
                let transitions = match jira::client(conn.as_deref()).await {
                    Some(client) => rt::run(async move { client.transitions(&key).await }).await.unwrap_or_default(),
                    None => vec![],
                };
                let Some(mb) = mb_weak.upgrade() else { return };
                let mut menu = Menu::new();
                if transitions.is_empty() {
                    menu.disabled("No transitions available");
                    state.set(false);
                } else {
                    menu.section(Some("Move to"));
                    for t in transitions {
                        let (mover, id) = (mover.clone(), t.id.clone());
                        menu.item(&t.title(), move || mover(id.clone()));
                    }
                }
                popover.set_menu_model(Some(&menu.model));
                menu.attach(&mb);
            });
        });
        mb
    }
}

pub struct MergeFollowUp {
    pub widget: gtk::Box,
    signature: RefCell<String>,
    pr_url: RefCell<String>,
    issues: RefCell<Vec<JiraIssue>>,
    moves: RefCell<HashMap<String, JiraTransition>>,
    working: RefCell<Option<String>>,
    error: RefCell<Option<String>>,
    generation: Cell<u64>,
}

impl MergeFollowUp {
    pub fn new() -> Rc<Self> {
        let widget = vbox(6);
        widget.add_css_class("banner-box");
        widget.add_css_class("sky");
        widget.set_visible(false);
        widget.update_property(&[gtk::accessible::Property::Label("Jira follow-up")]);
        Rc::new(MergeFollowUp {
            widget,
            signature: RefCell::new(String::new()),
            pr_url: RefCell::new(String::new()),
            issues: RefCell::new(vec![]),
            moves: RefCell::new(HashMap::new()),
            working: RefCell::new(None),
            error: RefCell::new(None),
            generation: Cell::new(0),
        })
    }

    pub fn reset(&self) {
        self.signature.borrow_mut().clear();
    }

    pub fn update(self: &Rc<Self>, url: &str, merged: bool, keys: Vec<String>, repo: &crate::api::models::RepoRef) {
        let keys: Vec<String> = keys.into_iter().take(5).collect();
        let signature = format!("{url}|{merged}|{}|{}", keys.join(","), jira::is_configured());
        if *self.signature.borrow() == signature {
            return;
        }
        *self.signature.borrow_mut() = signature;
        *self.pr_url.borrow_mut() = url.to_string();
        self.generation.set(self.generation.get() + 1);
        self.issues.borrow_mut().clear();
        self.moves.borrow_mut().clear();
        *self.working.borrow_mut() = None;
        *self.error.borrow_mut() = None;
        self.render();
        if !merged || keys.is_empty() || jira::is_follow_up_dismissed(url) || !jira::is_configured() {
            return;
        }
        let generation = self.generation.get();
        let known: Vec<(String, Option<JiraIssue>)> = keys.into_iter().map(|k| (k.clone(), jira::cached(&k, Some(repo)))).collect();
        let repo = repo.clone();
        let weak = Rc::downgrade(self);
        rt::spawn_local(async move {
            let mut found = vec![];
            for (key, hit) in known {
                match hit {
                    Some(issue) => found.push(issue),
                    None => {
                        if let Ok(issue) = jira::fetch_issue(&key, Some(&repo)).await {
                            found.push(issue);
                        }
                    }
                }
            }
            let mut moves = HashMap::new();
            for issue in jira::open_issues(&found) {
                let Some(client) = jira::client(issue.connection_id.as_deref()).await else { continue };
                let key = issue.key.clone();
                let transitions = rt::run(async move { client.transitions(&key).await }).await.unwrap_or_default();
                if let Some(t) = jira::done_transition(&transitions) {
                    moves.insert(issue.key, t);
                }
            }
            let Some(me) = weak.upgrade() else { return };
            if me.generation.get() != generation {
                return;
            }
            *me.issues.borrow_mut() = found;
            *me.moves.borrow_mut() = moves;
            me.render();
        });
    }

    fn render(self: &Rc<Self>) {
        clear(&self.widget);
        let pending = jira::open_issues(&self.issues.borrow());
        self.widget.set_visible(!pending.is_empty());
        if pending.is_empty() {
            return;
        }
        let working = self.working.borrow().clone();
        for issue in pending {
            let row = hbox(8);
            row.append(&colored_icon("sy-tag-symbolic", 14, "sky"));
            row.append(&label_with(&issue.key, &["sy-mono", "sy-bold", "sy-text"]));
            row.append(&ellipsized(&format!("is still {}", issue.status), &["sy-muted"]));
            row.append(&spacer());
            if let Some(t) = self.moves.borrow().get(&issue.key).cloned() {
                let text = if working.as_deref() == Some(issue.key.as_str()) { "Moving…".to_string() } else { format!("Move to {}", t.to) };
                let mv = button(&text);
                mv.add_css_class("banner-button");
                mv.add_css_class("tint-green");
                mv.set_valign(gtk::Align::Center);
                mv.set_sensitive(working.is_none());
                let (weak, issue) = (Rc::downgrade(self), issue.clone());
                mv.connect_clicked(move |_| {
                    if let Some(me) = weak.upgrade() {
                        me.move_issue(&issue, &t);
                    }
                });
                row.append(&mv);
            }
            let open = button("Open in Jira");
            open.add_css_class("banner-button");
            open.set_valign(gtk::Align::Center);
            let url = issue.url.clone();
            open.connect_clicked(move |_| util::open_url(&url));
            row.append(&open);
            self.widget.append(&row);
        }
        let footer = hbox(8);
        if let Some(e) = self.error.borrow().as_ref() {
            footer.append(&wrap_label(e, &["fg-red", "sy-small"]));
        }
        footer.append(&spacer());
        let later = link_button("Not now");
        later.add_css_class("sy-small");
        let weak = Rc::downgrade(self);
        later.connect_clicked(move |_| {
            let Some(me) = weak.upgrade() else { return };
            jira::dismiss_follow_up(&me.pr_url.borrow());
            me.generation.set(me.generation.get() + 1);
            me.issues.borrow_mut().clear();
            me.render();
        });
        footer.append(&later);
        self.widget.append(&footer);
    }

    fn move_issue(self: &Rc<Self>, issue: &JiraIssue, t: &JiraTransition) {
        if self.working.borrow().is_some() {
            return;
        }
        *self.working.borrow_mut() = Some(issue.key.clone());
        *self.error.borrow_mut() = None;
        self.render();
        let (weak, key, id, target, generation, conn) = (Rc::downgrade(self), issue.key.clone(), t.id.clone(), t.to.clone(), self.generation.get(), issue.connection_id.clone());
        rt::spawn_local(async move {
            let result = match jira::client(conn.as_deref()).await {
                Some(client) => {
                    let k = key.clone();
                    rt::run(async move {
                        client.transition(&k, &id).await?;
                        Ok::<_, ApiError>(client.issue(&k).await.ok())
                    })
                    .await
                }
                None => Err(ApiError::new("Jira isn't connected")),
            };
            let result = result.map(|fresh| {
                fresh.map(|mut fresh| {
                    fresh.connection_id = conn;
                    fresh
                })
            });
            if let Ok(Some(fresh)) = &result {
                jira::remember(fresh);
            }
            if result.is_ok() {
                crate::app::toast(&format!("{key} moved to {target}"));
            }
            let Some(me) = weak.upgrade() else { return };
            if me.generation.get() != generation {
                return;
            }
            *me.working.borrow_mut() = None;
            match result {
                Ok(Some(fresh)) => {
                    let mut issues = me.issues.borrow_mut();
                    if let Some(slot) = issues.iter_mut().find(|i| i.key == fresh.key) {
                        *slot = fresh;
                    }
                }
                Ok(None) => {}
                Err(e) => *me.error.borrow_mut() = Some(e.message),
            }
            me.render();
        });
    }
}

fn meta(issue: &JiraIssue) -> gtk::FlowBox {
    let f = gtk::FlowBox::new();
    f.add_css_class("jira-meta");
    f.set_selection_mode(gtk::SelectionMode::None);
    f.set_homogeneous(false);
    f.set_column_spacing(8);
    f.set_row_spacing(6);
    f.set_max_children_per_line(12);
    f.set_halign(gtk::Align::Start);
    match &issue.assignee {
        Some(a) => f.append(&meta_chip(&avatar(issue.assignee_avatar.as_deref(), 16, Some(a)), a, "Assignee")),
        None => f.append(&meta_chip(&icon("sy-person-symbolic", 12), "Unassigned", "Assignee")),
    }
    if let Some(p) = &issue.priority {
        f.append(&meta_chip(&colored_icon("sy-flag-symbolic", 12, priority_color(p)), p, "Priority"));
    }
    if let Some(r) = issue.reporter.as_ref().filter(|r| Some(*r) != issue.assignee.as_ref()) {
        f.append(&meta_chip(&icon("sy-comment-symbolic", 12), r, "Reporter"));
    }
    if issue.updated.is_some() {
        f.append(&meta_chip(&icon("sy-clock-symbolic", 12), &util::rel(issue.updated), "Updated"));
    }
    let mut child = f.first_child();
    while let Some(c) = child {
        c.set_focusable(false);
        child = c.next_sibling();
    }
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colors_follow_status_category_and_priority() {
        assert_eq!(status_color("done"), "green");
        assert_eq!(status_color("indeterminate"), "sky");
        assert_eq!(status_color("new"), "muted");
        assert_eq!(priority_color("Blocker"), "red");
        assert_eq!(priority_color("Major"), "coral");
        assert_eq!(priority_color("Medium"), "amber");
        assert_eq!(priority_color("Low"), "muted");
    }

    #[test]
    fn type_icons_match_issue_kind() {
        assert_eq!(type_icon(Some("Bug")).1, "red");
        assert_eq!(type_icon(Some("Epic")).1, "violet");
        assert_eq!(type_icon(Some("Story")).1, "green");
        assert_eq!(type_icon(Some("Sub-task")).0, "sy-checklist-symbolic");
        assert_eq!(type_icon(None).0, "sy-check-circle-symbolic");
    }

    #[test]
    fn long_descriptions_are_clamped() {
        assert!(!is_long_description("short"));
        assert!(is_long_description(&"x".repeat(321)));
        assert!(is_long_description("1\n2\n3\n4\n5\n6\n7"));
        assert!(!is_long_description("1\n\n2\n\n3\n\n4\n\n5\n\n6"));
    }
}
