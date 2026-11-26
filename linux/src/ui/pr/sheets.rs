use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use adw::prelude::*;

use super::backend::PrAction;
use super::model::{Change, PrModel};
use crate::api::models::{CheckContext, ReviewThread};
use crate::ui::composer::Composer;
use crate::ui::dialogs::Sheet;
use crate::ui::widgets::*;
use crate::util;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MergeMethod {
    Merge,
    Squash,
    Rebase,
}

impl MergeMethod {
    pub const ALL: [MergeMethod; 3] = [MergeMethod::Merge, MergeMethod::Squash, MergeMethod::Rebase];

    pub fn key(&self) -> &'static str {
        match self {
            MergeMethod::Merge => "MERGE",
            MergeMethod::Squash => "SQUASH",
            MergeMethod::Rebase => "REBASE",
        }
    }

    pub fn from_key(k: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|m| m.key() == k)
    }

    pub fn title(&self) -> &'static str {
        match self {
            MergeMethod::Merge => "Merge commit",
            MergeMethod::Squash => "Squash and merge",
            MergeMethod::Rebase => "Rebase and merge",
        }
    }
}

fn close_on_success(sheet: &Sheet) -> impl Fn(bool) + Clone {
    let d = sheet.dialog.clone();
    move |ok: bool| {
        if ok {
            d.close();
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Verdict {
    Comment,
    Approve,
    RequestChanges,
}

impl Verdict {
    pub fn event(&self) -> &'static str {
        match self {
            Verdict::Comment => "COMMENT",
            Verdict::Approve => "APPROVE",
            Verdict::RequestChanges => "REQUEST_CHANGES",
        }
    }

    pub fn submit_label(&self) -> &'static str {
        match self {
            Verdict::Comment => "Comment",
            Verdict::Approve => "Approve",
            Verdict::RequestChanges => "Request changes",
        }
    }

    pub fn tint(&self) -> &'static str {
        match self {
            Verdict::Comment => "accent",
            Verdict::Approve => "green",
            Verdict::RequestChanges => "red",
        }
    }

    pub fn blocked_reason(&self, blank: bool, pending: usize) -> Option<&'static str> {
        if !blank || pending > 0 {
            return None;
        }
        match self {
            Verdict::Approve => None,
            Verdict::Comment => Some("Write a summary or add inline comments to send a comment."),
            Verdict::RequestChanges => Some("Explain what needs to change, or add inline comments."),
        }
    }

    pub fn done_message(&self, prefix: &str, number: i64) -> String {
        match self {
            Verdict::Comment => format!("Review sent on {prefix}{number}"),
            Verdict::Approve => format!("Approved {prefix}{number}"),
            Verdict::RequestChanges => format!("Requested changes on {prefix}{number}"),
        }
    }
}

pub fn after_review(model: &Rc<PrModel>, verdict: Verdict, number: i64) {
    let msg = verdict.done_message(model.features.number_prefix(), number);
    if verdict == Verdict::Approve && crate::app::next_review(Some(&model.r)).is_some() {
        let r = model.r.clone();
        crate::app::toast_action(&format!("✓ {msg}"), "Next review →", move || crate::app::open_next_review(Some(&r)));
    } else {
        crate::app::toast(&msg);
    }
}

fn pending_list(model: &Rc<PrModel>) -> Option<gtk::Box> {
    let pending = model.pending.borrow().clone();
    if pending.is_empty() {
        return None;
    }
    let b = vbox(4);
    b.add_css_class("sy-sunken");
    pad(&b, 10);
    b.append(&label_with(&format!("PENDING INLINE COMMENTS · {}", pending.len()), &["sy-eyebrow"]));
    for c in pending.iter().take(8) {
        let row = hbox(8);
        let loc = label_with(&format!("{}:{}", c.path.rsplit('/').next().unwrap_or(&c.path), c.line), &["sy-mono", "sy-small", "sy-link"]);
        loc.set_tooltip_text(Some(&format!("{}:{}", c.path, c.line)));
        row.append(&loc);
        let text = ellipsized(c.body.lines().next().unwrap_or(""), &["sy-muted", "sy-small"]);
        text.set_hexpand(true);
        row.append(&text);
        b.append(&row);
    }
    if pending.len() > 8 {
        b.append(&label_with(&format!("and {} more", pending.len() - 8), &["sy-dim", "sy-small"]));
    }
    Some(b)
}

pub fn review(model: Rc<PrModel>) {
    let Some(pr) = model.pr.borrow().clone() else { return };
    let f = model.features;
    let sheet = Sheet::new(&format!("Review {}{}", f.number_prefix(), pr.number), 560, -1);
    let pending = model.pending.borrow().len();
    if model.restored_drafts.get() {
        let l = hbox(6);
        l.append(&icon("sy-clock-symbolic", 13));
        l.append(&label_with("Restored from your last session", &["sy-muted", "sy-small"]));
        sheet.body.append(&l);
    }
    let own = pr.viewer_did_author;
    let verdict = Rc::new(std::cell::Cell::new(Verdict::Comment));
    let segments = hbox(0);
    segments.add_css_class("linked");
    segments.set_halign(gtk::Align::Start);
    let mut toggles: Vec<(Verdict, gtk::ToggleButton)> = vec![];
    for v in [Verdict::Comment, Verdict::Approve, Verdict::RequestChanges] {
        let t = gtk::ToggleButton::with_label(v.submit_label());
        if let Some((_, first)) = toggles.first() {
            t.set_group(Some(first));
        }
        segments.append(&t);
        toggles.push((v, t));
    }
    toggles[0].1.set_active(true);
    segments.update_property(&[gtk::accessible::Property::Label("Verdict")]);
    let can_approve = pr.viewer_can_approve.unwrap_or(!own) && pr.viewer_approved != Some(true);
    for (v, t) in &toggles {
        match v {
            Verdict::Approve => t.set_sensitive(can_approve),
            Verdict::RequestChanges => {
                t.set_sensitive(!own);
                t.set_visible(f.request_changes);
            }
            Verdict::Comment => {}
        }
    }
    if own && !can_approve {
        sheet.body.append(&label_with(&format!("This is your {}, so you can leave a comment but not approve it or request changes.", f.request_title()), &["sy-muted", "sy-small"]));
    } else {
        sheet.body.append(&segments);
    }
    let composer = Composer::new("Review summary (optional when approving)", 140);
    composer.set_text(&model.summary_draft.borrow());
    let draft_model = model.clone();
    let draft_comp = Rc::downgrade(&composer);
    composer.on_changed(move || {
        if let Some(c) = draft_comp.upgrade() {
            *draft_model.summary_draft.borrow_mut() = c.text();
            draft_model.drafts_changed();
        }
    });
    sheet.body.append(&composer.widget);
    let reason = label_with("", &["ink-amber", "sy-small"]);
    reason.set_wrap(true);
    reason.set_visible(false);
    sheet.body.append(&reason);
    if let Some(list) = pending_list(&model) {
        sheet.body.append(&list);
    }
    if pending > 0 {
        let discard = destructive("Discard pending comments");
        let m = model.clone();
        let d = sheet.dialog.clone();
        discard.connect_clicked(move |_| {
            let m = m.clone();
            let d = d.clone();
            let count = m.pending.borrow().len();
            let heading = format!("Discard {count} pending comment{}?", if count == 1 { "" } else { "s" });
            crate::ui::dialogs::confirm(&heading, Some("The inline comments you haven’t submitted yet will be lost."), "Discard", true, move || {
                m.pending.borrow_mut().clear();
                m.restored_drafts.set(false);
                m.save_drafts_now();
                m.emit(Change::Diff);
                m.emit(Change::Pr);
                d.close();
            });
        });
        sheet.footer.append(&discard);
    }
    sheet.add_footer_spacer();
    sheet.cancel_button();
    let submit = gtk::Button::with_label("Comment");
    sheet.footer.append(&submit);
    let sync: Rc<dyn Fn()> = {
        let submit = submit.clone();
        let reason = reason.clone();
        let comp = composer.clone();
        let m = model.clone();
        let verdict = verdict.clone();
        Rc::new(move || {
            let v = verdict.get();
            for x in [Verdict::Comment, Verdict::Approve, Verdict::RequestChanges] {
                submit.remove_css_class(&format!("tint-{}", x.tint()));
            }
            submit.add_css_class(&format!("tint-{}", v.tint()));
            submit.set_label(v.submit_label());
            let why = v.blocked_reason(comp.is_blank(), m.pending.borrow().len());
            submit.set_sensitive(why.is_none());
            reason.set_text(why.unwrap_or(""));
            reason.set_visible(why.is_some());
        })
    };
    for (v, t) in &toggles {
        let v = *v;
        let verdict = verdict.clone();
        let sync = sync.clone();
        t.connect_toggled(move |t| {
            if t.is_active() {
                verdict.set(v);
                sync();
            }
        });
    }
    let s = sync.clone();
    composer.on_changed(move || s());
    sync();
    let done = close_on_success(&sheet);
    let m = model.clone();
    let comp = composer.clone();
    let number = pr.number;
    let go = Rc::new(move || {
        let v = verdict.get();
        if m.busy.get() || v.blocked_reason(comp.is_blank(), m.pending.borrow().len()).is_some() {
            return;
        }
        let body = comp.text();
        let m = m.clone();
        let done = done.clone();
        crate::rt::spawn_local(async move {
            let ok = m.clone().submit_review(v.event().to_string(), body).await;
            if ok {
                after_review(&m, v, number);
            }
            done(ok)
        });
    });
    let g = go.clone();
    submit.connect_clicked(move |_| g());
    let g = go.clone();
    composer.on_submit(move || g());
    sheet.present();
    composer.grab_focus();
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MergePrimary {
    Merge,
    MergeWhenReady,
    ViewConflicts,
    UpdateBranch,
    MergeAnyway,
}

impl MergePrimary {
    pub fn title(&self) -> &'static str {
        match self {
            MergePrimary::Merge => "Merge",
            MergePrimary::MergeWhenReady => "Merge when ready",
            MergePrimary::ViewConflicts => "View conflicts",
            MergePrimary::UpdateBranch => "Update branch",
            MergePrimary::MergeAnyway => "Merge anyway",
        }
    }
}

