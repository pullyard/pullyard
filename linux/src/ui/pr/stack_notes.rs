use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use super::super::widgets::*;
use crate::stack::notes::{self, NoteKind, StackNote};
use crate::util;

pub fn sticky(list: &[StackNote], on_path: bool) -> gtk::Box {
    let mut sorted: Vec<&StackNote> = list.iter().collect();
    sorted.sort_by(|a, b| b.updated.cmp(&a.updated));
    let b = vbox(3);
    b.add_css_class("stack-sticky");
    b.set_size_request(-1, crate::stack::metrics::NOTE_HEIGHT as i32);
    b.set_overflow(gtk::Overflow::Hidden);
    if !on_path {
        b.set_opacity(0.75);
    }
    let head = hbox(5);
    head.append(&colored_icon("document-edit-symbolic", 12, "amber"));
    head.append(&label_with(&util::plural(sorted.len() as i64, "note", "notes"), &["fg-amber", "sy-bold", "sy-tiny"]));
    head.append(&spacer());
    b.append(&head);
    for n in sorted.iter().take(2) {
        let row = hbox(5);
        let dot = fixed_box(&["stack-dot", &format!("edge-{}", n.kind.color())], 6, 6);
        row.append(&dot);
        row.append(&label_with(n.kind.title(), &[&format!("fg-{}", n.kind.color()), "sy-bold", "sy-tiny"]));
        let text = ellipsized(&n.text.replace('\n', " "), &["sy-text", "sy-small"]);
        text.set_hexpand(true);
        row.append(&text);
        b.append(&row);
    }
    if sorted.len() > 2 {
        b.append(&label_with(&format!("+{} more", sorted.len() - 2), &["sy-muted", "sy-tiny"]));
    }
    b.set_tooltip_text(Some("Click to read and edit all notes"));
    b
}

struct Draft {
    note: RefCell<StackNote>,
}

pub struct NotesEditor {
    pub widget: gtk::Box,
    key: String,
    drafts: RefCell<Vec<Rc<Draft>>>,
    rows: gtk::Box,
    pending: RefCell<Option<glib::SourceId>>,
}

impl NotesEditor {
    pub fn new(key: String, number: i64, title: &str, on_close: Rc<dyn Fn()>) -> Rc<Self> {
        let widget = vbox(10);
        widget.add_css_class("stack-notes-panel");
        widget.set_size_request(340, -1);
        widget.set_halign(gtk::Align::End);
        widget.set_valign(gtk::Align::Start);
        pad(&widget, 12);
        let head = hbox(8);
        head.append(&colored_icon("document-edit-symbolic", 16, "amber"));
        let titles = vbox(2);
        titles.set_hexpand(true);
        titles.append(&label_with(&format!("Notes on #{number}"), &["sy-heading", "sy-text"]));
        titles.append(&ellipsized(title, &["sy-muted", "sy-small"]));
        head.append(&titles);
        let close = icon_button("window-close-symbolic", "Close (Esc)");
        close.set_valign(gtk::Align::Start);
        let c = on_close.clone();
        close.connect_clicked(move |_| c());
        head.append(&close);
        widget.append(&head);
        let rows = vbox(12);
        let scroll = gtk::ScrolledWindow::new();
        scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        scroll.set_propagate_natural_height(true);
        scroll.set_max_content_height(360);
        scroll.set_child(Some(&rows));
        widget.append(&scroll);
        let foot = hbox(8);
        let add = gtk::Button::new();
        add.add_css_class("flat");
        add.set_child(Some(&icon_label_content("list-add-symbolic", "Add note")));
        foot.append(&add);
        foot.append(&spacer());
        foot.append(&label_with("Only on this computer", &["sy-dim", "sy-small"]));
        widget.append(&foot);
        let me = Rc::new(NotesEditor { widget, key: key.clone(), drafts: RefCell::new(vec![]), rows, pending: RefCell::new(None) });
        let mut existing = notes::shared().notes(&key);
        if existing.is_empty() {
            existing.push(StackNote::new(NoteKind::Note, ""));
        }
        for n in existing {
            me.add_row(n, false);
        }
        let w = Rc::downgrade(&me);
        add.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.add_row(StackNote::new(NoteKind::Note, ""), true);
            }
        });
        let w = Rc::downgrade(&me);
        me.widget.connect_destroy(move |_| {
            if let Some(me) = w.upgrade() {
                me.commit();
                notes::flush();
            }
        });
        me
    }

    fn add_row(self: &Rc<Self>, note: StackNote, focus: bool) {
        let draft = Rc::new(Draft { note: RefCell::new(note.clone()) });
        self.drafts.borrow_mut().push(draft.clone());
        let row = vbox(6);
        let top = hbox(6);
        let kinds = hbox(0);
        kinds.add_css_class("linked");
        let mut first: Option<gtk::ToggleButton> = None;
        for kind in NoteKind::ALL {
            let t = gtk::ToggleButton::with_label(kind.title());
            t.add_css_class("sy-small");
            match &first {
                Some(g) => t.set_group(Some(g)),
                None => first = Some(t.clone()),
            }
            if kind == note.kind {
                t.set_active(true);
            }
            let d = draft.clone();
            let w = Rc::downgrade(self);
            t.connect_toggled(move |t| {
                if t.is_active() && d.note.borrow().kind != kind {
                    d.note.borrow_mut().kind = kind;
                    if let Some(me) = w.upgrade() {
                        me.schedule();
                    }
                }
            });
            kinds.append(&t);
        }
        top.append(&kinds);
        top.append(&spacer());
        let delete = icon_button("user-trash-symbolic", "Delete note");
        top.append(&delete);
        row.append(&top);
        let text = gtk::TextView::new();
        text.set_wrap_mode(gtk::WrapMode::WordChar);
        text.add_css_class("stack-note-text");
        text.set_size_request(-1, 64);
        text.buffer().set_text(&note.text);
        let d = draft.clone();
        let w = Rc::downgrade(self);
        text.buffer().connect_changed(move |b| {
            let (start, end) = b.bounds();
            d.note.borrow_mut().text = b.text(&start, &end, false).to_string();
            if let Some(me) = w.upgrade() {
                me.schedule();
            }
        });
        row.append(&text);
        self.rows.append(&row);
        let w = Rc::downgrade(self);
        let d = draft.clone();
        let r = row.clone();
        delete.connect_clicked(move |_| {
            let Some(me) = w.upgrade() else { return };
            me.drafts.borrow_mut().retain(|x| !Rc::ptr_eq(x, &d));
            me.rows.remove(&r);
            me.commit();
        });
        if focus {
            text.grab_focus();
        }
    }

    fn schedule(self: &Rc<Self>) {
        if let Some(id) = self.pending.borrow_mut().take() {
            id.remove();
        }
        let w = Rc::downgrade(self);
        let id = glib::timeout_add_local_once(Duration::from_millis(700), move || {
            if let Some(me) = w.upgrade() {
                me.pending.borrow_mut().take();
                me.commit();
            }
        });
        *self.pending.borrow_mut() = Some(id);
    }

    pub fn commit(&self) {
        if let Some(id) = self.pending.borrow_mut().take() {
            id.remove();
        }
        let drafts: Vec<StackNote> = self.drafts.borrow().iter().map(|d| d.note.borrow().clone()).collect();
        notes::commit(&self.key, &drafts);
    }

    pub fn focus(&self) {
        let mut c = self.rows.first_child();
        while let Some(row) = c {
            if let Some(tv) = row.last_child().and_downcast::<gtk::TextView>() {
                tv.grab_focus();
                return;
            }
            c = row.next_sibling();
        }
    }
}
