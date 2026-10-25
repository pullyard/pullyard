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
use crate::jira::{self, JiraIssue};
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

pub fn connect_form() -> gtk::Box {
    let root = vbox(10);
    let weak = root.downgrade();
    let fill = Rc::new(move || {
        if let Some(root) = weak.upgrade() {
            clear(&root);
            build_form(&root);
        }
    });
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

fn build_form(root: &gtk::Box) {
    if jira::is_configured() {
        let row = hbox(10);
        row.append(&colored_icon("sy-check-circle-symbolic", 18, "green"));
        let texts = vbox(1);
        texts.set_hexpand(true);
        texts.append(&ellipsized(&jira::display_name().unwrap_or_else(|| "Connected".into()), &["sy-text"]));
        texts.append(&ellipsized(&jira::host(), &["sy-muted", "sy-small"]));
        row.append(&texts);
        let out = button("Disconnect");
        out.set_valign(gtk::Align::Center);
        out.connect_clicked(|_| jira::disconnect());
        row.append(&out);
        root.append(&row);
        return;
    }
    root.append(&wrap_label("Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in the system keyring.", &["sy-muted"]));
    let site = gtk::Entry::new();
    site.set_placeholder_text(Some("Jira address — acme.atlassian.net"));
    site.set_text(&jira::site());
    site.set_input_purpose(gtk::InputPurpose::Url);
    root.append(&site);
    let email = gtk::Entry::new();
    email.set_placeholder_text(Some("Atlassian account email (empty for a Data Center token)"));
    email.set_text(&jira::email());
    email.set_input_purpose(gtk::InputPurpose::Email);
    root.append(&email);
    let row = hbox(8);
    let token = gtk::PasswordEntry::new();
    token.set_show_peek_icon(true);
    token.set_hexpand(true);
    token.set_property("placeholder-text", "API token");
    let (connect, connect_stack) = busy_button("Connect");
    row.append(&token);
    row.append(&connect);
    root.append(&row);
    let create = link_button("Create an API token at id.atlassian.com");
    create.set_halign(gtk::Align::Start);
    create.connect_clicked(|_| util::open_url(jira::TOKEN_URL));
    root.append(&create);
    let error = wrap_label("", &["fg-red", "sy-small"]);
    error.set_selectable(true);
    error.set_visible(false);
    root.append(&error);
    let sync = {
        let (site, token, connect) = (site.clone(), token.clone(), connect.clone());
        move || connect.set_sensitive(!site.text().trim().is_empty() && !token.text().trim().is_empty())
    };
    sync();
    let s = sync.clone();
    site.connect_changed(move |_| s());
    let s = sync.clone();
    token.connect_changed(move |_| s());
    let busy = Rc::new(Cell::new(false));
    let token_entry = token.clone();
    let submit = Rc::new(move || {
        if busy.get() || site.text().trim().is_empty() || token.text().trim().is_empty() {
            return;
        }
        busy.set(true);
        connect_stack.set_visible_child_name("busy");
        error.set_visible(false);
        let (site_v, email_v, token_v) = (site.text().to_string(), email.text().to_string(), token.text().to_string());
        let (busy, stack, error, token) = (busy.clone(), connect_stack.clone(), error.clone(), token.clone());
        rt::spawn_local(async move {
            let result = jira::connect(site_v, email_v, token_v).await;
            busy.set(false);
            stack.set_visible_child_name("label");
            match result {
                Ok(()) => token.set_text(""),
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
            match jira::cached(&key) {
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
        rt::spawn_local(async move {
            let Some(client) = jira::client().await else {
                if let Some(me) = weak.upgrade() {
                    me.pending.set(0);
                    me.render();
                }
                return;
            };
            for key in missing {
                let c = client.clone();
                let k = key.clone();
                let weak = weak.clone();
                rt::spawn_local(async move {
                    let result = rt::run(async move { c.issue(&k).await }).await;
                    let Some(me) = weak.upgrade() else { return };
                    me.pending.set(me.pending.get().saturating_sub(1));
                    match result {
                        Ok(issue) => {
                            jira::remember(&issue);
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
        let host = jira::host();
        if !host.is_empty() {
            texts.append(&ellipsized(&host, &["sy-muted", "sy-small"]));
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
            let key = parent.clone();
            b.connect_clicked(move |_| {
                if let Some(url) = jira::browse_url(&key) {
                    util::open_url(&url);
                }
            });
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
        head.append(&spacer());
        head.append(&self.status_menu(&issue, show_error));
        if collapsible {
            let collapse = icon_button("pan-up-symbolic", "Collapse");
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
        mb.set_always_show_arrow(false);
        let pill = Rc::new(status_pill(&issue.status, &issue.status_category, true));
        mb.set_child(Some(&pill.widget));
        let placeholder = Menu::new();
        placeholder.disabled("Loading…");
        let popover = gtk::PopoverMenu::from_model(Some(&placeholder.model));
        placeholder.attach(&mb);
        mb.set_popover(Some(&popover));
        let mover: Rc<dyn Fn(String)> = {
            let (key, weak, mb_weak) = (issue.key.clone(), Rc::downgrade(self), mb.downgrade());
            Rc::new(move |id: String| {
                let Some(mb) = mb_weak.upgrade() else { return };
                mb.set_sensitive(false);
                pill.dot.set_visible(false);
                pill.busy.set_visible(true);
                show_error(None);
                let (key, weak, mb_weak, pill, show_error) = (key.clone(), weak.clone(), mb_weak.clone(), pill.clone(), show_error.clone());
                rt::spawn_local(async move {
                    let result = match jira::client().await {
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
                        Ok(issue) => {
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
        let (key, mb_weak) = (issue.key.clone(), mb.downgrade());
        popover.connect_show(move |p| {
            if state.replace(true) {
                return;
            }
            let (key, mb_weak, popover, mover, state) = (key.clone(), mb_weak.clone(), p.clone(), mover.clone(), state.clone());
            rt::spawn_local(async move {
                let transitions = match jira::client().await {
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
