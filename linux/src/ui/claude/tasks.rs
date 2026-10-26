use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use crate::claude::chat::{ChatItem, ChatSession, TaskState, ToolCall};
use crate::ui::menu::{context_menu, Menu};
use crate::ui::widgets::*;
use crate::util;

pub struct TasksPanel {
    pub widget: gtk::Stack,
    chat: Rc<ChatSession>,
    list: gtk::Box,
    expanded: RefCell<HashSet<String>>,
    show_finished: Cell<bool>,
    pending: Cell<bool>,
    on_running: RefCell<Option<Box<dyn Fn(usize)>>>,
}

impl TasksPanel {
    pub fn new(chat: Rc<ChatSession>) -> Rc<Self> {
        let widget = gtk::Stack::new();
        widget.set_vexpand(true);
        widget.add_named(&empty_state("sy-terminal-symbolic", "dim", "No tasks yet", Some("Commands and agents Claude runs will show up here")), Some("empty"));
        let list = vbox(2);
        margins(&list, 8, 8, 8, 8);
        widget.add_named(&scrolled(&list), Some("list"));
        let me = Rc::new(TasksPanel {
            widget,
            chat: chat.clone(),
            list,
            expanded: RefCell::new(HashSet::new()),
            show_finished: Cell::new(true),
            pending: Cell::new(false),
            on_running: RefCell::new(None),
        });
        let w = Rc::downgrade(&me);
        chat.changed.connect(move |_| match w.upgrade() {
            Some(me) => {
                me.schedule();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        glib::timeout_add_seconds_local(1, move || match w.upgrade() {
            Some(me) => {
                if me.widget.is_mapped() && me.calls().iter().any(|c| c.task_state() == TaskState::Running) {
                    me.render();
                }
                glib::ControlFlow::Continue
            }
            None => glib::ControlFlow::Break,
        });
        me.render();
        me
    }

    pub fn on_running(&self, f: impl Fn(usize) + 'static) {
        *self.on_running.borrow_mut() = Some(Box::new(f));
        self.report();
    }

    fn calls(&self) -> Vec<Rc<ToolCall>> {
        self.chat
            .items
            .borrow()
            .iter()
            .rev()
            .filter_map(|i| match i {
                ChatItem::Tool(c) if c.is_task() => Some(c.clone()),
                _ => None,
            })
            .collect()
    }

    fn report(&self) {
        let running = self.calls().iter().filter(|c| c.task_state() == TaskState::Running).count();
        if let Some(f) = self.on_running.borrow().as_ref() {
            f(running);
        }
    }

    fn schedule(self: &Rc<Self>) {
        if self.pending.replace(true) {
            return;
        }
        let w = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(250), move || {
            if let Some(me) = w.upgrade() {
                me.pending.set(false);
                me.render();
            }
        });
    }

    fn render(self: &Rc<Self>) {
        self.report();
        let calls = self.calls();
        clear(&self.list);
        if calls.is_empty() {
            self.widget.set_visible_child_name("empty");
            return;
        }
        self.widget.set_visible_child_name("list");
        let (running, finished): (Vec<_>, Vec<_>) = calls.into_iter().partition(|c| c.task_state() == TaskState::Running);
        if !running.is_empty() {
            self.list.append(&self.header(&format!("Running {}", running.len()), false));
            for c in &running {
                self.list.append(&self.row(c));
            }
        }
        if !finished.is_empty() {
            self.list.append(&self.header(&format!("Finished {}", finished.len()), true));
            if self.show_finished.get() {
                for c in &finished {
                    self.list.append(&self.row(c));
                }
            }
        }
    }

    fn header(self: &Rc<Self>, title: &str, collapsible: bool) -> gtk::Box {
        let b = hbox(4);
        margins(&b, 8, 6, 4, 6);
        b.append(&label_with(title, &["sy-muted", "sy-small", "sy-bold"]));
        if collapsible {
            b.append(&colored_icon(if self.show_finished.get() { "sy-down-symbolic" } else { "go-next-symbolic" }, 10, "dim"));
            let w = Rc::downgrade(self);
            on_click_widget(&b, move || {
                if let Some(me) = w.upgrade() {
                    me.show_finished.set(!me.show_finished.get());
                    me.render();
                }
            });
        }
        b
    }

    fn row(self: &Rc<Self>, call: &Rc<ToolCall>) -> gtk::Box {
        let open = self.expanded.borrow().contains(&call.id);
        let state = call.task_state();
        let outer = vbox(6);
        if open {
            outer.add_css_class("sy-sunken");
        }
        let line = hbox(8);
        margins(&line, 6, 6, 6, 6);
        line.append(&colored_icon(if call.name == "Bash" { "sy-terminal-symbolic" } else { "sy-person-symbolic" }, 12, "dim"));
        let titles = vbox(2);
        titles.set_hexpand(true);
        let title = ellipsized(&title(call), &["sy-text"]);
        title.set_xalign(0.0);
        titles.append(&title);
        if let Some(sub) = subtitle(call) {
            let l = ellipsized(&sub, &["sy-muted", "sy-small"]);
            l.set_xalign(0.0);
            titles.append(&l);
        }
        line.append(&titles);
        match state {
            TaskState::Running => {
                if let Some(start) = call.started_at.get() {
                    line.append(&label_with(&duration(start.elapsed()), &["sy-muted", "sy-small"]));
                }
                line.append(&spinner(12));
            }
            TaskState::Failed => line.append(&label_with("Failed", &["fg-red", "sy-small", "sy-bold"])),
            TaskState::Stopped => line.append(&label_with("Stopped", &["sy-muted", "sy-small"])),
            TaskState::Done => {
                if let (Some(a), Some(b)) = (call.started_at.get(), call.finished_at.get()) {
                    line.append(&label_with(&duration(b.saturating_duration_since(a)), &["sy-muted", "sy-small"]));
                }
            }
        }
        line.append(&colored_icon(if open { "sy-down-symbolic" } else { "go-next-symbolic" }, 10, "dim"));
        let w = Rc::downgrade(self);
        let id = call.id.clone();
        on_click_widget(&line, move || {
            if let Some(me) = w.upgrade() {
                {
                    let mut set = me.expanded.borrow_mut();
                    if !set.remove(&id) {
                        set.insert(id.clone());
                    }
                }
                me.render();
            }
        });
        let command = call.string("command").unwrap_or_default();
        let out = output(call);
        let (c2, o2) = (command.clone(), out.clone());
        context_menu(&line, move || {
            let m = Menu::ctx();
            if !c2.is_empty() {
                let c = c2.clone();
                m.item("Copy Command", move || util::copy(&c));
            }
            if let Some(o) = o2.clone() {
                m.item("Copy Output", move || util::copy(&o));
            }
            m
        });
        outer.append(&line);
        if open {
            let details = vbox(6);
            margins(&details, 0, 6, 8, 6);
            if !command.is_empty() {
                let l = selectable(wrap_label(&format!("$ {command}"), &["sy-mono", "sy-small", "sy-text"]));
                l.set_xalign(0.0);
                let b = vbox(0);
                b.add_css_class("sy-raised");
                pad(&b, 8);
                b.append(&l);
                details.append(&b);
            }
            if let Some(out) = out.filter(|o| !o.is_empty()) {
                let tail: String = if out.chars().count() > 8000 { out.chars().skip(out.chars().count() - 8000).collect() } else { out };
                let l = selectable(wrap_label(&tail, &["sy-mono", "sy-small", if state == TaskState::Failed { "fg-red" } else { "sy-muted" }]));
                l.set_xalign(0.0);
                l.set_valign(gtk::Align::Start);
                pad(&l, 8);
                let s = scrolled(&l);
                s.set_vexpand(false);
                s.set_propagate_natural_height(true);
                s.set_max_content_height(180);
                details.append(&s);
            }
            outer.append(&details);
        }
        outer
    }
}

fn title(call: &ToolCall) -> String {
    if let Some(d) = call.string("description").filter(|d| !d.is_empty()) {
        return d;
    }
    if let Some(c) = call.string("command").filter(|c| !c.is_empty()) {
        return c.lines().next().unwrap_or_default().to_string();
    }
    if let Some(p) = call.string("prompt").filter(|p| !p.is_empty()) {
        return p.chars().take(80).collect();
    }
    call.name.clone()
}

fn subtitle(call: &ToolCall) -> Option<String> {
    if call.name == "Bash" {
        return call.backgrounded.get().then(|| "Background".to_string());
    }
    let mut parts = Vec::new();
    if let Some(t) = call.string("subagent_type").filter(|t| !t.is_empty()) {
        parts.push(t);
    }
    if let Some(n) = call.task_tokens.get() {
        parts.push(if n >= 1000 { format!("{:.1}k tokens", n as f64 / 1000.0) } else { format!("{n} tokens") });
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

fn output(call: &ToolCall) -> Option<String> {
    if let Some(s) = call.structured.borrow().as_ref() {
        let joined = ["stdout", "stderr"].iter().filter_map(|k| s.get(*k).and_then(|v| v.as_str())).filter(|v| !v.is_empty()).collect::<Vec<_>>().join("\n");
        if !joined.is_empty() {
            return Some(joined);
        }
    }
    call.task_summary.borrow().clone().or_else(|| call.result_text.borrow().clone())
}

pub fn duration(d: Duration) -> String {
    let s = d.as_secs_f64().round() as u64;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m {}s", s / 60, s % 60)
    } else {
        format!("{}h {}m", s / 3600, (s % 3600) / 60)
    }
}
