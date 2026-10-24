use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use adw::prelude::*;

use super::pr::model::PrModel;
use super::widgets::*;
use crate::jira::{self, JiraIssue, JiraTransition};
use crate::{rt, util};

fn card() -> gtk::Box {
    let c = vbox(10);
    c.add_css_class("sy-card");
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
    issues: RefCell<HashMap<String, JiraIssue>>,
    errors: RefCell<HashMap<String, String>>,
    signature: RefCell<String>,
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
        let content = vbox(14);
        pad(&content, 20);
        let clamp = adw::Clamp::new();
        clamp.set_maximum_size(820);
        clamp.set_child(Some(&content));
        let widget = scrolled(&clamp);
        let me = Rc::new(JiraTab { widget, model, content, issues: RefCell::new(HashMap::new()), errors: RefCell::new(HashMap::new()), signature: RefCell::new(String::new()) });
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
        self.render();
        self.load(keys);
    }

    fn refresh(self: &Rc<Self>) {
        self.signature.borrow_mut().clear();
        self.update();
    }

    fn load(self: &Rc<Self>, keys: Vec<String>) {
        if !jira::is_configured() {
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
        self.render();
        if missing.is_empty() {
            return;
        }
        let weak = Rc::downgrade(self);
        rt::spawn_local(async move {
            let Some(client) = jira::client().await else { return };
            for key in missing {
                let c = client.clone();
                let k = key.clone();
                let weak = weak.clone();
                rt::spawn_local(async move {
                    let result = rt::run(async move { c.issue(&k).await }).await;
                    let Some(me) = weak.upgrade() else { return };
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
            let c = card();
            c.append(&connect_form());
            self.content.append(&c);
            return;
        }
        let keys = keys(&self.model);
        let url = self.pr_url();
        let linked = jira::linked(&url);
        if keys.is_empty() {
            let c = card();
            let head = hbox(8);
            head.append(&colored_icon("sy-tag-symbolic", 16, "muted"));
            head.append(&label_with("No Jira ticket found", &["sy-heading", "sy-text"]));
            c.append(&head);
            c.append(&wrap_label("PullYard looks for keys like ABC-123 in the title, branch and description. Link one by hand:", &["sy-muted"]));
            c.append(&self.link_field());
            self.content.append(&c);
            return;
        }
        for key in &keys {
            let manual = linked.contains(key);
            let issue = self.issues.borrow().get(key).cloned();
            let error = self.errors.borrow().get(key).cloned();
            if let Some(issue) = issue {
                self.content.append(&self.issue_card(issue, manual));
            } else if let Some(e) = error {
                let c = card();
                let row = hbox(8);
                row.append(&colored_icon("sy-attention-symbolic", 14, "amber"));
                let l = wrap_label(&format!("{key}: {e}"), &["fg-amber"]);
                l.set_selectable(true);
                l.set_hexpand(true);
                row.append(&l);
                if manual {
                    row.append(&self.unlink_button(key));
                }
                c.append(&row);
                self.content.append(&c);
            } else {
                let c = card();
                let row = hbox(10);
                row.append(&spinner(12));
                row.append(&label_with(key, &["sy-muted"]));
                c.append(&row);
                self.content.append(&c);
            }
        }
        self.content.append(&self.link_field());
    }

    fn unlink_button(self: &Rc<Self>, key: &str) -> gtk::Button {
        let b = button("Unlink");
        b.set_valign(gtk::Align::Center);
        let w = Rc::downgrade(self);
        let key = key.to_string();
        b.connect_clicked(move |_| {
            let Some(me) = w.upgrade() else { return };
            jira::unlink(&me.pr_url(), &key);
            me.issues.borrow_mut().remove(&key);
            me.errors.borrow_mut().remove(&key);
            me.refresh();
            me.model.emit(super::pr::model::Change::Pr);
        });
        b
    }

    fn link_field(self: &Rc<Self>) -> gtk::Box {
        let row = hbox(8);
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("ABC-123"));
        entry.set_width_chars(12);
        let go = button("Link ticket");
        go.set_sensitive(false);
        let g = go.clone();
        entry.connect_changed(move |e| g.set_sensitive(e.text().trim().chars().count() >= 3));
        let w = Rc::downgrade(self);
        let e = entry.clone();
        let submit = Rc::new(move || {
            let Some(me) = w.upgrade() else { return };
            let url = me.pr_url();
            if url.is_empty() || jira::link(&url, &e.text()).is_none() {
                return;
            }
            e.set_text("");
            me.refresh();
            me.model.emit(super::pr::model::Change::Pr);
        });
        let s = submit.clone();
        go.connect_clicked(move |_| s());
        let s = submit.clone();
        entry.connect_activate(move |_| s());
        row.append(&entry);
        row.append(&go);
        row
    }

    fn issue_card(self: &Rc<Self>, issue: JiraIssue, manual: bool) -> gtk::Box {
        let c = card();
        c.set_spacing(12);
        let head = hbox(8);
        let (icon_name, color) = type_icon(issue.kind.as_deref());
        head.append(&colored_icon(icon_name, 16, color));
        let key = link_button(&issue.key);
        key.add_css_class("sy-mono");
        let url = issue.url.clone();
        key.connect_clicked(move |_| util::open_url(&url));
        head.append(&key);
        if let Some(t) = &issue.kind {
            head.append(&label_with(t, &["sy-muted", "sy-small"]));
        }
        head.append(&spacer());
        let error = wrap_label("", &["fg-red", "sy-small"]);
        error.set_visible(false);
        head.append(&self.status_menu(&issue, &error));
        c.append(&head);
        let summary = wrap_label(&issue.summary, &["sy-heading", "sy-text", "title-4"]);
        summary.set_selectable(true);
        c.append(&summary);
        let meta = hbox(16);
        meta.add_css_class("sy-muted");
        meta.add_css_class("sy-small");
        match &issue.assignee {
            Some(a) => {
                let b = hbox(6);
                b.append(&avatar(issue.assignee_avatar.as_deref(), 18, Some(a)));
                b.append(&label(a));
                meta.append(&b);
            }
            None => meta.append(&icon_label_content("sy-person-symbolic", "Unassigned")),
        }
        if let Some(p) = &issue.priority {
            meta.append(&icon_label_content("sy-attention-symbolic", p));
        }
        if let Some(r) = &issue.reporter {
            meta.append(&icon_label_content("sy-comment-symbolic", &format!("Reported by {r}")));
        }
        if issue.updated.is_some() {
            meta.append(&label(&format!("Updated {}", util::rel(issue.updated))));
        }
        c.append(&meta);
        if !issue.description.is_empty() {
            let d = wrap_label(&issue.description, &["sy-text"]);
            d.set_selectable(true);
            d.set_opacity(0.9);
            c.append(&d);
            if issue.description.chars().count() > 500 {
                d.set_lines(8);
                d.set_ellipsize(gtk::pango::EllipsizeMode::End);
                let more = link_button("Show more");
                more.set_halign(gtk::Align::Start);
                let d2 = d.clone();
                more.connect_clicked(move |b| {
                    let expanded = d2.lines() < 0;
                    d2.set_lines(if expanded { 8 } else { -1 });
                    d2.set_ellipsize(if expanded { gtk::pango::EllipsizeMode::End } else { gtk::pango::EllipsizeMode::None });
                    b.set_label(if expanded { "Show more" } else { "Show less" });
                });
                c.append(&more);
            }
        }
        c.append(&error);
        let actions = hbox(8);
        let open = button("Open in Jira");
        let url = issue.url.clone();
        open.connect_clicked(move |_| util::open_url(&url));
        actions.append(&open);
        if manual {
            actions.append(&self.unlink_button(&issue.key));
        }
        c.append(&actions);
        c
    }

    fn status_menu(self: &Rc<Self>, issue: &JiraIssue, error: &gtk::Label) -> gtk::MenuButton {
        let mb = gtk::MenuButton::new();
        mb.add_css_class("flat");
        mb.set_valign(gtk::Align::Center);
        mb.set_tooltip_text(Some("Change status"));
        mb.set_always_show_arrow(false);
        let pill = hbox(5);
        pill.add_css_class("chip");
        pill.add_css_class(status_color(&issue.status_category));
        let moving = spinner(10);
        moving.set_visible(false);
        pill.append(&moving);
        pill.append(&label_with(&issue.status.to_uppercase(), &["sy-bold"]));
        pill.append(&icon("pan-down-symbolic", 10));
        mb.set_child(Some(&pill));
        let popover = gtk::Popover::new();
        let list = vbox(2);
        pad(&list, 4);
        popover.set_child(Some(&list));
        mb.set_popover(Some(&popover));
        let loaded: Rc<Cell<bool>> = Rc::new(Cell::new(false));
        let key = issue.key.clone();
        let weak: Weak<JiraTab> = Rc::downgrade(self);
        let error = error.clone();
        let mb_weak = mb.downgrade();
        popover.connect_show(move |p| {
            if loaded.get() {
                return;
            }
            loaded.set(true);
            let list = list.clone();
            clear(&list);
            list.append(&label_with("Loading…", &["sy-muted", "sy-small"]));
            let (key, weak, error, popover, moving, mb_weak, loaded) = (key.clone(), weak.clone(), error.clone(), p.clone(), moving.clone(), mb_weak.clone(), loaded.clone());
            rt::spawn_local(async move {
                let Some(client) = jira::client().await else { return };
                let k = key.clone();
                let c = client.clone();
                let result = rt::run(async move { c.transitions(&k).await }).await;
                clear(&list);
                let transitions: Vec<JiraTransition> = match result {
                    Ok(t) => t,
                    Err(e) => {
                        loaded.set(false);
                        list.append(&wrap_label(&e.message, &["fg-red", "sy-small"]));
                        return;
                    }
                };
                if transitions.is_empty() {
                    list.append(&label_with("No transitions available", &["sy-muted", "sy-small"]));
                }
                for t in transitions {
                    let b = gtk::Button::with_label(&t.title());
                    b.add_css_class("flat");
                    if let Some(l) = b.child().and_downcast::<gtk::Label>() {
                        l.set_xalign(0.0);
                    }
                    let (key, weak, error, popover, moving, mb_weak, client) = (key.clone(), weak.clone(), error.clone(), popover.clone(), moving.clone(), mb_weak.clone(), client.clone());
                    b.connect_clicked(move |_| {
                        popover.popdown();
                        moving.set_visible(true);
                        error.set_visible(false);
                        if let Some(mb) = mb_weak.upgrade() {
                            mb.set_sensitive(false);
                        }
                        let (key, id, weak, error, moving, mb_weak, client) = (key.clone(), t.id.clone(), weak.clone(), error.clone(), moving.clone(), mb_weak.clone(), client.clone());
                        rt::spawn_local(async move {
                            let k = key.clone();
                            let result = rt::run(async move {
                                client.transition(&k, &id).await?;
                                client.issue(&k).await
                            })
                            .await;
                            moving.set_visible(false);
                            if let Some(mb) = mb_weak.upgrade() {
                                mb.set_sensitive(true);
                            }
                            match result {
                                Ok(issue) => {
                                    jira::remember(&issue);
                                    if let Some(me) = weak.upgrade() {
                                        me.issues.borrow_mut().insert(key, issue);
                                        me.render();
                                    }
                                }
                                Err(e) => {
                                    error.set_text(&e.message);
                                    error.set_visible(true);
                                }
                            }
                        });
                    });
                    list.append(&b);
                }
            });
        });
        mb
    }
}