pub fn merge_buttons(ready: bool, conflicts: bool, behind: bool, waiting: bool, auto_available: bool) -> (MergePrimary, Option<MergePrimary>) {
    if ready {
        return (MergePrimary::Merge, auto_available.then_some(MergePrimary::MergeWhenReady));
    }
    if conflicts {
        return (MergePrimary::ViewConflicts, Some(MergePrimary::MergeAnyway));
    }
    if behind {
        return (MergePrimary::UpdateBranch, Some(MergePrimary::MergeAnyway));
    }
    if waiting && auto_available {
        return (MergePrimary::MergeWhenReady, Some(MergePrimary::MergeAnyway));
    }
    (MergePrimary::MergeAnyway, auto_available.then_some(MergePrimary::MergeWhenReady))
}

fn merge_glyph(m: MergeMethod) -> &'static str {
    match m {
        MergeMethod::Merge => "sy-merge-symbolic",
        MergeMethod::Squash => "sy-commit-symbolic",
        MergeMethod::Rebase => "sy-branch-symbolic",
    }
}

fn after_merge(model: &Rc<PrModel>, number: i64, base: String, restore: Option<(String, String, String)>) {
    let msg = format!("Merged {}{number} into {base}", model.features.number_prefix());
    match restore {
        Some((repo, branch, sha)) => {
            let m = model.clone();
            crate::app::toast_action(&msg, "Restore branch", move || {
                let m = m.clone();
                let (repo, branch, sha) = (repo.clone(), branch.clone(), sha.clone());
                crate::rt::spawn_local(async move {
                    if m.restore_branch(repo, branch.clone(), sha).await {
                        crate::app::toast(&format!("Restored {branch}"));
                    }
                });
            });
        }
        None if crate::app::next_review(Some(&model.r)).is_some() => {
            let r = model.r.clone();
            crate::app::toast_action(&msg, "Next review →", move || crate::app::open_next_review(Some(&r)));
        }
        None => crate::app::toast(&msg),
    }
}

