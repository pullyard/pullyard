use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use super::model::{Change, PrModel, PrTab};
use super::stack_graph::StackCanvas;
use super::stack_notes::{self, NotesEditor};
use crate::api::models::{ItemRef, Route};
use crate::app;
use crate::claude::sessions::SessionInfo;
use crate::stack::{self, metrics, notes, StackTree};
use crate::ui::menu::{context_menu, Menu};
use crate::ui::widgets::*;
use crate::{brand, settings, util};

thread_local! {
    static ANCHORS: RefCell<HashMap<String, f64>> = RefCell::new(HashMap::new());
    static LAST: RefCell<std::rc::Weak<StackTab>> = const { RefCell::new(std::rc::Weak::new()) };
}

pub fn last() -> Option<Rc<StackTab>> {
    LAST.with(|l| l.borrow().upgrade())
}

fn graph_mode() -> bool {
    settings::read(|s| s.stack_view == "graph")
}

struct StackList {
    widget: gtk::ScrolledWindow,
    items: gtk::StringList,
    rows: RefCell<Vec<(i64, usize)>>,
    bound: RefCell<HashMap<i64, glib::WeakRef<gtk::Box>>>,
    pending: Cell<Option<f64>>,
    anchor: RefCell<String>,
}

pub struct StackTab {
    pub widget: gtk::Box,
    model: Rc<PrModel>,
    tree: RefCell<StackTree>,
    overlay: gtk::Overlay,
    body: adw::Bin,
    summary: gtk::Label,
    list_toggle: gtk::ToggleButton,
    graph_toggle: gtk::ToggleButton,
    list: RefCell<Option<Rc<StackList>>>,
    canvas: RefCell<Option<StackCanvas>>,
    zoom_label: RefCell<Option<gtk::Label>>,
    notes_for: Cell<Option<i64>>,
    editor: RefCell<Option<(Rc<NotesEditor>, gtk::Revealer)>>,
    loading: Cell<Option<i64>>,
    sessions: RefCell<HashMap<i64, SessionInfo>>,
}

fn mode_toggle(icon_name: &str, text: &str) -> gtk::ToggleButton {
    let t = gtk::ToggleButton::new();
    let content = hbox(6);
    content.append(&icon(icon_name, 14));
    content.append(&gtk::Label::new(Some(text)));
    t.set_child(Some(&content));
    t
}

pub fn status_pill(status: stack::StackStatus) -> gtk::Label {
    let l = label_with(status.title(), &["chip", status.color(), "sy-bold", "stack-pill"]);
    l.set_valign(gtk::Align::Center);
    l
}

pub fn base_pill(name: &str) -> gtk::Widget {
    let b = hbox(6);
    b.add_css_class("stack-base-pill");
    b.set_halign(gtk::Align::Fill);
    b.set_valign(gtk::Align::Fill);
    let inner = hbox(6);
    inner.set_halign(gtk::Align::Center);
    inner.set_hexpand(true);
    inner.append(&icon("sy-branch-symbolic", 13));
    let l = label_with(name, &["sy-mono", "sy-text"]);
    l.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    inner.append(&l);
    b.append(&inner);
    b.set_tooltip_text(Some(name));
    b.upcast()
}

pub fn ask_support() {
    let d = adw::AlertDialog::new(
        Some("Like the stack graph?"),
        Some(&format!("{} is free and built by one developer. If it saves you time, you can be part of it by buying a pizza that keeps it going. We only ask once.", brand::APP_NAME)),
    );
    d.add_response("ok", "OK");
    d.add_response("pizza", "Buy a Pizza 🍕");
    d.set_response_appearance("pizza", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("ok"));
    d.set_close_response("ok");
    d.connect_response(None, |_, r| {
        if r == "pizza" {
            util::open_in_default_browser(brand::DONATE_URL);
        }
    });
    d.present(app::main_window().as_ref());
}

