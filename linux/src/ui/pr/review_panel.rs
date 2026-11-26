use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;

use super::model::{Change, PrModel};
use super::sheets::{after_review, Verdict};
use crate::ui::composer::Composer;
use crate::ui::widgets::*;
use crate::util;

pub struct ReviewPanel {
    pub widget: gtk::Box,
    model: Rc<PrModel>,
    status: gtk::Box,
    pending: gtk::Box,
    segments: gtk::Box,
    own_note: gtk::Label,
    composer: Rc<Composer>,
    reason: gtk::Label,
    submit: gtk::Button,
    verdict: Cell<Verdict>,
}

pub fn next_unviewed(files: &[String], viewed: &std::collections::HashSet<String>) -> Option<String> {
    files.iter().find(|f| !viewed.contains(*f)).cloned()
}

impl ReviewPanel {
    pub fn new(model: Rc<PrModel>) -> Rc<Self> {
        let widget = vbox(12);
        widget.add_css_class("review-panel");
        widget.set_size_request(300, -1);
        pad(&widget, 14);
        let head = hbox(6);
        head.append(&colored_icon("sy-eye-symbolic", 14, "sky"));
        head.append(&label_with("REVIEW", &["sy-eyebrow"]));
        widget.append(&head);
        let status = vbox(8);
        widget.append(&status);
        widget.append(&line());
        let segments = hbox(0);
        segments.add_css_class("linked");
        segments.set_homogeneous(true);
        segments.update_property(&[gtk::accessible::Property::Label("Verdict")]);
        widget.append(&segments);
        let own_note = wrap_label("Your own pull request: you can comment, not approve.", &["sy-muted", "sy-small"]);
        own_note.set_visible(false);
        widget.append(&own_note);
        let composer = Composer::new("Summary (Ctrl+Enter to submit)", 110);
        composer.set_text(&model.summary_draft.borrow());
        widget.append(&composer.widget);
        let reason = wrap_label("", &["ink-amber", "sy-small"]);
        reason.set_visible(false);
        widget.append(&reason);
        let submit = gtk::Button::with_label("Comment");
        submit.set_halign(gtk::Align::End);
        submit.set_tooltip_text(Some("Submit review (Ctrl+Enter)"));
        widget.append(&submit);
        widget.append(&line());
        let pending = vbox(6);
        let scroll = scrolled(&pending);
        widget.append(&scroll);
        let me = Rc::new(ReviewPanel { widget, model: model.clone(), status, pending, segments, own_note, composer, reason, submit, verdict: Cell::new(Verdict::Comment) });
        let mut first: Option<gtk::ToggleButton> = None;
        for v in [Verdict::Comment, Verdict::Approve, Verdict::RequestChanges] {
            let t = gtk::ToggleButton::with_label(v.submit_label());
            match &first {
                Some(f) => t.set_group(Some(f)),
                None => {
                    t.set_active(true);
                    first = Some(t.clone());
                }
            }
            let w = Rc::downgrade(&me);
            t.connect_toggled(move |t| {
                if let (true, Some(me)) = (t.is_active(), w.upgrade()) {
                    me.verdict.set(v);
                    me.sync_submit();
                }
            });
            me.segments.append(&t);
        }
        let w = Rc::downgrade(&me);
        me.composer.on_changed(move || {
            if let Some(me) = w.upgrade() {
                *me.model.summary_draft.borrow_mut() = me.composer.text();
                me.model.drafts_changed();
                me.sync_submit();
            }
        });
        let w = Rc::downgrade(&me);
        me.submit.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.send();
            }
        });
        let w = Rc::downgrade(&me);
        me.composer.on_submit(move || {
            if let Some(me) = w.upgrade() {
                me.send();
            }
        });
        let w = Rc::downgrade(&me);
        model.changed.connect(move |c| match w.upgrade() {
            Some(me) => {
                if matches!(c, Change::Pr | Change::Diff | Change::Files) {
                    me.render();
                }
                true
            }
            None => false,
        });
        me.render();
        me
    }

    fn file_paths(&self) -> Vec<String> {
        self.model.files.borrow().iter().map(|f| f.id.clone()).collect()
    }

    fn render(self: &Rc<Self>) {
        let Some(pr) = self.model.pr.borrow().clone() else { return };
        let own = pr.viewer_did_author;
        self.segments.set_visible(!own);
        self.own_note.set_visible(own);
        if own && self.verdict.get() != Verdict::Comment {
            self.verdict.set(Verdict::Comment);
        }
        clear(&self.status);
        let files = self.file_paths();
        let total = if files.is_empty() { pr.changed_files.max(0) as usize } else { files.len() };
        let viewed = self.model.viewed.borrow().clone();
        let seen = files.iter().filter(|f| viewed.contains(*f)).count();
        let progress_row = hbox(8);
        let bar = gtk::ProgressBar::new();
        bar.add_css_class("viewed-progress");
        bar.set_fraction(if total == 0 { 0.0 } else { seen as f64 / total as f64 });
        bar.set_hexpand(true);
        bar.set_valign(gtk::Align::Center);
        progress_row.append(&bar);
        progress_row.append(&label_with(&format!("{seen}/{total} files viewed"), &["sy-muted", "sy-small", "sy-meta-num"]));
        self.status.append(&progress_row);
        if let Some(next) = next_unviewed(&files, &viewed) {
            let b = link_button(&format!("Next unviewed file · {}", next.rsplit('/').next().unwrap_or(&next)));
            b.set_halign(gtk::Align::Start);
            b.set_tooltip_text(Some(&next));
            let m = self.model.clone();
            b.connect_clicked(move |_| m.reveal_file(&next));
            self.status.append(&b);
        }
        let unresolved = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved && !t.is_outdated).count();
        if unresolved > 0 {
            let b = link_button(&util::plural(unresolved as i64, "unresolved thread", "unresolved threads"));
            b.set_halign(gtk::Align::Start);
            let m = self.model.clone();
            b.connect_clicked(move |_| m.set_tab(super::model::PrTab::Conversation));
            self.status.append(&b);
        }
        self.render_pending();
        self.sync_submit();
    }

    fn render_pending(self: &Rc<Self>) {
        clear(&self.pending);
        let pending = self.model.pending.borrow().clone();
        self.pending.append(&label_with(&format!("PENDING COMMENTS · {}", pending.len()), &["sy-eyebrow"]));
        if pending.is_empty() {
            self.pending.append(&wrap_label("Click a line number in Files to add an inline comment.", &["sy-dim", "sy-small"]));
            return;
        }
        let mut paths: Vec<String> = pending.iter().map(|c| c.path.clone()).collect();
        paths.dedup();
        let mut seen = std::collections::HashSet::new();
        for path in paths.into_iter().filter(|p| seen.insert(p.clone())) {
            let open = link_button(path.rsplit('/').next().unwrap_or(&path));
            open.set_halign(gtk::Align::Start);
            open.set_tooltip_text(Some(&format!("Open {path}")));
            let m = self.model.clone();
            let p = path.clone();
            open.connect_clicked(move |_| m.reveal_file(&p));
            self.pending.append(&open);
            for c in pending.iter().filter(|c| c.path == path) {
                let row = hbox(6);
                row.set_margin_start(10);
                row.append(&label_with(&format!("L{}", c.line), &["sy-mono", "sy-small", "sy-muted"]));
                let text = ellipsized(c.body.lines().next().unwrap_or(""), &["sy-text", "sy-small"]);
                text.set_hexpand(true);
                text.set_tooltip_text(Some(&c.body));
                row.append(&text);
                let trash = icon_button("user-trash-symbolic", "Delete pending comment");
                let m = self.model.clone();
                let id = c.id.clone();
                trash.connect_clicked(move |_| {
                    m.pending.borrow_mut().retain(|p| p.id != id);
                    m.save_drafts_now();
                    m.emit(Change::Diff);
                });
                row.append(&trash);
                self.pending.append(&row);
            }
        }
    }

    fn sync_submit(&self) {
        let v = self.verdict.get();
        for x in [Verdict::Comment, Verdict::Approve, Verdict::RequestChanges] {
            self.submit.remove_css_class(&format!("tint-{}", x.tint()));
        }
        self.submit.add_css_class(&format!("tint-{}", v.tint()));
        self.submit.set_label(v.submit_label());
        let why = v.blocked_reason(self.composer.is_blank(), self.model.pending.borrow().len());
        self.submit.set_sensitive(why.is_none() && !self.model.busy.get());
        self.reason.set_text(why.unwrap_or(""));
        self.reason.set_visible(why.is_some());
    }

    fn send(self: &Rc<Self>) {
        let v = self.verdict.get();
        if self.model.busy.get() || v.blocked_reason(self.composer.is_blank(), self.model.pending.borrow().len()).is_some() {
            return;
        }
        let body = self.composer.text();
        let m = self.model.clone();
        let me = self.clone();
        let number = m.r.number;
        crate::rt::spawn_local(async move {
            if m.clone().submit_review(v.event().to_string(), body).await {
                me.composer.set_text("");
                after_review(&m, v, number);
                me.render();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_unviewed_skips_viewed_files() {
        let files = vec!["a.rs".to_string(), "b.rs".to_string(), "c.rs".to_string()];
        let mut viewed = std::collections::HashSet::new();
        viewed.insert("a.rs".to_string());
        assert_eq!(next_unviewed(&files, &viewed).as_deref(), Some("b.rs"));
        viewed.insert("b.rs".to_string());
        viewed.insert("c.rs".to_string());
        assert_eq!(next_unviewed(&files, &viewed), None);
    }
}