pub fn merge(model: Rc<PrModel>) {
    let Some(pr) = model.pr.borrow().clone() else { return };
    let repo = model.repo.borrow().clone();
    let allowed: Vec<MergeMethod> = match &repo {
        None => MergeMethod::ALL.to_vec(),
        Some(r) => MergeMethod::ALL
            .into_iter()
            .filter(|m| match m {
                MergeMethod::Merge => r.merge_commit_allowed,
                MergeMethod::Squash => r.squash_merge_allowed,
                MergeMethod::Rebase => r.rebase_merge_allowed,
            })
            .collect(),
    };
    let f = model.features;
    let prefix = f.number_prefix();
    let method_title = move |m: MergeMethod| if m == MergeMethod::Merge && f.is_gitlab() { "Merge" } else { m.title() };
    let sheet = Sheet::new(&format!("Merge {prefix}{} into {}", pr.number, pr.base_ref_name), 580, -1);
    let checklist = vbox(0);
    sheet.body.append(&checklist);
    let render_list: Rc<dyn Fn()> = {
        let checklist = checklist.downgrade();
        let m = model.clone();
        Rc::new(move || {
            let Some(c) = checklist.upgrade() else { return };
            let Some(pr) = m.pr.borrow().clone() else { return };
            clear(&c);
            let reqs = m.requirements();
            let st = super::merge_status(&pr, &reqs);
            let head = hbox(8);
            head.append(&colored_icon(st.icon, 16, st.color));
            head.append(&wrap_label(&st.text, &["sy-text", "sy-heading"]));
            c.append(&head);
            if !reqs.is_empty() {
                let list = super::requirements_list(&m, &pr, &reqs, None);
                list.set_margin_top(8);
                list.set_margin_start(4);
                c.append(&list);
            }
        })
    };
    render_list();
    let weak_list = checklist.downgrade();
    let r = render_list.clone();
    model.changed.connect(move |c| {
        if weak_list.upgrade().is_none() {
            return false;
        }
        if matches!(c, Change::Pr | Change::Rules) {
            r();
        }
        true
    });
    let default = MergeMethod::from_key(repo.as_ref().map(|r| r.viewer_default_merge_method.as_str()).unwrap_or("MERGE")).unwrap_or(MergeMethod::Merge);
    let initial = allowed.iter().position(|m| *m == default).unwrap_or(0);
    let selected = Rc::new(std::cell::Cell::new(allowed.get(initial).copied().unwrap_or(MergeMethod::Merge)));
    let uses_queue = f.merge_queue && pr.is_merge_queue_enabled == Some(true) && pr.merge_queue_entry.is_none() && pr.is_in_merge_queue != Some(true);
    if uses_queue {
        let note = hbox(6);
        note.append(&icon("sy-archive-symbolic", 14));
        let text = wrap_label(
            &format!("{} uses a {}. Add the {} to it and it merges once the required checks pass; merging directly may be rejected.", pr.base_ref_name, f.queue_title(), f.request_title()),
            &["caption", "sy-muted"],
        );
        text.set_hexpand(true);
        text.set_xalign(0.0);
        note.append(&text);
        sheet.body.append(&note);
    }
    let title = gtk::Entry::new();
    title.set_placeholder_text(Some(&format!("Commit title ({} default)", f.service_title())));
    let message = Composer::new("Commit description (optional)", 80);
    let commit_box = vbox(8);
    commit_box.append(&title);
    commit_box.append(&message.widget);
    let prefill = {
        let title = title.clone();
        let commit_box = commit_box.clone();
        let pr_title = pr.title.clone();
        let number = pr.number;
        let github = f.provider.is_github();
        Rc::new(move |m: MergeMethod| {
            commit_box.set_visible(m != MergeMethod::Rebase);
            let squashed = if github { format!("{pr_title} (#{number})") } else { pr_title.clone() };
            title.set_text(&if m == MergeMethod::Squash { squashed } else { String::new() });
        })
    };
    if allowed.len() > 1 {
        let seg = hbox(0);
        seg.add_css_class("linked");
        seg.set_halign(gtk::Align::Start);
        seg.update_property(&[gtk::accessible::Property::Label("Merge method")]);
        let mut first: Option<gtk::ToggleButton> = None;
        for m in &allowed {
            let t = gtk::ToggleButton::new();
            t.set_child(Some(&icon_label_content(merge_glyph(*m), method_title(*m))));
            if let Some(f) = &first {
                t.set_group(Some(f));
            } else {
                first = Some(t.clone());
            }
            t.set_active(*m == selected.get());
            let m = *m;
            let sel = selected.clone();
            let p = prefill.clone();
            t.connect_toggled(move |t| {
                if t.is_active() {
                    sel.set(m);
                    p(m);
                }
            });
            seg.append(&t);
        }
        sheet.body.append(&seg);
    }
    sheet.body.append(&commit_box);
    prefill(selected.get());
    let delete_on_merge = repo.as_ref().map(|r| r.delete_branch_on_merge).unwrap_or(false);
    let same_repo = pr.head_repository.as_ref().map(|h| h.name_with_owner == model.r.repo.full()).unwrap_or(false);
    let delete = gtk::CheckButton::with_label(&format!("Delete branch {} after merge", pr.head_ref_name));
    delete.set_active(true);
    delete.set_visible(!delete_on_merge && same_repo);
    sheet.body.append(&delete);
    let done = close_on_success(&sheet);
    let reqs = model.requirements();
    let st = super::merge_status(&pr, &reqs);
    let conflicts = pr.mergeable == "CONFLICTING" || pr.merge_state_status.as_deref() == Some("DIRTY");
    let behind = pr.merge_state_status.as_deref() == Some("BEHIND");
    let failed = pr.checks().iter().any(|c| c.outcome() == crate::api::models::CheckOutcome::Failure);
    let waiting = !failed && (reqs.iter().any(|r| r.state == crate::api::merge_readiness::RequirementState::Pending) || pr.review_decision.as_deref() == Some("REVIEW_REQUIRED"));
    let auto_available = repo.as_ref().map(|r| r.auto_merge_allowed).unwrap_or(false) && pr.auto_merge_request.is_none() && !st.ready;
    let (primary, secondary) = merge_buttons(st.ready, conflicts, behind, waiting, auto_available);
    let merge_now = {
        let m = model.clone();
        let sel = selected.clone();
        let title = title.clone();
        let message = message.clone();
        let delete = delete.clone();
        let done = done.clone();
        let blocked = !st.ready;
        let reason = st.text.clone();
        let number = pr.number;
        let base = pr.base_ref_name.clone();
        let head = pr.head_ref_name.clone();
        let head_repo = pr.head_repository.as_ref().map(|h| h.name_with_owner.clone());
        let sha = pr.head_ref_oid.clone();
        Rc::new(move || {
            if m.busy.get() {
                return;
            }
            let method = sel.get();
            let del = delete.is_active() && !delete_on_merge && same_repo;
            let mut body = format!("{} · {}", method_title(method), if del { format!("deletes {head}") } else { format!("keeps {head}") });
            if blocked {
                body = format!("{body}\n\nNot everything is ready: {reason}.");
            }
            let d = adw::AlertDialog::new(Some(&format!("Merge {prefix}{number} into {base}?")), Some(&body));
            d.add_response("cancel", "Cancel");
            d.add_response("merge", if blocked { "Merge anyway" } else { "Merge" });
            d.set_response_appearance("merge", if blocked { adw::ResponseAppearance::Destructive } else { adw::ResponseAppearance::Suggested });
            d.set_default_response(Some(if blocked { "cancel" } else { "merge" }));
            d.set_close_response("cancel");
            let (m, title, message, done, base, head, head_repo, sha) = (m.clone(), title.clone(), message.clone(), done.clone(), base.clone(), head.clone(), head_repo.clone(), sha.clone());
            d.connect_response(None, move |_, r| {
                if r != "merge" {
                    return;
                }
                let key = method.key().to_string();
                let t = title.text().trim().to_string();
                let b = message.text().trim().to_string();
                let (m, done, base) = (m.clone(), done.clone(), base.clone());
                let restore = if del && m.api.is_some() { head_repo.clone().map(|repo| (repo, head.clone(), sha.clone())) } else { None };
                crate::rt::spawn_local(async move {
                    let ok = m.clone().merge(key, if t.is_empty() { None } else { Some(t) }, if b.is_empty() { None } else { Some(b) }, del).await;
                    if ok {
                        after_merge(&m, number, base, restore);
                    }
                    done(ok)
                });
            });
            let w = crate::app::main_window();
            d.present(w.as_ref());
        })
    };
    let run: Rc<dyn Fn(MergePrimary)> = {
        let m = model.clone();
        let sel = selected.clone();
        let done = done.clone();
        let merge_now = merge_now.clone();
        let d = sheet.dialog.clone();
        Rc::new(move |p: MergePrimary| match p {
            MergePrimary::Merge | MergePrimary::MergeAnyway => merge_now(),
            MergePrimary::MergeWhenReady => {
                let key = sel.get().key().to_string();
                let m = m.clone();
                let done = done.clone();
                crate::rt::spawn_local(async move {
                    let ok = m.enable_auto_merge(key).await;
                    if ok {
                        crate::app::toast("Auto-merge enabled");
                    }
                    done(ok)
                });
            }
            MergePrimary::UpdateBranch => {
                let m = m.clone();
                crate::rt::spawn_local(async move {
                    if m.simple(PrAction::UpdateBranch).await {
                        crate::app::toast("Updating branch");
                    }
                });
            }
            MergePrimary::ViewConflicts => {
                d.close();
                m.set_tab(super::model::PrTab::Conversation);
                m.emit(Change::ScrollBottom);
            }
        })
    };
    let auto_tooltip = if f.is_gitlab() { "Merge automatically when the pipeline succeeds" } else { "Merge automatically when checks and reviews pass" };
    sheet.add_footer_spacer();
    sheet.cancel_button();
    if let Some(sec) = secondary {
        let b = button(sec.title());
        if sec == MergePrimary::MergeAnyway {
            b.add_css_class("merge-anyway");
            b.set_sensitive(!conflicts && !allowed.is_empty());
        }
        if sec == MergePrimary::MergeWhenReady {
            b.set_tooltip_text(Some(auto_tooltip));
        }
        let r = run.clone();
        b.connect_clicked(move |_| r(sec));
        sheet.footer.append(&b);
    }
    let enqueue = uses_queue.then(|| {
        let enqueue = tinted(&format!("Add to {}", f.queue_title()), "green");
        let m = model.clone();
        let d = sheet.dialog.clone();
        enqueue.connect_clicked(move |_| {
            if m.busy.get() {
                return;
            }
            let m = m.clone();
            let d = d.clone();
            crate::rt::spawn_local(async move {
                let title = m.features.queue_title();
                if m.simple(PrAction::Enqueue).await {
                    crate::app::toast(&format!("Added to the {title}"));
                    d.close();
                }
            });
        });
        enqueue
    });
    let go = gtk::Button::with_label(if uses_queue && primary == MergePrimary::Merge { "Merge directly" } else { primary.title() });
    match primary {
        MergePrimary::Merge if uses_queue => {}
        MergePrimary::Merge => go.add_css_class("tint-green"),
        MergePrimary::MergeAnyway => go.add_css_class("merge-anyway"),
        MergePrimary::MergeWhenReady => {
            go.add_css_class("suggested-action");
            go.set_tooltip_text(Some(auto_tooltip));
        }
        _ => go.add_css_class("suggested-action"),
    }
    if matches!(primary, MergePrimary::Merge | MergePrimary::MergeAnyway) {
        go.set_sensitive(!allowed.is_empty());
    }
    let r = run.clone();
    go.connect_clicked(move |_| r(primary));
    sheet.footer.append(&go);
    if let Some(enqueue) = &enqueue {
        sheet.footer.append(enqueue);
    }
    let focus = match (&enqueue, primary) {
        (Some(e), _) => Some(e.clone()),
        (None, MergePrimary::Merge) => Some(go.clone()),
        _ => None,
    };
    if let Some(b) = &focus {
        sheet.dialog.set_default_widget(Some(b));
    }
    sheet.present();
    if let Some(b) = focus {
        b.grab_focus();
    }
}