impl StackTab {
    pub fn new(model: Rc<PrModel>, tree: StackTree) -> Rc<Self> {
        let widget = vbox(0);
        let bar = hbox(10);
        margins(&bar, 8, 12, 8, 12);
        let toggles = hbox(0);
        toggles.add_css_class("linked");
        let list_toggle = mode_toggle("view-list-symbolic", "List");
        let graph_toggle = mode_toggle("sy-branch-symbolic", "Graph");
        graph_toggle.set_group(Some(&list_toggle));
        toggles.append(&list_toggle);
        toggles.append(&graph_toggle);
        bar.append(&toggles);
        let summary = ellipsized("", &["sy-muted", "sy-small"]);
        summary.set_hexpand(true);
        bar.append(&summary);
        widget.append(&bar);
        widget.append(&line());
        let body = adw::Bin::new();
        body.set_vexpand(true);
        body.set_hexpand(true);
        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&body));
        overlay.set_vexpand(true);
        widget.append(&overlay);
        let me = Rc::new(StackTab {
            widget,
            model,
            tree: RefCell::new(tree),
            overlay,
            body,
            summary,
            list_toggle: list_toggle.clone(),
            graph_toggle: graph_toggle.clone(),
            list: RefCell::new(None),
            canvas: RefCell::new(None),
            zoom_label: RefCell::new(None),
            notes_for: Cell::new(None),
            editor: RefCell::new(None),
            loading: Cell::new(None),
            sessions: RefCell::new(HashMap::new()),
        });
        if graph_mode() {
            graph_toggle.set_active(true);
        } else {
            list_toggle.set_active(true);
        }
        let w = Rc::downgrade(&me);
        graph_toggle.connect_toggled(move |t| {
            if let Some(me) = w.upgrade() {
                me.switch_mode(t.is_active());
            }
        });
        let shortcuts = gtk::ShortcutController::new();
        let w = Rc::downgrade(&me);
        let action = gtk::CallbackAction::new(move |_, _| match w.upgrade() {
            Some(me) if me.notes_for.get().is_some() => {
                me.show_notes(None);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        });
        shortcuts.add_shortcut(gtk::Shortcut::new(gtk::ShortcutTrigger::parse_string("Escape"), Some(action)));
        me.widget.add_controller(shortcuts);
        let w = Rc::downgrade(&me);
        notes::on_change(move |key| match w.upgrade() {
            Some(me) => {
                me.notes_changed(key);
                true
            }
            None => false,
        });
        me.match_sessions();
        me.render_summary();
        me.show_body();
        LAST.with(|l| *l.borrow_mut() = Rc::downgrade(&me));
        me
    }

    pub fn set_graph(&self, graph: bool) {
        if graph {
            self.graph_toggle.set_active(true);
        } else {
            self.list_toggle.set_active(true);
        }
    }

    pub fn canvas(&self) -> Option<StackCanvas> {
        self.canvas.borrow().clone()
    }

    pub fn current(&self) -> i64 {
        self.tree.borrow().current
    }

    pub fn close(&self) {
        self.close_editor();
        self.canvas.borrow_mut().take();
        self.list.borrow_mut().take();
    }

    pub fn update(self: &Rc<Self>, tree: StackTree) {
        if *self.tree.borrow() == tree {
            return;
        }
        let current_changed = self.tree.borrow().current != tree.current;
        *self.tree.borrow_mut() = tree;
        if current_changed {
            self.loading.set(None);
        }
        if let Some(n) = self.notes_for.get() {
            if !self.tree.borrow().nodes.contains_key(&n) {
                self.show_notes(None);
            }
        }
        self.match_sessions();
        self.render_summary();
        if let Some(list) = self.list.borrow().clone() {
            self.reload_list(&list);
        }
        if let Some(c) = self.canvas.borrow().as_ref() {
            c.set_tree(&self.tree.borrow(), self.noted());
        }
    }

    fn render_summary(&self) {
        let tree = self.tree.borrow();
        self.summary.set_text(&format!("{} on {}", util::plural(tree.count() as i64, "pull request", "pull requests"), tree.base));
    }

    fn noted(&self) -> HashSet<i64> {
        let store = notes::shared();
        self.tree.borrow().nodes.keys().copied().filter(|n| store.has_notes(&self.model.stack_note_key(*n))).collect()
    }

    fn switch_mode(self: &Rc<Self>, graph: bool) {
        if graph == graph_mode() {
            return;
        }
        settings::update(|s| s.stack_view = if graph { "graph".into() } else { "list".into() });
        self.show_body();
        if graph && !settings::read(|s| s.stack_support_asked) {
            settings::update(|s| s.stack_support_asked = true);
            glib::timeout_add_local_once(Duration::from_millis(600), ask_support);
        }
    }

    fn show_body(self: &Rc<Self>) {
        let graph = graph_mode();
        if graph {
            self.list.borrow_mut().take();
            *self.zoom_label.borrow_mut() = None;
            let w = self.build_graph();
            self.body.set_child(Some(&w));
        } else {
            self.canvas.borrow_mut().take();
            *self.zoom_label.borrow_mut() = None;
            let list = self.build_list();
            self.body.set_child(Some(&list.widget));
            *self.list.borrow_mut() = Some(list);
        }
    }

    fn build_list(self: &Rc<Self>) -> Rc<StackList> {
        let items = gtk::StringList::new(&[]);
        let selection = gtk::NoSelection::new(Some(items.clone()));
        let factory = gtk::SignalListItemFactory::new();
        let view = gtk::ListView::new(Some(selection), Some(factory.clone()));
        view.add_css_class("stack-list");
        view.set_single_click_activate(true);
        let widget = scrolled(&view);
        let list = Rc::new(StackList { widget, items, rows: RefCell::new(vec![]), bound: RefCell::new(HashMap::new()), pending: Cell::new(None), anchor: RefCell::new(String::new()) });
        let w = Rc::downgrade(self);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let holder = hbox(8);
            item.set_child(Some(&holder));
            let me = w.clone();
            let h = holder.downgrade();
            context_menu(&holder, move || {
                let number = h.upgrade().and_then(|h| h.widget_name().strip_prefix("pr:").and_then(|n| n.parse::<i64>().ok()));
                match (me.upgrade(), number) {
                    (Some(me), Some(n)) => me.node_menu(n),
                    _ => Menu::ctx(),
                }
            });
        });
        let w = Rc::downgrade(self);
        let lw = Rc::downgrade(&list);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let (Some(me), Some(list)) = (w.upgrade(), lw.upgrade()) else { return };
            let Some(holder) = item.child().and_downcast::<gtk::Box>() else { return };
            let pos = item.position() as usize;
            if pos == 0 {
                holder.set_widget_name("base");
                me.render_base(&holder);
                return;
            }
            let Some((number, depth)) = list.rows.borrow().get(pos - 1).copied() else { return };
            holder.set_widget_name(&format!("pr:{number}"));
            list.bound.borrow_mut().insert(number, holder.downgrade());
            me.render_row(&holder, number, depth);
        });
        let lw = Rc::downgrade(&list);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let Some(list) = lw.upgrade() else { return };
            if let Some(holder) = item.child().and_downcast::<gtk::Box>() {
                list.bound.borrow_mut().retain(|_, h| h.upgrade().as_ref() != Some(&holder));
            }
        });
        let w = Rc::downgrade(self);
        let lw = Rc::downgrade(&list);
        view.connect_activate(move |_, pos| {
            let (Some(me), Some(list)) = (w.upgrade(), lw.upgrade()) else { return };
            if pos == 0 {
                return;
            }
            let number = list.rows.borrow().get(pos as usize - 1).map(|r| r.0);
            if let Some(n) = number {
                me.open(n, true);
            }
        });
        let adj = list.widget.vadjustment();
        let lw = Rc::downgrade(&list);
        adj.connect_value_changed(move |a| {
            let Some(list) = lw.upgrade() else { return };
            if list.pending.get().is_none() {
                let key = list.anchor.borrow().clone();
                ANCHORS.with(|m| m.borrow_mut().insert(key, a.value()));
            }
        });
        let lw = Rc::downgrade(&list);
        adj.connect_changed(move |a| {
            let Some(list) = lw.upgrade() else { return };
            if let Some(target) = list.pending.get() {
                a.set_value(target);
                if (a.value() - target).abs() < 1.0 {
                    list.pending.set(None);
                }
            }
        });
        self.reload_list(&list);
        let saved = ANCHORS.with(|m| m.borrow().get(list.anchor.borrow().as_str()).copied());
        match saved {
            Some(v) => {
                list.pending.set(Some(v));
                let lw = Rc::downgrade(&list);
                glib::timeout_add_local_once(Duration::from_millis(500), move || {
                    if let Some(list) = lw.upgrade() {
                        list.pending.set(None);
                    }
                });
            }
            None => {
                let current = self.tree.borrow().current;
                let index = list.rows.borrow().iter().position(|r| r.0 == current);
                if let Some(i) = index.filter(|i| *i > 3) {
                    let v = view.clone();
                    glib::idle_add_local_once(move || v.scroll_to(i as u32 + 1, gtk::ListScrollFlags::NONE, None));
                }
            }
        }
        list
    }

    fn reload_list(self: &Rc<Self>, list: &StackList) {
        let tree = self.tree.borrow();
        let rows = tree.rows();
        *list.anchor.borrow_mut() = tree.anchor_key();
        drop(tree);
        let same = *list.rows.borrow() == rows && list.items.n_items() as usize == rows.len() + 1;
        if same {
            self.refresh_rows();
            return;
        }
        *list.rows.borrow_mut() = rows.clone();
        let mut names: Vec<String> = vec!["base".into()];
        names.extend(rows.iter().map(|(n, _)| n.to_string()));
        let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
        list.items.splice(0, list.items.n_items(), &refs);
    }

    fn refresh_rows(self: &Rc<Self>) {
        let Some(list) = self.list.borrow().clone() else { return };
        let rows = list.rows.borrow().clone();
        let bound: Vec<(i64, gtk::Box)> = list.bound.borrow().iter().filter_map(|(n, h)| h.upgrade().map(|h| (*n, h))).collect();
        for (n, holder) in bound {
            if let Some(depth) = rows.iter().find(|r| r.0 == n).map(|r| r.1) {
                self.render_row(&holder, n, depth);
            }
        }
    }

    fn render_base(&self, holder: &gtk::Box) {
        clear(holder);
        for c in ["stack-row", "current", "opening"] {
            holder.remove_css_class(c);
        }
        holder.set_sensitive(true);
        holder.set_opacity(1.0);
        holder.add_css_class("stack-base-row");
        holder.append(&colored_icon("sy-branch-symbolic", 13, "muted"));
        holder.append(&label_with(&self.tree.borrow().base, &["sy-mono", "sy-muted"]));
    }

    fn render_row(self: &Rc<Self>, holder: &gtk::Box, number: i64, depth: usize) {
        clear(holder);
        holder.remove_css_class("stack-base-row");
        let tree = self.tree.borrow();
        let Some(node) = tree.nodes.get(&number).cloned() else { return };
        let current = number == tree.current;
        let on_path = tree.path_set().contains(&number);
        drop(tree);
        let busy = self.loading.get();
        let opening = busy == Some(number);
        holder.add_css_class("stack-row");
        for (c, on) in [("current", current), ("opening", opening)] {
            if on {
                holder.add_css_class(c);
            } else {
                holder.remove_css_class(c);
            }
        }
        let indent = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        indent.set_size_request(depth as i32 * 22, 1);
        holder.append(&indent);
        let mark = icon(if depth == 0 { "sy-dot-symbolic" } else { "pan-end-symbolic" }, 12);
        mark.add_css_class(if on_path { "fg-indigo" } else { "sy-dim" });
        holder.append(&mark);
        let badge = state_badge(node.visual_state(), true);
        badge.set_valign(gtk::Align::Center);
        holder.append(&badge);
        holder.append(&label_with(&format!("#{number}"), &["sy-muted", "sy-bold"]));
        let title = ellipsized(&node.title, &["sy-text"]);
        if current {
            title.add_css_class("sy-bold");
        }
        title.set_hexpand(true);
        holder.append(&title);
        if let Some(key) = node.jira_key().filter(|k| !node.head_ref_name.contains(k.as_str())) {
            holder.append(&label_with(&key, &["sy-mono", "sy-muted", "sy-small"]));
        }
        if self.sessions.borrow().contains_key(&number) {
            holder.append(&tooltip(colored_icon("sy-sparkles-symbolic", 12, "coral"), "Has a Claude Code session"));
        }
        holder.append(&chip(&node.head_ref_name, if current { "violet" } else { "slate" }, Some("sy-branch-symbolic"), true));
        holder.append(&self.note_button(number));
        if opening {
            holder.append(&spinner(14));
        }
        holder.append(&status_pill(node.status()));
        let dimmed = busy.is_some() && !opening;
        holder.set_sensitive(!dimmed);
        holder.set_opacity(if dimmed { 0.55 } else { 1.0 });
        holder.set_tooltip_text(Some(&format!("#{number} {}", node.title)));
    }

    fn note_button(self: &Rc<Self>, number: i64) -> gtk::Box {
        let count = notes::shared().count(&self.model.stack_note_key(number));
        let b = hbox(3);
        b.add_css_class("stack-note-btn");
        b.set_valign(gtk::Align::Center);
        if count > 0 {
            b.append(&colored_icon("document-edit-symbolic", 12, "amber"));
            b.append(&label_with(&count.to_string(), &["fg-amber", "sy-bold", "sy-small"]));
            b.set_tooltip_text(Some(&format!("{} — click to open", util::plural(count as i64, "note", "notes"))));
        } else {
            let i = icon("document-new-symbolic", 12);
            i.add_css_class("sy-dim");
            b.append(&i);
            b.set_tooltip_text(Some("Add a note"));
        }
        let w = Rc::downgrade(self);
        on_click_widget(&b, move || {
            if let Some(me) = w.upgrade() {
                me.show_notes(Some(number));
            }
        });
        b
    }

    fn node_menu(self: &Rc<Self>, number: i64) -> Menu {
        let m = Menu::ctx();
        let tree = self.tree.borrow();
        let Some(node) = tree.nodes.get(&number).cloned() else { return m };
        let current = number == tree.current;
        drop(tree);
        if current {
            m.disabled(&format!("Open #{number}"));
        } else {
            let w = Rc::downgrade(self);
            m.item(&format!("Open #{number}"), move || {
                if let Some(me) = w.upgrade() {
                    me.open(number, graph_mode());
                }
            });
        }
        let count = notes::shared().count(&self.model.stack_note_key(number));
        let w = Rc::downgrade(self);
        m.item(if count > 0 { "Notes…" } else { "Add note…" }, move || {
            if let Some(me) = w.upgrade() {
                me.show_notes(Some(number));
            }
        });
        let branch = node.head_ref_name.clone();
        m.item("Copy branch name", move || {
            util::copy(&branch);
            app::toast("Copied branch name");
        });
        m
    }

    fn build_graph(self: &Rc<Self>) -> gtk::Widget {
        let w = Rc::downgrade(self);
        let factory: super::stack_graph::CardFactory = Rc::new(move |n, compact| match w.upgrade() {
            Some(me) => me.card(n, compact),
            None => gtk::Box::new(gtk::Orientation::Horizontal, 0).upcast(),
        });
        let zoom_label = label_with("100%", &["sy-small"]);
        zoom_label.set_width_chars(5);
        zoom_label.set_xalign(0.5);
        let zl = zoom_label.downgrade();
        let on_view: Rc<dyn Fn(f64)> = Rc::new(move |z| {
            if let Some(l) = zl.upgrade() {
                l.set_text(&format!("{}%", (z * 100.0).round() as i64));
            }
        });
        let canvas = StackCanvas::new(factory, Rc::new(base_pill), on_view);
        canvas.set_tree(&self.tree.borrow(), self.noted());
        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&canvas));
        let bar = hbox(2);
        bar.add_css_class("stack-zoom-bar");
        bar.set_halign(gtk::Align::End);
        bar.set_valign(gtk::Align::End);
        pad(&bar, 12);
        let c = canvas.clone();
        let out = icon_button("zoom-out-symbolic", "Zoom out (pinch or Ctrl+scroll works too)");
        out.connect_clicked(move |_| c.zoom_by(-0.15));
        bar.append(&out);
        let actual = gtk::Button::new();
        actual.add_css_class("flat");
        actual.set_child(Some(&zoom_label));
        actual.set_tooltip_text(Some("Actual size"));
        let c = canvas.clone();
        actual.connect_clicked(move |_| c.actual_size());
        bar.append(&actual);
        let c = canvas.clone();
        let zin = icon_button("zoom-in-symbolic", "Zoom in");
        zin.connect_clicked(move |_| c.zoom_by(0.15));
        bar.append(&zin);
        let c = canvas.clone();
        let fit = icon_button("zoom-fit-best-symbolic", "Fit to window");
        fit.connect_clicked(move |_| c.fit());
        bar.append(&fit);
        let c = canvas.clone();
        let here = icon_button("find-location-symbolic", "Show this pull request");
        here.connect_clicked(move |_| c.focus_current());
        bar.append(&here);
        overlay.add_overlay(&bar);
        *self.zoom_label.borrow_mut() = Some(zoom_label);
        *self.canvas.borrow_mut() = Some(canvas);
        overlay.upcast()
    }

    fn card(self: &Rc<Self>, number: i64, compact: bool) -> gtk::Widget {
        let tree = self.tree.borrow();
        let Some(node) = tree.nodes.get(&number).cloned() else { return gtk::Box::new(gtk::Orientation::Horizontal, 0).upcast() };
        let current = number == tree.current;
        let on_path = tree.path_set().contains(&number);
        drop(tree);
        let opening = self.loading.get() == Some(number);
        let key = self.model.stack_note_key(number);
        let store = notes::shared();
        let status = node.status();
        let w = Rc::downgrade(self);
        let open = move || {
            if let Some(me) = w.upgrade() {
                me.open(number, false);
            }
        };
        if compact {
            let b = hbox(0);
            b.add_css_class("stack-card");
            b.add_css_class("compact");
            if current {
                b.add_css_class("current");
            }
            b.set_overflow(gtk::Overflow::Hidden);
            let strip = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            strip.add_css_class("stack-status-bar");
            strip.add_css_class(&format!("edge-{}", status.color()));
            strip.set_size_request(14, -1);
            b.append(&strip);
            let col = vbox(6);
            col.set_valign(gtk::Align::Center);
            margins(&col, 0, 20, 0, 20);
            let top = hbox(10);
            top.append(&label_with(&format!("#{number}"), &["stack-compact-num", "sy-text"]));
            if store.has_notes(&key) {
                top.append(&colored_icon("document-edit-symbolic", 30, "amber"));
            }
            col.append(&top);
            col.append(&label_with(status.title(), &["stack-compact-status", &format!("fg-{}", status.color())]));
            b.append(&col);
            if !on_path {
                b.set_opacity(0.6);
            }
            on_click_widget(&b, open);
            return b.upcast();
        }
        let outer = vbox(metrics::NOTE_GAP as i32);
        let card = vbox(3);
        card.add_css_class("stack-card");
        if current || opening {
            card.add_css_class("current");
        }
        card.set_size_request(-1, metrics::CARD_HEIGHT as i32);
        card.set_overflow(gtk::Overflow::Hidden);
        let head = hbox(6);
        head.append(&label_with(&format!("#{number}"), &["sy-bold", "sy-text"]));
        if let Some(k) = node.jira_key() {
            head.append(&label_with(&k, &["sy-mono", "sy-muted", "sy-small"]));
        }
        head.append(&spacer());
        head.append(&self.note_button(number));
        if opening {
            head.append(&spinner(14));
        }
        head.append(&status_pill(status));
        card.append(&head);
        card.append(&ellipsized(&node.title, &["sy-bold", "sy-text"]));
        let field = |name: &str, value: &str| {
            let row = hbox(6);
            let l = label_with(name, &["sy-dim", "sy-small"]);
            l.set_size_request(48, -1);
            row.append(&l);
            let v = label_with(value, &["sy-mono", "sy-small", "sy-text"]);
            v.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            v.set_hexpand(true);
            row.append(&v);
            row
        };
        card.append(&field("branch", &node.head_ref_name));
        card.append(&field("base", &node.base_ref_name));
        if let Some(s) = self.sessions.borrow().get(&number).cloned() {
            let row = hbox(6);
            let l = label_with("session", &["sy-dim", "sy-small"]);
            l.set_size_request(48, -1);
            row.append(&l);
            let link = ellipsized(&s.title, &["fg-accent", "sy-small"]);
            link.set_hexpand(true);
            link.set_tooltip_text(Some("Resume Claude Code session"));
            on_click_widget(&link, move || resume(&s));
            row.append(&link);
            card.append(&row);
        }
        if let Some(oid) = &node.commit_oid {
            let c = ellipsized(&format!("› {oid} {}", node.commit_headline.clone().unwrap_or_default()), &["stack-commit"]);
            card.append(&c);
        }
        if !(on_path || opening) {
            card.set_opacity(0.6);
        }
        let who = node.author.as_ref().map(|a| format!("@{a}")).unwrap_or_default();
        card.set_tooltip_text(Some(&format!("#{number} {} · {who} — {}", node.title, if current { "click to center" } else { "click to open" })));
        on_click_widget(&card, open);
        let w = Rc::downgrade(self);
        context_menu(&card, move || match w.upgrade() {
            Some(me) => me.node_menu(number),
            None => Menu::ctx(),
        });
        outer.append(&card);
        if store.has_notes(&key) {
            let s = stack_notes::sticky(&store.notes(&key), on_path);
            let w = Rc::downgrade(self);
            on_click_widget(&s, move || {
                if let Some(me) = w.upgrade() {
                    me.show_notes(Some(number));
                }
            });
            outer.append(&s);
        }
        outer.upcast()
    }

    fn notes_changed(self: &Rc<Self>, key: &str) {
        let number = self.tree.borrow().nodes.keys().copied().find(|n| self.model.stack_note_key(*n) == key);
        if number.is_none() {
            return;
        }
        self.refresh_rows();
        let canvas = self.canvas.borrow().clone();
        if let Some(c) = canvas {
            c.set_tree(&self.tree.borrow(), self.noted());
        }
    }

    pub fn show_notes(self: &Rc<Self>, number: Option<i64>) {
        if self.notes_for.get() == number {
            if let Some((e, _)) = self.editor.borrow().as_ref() {
                e.focus();
            }
            return;
        }
        self.close_editor();
        self.notes_for.set(number);
        let Some(n) = number else { return };
        let title = self.tree.borrow().nodes.get(&n).map(|x| x.title.clone()).unwrap_or_default();
        let w = Rc::downgrade(self);
        let editor = NotesEditor::new(
            self.model.stack_note_key(n),
            n,
            &title,
            Rc::new(move || {
                if let Some(me) = w.upgrade() {
                    me.show_notes(None);
                }
            }),
        );
        let revealer = gtk::Revealer::new();
        revealer.set_transition_type(gtk::RevealerTransitionType::Crossfade);
        revealer.set_transition_duration(150);
        revealer.set_halign(gtk::Align::End);
        revealer.set_valign(gtk::Align::Start);
        revealer.set_child(Some(&editor.widget));
        self.overlay.add_overlay(&revealer);
        revealer.set_reveal_child(true);
        editor.focus();
        *self.editor.borrow_mut() = Some((editor, revealer));
    }

    fn close_editor(&self) {
        self.notes_for.set(None);
        let Some((editor, revealer)) = self.editor.borrow_mut().take() else { return };
        editor.commit();
        notes::flush();
        let overlay = self.overlay.clone();
        revealer.connect_child_revealed_notify(move |r| {
            if !r.is_child_revealed() && r.parent().is_some() {
                overlay.remove_overlay(r);
            }
        });
        revealer.set_reveal_child(false);
        if !adw::is_animations_enabled(&revealer) && revealer.parent().is_some() {
            self.overlay.remove_overlay(&revealer);
        }
    }

    fn match_sessions(&self) {
        let mut out: HashMap<i64, SessionInfo> = HashMap::new();
        if let Some(a) = app::try_get() {
            let projects = a.claude.projects.borrow();
            let repo = self.model.r.repo.full().to_lowercase();
            let mut by_pr: HashMap<i64, &SessionInfo> = HashMap::new();
            let mut by_branch: HashMap<&str, &SessionInfo> = HashMap::new();
            for s in projects.iter().flat_map(|p| p.sessions.iter()) {
                let same_repo = s.pr_url.as_deref().is_none_or(|u| u.to_lowercase().contains(&format!("/{repo}/")));
                if let Some(n) = s.pr_number.filter(|_| same_repo) {
                    by_pr.entry(n).or_insert(s);
                }
                if let Some(b) = s.branch.as_deref() {
                    by_branch.entry(b).or_insert(s);
                }
            }
            for node in self.tree.borrow().nodes.values() {
                if let Some(s) = by_pr.get(&node.number).or_else(|| by_branch.get(node.head_ref_name.as_str())) {
                    out.insert(node.number, (*s).clone());
                }
            }
        }
        *self.sessions.borrow_mut() = out;
    }

    fn set_loading(self: &Rc<Self>, n: Option<i64>) {
        let before = self.loading.replace(n);
        if before == n {
            return;
        }
        self.refresh_rows();
        if let Some(c) = self.canvas.borrow().as_ref() {
            for x in [before, n].into_iter().flatten() {
                c.refresh_card(x);
            }
        }
    }

    pub fn open(self: &Rc<Self>, number: i64, in_place: bool) {
        if self.loading.get().is_some() {
            return;
        }
        let (current, node) = {
            let tree = self.tree.borrow();
            (tree.current, tree.nodes.get(&number).cloned())
        };
        if number == current {
            if !in_place {
                if let Some(c) = self.canvas.borrow().as_ref() {
                    c.focus_current();
                }
            }
            return;
        }
        let r = ItemRef { repo: self.model.r.repo.clone(), number };
        let Some(next) = app::pr_model(&r) else {
            switch_to(r);
            return;
        };
        if let Some(node) = node {
            let nodes = stack::store::memory_nodes(&self.model.api, &self.model.r.repo).unwrap_or_else(|| self.tree.borrow().nodes.values().cloned().collect());
            next.seed_stack(&node, &nodes);
        } else {
            next.tab.set(PrTab::Stack);
        }
        if !in_place || next.pr.borrow().is_some() {
            switch_to(r);
            return;
        }
        let here = Route::Pr(self.model.r.clone());
        self.set_loading(Some(number));
        let w = Rc::downgrade(self);
        let nw = Rc::downgrade(&next);
        let finished = Rc::new(Cell::new(false));
        let f = finished.clone();
        next.changed.connect(move |c| {
            if f.get() {
                return false;
            }
            let Some(next) = nw.upgrade() else { return false };
            if !matches!(c, Change::Pr) || (next.pr.borrow().is_none() && next.error.borrow().is_none() && !next.not_pr.get()) {
                return true;
            }
            f.set(true);
            let target = next.r.clone();
            if let Some(me) = w.upgrade() {
                me.set_loading(None);
            }
            if app::visible_route().as_ref() == Some(&here) {
                switch_to(target);
            }
            false
        });
        next.open();
        let w = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(30), move || {
            if !finished.get() {
                finished.set(true);
                if let Some(me) = w.upgrade() {
                    me.set_loading(None);
                }
            }
        });
    }
}

fn switch_to(r: ItemRef) {
    app::open(Route::Pr(r), false);
}

fn resume(s: &SessionInfo) {
    let Some(a) = app::try_get() else { return };
    app::set_section(app::Section::Claude);
    a.claude.resume(s, false, None);
}