pub fn edit(model: Rc<PrModel>) {
    let Some(pr) = model.pr.borrow().clone() else { return };
    let sheet = Sheet::new(&format!("Edit {}{}", model.features.number_prefix(), pr.number), 680, 560);
    let title = gtk::Entry::new();
    title.set_text(&pr.title);
    title.set_placeholder_text(Some("Title"));
    sheet.body.append(&title);
    let body = Composer::new("Description (Markdown)", 260);
    body.set_text(&pr.body);
    sheet.body.append(&body.widget);
    sheet.add_footer_spacer();
    sheet.cancel_button();
    let save = suggested("Save");
    sheet.footer.append(&save);
    let done = close_on_success(&sheet);
    let m = model.clone();
    let b2 = body.clone();
    let go = Rc::new(move || {
        let t = title.text().to_string();
        if t.trim().is_empty() || m.busy.get() {
            return;
        }
        let text = b2.text();
        let m = m.clone();
        let done = done.clone();
        crate::rt::spawn_local(async move { done(m.edit(t, text).await) });
    });
    let g = go.clone();
    save.connect_clicked(move |_| g());
    let g = go.clone();
    body.on_submit(move || g());
    sheet.present();
}

pub fn reviewers(model: Rc<PrModel>) {
    let sheet = Sheet::new("Request review", 560, -1);
    let viewer = model.viewer_login.borrow().clone();
    let candidates: Vec<super::model::ReviewerInfo> = model.reviewers().into_iter().filter(|r| r.login != viewer && !r.login.ends_with("[bot]") && (r.is_team || !r.login.contains('/'))).collect();
    let rerequest: HashSet<String> = model.reviewers_to_rerequest().into_iter().collect();
    let selected: Rc<RefCell<HashSet<String>>> = Rc::new(RefCell::new(rerequest.clone()));
    let go = suggested("Request");
    let load_labels: Rc<RefCell<Vec<(String, gtk::Label)>>> = Rc::new(RefCell::new(Vec::new()));
    let load_label = {
        let load_labels = load_labels.clone();
        move |handle: &str| -> gtk::Label {
            let l = label_with("", &["sy-dim", "sy-small"]);
            l.set_visible(false);
            load_labels.borrow_mut().push((handle.to_string(), l.clone()));
            l
        }
    };
    if !candidates.is_empty() {
        sheet.body.append(&label_with("Reviewers on this pull request", &["sy-muted", "sy-small"]));
        for r in &candidates {
            let check = gtk::CheckButton::new();
            check.set_active(selected.borrow().contains(&r.login));
            let content = hbox(6);
            content.append(&super::reviewer_badge(r));
            content.append(&label_with(&r.login, &["sy-text"]));
            if r.is_team {
                content.append(&label_with("team", &["sy-muted", "sy-small"]));
            }
            if r.code_owner {
                content.append(&label_with("code owner", &["fg-violet", "sy-small"]));
            }
            content.append(&load_label(&r.login));
            if rerequest.contains(&r.login) {
                content.append(&label_with("reviewed before latest push", &["fg-amber", "sy-small"]));
            } else if r.state == "PENDING" {
                content.append(&label_with("already requested", &["sy-muted", "sy-small"]));
            }
            check.set_child(Some(&content));
            let s = selected.clone();
            let login = r.login.clone();
            check.connect_toggled(move |c| {
                if c.is_active() {
                    s.borrow_mut().insert(login.clone());
                } else {
                    s.borrow_mut().remove(&login);
                }
            });
            sheet.body.append(&check);
        }
    }
    let owner_suggestions: Vec<String> = {
        let mut exclude: HashSet<String> = candidates.iter().map(|c| c.login.to_lowercase()).collect();
        exclude.insert(viewer.to_lowercase());
        if let Some(author) = model.pr.borrow().as_ref().and_then(|p| p.author.as_ref()) {
            exclude.insert(author.login.to_lowercase());
        }
        let suggestions = model.ownership().map(|o| o.suggestions(&exclude)).unwrap_or_default();
        if !suggestions.is_empty() {
            sheet.body.append(&label_with("Code owners of changed files", &["sy-muted", "sy-small"]));
        }
        for o in &suggestions {
            let check = gtk::CheckButton::new();
            check.set_active(selected.borrow().contains(&o.handle));
            let content = hbox(6);
            content.append(&label_with(&o.handle, &["sy-text"]));
            if o.is_team {
                content.append(&label_with("team", &["sy-muted", "sy-small"]));
            }
            content.append(&load_label(&o.handle));
            content.append(&label_with("not requested", &["sy-muted", "sy-small"]));
            check.set_child(Some(&content));
            let s = selected.clone();
            let handle = o.handle.clone();
            check.connect_toggled(move |c| {
                if c.is_active() {
                    s.borrow_mut().insert(handle.clone());
                } else {
                    s.borrow_mut().remove(&handle);
                }
            });
            sheet.body.append(&check);
        }
        suggestions.into_iter().map(|o| o.handle).collect()
    };
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some("Other logins or teams, comma-separated, e.g. alice, org/team"));
    sheet.body.append(&entry);
    sheet.add_footer_spacer();
    sheet.cancel_button();
    sheet.footer.append(&go);
    let requested = {
        let selected = selected.clone();
        let entry = entry.clone();
        let candidates = candidates.clone();
        let owner_suggestions = owner_suggestions.clone();
        Rc::new(move || -> Vec<String> {
            let typed: Vec<String> = entry.text().split([',', ' ']).map(|s| s.trim_matches(|c| c == '@' || c == ' ').to_string()).filter(|s| !s.is_empty()).collect();
            let mut seen = HashSet::new();
            candidates.iter().map(|c| c.login.clone()).chain(owner_suggestions.iter().cloned()).filter(|l| selected.borrow().contains(l)).chain(typed).filter(|l| seen.insert(l.clone())).collect()
        })
    };
    let update = {
        let go = go.clone();
        let requested = requested.clone();
        let m = model.clone();
        Rc::new(move || {
            let n = requested().len();
            go.set_label(&if n == 0 { "Request".to_string() } else { format!("Request ({n})") });
            go.set_sensitive(n > 0 && !m.busy.get());
        })
    };
    update();
    let u = update.clone();
    entry.connect_changed(move |_| u());
    let mut c = sheet.body.first_child();
    while let Some(w) = c {
        if let Ok(check) = w.clone().downcast::<gtk::CheckButton>() {
            let u = update.clone();
            check.connect_toggled(move |_| u());
        }
        c = w.next_sibling();
    }
    let done = close_on_success(&sheet);
    let m = model.clone();
    let send = Rc::new(move || {
        let list = requested();
        if list.is_empty() {
            return;
        }
        let m = m.clone();
        let done = done.clone();
        crate::rt::spawn_local(async move { done(m.request_reviewers(list).await) });
    });
    let s = send.clone();
    go.connect_clicked(move |_| s());
    let s = send.clone();
    entry.connect_activate(move |_| s());
    if let Some(api) = model.api.clone() {
        let handles: Vec<String> = load_labels.borrow().iter().map(|(h, _)| h.clone()).collect();
        if !handles.is_empty() {
            crate::rt::spawn_local(async move {
                let counts = crate::api::review_load::load(handles, api).await;
                for (handle, l) in load_labels.borrow().iter() {
                    let Some(n) = counts.get(&handle.to_lowercase()).copied() else { continue };
                    l.set_text(&format!("· {}", crate::api::review_load::label(n)));
                    if crate::api::review_load::busy(n) {
                        l.remove_css_class("sy-dim");
                        l.add_css_class("fg-amber");
                    }
                    l.set_tooltip_text(Some(&format!("Open pull requests waiting for {handle}'s review, among those you can see")));
                    l.set_visible(true);
                }
            });
        }
    }
    sheet.present();
}

pub fn reply(model: Rc<PrModel>, thread: ReviewThread) {
    let sheet = Sheet::new("Reply to thread", 560, -1);
    sheet.body.append(&label_with(&format!("{}{}", thread.path, thread.line.map(|l| format!(":{l}")).unwrap_or_default()), &["sy-mono", "sy-muted", "sy-small"]));
    if let Some(last) = thread.comments.nodes.last() {
        let row = hbox(8);
        row.add_css_class("sy-sunken");
        pad(&row, 8);
        let av = avatar(last.author.as_ref().and_then(|a| a.avatar_url.as_deref()), 18, None);
        av.set_valign(gtk::Align::Start);
        row.append(&av);
        let body = crate::ui::markdown::inline_label(&last.body);
        body.set_lines(6);
        body.set_ellipsize(gtk::pango::EllipsizeMode::End);
        row.append(&body);
        sheet.body.append(&row);
    }
    let composer = Composer::new("Reply (Markdown)", 120);
    composer.set_text(model.reply_drafts.borrow().get(&thread.id).map(String::as_str).unwrap_or(""));
    let draft_model = model.clone();
    let draft_comp = Rc::downgrade(&composer);
    let draft_id = thread.id.clone();
    composer.on_changed(move || {
        if let Some(c) = draft_comp.upgrade() {
            draft_model.set_reply_draft(&draft_id, &c.text());
        }
    });
    sheet.body.append(&composer.widget);
    let done = close_on_success(&sheet);
    let send = {
        let m = model.clone();
        let comp = composer.clone();
        let id = thread.id.clone();
        Rc::new(move |resolve: bool| {
            if comp.is_blank() || m.busy.get() {
                return;
            }
            let body = comp.text();
            let m = m.clone();
            let id = id.clone();
            let done = done.clone();
            crate::rt::spawn_local(async move {
                if m.clone().reply(id.clone(), body).await {
                    if resolve {
                        m.clone().set_resolved(id, true).await;
                    }
                    done(true);
                }
            });
        })
    };
    if thread.viewer_can_resolve && !thread.is_resolved {
        let rr = button("Reply and resolve");
        let s = send.clone();
        rr.connect_clicked(move |_| s(true));
        sheet.footer.append(&rr);
    }
    sheet.add_footer_spacer();
    sheet.cancel_button();
    let go = suggested("Reply");
    let s = send.clone();
    go.connect_clicked(move |_| s(false));
    let s = send.clone();
    composer.on_submit(move || s(false));
    sheet.footer.append(&go);
    sheet.present();
    composer.grab_focus();
}

pub fn clean_log(raw: &str) -> String {
    raw.split('\n')
        .map(|line| {
            let l = line.strip_prefix('\u{feff}').unwrap_or(line);
            let chars: Vec<char> = l.chars().collect();
            if chars.len() > 29 && chars.get(4) == Some(&'-') {
                if let Some(space) = l.find(' ') {
                    if (20..=34).contains(&space) {
                        return l[space + 1..].to_string();
                    }
                }
            }
            l.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn filter_errors(s: &str) -> String {
    let lines: Vec<&str> = s.split('\n').collect();
    let mut keep: Vec<String> = vec![];
    for (i, l) in lines.iter().enumerate() {
        if l.contains("##[error]") || l.to_lowercase().contains("error") || l.contains("FAILED") || l.contains('✗') {
            let from = i.saturating_sub(3);
            if keep.last().map(|x| x != "…").unwrap_or(false) {
                keep.push("…".into());
            }
            keep.extend(lines[from..=i].iter().map(|x| x.to_string()));
        }
    }
    if keep.is_empty() {
        "No error lines found".into()
    } else {
        keep.join("\n")
    }
}

struct LogText {
    text: String,
    tags: Vec<(i32, usize)>,
}

const LOG_TAGS: [(&str, &str); 3] = [("err", "#e01b24"), ("warn", "#e66100"), ("group", "#3584e4")];

fn log_text(text: String) -> LogText {
    let tags = text
        .split('\n')
        .enumerate()
        .filter_map(|(i, line)| {
            let kind = if line.contains("##[error]") {
                0
            } else if line.contains("##[warning]") {
                1
            } else if line.starts_with("##[group]") {
                2
            } else {
                return None;
            };
            Some((i as i32, kind))
        })
        .collect();
    LogText { text, tags }
}

fn log_tag_table() -> gtk::TextTagTable {
    let table = gtk::TextTagTable::new();
    for (name, color) in LOG_TAGS {
        let t = gtk::TextTag::new(Some(name));
        t.set_foreground(Some(color));
        table.add(&t);
    }
    table
}

fn log_buffer(table: &gtk::TextTagTable, log: &LogText) -> gtk::TextBuffer {
    let _span = crate::diagnostics::ui_span("cilog.render");
    let buffer = gtk::TextBuffer::new(Some(table));
    buffer.set_text(&log.text);
    let tags: Vec<Option<gtk::TextTag>> = LOG_TAGS.iter().map(|(name, _)| table.lookup(name)).collect();
    for &(line, kind) in &log.tags {
        let (Some(t), Some(start)) = (tags[kind].as_ref(), buffer.iter_at_line(line)) else { continue };
        let mut end = start;
        end.forward_to_line_end();
        buffer.apply_tag(t, &start, &end);
    }
    buffer
}

fn show_log(view: &gtk::TextView, buffer: &gtk::TextBuffer) {
    view.set_buffer(Some(buffer));
    let end = buffer.end_iter();
    let mark = buffer.create_mark(None, &end, false);
    view.scroll_mark_onscreen(&mark);
}

pub fn job_log<F>(load: F, check: CheckContext, fix: Option<Rc<dyn Fn(Option<String>)>>)
where
    F: std::future::Future<Output = crate::api::ApiResult<String>> + Send + 'static,
{
    let sheet = Sheet::new(&check.workflow_name().map(|w| format!("{w} / {}", check.title())).unwrap_or_else(|| check.title()), 980, 640);
    let stack = gtk::Stack::new();
    stack.add_named(&loading(), Some("loading"));
    let view = gtk::TextView::new();
    view.set_editable(false);
    view.set_monospace(true);
    view.add_css_class("log-view");
    view.set_left_margin(8);
    view.set_top_margin(8);
    stack.add_named(&scrolled_both(&view), Some("log"));
    stack.set_size_request(-1, 480);
    sheet.body.append(&stack);
    let errors_only = gtk::CheckButton::with_label("Errors only");
    sheet.footer.append(&errors_only);
    let copy = button("Copy");
    copy.set_sensitive(false);
    sheet.footer.append(&copy);
    if let Some(link) = check.link() {
        let open = button("Open in browser");
        open.connect_clicked(move |_| util::open_url(&link));
        sheet.footer.append(&open);
    }
    sheet.add_footer_spacer();
    let log: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    if let Some(fix) = fix {
        let b = tinted("Fix with agent", "coral");
        let d = sheet.dialog.clone();
        let l = log.clone();
        b.connect_clicked(move |_| {
            let text = l.borrow().clone();
            d.close();
            fix(text);
        });
        sheet.footer.append(&b);
    }
    let close = button("Close");
    let d = sheet.dialog.clone();
    close.connect_clicked(move |_| {
        d.close();
    });
    sheet.footer.append(&close);
    let l = log.clone();
    copy.connect_clicked(move |_| {
        if let Some(s) = l.borrow().as_ref() {
            util::copy(s);
        }
    });
    let table = log_tag_table();
    let full: Rc<RefCell<Option<gtk::TextBuffer>>> = Rc::new(RefCell::new(None));
    let errors: Rc<RefCell<Option<gtk::TextBuffer>>> = Rc::new(RefCell::new(None));
    let errors_text: Rc<RefCell<Option<LogText>>> = Rc::new(RefCell::new(None));
    let errors_buffer = {
        let table = table.clone();
        let errors = errors.clone();
        let errors_text = errors_text.clone();
        Rc::new(move || -> Option<gtk::TextBuffer> {
            if let Some(b) = errors.borrow().as_ref() {
                return Some(b.clone());
            }
            let b = log_buffer(&table, errors_text.borrow().as_ref()?);
            *errors.borrow_mut() = Some(b.clone());
            Some(b)
        })
    };
    let f = full.clone();
    let v = view.clone();
    let eb = errors_buffer.clone();
    errors_only.connect_toggled(move |c| {
        let buffer = if c.is_active() { eb() } else { f.borrow().clone() };
        if let Some(b) = buffer {
            show_log(&v, &b);
        }
    });
    sheet.present();
    crate::rt::spawn_local(async move {
        let res = crate::rt::run(load).await;
        let res = match res {
            Ok(raw) => Ok(crate::rt::blocking(move || {
                let text = clean_log(&raw);
                let errors = log_text(filter_errors(&text));
                (log_text(text), errors)
            })
            .await),
            Err(e) => Err(e),
        };
        match res {
            Ok((text, errs)) => {
                let buffer = log_buffer(&table, &text);
                *errors_text.borrow_mut() = Some(errs);
                let target = if errors_only.is_active() { errors_buffer() } else { Some(buffer.clone()) };
                *full.borrow_mut() = Some(buffer);
                if let Some(b) = target {
                    show_log(&view, &b);
                }
                *log.borrow_mut() = Some(text.text);
                copy.set_sensitive(true);
                stack.set_visible_child_name("log");
                gtk::glib::idle_add_local_once(move || {
                    errors_buffer();
                });
            }
            Err(e) => {
                stack.add_named(&error_state(&e.message, None), Some("error"));
                stack.set_visible_child_name("error");
            }
        }
    });
}

pub fn close_loop_banner(model: &Rc<PrModel>, pr: &crate::api::models::PullRequestDetail, on_dismiss: impl Fn() + 'static) -> Option<gtk::Box> {
    let ws = crate::app::try_get()?.claude.clone();
    let pending = crate::close_loop::pending(ws.review_fixes.borrow().get(&model.r), pr)?;
    let b = hbox(8);
    b.add_css_class("banner-box");
    b.add_css_class("green");
    b.set_vexpand(false);
    b.set_valign(gtk::Align::Start);
    margins(&b, 6, 16, 0, 16);
    b.append(&icon_tile("sy-comment-symbolic", "green", 18));
    b.append(&ellipsized(
        &format!(
            "{} since Fix with agent · {}",
            util::plural(pending.new_commits as i64, "new commit", "new commits"),
            util::plural(pending.threads.len() as i64, "thread still open", "threads still open")
        ),
        &["sy-text"],
    ));
    b.append(&spacer());
    let btn = tinted("Reply and resolve…", "green");
    btn.add_css_class("banner-button");
    btn.set_valign(gtk::Align::Center);
    btn.set_vexpand(false);
    let m = model.clone();
    let threads = pending.threads.clone();
    btn.connect_clicked(move |_| close_loop(m.clone(), threads.clone()));
    b.append(&btn);
    let dismiss = icon_button("sy-x-symbolic", "Dismiss");
    dismiss.add_css_class("flat");
    dismiss.set_valign(gtk::Align::Center);
    let r = model.r.clone();
    dismiss.connect_clicked(move |_| {
        ws.review_fixes.borrow_mut().remove(&r);
        on_dismiss();
    });
    b.append(&dismiss);
    Some(b)
}

pub fn close_loop(model: Rc<PrModel>, preselected: Vec<String>) {
    let Some(pr) = model.pr.borrow().clone() else { return };
    let threads: Vec<ReviewThread> = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved && t.viewer_can_reply).cloned().collect();
    let sheet = Sheet::new("Reply and resolve threads", 620, -1);
    let open: HashSet<String> = threads.iter().map(|t| t.id.clone()).collect();
    let selected: Rc<RefCell<HashSet<String>>> = Rc::new(RefCell::new(preselected.into_iter().filter(|id| open.contains(id)).collect()));
    let resolve = Rc::new(std::cell::Cell::new(true));
    let working = Rc::new(std::cell::Cell::new(false));
    let info = wrap_label("", &["sy-muted"]);
    sheet.body.append(&info);
    let head = hbox(6);
    let t = label_with("Open threads", &["sy-muted", "sy-small", "sy-bold"]);
    t.set_hexpand(true);
    head.append(&t);
    let all = link_button("All");
    let none = link_button("None");
    head.append(&all);
    head.append(&none);
    sheet.body.append(&head);
    let list = vbox(4);
    pad(&list, 8);
    if threads.is_empty() {
        list.append(&label_with("No open threads", &["sy-dim"]));
    }
    let mut rows: Vec<(String, gtk::CheckButton, gtk::Label)> = vec![];
    for th in &threads {
        let cell = vbox(1);
        let cbtn = gtk::CheckButton::new();
        cbtn.set_active(selected.borrow().contains(&th.id));
        let row = hbox(6);
        let loc = if th.path.is_empty() { "Thread".to_string() } else { format!("{}{}", th.path, th.line.or(th.original_line).map(|l| format!(":{l}")).unwrap_or_default()) };
        let p = label_with(&loc, &["sy-mono", "fg-sky", "sy-small"]);
        p.set_ellipsize(gtk::pango::EllipsizeMode::Start);
        p.set_max_width_chars(40);
        row.append(&p);
        if th.is_outdated {
            row.append(&chip("outdated", "amber", None, false));
        }
        let first = th.comments.nodes.first();
        row.append(&ellipsized(
            &format!("@{}: {}", first.and_then(|c| c.author.as_ref()).map(|a| a.login.as_str()).unwrap_or("?"), first.map(|c| c.body.replace('\n', " ")).unwrap_or_default()),
            &["sy-muted", "sy-small"],
        ));
        cbtn.set_child(Some(&row));
        cell.append(&cbtn);
        let err = wrap_label("", &["fg-red", "sy-tiny"]);
        err.set_margin_start(28);
        err.set_visible(false);
        cell.append(&err);
        list.append(&cell);
        rows.push((th.id.clone(), cbtn, err));
    }
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
    scroll.set_child(Some(&list));
    scroll.set_max_content_height(240);
    scroll.set_propagate_natural_height(true);
    sheet.body.append(&frame(&scroll, "sy-card-flat"));
    let composer = Composer::new("Reply (Markdown)", 56);
    composer.set_text(&crate::close_loop::default_reply(&pr.head_ref_oid));
    sheet.body.append(&composer.widget);
    let resolve_check = gtk::CheckButton::with_label("Resolve the threads after replying");
    resolve_check.set_active(true);
    sheet.body.append(&resolve_check);
    sheet.add_footer_spacer();
    sheet.cancel_button();
    let go = tinted("", "green");
    sheet.footer.append(&go);
    let update: Rc<dyn Fn()> = {
        let go = go.clone();
        let info = info.clone();
        let selected = selected.clone();
        let resolve = resolve.clone();
        let working = working.clone();
        let comp = composer.clone();
        Rc::new(move || {
            let n = selected.borrow().len();
            info.set_text(&format!("Posts the same reply on each selected thread{}. Use it once the fixes are pushed.", if resolve.get() { " and resolves it" } else { "" }));
            go.set_label(&if working.get() {
                "Working…".to_string()
            } else if resolve.get() {
                format!("Reply and resolve {n}")
            } else {
                format!("Reply to {n}")
            });
            go.set_sensitive(!working.get() && n > 0 && !comp.is_blank());
        })
    };
    let rows = Rc::new(rows);
    for (id, cbtn, _) in rows.iter() {
        let selected = selected.clone();
        let update = update.clone();
        let id = id.clone();
        cbtn.connect_toggled(move |c| {
            if c.is_active() {
                selected.borrow_mut().insert(id.clone());
            } else {
                selected.borrow_mut().remove(&id);
            }
            update();
        });
    }
    let r = rows.clone();
    all.connect_clicked(move |_| r.iter().for_each(|(_, c, _)| c.set_active(true)));
    let r = rows.clone();
    none.connect_clicked(move |_| r.iter().for_each(|(_, c, _)| c.set_active(false)));
    {
        let resolve = resolve.clone();
        let update = update.clone();
        resolve_check.connect_toggled(move |c| {
            resolve.set(c.is_active());
            update();
        });
    }
    {
        let update = update.clone();
        composer.on_changed(move || update());
    }
    let submit: Rc<dyn Fn()> = {
        let d = sheet.dialog.clone();
        let comp = composer.clone();
        let update = update.clone();
        Rc::new(move || {
            if working.get() || comp.is_blank() || selected.borrow().is_empty() {
                return;
            }
            let chosen: Vec<ReviewThread> = threads.iter().filter(|t| selected.borrow().contains(&t.id)).cloned().collect();
            let body = comp.text().trim().to_string();
            let resolve = resolve.get();
            working.set(true);
            for (_, _, err) in rows.iter() {
                err.set_visible(false);
            }
            update();
            let m = model.clone();
            let d = d.clone();
            let rows = rows.clone();
            let working = working.clone();
            let update = update.clone();
            crate::rt::spawn_local(async move {
                let total = chosen.len();
                let sent: HashSet<String> = chosen.iter().map(|t| t.id.clone()).collect();
                let failures = m.clone().close_loop(chosen, body, resolve).await;
                working.set(false);
                for (id, check, err) in rows.iter() {
                    if let Some(e) = failures.get(id) {
                        err.set_text(e);
                        err.set_visible(true);
                    } else if sent.contains(id) {
                        check.set_active(false);
                        err.set_visible(false);
                    }
                }
                update();
                let done = total - failures.len();
                if done > 0 {
                    let n = util::plural(done as i64, "thread", "threads");
                    crate::app::toast(&if resolve { format!("Replied and resolved {n}") } else { format!("Replied to {n}") });
                }
                if failures.is_empty() {
                    if let Some(a) = crate::app::try_get() {
                        a.claude.review_fixes.borrow_mut().remove(&m.r);
                    }
                    d.close();
                }
            });
        })
    };
    let s = submit.clone();
    go.connect_clicked(move |_| s());
    update();
    sheet.present();
}

#[derive(Clone, PartialEq, Eq)]
enum DraftPhase {
    Idle,
    LoadingFiles,
    Running,
    Ready,
    Failed(String),
}

struct DraftsSheet {
    model: Rc<PrModel>,
    pr: crate::api::models::PullRequestDetail,
    bin: Option<String>,
    dialog: adw::Dialog,
    content: gtk::Box,
    all: gtk::Button,
    none: gtk::Button,
    cancel: gtk::Button,
    go: gtk::Button,
    phase: RefCell<DraftPhase>,
    summary: RefCell<Option<String>>,
    note: RefCell<Option<String>>,
    drafts: RefCell<Vec<crate::review_drafts::ReviewDraft>>,
    rows: RefCell<Vec<(crate::review_drafts::ReviewDraft, gtk::CheckButton, Rc<Composer>)>>,
    run: RefCell<crate::review_drafts::DraftRun>,
}

pub fn review_drafts(model: Rc<PrModel>) {
    let Some(pr) = model.pr.borrow().clone() else { return };
    let sheet = Sheet::new("Draft review comments", 720, -1);
    sheet.body.append(&wrap_label(
        "The agent reads the diff and suggests inline comments. Nothing is posted: comments you keep are added to your pending review, and you submit them yourself.",
        &["sy-muted"],
    ));
    let content = vbox(8);
    sheet.body.append(&content);
    let all = link_button("All");
    let none = link_button("None");
    sheet.footer.append(&all);
    sheet.footer.append(&none);
    sheet.add_footer_spacer();
    let cancel = sheet.cancel_button();
    let go = tinted("Draft comments", "coral");
    sheet.footer.append(&go);
    let me = Rc::new(DraftsSheet {
        model,
        pr,
        bin: crate::host::claude_binary(),
        dialog: sheet.dialog.clone(),
        content,
        all: all.clone(),
        none: none.clone(),
        cancel,
        go: go.clone(),
        phase: RefCell::new(DraftPhase::Idle),
        summary: RefCell::new(None),
        note: RefCell::new(None),
        drafts: RefCell::new(vec![]),
        rows: RefCell::new(vec![]),
        run: RefCell::new(crate::review_drafts::DraftRun::default()),
    });
    let weak = Rc::downgrade(&me);
    all.connect_clicked(move |_| {
        if let Some(me) = weak.upgrade() {
            me.rows.borrow().iter().for_each(|(_, c, _)| c.set_active(true));
        }
    });
    let weak = Rc::downgrade(&me);
    none.connect_clicked(move |_| {
        if let Some(me) = weak.upgrade() {
            me.rows.borrow().iter().for_each(|(_, c, _)| c.set_active(false));
        }
    });
    let weak = Rc::downgrade(&me);
    go.connect_clicked(move |_| {
        let Some(me) = weak.upgrade() else { return };
        let phase = me.phase.borrow().clone();
        match phase {
            DraftPhase::Idle | DraftPhase::Failed(_) => me.start(),
            DraftPhase::Ready => me.accept(),
            _ => {}
        }
    });
    let held = RefCell::new(Some(me.clone()));
    sheet.dialog.connect_closed(move |_| {
        if let Some(me) = held.borrow_mut().take() {
            me.run.borrow().cancel();
        }
    });
    me.set_phase(DraftPhase::Idle);
    sheet.present();
}

impl DraftsSheet {
    fn set_phase(self: &Rc<Self>, phase: DraftPhase) {
        *self.phase.borrow_mut() = phase.clone();
        clear(&self.content);
        self.rows.borrow_mut().clear();
        match phase {
            DraftPhase::Idle => {
                if self.bin.is_none() {
                    self.content.append(&wrap_label("Install and sign in to the agent CLI first.", &["fg-amber"]));
                }
            }
            DraftPhase::LoadingFiles | DraftPhase::Running => {
                let row = hbox(8);
                row.append(&spinner(16));
                row.append(&wrap_label(if phase == DraftPhase::Running { "The agent is reading the diff. This can take a minute." } else { "Loading the diff…" }, &["sy-muted"]));
                self.content.append(&row);
            }
            DraftPhase::Failed(message) => self.content.append(&wrap_label(&message, &["fg-red"])),
            DraftPhase::Ready => self.render_drafts(),
        }
        self.update();
    }

    fn render_drafts(self: &Rc<Self>) {
        if let Some(s) = self.summary.borrow().as_deref() {
            self.content.append(&wrap_label(s, &["sy-text"]));
        }
        if let Some(n) = self.note.borrow().as_deref() {
            self.content.append(&wrap_label(n, &["sy-muted", "sy-small"]));
        }
        let drafts = self.drafts.borrow().clone();
        if drafts.is_empty() {
            self.content.append(&label_with("No comments suggested.", &["sy-dim"]));
            return;
        }
        let list = vbox(10);
        pad(&list, 8);
        let mut rows = vec![];
        for d in drafts {
            let cell = vbox(4);
            let check = gtk::CheckButton::new();
            check.set_active(true);
            let head = hbox(6);
            let color = match d.severity.as_str() {
                "bug" => "red",
                "risk" => "amber",
                _ => "slate",
            };
            head.append(&chip(&d.severity, color, None, false));
            let loc = label_with(&format!("{}:{}{}", d.path, d.line, if d.side == "LEFT" { " (old)" } else { "" }), &["sy-mono", "fg-sky", "sy-small"]);
            loc.set_ellipsize(gtk::pango::EllipsizeMode::Start);
            loc.set_max_width_chars(60);
            head.append(&loc);
            check.set_child(Some(&head));
            cell.append(&check);
            let body = Composer::new("Comment", 44);
            body.set_text(&d.body);
            body.widget.set_margin_start(28);
            cell.append(&body.widget);
            list.append(&cell);
            let weak = Rc::downgrade(self);
            check.connect_toggled(move |_| {
                if let Some(me) = weak.upgrade() {
                    me.update();
                }
            });
            let weak = Rc::downgrade(self);
            body.on_changed(move || {
                if let Some(me) = weak.upgrade() {
                    me.update();
                }
            });
            rows.push((d, check, body));
        }
        let scroll = gtk::ScrolledWindow::new();
        scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        scroll.set_child(Some(&list));
        scroll.set_max_content_height(380);
        scroll.set_propagate_natural_height(true);
        self.content.append(&frame(&scroll, "sy-card-flat"));
        *self.rows.borrow_mut() = rows;
    }

    fn chosen(&self) -> usize {
        self.rows.borrow().iter().filter(|(_, c, _)| c.is_active()).count()
    }

    fn update(&self) {
        let phase = self.phase.borrow().clone();
        let has_rows = !self.rows.borrow().is_empty();
        let ready = phase == DraftPhase::Ready;
        self.all.set_visible(ready && has_rows);
        self.none.set_visible(ready && has_rows);
        let busy = matches!(phase, DraftPhase::LoadingFiles | DraftPhase::Running);
        self.cancel.set_label(if busy { "Stop" } else { "Cancel" });
        match phase {
            DraftPhase::Idle | DraftPhase::Failed(_) => {
                self.go.set_visible(true);
                self.go.set_label("Draft comments");
                self.go.set_sensitive(self.bin.is_some());
            }
            DraftPhase::Ready => {
                let n = self.chosen();
                self.go.set_visible(true);
                self.go.set_label(&format!("Add {n} to review"));
                self.go.set_sensitive(n > 0);
            }
            _ => self.go.set_visible(false),
        }
    }

    fn start(self: &Rc<Self>) {
        let Some(bin) = self.bin.clone() else { return };
        let run = crate::review_drafts::DraftRun::default();
        *self.run.borrow_mut() = run.clone();
        self.set_phase(DraftPhase::LoadingFiles);
        let me = self.clone();
        crate::rt::spawn_local(async move {
            while me.model.files_loading.get() {
                crate::rt::sleep(std::time::Duration::from_millis(100)).await;
            }
            if !me.model.files_loaded.get() {
                me.model.clone().load_files(false).await;
            }
            if run.cancelled() {
                return;
            }
            let files = me.model.files.borrow().clone();
            if files.is_empty() {
                let message = me.model.files_error.borrow().clone().unwrap_or_else(|| "The diff couldn’t be loaded".to_string());
                me.set_phase(DraftPhase::Failed(message));
                return;
            }
            let prompt = crate::review_drafts::prompt(&me.pr, &me.model.r.repo, &files, &crate::ci_fix::nonce(), crate::review_drafts::BUDGET);
            me.set_phase(DraftPhase::Running);
            let config_dir = crate::claude::accounts::active_override();
            let text = prompt.text;
            let worker = run.clone();
            let res = crate::rt::blocking(move || worker.run_blocking(&bin, config_dir.as_deref(), text)).await;
            let parsed = res.and_then(|t| crate::review_drafts::parse(&t, &files).map_err(crate::review_drafts::RunError::Failed));
            match parsed {
                Ok(parsed) => {
                    let mut notes = vec![];
                    if parsed.dropped > 0 {
                        notes.push(format!("{} skipped because the line isn’t in the diff", util::plural(parsed.dropped as i64, "suggestion", "suggestions")));
                    }
                    if !prompt.skipped.is_empty() {
                        notes.push(format!("{} not sent (no text diff or too large)", util::plural(prompt.skipped.len() as i64, "file", "files")));
                    }
                    *me.summary.borrow_mut() = parsed.summary;
                    *me.note.borrow_mut() = if notes.is_empty() { None } else { Some(notes.join(" · ")) };
                    *me.drafts.borrow_mut() = parsed.drafts;
                    me.set_phase(DraftPhase::Ready);
                }
                Err(crate::review_drafts::RunError::Cancelled) => me.set_phase(DraftPhase::Idle),
                Err(crate::review_drafts::RunError::Failed(message)) => me.set_phase(DraftPhase::Failed(message)),
            }
        });
    }

    fn accept(&self) {
        let keep: Vec<crate::api::models::PendingComment> = self
            .rows
            .borrow()
            .iter()
            .filter(|(_, c, body)| c.is_active() && !body.is_blank())
            .map(|(d, _, body)| crate::api::models::PendingComment { id: uuid::Uuid::new_v4().to_string(), path: d.path.clone(), line: d.line, side: d.side.clone(), body: body.text() })
            .collect();
        let n = keep.len();
        self.model.pending.borrow_mut().extend(keep);
        self.model.emit(Change::Diff);
        crate::app::toast(&format!("Added {} to your pending review", util::plural(n as i64, "comment", "comments")));
        self.dialog.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdict_drives_label_colour_and_reason() {
        assert_eq!(Verdict::Approve.submit_label(), "Approve");
        assert_eq!(Verdict::Approve.tint(), "green");
        assert_eq!(Verdict::RequestChanges.tint(), "red");
        assert_eq!(Verdict::Comment.tint(), "accent");
        assert!(Verdict::Approve.blocked_reason(true, 0).is_none());
        assert!(Verdict::Comment.blocked_reason(true, 0).is_some());
        assert!(Verdict::Comment.blocked_reason(true, 2).is_none());
        assert!(Verdict::RequestChanges.blocked_reason(false, 0).is_none());
    }

    #[test]
    fn merge_primary_follows_state() {
        assert_eq!(merge_buttons(true, false, false, false, false), (MergePrimary::Merge, None));
        assert_eq!(merge_buttons(false, false, false, true, true), (MergePrimary::MergeWhenReady, Some(MergePrimary::MergeAnyway)));
        assert_eq!(merge_buttons(false, true, false, false, true), (MergePrimary::ViewConflicts, Some(MergePrimary::MergeAnyway)));
        assert_eq!(merge_buttons(false, false, true, true, true), (MergePrimary::UpdateBranch, Some(MergePrimary::MergeAnyway)));
        assert_eq!(merge_buttons(false, false, false, false, true), (MergePrimary::MergeAnyway, Some(MergePrimary::MergeWhenReady)));
        assert_eq!(merge_buttons(false, false, false, true, false), (MergePrimary::MergeAnyway, None));
    }
}
