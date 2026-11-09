pub mod backend;
pub mod diff_view;
pub mod files;
pub mod model;
pub mod sheets;
pub mod stack_graph;
pub mod stack_notes;
pub mod stack_tab;

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;

use self::backend::PrAction;
use self::model::{Change, PrModel, PrTab};
use super::composer::Composer;
use super::dialogs;
use super::fix_claude;
use super::html::HtmlView;
use super::menu::{context_menu, Menu};
use super::tabstrip::{TabItem, TabStrip};
use super::widgets::*;
use crate::api::code_owners::{OwnerEntry, OwnerStatus, OwnershipSummary};
use crate::api::merge_readiness::{self, MergeRequirement, RequirementAction, RequirementState};
use crate::api::risk::RiskLabel;
use crate::api::models::*;
use crate::stack::{StackNode, StackTree};
use crate::{app, util};

pub struct PrPage {
    pub model: Rc<PrModel>,
    page: gtk::glib::WeakRef<adw::NavigationPage>,
    title: adw::WindowTitle,
    actions: gtk::Box,
    busy: Loader,
    status: Rc<RefreshStatus>,
    header_box: gtk::Box,
    risk_slot: RefCell<Option<gtk::Box>>,
    banners: gtk::Box,
    tabs: Rc<TabStrip>,
    tabs_area: gtk::Stack,
    tab_stack: gtk::Stack,
    body: gtk::Stack,
    conversation: RefCell<Option<Rc<Conversation>>>,
    commits: RefCell<Option<gtk::ListBox>>,
    checks: RefCell<Option<gtk::ListBox>>,
    files: RefCell<Option<Rc<files::FilesTab>>>,
    stack_tab: RefCell<Option<Rc<stack_tab::StackTab>>>,
    jira_tab: RefCell<Option<Rc<super::jira::JiraTab>>>,
    rerequested: RefCell<Option<Vec<String>>>,
    sending_rerequest: Cell<bool>,
    replaced: Cell<bool>,
    actions_key: RefCell<String>,
    ci_session: Cell<Option<crate::claude::TabState>>,
}

pub struct Conversation {
    pub html: Rc<HtmlView>,
    composer: Rc<Composer>,
    next: gtk::Button,
    pub widget: gtk::Box,
}

impl Conversation {
    fn update_next(&self, open: usize) {
        self.next.set_visible(open > 0);
        if open > 0 {
            let text = format!("{open} unresolved · Next");
            self.next.set_child(Some(&icon_label_content("sy-down-symbolic", &text)));
            set_label(&self.next, &text);
        }
    }
}

pub fn page(r: &ItemRef) -> adw::NavigationPage {
    let Some(model) = app::pr_model(r) else {
        return adw::NavigationPage::new(&loading(), &r.title());
    };
    PrPage::new(model)
}

impl PrPage {
    pub fn new(model: Rc<PrModel>) -> adw::NavigationPage {
        let title = adw::WindowTitle::new(&model.r.title(), "");
        let header_box = vbox(8);
        margins(&header_box, 12, 16, 0, 16);
        let banners = vbox(0);
        let tabs = TabStrip::new(vec![
            TabItem { id: "conversation", title: "Conversation".into(), icon: "sy-comment-symbolic" },
            TabItem { id: "commits", title: "Commits".into(), icon: "sy-commit-symbolic" },
            TabItem { id: "checks", title: model.features.checks_title().into(), icon: "sy-checklist-symbolic" },
            TabItem { id: "files", title: "Files changed".into(), icon: "sy-file-symbolic" },
            TabItem { id: "stack", title: "Stack".into(), icon: "sy-stack-symbolic" },
            TabItem { id: "jira", title: "Jira".into(), icon: "sy-tag-symbolic" },
        ]);
        tabs.set_visible("stack", false);
        tabs.set_visible("jira", false);
        let tab_stack = gtk::Stack::new();
        tab_stack.set_transition_type(gtk::StackTransitionType::Crossfade);
        tab_stack.set_transition_duration(200);
        tab_stack.set_vexpand(true);
        let main = vbox(0);
        main.append(&header_box);
        main.append(&banners);
        tabs.widget.set_margin_top(6);
        let tabs_area = gtk::Stack::new();
        tabs_area.set_vhomogeneous(false);
        tabs_area.add_named(&tabs.widget, Some("tabs"));
        tabs_area.add_named(&tab_placeholder(), Some("placeholder"));
        main.append(&tabs_area);
        main.append(&line());
        main.append(&tab_stack);
        let body = gtk::Stack::new();
        body.add_named(&loading(), Some("loading"));
        body.add_named(&main, Some("main"));
        let (toolbar, hb, _) = toolbar_page("", "", &body);
        hb.set_title_widget(Some(&title));
        toolbar.add_css_class("sy-panel-pane");
        let actions = hbox(4);
        let busy = spinner(14);
        busy.set_visible(false);
        let holder: Rc<RefCell<Option<std::rc::Weak<PrPage>>>> = Rc::new(RefCell::new(None));
        let h = holder.clone();
        let status = RefreshStatus::new(true, move || {
            if let Some(me) = h.borrow().as_ref().and_then(|w| w.upgrade()) {
                me.model.load(true);
            }
        });
        hb.pack_end(&status.header_button());
        hb.pack_end(&actions);
        hb.pack_end(&status.widget);
        hb.pack_end(&busy);
        let page = adw::NavigationPage::new(&toolbar, &model.r.title());
        let me = Rc::new(PrPage {
            model: model.clone(),
            page: page.downgrade(),
            title,
            actions,
            busy,
            status,
            header_box,
            risk_slot: RefCell::new(None),
            banners,
            tabs,
            tabs_area,
            tab_stack,
            body,
            conversation: RefCell::new(None),
            commits: RefCell::new(None),
            checks: RefCell::new(None),
            files: RefCell::new(None),
            stack_tab: RefCell::new(None),
            jira_tab: RefCell::new(None),
            rerequested: RefCell::new(None),
            sending_rerequest: Cell::new(false),
            replaced: Cell::new(false),
            actions_key: RefCell::new(String::new()),
            ci_session: Cell::new(None),
        });
        *holder.borrow_mut() = Some(Rc::downgrade(&me));
        if let Some(a) = app::try_get() {
            let w = Rc::downgrade(&me);
            a.claude.changed.connect(move |_| {
                let Some(me) = w.upgrade() else { return false };
                if fix_claude::ci_session(&me.model.r).map(|(_, s)| s) != me.ci_session.get() {
                    let pr = me.model.pr.borrow().clone();
                    if let Some(pr) = pr {
                        me.render_banners(&pr);
                    }
                }
                true
            });
        }

        let w = Rc::downgrade(&me);
        crate::jira::on_change(move |_| match w.upgrade() {
            Some(me) => {
                me.render_jira_badge();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        me.tabs.on_change(move |id| {
            if let Some(me) = w.upgrade() {
                me.model.set_tab(PrTab::from_id(id));
            }
        });
        let w = Rc::downgrade(&me);
        model.changed.connect(move |c| match w.upgrade() {
            Some(me) => {
                me.on_change(c);
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        app::on_refresh(move |_| match w.upgrade() {
            Some(me) => {
                me.model.load(true);
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        app::on_live_visible(&toolbar, move |_| match w.upgrade() {
            Some(me) => {
                me.model.refresh_live();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        crate::theme::on_change(move |_| match w.upgrade() {
            Some(me) => {
                me.model.rerender_html();
                true
            }
            None => false,
        });
        me.show_tab();
        me.render();
        model.open();
        keep_alive(&toolbar, me);
        page
    }

    fn on_change(self: &Rc<Self>, c: &Change) {
        match c {
            Change::Pr => {
                self.render();
                if self.model.tab.get() == PrTab::Files {
                    self.model.ensure_files();
                }
            }
            Change::Busy => {
                self.busy.set_visible(self.model.busy.get());
                self.status.update(self.model.last_updated.get(), self.model.loading.get(), self.model.refresh_error.borrow().clone());
            }
            Change::Stack => self.on_stack(),
            Change::Tab => self.show_tab(),
            Change::ScrollBottom => {
                if let Some(c) = self.conversation.borrow().as_ref() {
                    c.html.scroll_to_bottom_after_load();
                }
            }
            Change::FocusThread => {
                if let Some(c) = self.conversation.borrow().as_ref() {
                    c.html.focus_next_unresolved();
                }
            }
            Change::ActionError(e) => dialogs::error(e),
            Change::Diff => {
                let pr = self.model.pr.borrow().clone();
                if let Some(pr) = pr {
                    self.render_actions(&pr);
                }
            }
            Change::Files => {
                self.render_risks();
                if self.model.tab.get() == PrTab::Files {
                    self.model.refresh_stale_files();
                }
            }
            Change::Rules => self.render_header(),
            Change::Reveal(_) => {}
        }
    }

    fn show_tab(self: &Rc<Self>) {
        let tab = self.model.tab.get();
        if self.tabs.active() != tab.id() {
            self.tabs.select(tab.id());
        }
        if self.tab_stack.child_by_name(tab.id()).is_none() {
            let w: gtk::Widget = match tab {
                PrTab::Conversation => {
                    let c = self.build_conversation();
                    let w = c.widget.clone().upcast();
                    *self.conversation.borrow_mut() = Some(c);
                    w
                }
                PrTab::Commits => {
                    let l = gtk::ListBox::new();
                    l.add_css_class("sy-list");
                    let w = Rc::downgrade(self);
                    l.connect_row_activated(move |_, row| {
                        if let Some(me) = w.upgrade() {
                            let name = row.widget_name().to_string();
                            if let Some(oid) = name.strip_prefix("commit:") {
                                app::open(Route::Commit(me.model.r.repo.clone(), oid.to_string()), true);
                            } else if name == "all-commits" {
                                if let Some(pr) = me.model.pr.borrow().as_ref() {
                                    util::open_url(&format!("{}/commits", pr.url));
                                }
                            }
                        }
                    });
                    *self.commits.borrow_mut() = Some(l.clone());
                    scrolled(&l).upcast()
                }
                PrTab::Checks => {
                    let l = gtk::ListBox::new();
                    l.add_css_class("sy-list");
                    l.set_selection_mode(gtk::SelectionMode::None);
                    *self.checks.borrow_mut() = Some(l.clone());
                    scrolled(&l).upcast()
                }
                PrTab::Files => {
                    let f = files::FilesTab::new(self.model.clone());
                    let w = f.widget.clone().upcast();
                    *self.files.borrow_mut() = Some(f);
                    w
                }
                PrTab::Stack => {
                    let tree = self.model.stack.borrow().clone();
                    match tree {
                        Some(tree) => {
                            let t = stack_tab::StackTab::new(self.model.clone(), tree);
                            let w = t.widget.clone().upcast();
                            *self.stack_tab.borrow_mut() = Some(t);
                            w
                        }
                        None => loading(),
                    }
                }
                PrTab::Jira => {
                    let t = super::jira::JiraTab::new(self.model.clone());
                    let w = t.widget.clone().upcast();
                    *self.jira_tab.borrow_mut() = Some(t);
                    w
                }
            };
            self.tab_stack.add_named(&w, Some(tab.id()));
            self.render_tabs();
        }
        self.tab_stack.set_visible_child_name(tab.id());
        if tab != PrTab::Stack {
            self.unload_stack();
        }
        if tab == PrTab::Files {
            self.model.ensure_files();
        }
    }

    fn unload_stack(&self) {
        if let Some(t) = self.stack_tab.borrow_mut().take() {
            t.close();
        }
        if let Some(w) = self.tab_stack.child_by_name(PrTab::Stack.id()) {
            self.tab_stack.remove(&w);
        }
    }

    fn on_stack(self: &Rc<Self>) {
        self.render_header();
        self.render_stack_badge();
        let tree = self.model.stack.borrow().clone();
        let tab = self.stack_tab.borrow().clone();
        match (tab, tree) {
            (Some(t), Some(tree)) => t.update(tree),
            (None, Some(_)) if self.model.tab.get() == PrTab::Stack => {
                self.unload_stack();
                self.show_tab();
            }
            _ => {}
        }
    }

    fn render_stack_badge(&self) {
        let count = self.model.stack.borrow().as_ref().map(|t| t.count());
        self.tabs.set_visible("stack", count.is_some());
        self.tabs.set_badge("stack", count.map(|c| c.to_string()).as_deref(), None);
    }

    fn build_conversation(self: &Rc<Self>) -> Rc<Conversation> {
        let html = HtmlView::new();
        let composer = Composer::new("Comment (Markdown) — Ctrl+Enter to send", 56);
        composer.widget.set_hexpand(true);
        let send = composer.send_button("Comment");
        send.set_valign(gtk::Align::End);
        let row = hbox(8);
        pad(&row, 10);
        row.append(&composer.widget);
        row.append(&send);
        let next = gtk::Button::new();
        next.add_css_class("sy-small");
        next.set_halign(gtk::Align::End);
        next.set_valign(gtk::Align::End);
        pad(&next, 10);
        next.set_tooltip_text(Some("Jump to the next unresolved thread (Ctrl+Alt+Down)"));
        next.set_visible(false);
        let m = self.model.clone();
        next.connect_clicked(move |_| m.next_unresolved_thread());
        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&html.view));
        overlay.add_overlay(&next);
        overlay.set_vexpand(true);
        let widget = vbox(0);
        widget.append(&overlay);
        widget.append(&line());
        widget.append(&row);
        let shortcuts = gtk::ShortcutController::new();
        shortcuts.set_scope(gtk::ShortcutScope::Managed);
        let m = self.model.clone();
        let action = gtk::CallbackAction::new(move |_, _| {
            if m.unresolved_threads() == 0 {
                return gtk::glib::Propagation::Proceed;
            }
            m.next_unresolved_thread();
            gtk::glib::Propagation::Stop
        });
        shortcuts.add_shortcut(gtk::Shortcut::new(gtk::ShortcutTrigger::parse_string("<Control><Alt>Down"), Some(action)));
        widget.add_controller(shortcuts);
        let c = Rc::new(Conversation { html: html.clone(), composer: composer.clone(), next, widget });
        c.update_next(self.model.unresolved_threads());
        let w = Rc::downgrade(self);
        let weak_comp = Rc::downgrade(&composer);
        let submit = Rc::new(move || {
            let Some(me) = w.upgrade() else { return };
            let Some(comp) = weak_comp.upgrade() else { return };
            if comp.is_blank() || me.model.busy.get() {
                return;
            }
            let body = comp.text();
            let comp = comp.clone();
            let m = me.model.clone();
            comp.set_busy(true);
            crate::rt::spawn_local(async move {
                let sent = m.comment(body).await;
                comp.set_busy(false);
                if sent {
                    comp.set_text("");
                }
            });
        });
        let s = submit.clone();
        send.connect_clicked(move |_| s());
        let s = submit.clone();
        composer.on_submit(move || s());
        let w = Rc::downgrade(self);
        html.on_action(move |kind, id| {
            let Some(me) = w.upgrade() else { return };
            let m = me.model.clone();
            match kind.as_str() {
                "reply" => {
                    let t = m.pr.borrow().as_ref().and_then(|p| p.review_threads.nodes.iter().find(|t| t.id == id).cloned());
                    if let Some(t) = t {
                        sheets::reply(m.clone(), t);
                    }
                }
                "resolve" => crate::rt::spawn_local(async move {
                    m.set_resolved(id, true).await;
                }),
                "unresolve" => crate::rt::spawn_local(async move {
                    m.set_resolved(id, false).await;
                }),
                "file" => m.reveal_file(&id),
                _ => {}
            }
        });
        html.on_link(|url| {
            if url == "https://github.com/" || url == "https://github.com" {
                return;
            }
            match util::parse_github_url(&url, false) {
                Some(r) => app::open(r, true),
                None => util::open_url(&url),
            }
        });
        let h = self.model.html.borrow().clone();
        if !h.is_empty() {
            html.set_html(&h);
        }
        c
    }

    fn render(self: &Rc<Self>) {
        let _span = crate::diagnostics::ui_span("pr.render");
        self.on_change(&Change::Busy);
        if self.model.not_pr.get() {
            if !self.replaced.get() {
                self.replaced.set(true);
                let child = super::issue::page_child(&self.model.r);
                if let Some(page) = self.page.upgrade() {
                    page.set_child(Some(&child));
                }
            }
            return;
        }
        let pr = self.model.pr.borrow().clone();
        let Some(pr) = pr else {
            if let Some(e) = self.model.error.borrow().clone() {
                let w = Rc::downgrade(self);
                let err = error_state(
                    &e,
                    Some(Box::new(move || {
                        if let Some(me) = w.upgrade() {
                            me.model.load(false);
                        }
                    })),
                );
                if let Some(old) = self.body.child_by_name("error") {
                    self.body.remove(&old);
                }
                self.body.add_named(&err, Some("error"));
                self.body.set_visible_child_name("error");
            } else if let Some(node) = self.model.preview.borrow().clone().filter(|_| self.model.tab.get() == PrTab::Stack && self.model.stack.borrow().is_some()) {
                self.render_preview(&node);
            } else {
                self.body.set_visible_child_name("loading");
            }
            return;
        };
        self.body.set_visible_child_name("main");
        self.tabs_area.set_visible_child_name("tabs");
        self.title.set_title(&pr.title);
        self.title.set_subtitle(&format!("{} {}{}", self.model.r.repo.full(), self.model.features.number_prefix(), pr.number));
        if let Some(page) = self.page.upgrade() {
            page.set_title(&pr.title);
        }
        self.render_header();
        self.render_banners(&pr);
        self.render_actions(&pr);
        self.render_tabs();
    }

    fn render_jira_badge(&self) {
        let keys = super::jira::keys(&self.model);
        self.tabs.set_visible("jira", crate::jira::is_configured() || !keys.is_empty());
        self.tabs.set_badge("jira", keys.first().map(String::as_str), None);
        if let Some(t) = self.jira_tab.borrow().as_ref() {
            t.update();
        }
    }

    fn render_tabs(self: &Rc<Self>) {
        let _span = crate::diagnostics::ui_span("pr.tabs");
        self.render_stack_badge();
        self.render_jira_badge();
        let pr = self.model.pr.borrow().clone();
        let Some(pr) = pr else { return };
        let unresolved = pr.review_threads.nodes.iter().filter(|t| !t.is_resolved && !t.is_outdated).count();
        self.tabs.set_badge("conversation", if unresolved > 0 { Some(unresolved.to_string()) } else { None }.as_deref(), None);
        self.tabs.set_badge("commits", Some(&pr.all_commits.total_count.unwrap_or(pr.all_commits.nodes.len() as i64).to_string()), None);
        let checks = pr.checks();
        let failed = checks.iter().filter(|c| c.outcome() == CheckOutcome::Failure).count();
        let pending = checks.iter().filter(|c| c.outcome() == CheckOutcome::Pending).count();
        let (text, color) = if checks.is_empty() {
            ("0".to_string(), "muted")
        } else if failed > 0 {
            (format!("✕{failed}"), "red")
        } else if pending > 0 {
            (format!("…{pending}"), "amber")
        } else {
            (format!("✓{}", checks.len()), "green")
        };
        self.tabs.set_badge("checks", Some(&text), Some(color));
        self.tabs.set_badge("files", Some(&pr.changed_files.to_string()), None);
        if let Some(c) = self.conversation.borrow().as_ref() {
            let h = self.model.html.borrow().clone();
            c.html.set_html(&h);
            c.update_next(self.model.unresolved_threads());
        }
        if let Some(l) = self.commits.borrow().as_ref() {
            self.render_commits(l, &pr);
        }
        if let Some(l) = self.checks.borrow().as_ref() {
            self.render_checks(l, &pr);
        }
    }

    fn render_commits(&self, l: &gtk::ListBox, pr: &PullRequestDetail) {
        l.remove_all();
        for node in pr.all_commits.nodes.iter().rev() {
            let c = &node.commit;
            let row = gtk::ListBoxRow::new();
            row.set_widget_name(&format!("commit:{}", c.oid));
            let b = hbox(10);
            margins(&b, 2, 0, 2, 0);
            let author = c.author.as_ref();
            b.append(&avatar(author.and_then(|a| a.avatar_url.as_deref()), 22, None));
            let col = vbox(2);
            col.set_hexpand(true);
            let t = wrap_label(&c.message_headline, &["sy-text"]);
            t.set_lines(2);
            t.set_ellipsize(gtk::pango::EllipsizeMode::End);
            col.append(&t);
            let who = author.and_then(|a| a.user.as_ref().map(|u| u.login.clone()).or_else(|| a.name.clone())).unwrap_or_default();
            col.append(&label_with(&format!("{who} · {}", util::rel(Some(c.committed_date))), &["sy-muted", "sy-small"]));
            b.append(&col);
            if let Some(ci) = ci_icon(c.status_check_rollup.as_ref().map(|s| s.state.as_str())) {
                b.append(&ci);
            }
            b.append(&label_with(&c.abbreviated_oid, &["sy-mono", "sy-muted", "sy-small"]));
            b.append(&icon("go-next-symbolic", 12));
            row.set_child(Some(&b));
            let oid = c.oid.clone();
            let url = c.url.clone();
            context_menu(&row, move || {
                let m = Menu::ctx();
                let o = oid.clone();
                m.item("Copy SHA", move || util::copy(&o));
                let u = url.clone();
                m.item("Open in browser", move || util::open_url(&u));
                m
            });
            l.append(&row);
        }
        let total = pr.all_commits.total_count.unwrap_or(0);
        if total > pr.all_commits.nodes.len() as i64 {
            let row = gtk::ListBoxRow::new();
            row.set_widget_name("all-commits");
            row.set_child(Some(&label_with(&format!("Show all {total} commits in browser"), &["fg-accent"])));
            l.append(&row);
        }
    }

    fn render_checks(self: &Rc<Self>, l: &gtk::ListBox, pr: &PullRequestDetail) {
        l.remove_all();
        let mut checks = pr.checks();
        checks.sort_by(|a, b| (a.outcome(), a.title()).cmp(&(b.outcome(), b.title())));
        let failed_runs: std::collections::HashSet<i64> = checks.iter().filter(|c| c.outcome() == CheckOutcome::Failure).filter_map(|c| c.run_id()).collect();
        if checks.is_empty() {
            let row = gtk::ListBoxRow::new();
            let empty = if self.model.features.is_gitlab() { "No pipeline for the latest commit" } else { "No checks for the latest commit" };
            row.set_child(Some(&label_with(empty, &["sy-muted"])));
            l.append(&row);
        }
        if self.model.features.rerun_checks && !failed_runs.is_empty() && self.model.can_write() {
            let b = icon_label_button("view-refresh-symbolic", &format!("Re-run failed jobs ({} workflow)", failed_runs.len()));
            b.add_css_class("flat");
            b.set_halign(gtk::Align::Start);
            let m = self.model.clone();
            let n = failed_runs.len() as i64;
            b.connect_clicked(move |_| {
                let m = m.clone();
                dialogs::confirm(
                    "Re-run failed jobs?",
                    Some(format!("GitHub re-runs only the failed jobs of {} on the latest commit.", util::plural(n, "workflow run", "workflow runs")).as_str()),
                    "Re-run",
                    false,
                    move || {
                        let m = m.clone();
                        crate::rt::spawn_local(async move {
                            m.rerun_failed().await;
                        });
                    },
                );
            });
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&b));
            l.append(&row);
        }
        for c in checks {
            let row = gtk::ListBoxRow::new();
            let b = hbox(10);
            margins(&b, 2, 0, 2, 0);
            b.append(&outcome_icon(c.outcome()));
            let col = vbox(1);
            col.set_hexpand(true);
            col.append(&ellipsized(&c.workflow_name().map(|w| format!("{w} / {}", c.title())).unwrap_or_else(|| c.title()), &["sy-text"]));
            let mut parts = vec![match c.outcome() {
                CheckOutcome::Success => "Successful".to_string(),
                CheckOutcome::Failure => "Failed".into(),
                CheckOutcome::Pending => {
                    if c.status.as_deref() == Some("QUEUED") {
                        "Queued".into()
                    } else {
                        "In progress".into()
                    }
                }
                CheckOutcome::Neutral => {
                    if c.conclusion.as_deref() == Some("CANCELLED") {
                        "Cancelled".into()
                    } else {
                        "Neutral".into()
                    }
                }
                CheckOutcome::Skipped => "Skipped".into(),
            }];
            if let Some(d) = c.duration() {
                parts.push(d);
            }
            if let Some(d) = c.description.clone().filter(|d| !d.is_empty()) {
                parts.push(d);
            }
            col.append(&ellipsized(&parts.join(" · "), &["sy-muted", "sy-small"]));
            b.append(&col);
            if self.model.features.job_logs && self.model.backend.can_show_log(&c) && c.outcome() != CheckOutcome::Pending && c.outcome() != CheckOutcome::Skipped {
                let log = button("Log");
                log.add_css_class("flat");
                let m = self.model.clone();
                let cc = c.clone();
                let failed = self.model.features.agent && crate::ci_fix::is_fixable(&c);
                log.connect_clicked(move |_| {
                    let fix: Option<Rc<dyn Fn(Option<String>)>> = if failed {
                        let m = m.clone();
                        let id = cc.id();
                        Some(Rc::new(move |text: Option<String>| match text {
                            Some(t) => fix_claude::show_ci_with_log(m.clone(), id.clone(), t),
                            None => fix_claude::show_ci(m.clone(), Some(id.clone())),
                        }))
                    } else {
                        None
                    };
                    let backend = m.backend.clone();
                    let r = m.r.clone();
                    let check = cc.clone();
                    sheets::job_log(async move { backend.job_log(&r, &check).await }, cc.clone(), fix);
                });
                b.append(&log);
            }
            if self.model.features.agent && crate::ci_fix::is_fixable(&c) {
                let fix = icon_label_button("sy-sparkles-symbolic", "Fix with agent");
                fix.add_css_class("flat");
                fix.set_tooltip_text(Some("Send this check's failure log to a new Claude Code session"));
                let m = self.model.clone();
                let id = c.id();
                fix.connect_clicked(move |_| fix_claude::show_ci(m.clone(), Some(id.clone())));
                b.append(&fix);
            }
            if let Some(link) = c.link() {
                let open = icon_button("sy-external-symbolic", "Open in browser");
                open.connect_clicked(move |_| util::open_url(&link));
                b.append(&open);
            }
            row.set_child(Some(&b));
            l.append(&row);
        }
    }

    fn render_header(self: &Rc<Self>) {
        let pr = self.model.pr.borrow().clone();
        let Some(pr) = pr else { return };
        clear(&self.header_box);
        let top = hbox(8);
        let t = wrap_label(&pr.title, &["sy-title", "sy-text"]);
        t.set_selectable(true);
        top.append(&t);
        top.append(&label_with(&format!("{}{}", self.model.features.number_prefix(), pr.number), &["sy-title-num"]));
        self.header_box.append(&top);
        let meta = hbox(8);
        meta.append(&state_badge(pr.visual_state(), false));
        meta.append(&avatar(pr.author.as_ref().and_then(|a| a.avatar_url.as_deref()), 18, None));
        meta.append(&label_with(pr.author.as_ref().map(|a| a.login.as_str()).unwrap_or("ghost"), &["sy-bold", "sy-text"]));
        meta.append(&branch_chip(&pr.base_ref_name, "sky"));
        meta.append(&label_with("←", &["sy-dim"]));
        meta.append(&branch_chip(&pr.head_ref_name, "violet"));
        if let Some((additions, deletions)) = self.model.diff_stat() {
            meta.append(&diff_stat(additions, deletions));
        }
        meta.append(&spacer());
        let created = label_with(&util::rel(Some(pr.created_at)), &["sy-muted"]);
        created.set_tooltip_text(Some(&util::full_date(pr.created_at)));
        meta.append(&created);
        self.header_box.append(&meta);
        let reviewers = self.model.reviewers();
        if !pr.labels.nodes.is_empty() || !reviewers.is_empty() || !pr.assignees.nodes.is_empty() {
            let row = gtk::FlowBox::new();
            row.set_selection_mode(gtk::SelectionMode::None);
            row.set_max_children_per_line(40);
            row.set_column_spacing(6);
            row.set_row_spacing(4);
            for l in &pr.labels.nodes {
                row.insert(&label_chip(l), -1);
            }
            if !reviewers.is_empty() {
                row.insert(&label_with("Reviewers:", &["sy-muted", "sy-small"]), -1);
                for r in &reviewers {
                    row.insert(&reviewer_badge(r), -1);
                }
            }
            if !pr.assignees.nodes.is_empty() {
                row.insert(&label_with("Assignees:", &["sy-muted", "sy-small"]), -1);
                for a in &pr.assignees.nodes {
                    row.insert(&tooltip(avatar(a.avatar_url.as_deref(), 18, None), &a.login), -1);
                }
            }
            self.header_box.append(&row);
        }
        let tree = self.model.stack.borrow().clone();
        if let Some(tree) = tree {
            self.header_box.append(&stack_strip(&self.model, &tree, true));
        }
        let slot = vbox(0);
        self.header_box.append(&slot);
        *self.risk_slot.borrow_mut() = Some(slot);
        self.render_risks();
        if let Some(bar) = merge_status_bar(&self.model, &pr, Rc::new({
            let m = self.model.clone();
            move || sheets::merge(m.clone())
        }), self.model.features.request_reviewers.then(|| -> Rc<dyn Fn()> {
            let m = self.model.clone();
            Rc::new(move || sheets::reviewers(m.clone()))
        })) {
            self.header_box.append(&bar);
        }
    }

    fn render_risks(&self) {
        let Some(slot) = self.risk_slot.borrow().clone() else { return };
        clear(&slot);
        let open = self.model.pr.borrow().as_ref().map(|p| p.is_open()).unwrap_or(false);
        let risks = if open { self.model.risks() } else { vec![] };
        slot.set_visible(!risks.is_empty());
        if !risks.is_empty() {
            slot.append(&risk_strip(&self.model, &risks));
        }
    }

    fn render_preview(self: &Rc<Self>, node: &StackNode) {
        self.body.set_visible_child_name("main");
        self.tabs_area.set_visible_child_name("placeholder");
        self.title.set_title(&node.title);
        self.title.set_subtitle(&format!("{} #{}", self.model.r.repo.full(), node.number));
        if let Some(page) = self.page.upgrade() {
            page.set_title(&node.title);
        }
        clear(&self.header_box);
        clear(&self.banners);
        let top = hbox(8);
        top.append(&wrap_label(&node.title, &["sy-title", "sy-text"]));
        top.append(&label_with(&format!("#{}", node.number), &["sy-title-num"]));
        let spin = spinner(16);
        spin.set_valign(gtk::Align::Center);
        top.append(&spin);
        self.header_box.append(&top);
        let meta = hbox(8);
        meta.append(&state_badge(node.visual_state(), false));
        meta.append(&label_with(node.author.as_deref().unwrap_or(""), &["sy-bold", "sy-text"]));
        meta.append(&branch_chip(&node.base_ref_name, "sky"));
        meta.append(&label_with("←", &["sy-dim"]));
        meta.append(&branch_chip(&node.head_ref_name, "violet"));
        meta.append(&spacer());
        meta.append(&shimmer(70, 12));
        self.header_box.append(&meta);
        let tree = self.model.stack.borrow().clone();
        if let Some(tree) = tree {
            self.header_box.append(&stack_strip(&self.model, &tree, false));
        }
        for _ in 0..2 {
            let bar = shimmer(-1, 30);
            bar.set_hexpand(true);
            bar.add_css_class("wide");
            self.header_box.append(&bar);
        }
        self.render_stack_badge();
        if self.tab_stack.child_by_name(PrTab::Stack.id()).is_none() {
            self.show_tab();
        }
    }

    fn render_banners(self: &Rc<Self>, pr: &PullRequestDetail) {
        clear(&self.banners);
        if !self.model.features.request_reviewers {
            return;
        }
        if let Some(b) = self.rereview_banner(pr, true) {
            self.banners.append(&b);
        }
        if !self.model.features.agent {
            return;
        }
        self.ci_session.set(fix_claude::ci_session(&self.model.r).map(|(_, s)| s));
        let m = self.model.clone();
        if let Some(b) = fix_claude::ci_banner(pr, &self.model.r, move || fix_claude::show_ci(m.clone(), None)) {
            self.banners.append(&b);
        }
        let m = self.model.clone();
        if let Some(b) = fix_claude::banner(pr, move || fix_claude::show(m.clone())) {
            self.banners.append(&b);
        }
    }

    pub fn rereview_banner(self: &Rc<Self>, pr: &PullRequestDetail, inset: bool) -> Option<gtk::Box> {
        rereview_banner(&self.model, pr, inset, self.rerequested.borrow().clone(), self.sending_rerequest.get(), {
            let w = Rc::downgrade(self);
            Rc::new(move |logins: Vec<String>| {
                let Some(me) = w.upgrade() else { return };
                me.sending_rerequest.set(true);
                me.render();
                let m = me.model.clone();
                crate::rt::spawn_local(async move {
                    let ok = m.request_reviewers(logins.clone()).await;
                    me.sending_rerequest.set(false);
                    if ok {
                        *me.rerequested.borrow_mut() = Some(logins);
                        me.render();
                        crate::rt::sleep(std::time::Duration::from_millis(2500)).await;
                        *me.rerequested.borrow_mut() = None;
                    }
                    me.render();
                });
            })
        })
    }

    fn render_actions(self: &Rc<Self>, pr: &PullRequestDetail) {
        let m = self.model.clone();
        let key = format!(
            "{}|{}|{}|{}|{}|{}|{}|{:?}|{}|{}|{}|{}",
            pr.number,
            pr.state,
            pr.is_draft,
            pr.merged,
            pr.viewer_can_update,
            pr.viewer_did_author,
            m.can_write(),
            pr.merge_state_status,
            pr.auto_merge_request.is_some(),
            pr.head_ref.is_some(),
            m.pending.borrow().len(),
            pr.head_ref_name
        ) + &format!("|{:?}|{:?}", pr.viewer_can_approve, pr.viewer_approved);
        if *self.actions_key.borrow() == key {
            return;
        }
        *self.actions_key.borrow_mut() = key;
        clear(&self.actions);
        if pr.is_open() {
            let pending = m.pending.borrow().len();
            let split = adw::SplitButton::new();
            split.set_label(&if pending == 0 { "Review".to_string() } else { format!("Review ({pending})") });
            split.set_tooltip_text(Some("Submit review"));
            let menu = Menu::new();
            let mm = m.clone();
            menu.item("Write review…", move || sheets::review(mm.clone()));
            let features = m.features;
            if pr.viewer_can_approve.unwrap_or(!pr.viewer_did_author) && pr.viewer_approved != Some(true) {
                let mm = m.clone();
                menu.item("Approve", move || {
                    let mm = mm.clone();
                    let pending = mm.pending.borrow().len();
                    let heading = if pending > 0 {
                        format!("Approve and submit {pending} pending comment{}?", if pending == 1 { "" } else { "s" })
                    } else {
                        format!("Approve this {}?", features.request_title())
                    };
                    let label = if pending > 0 { "Approve and submit" } else { "Approve" };
                    dialogs::confirm(&heading, None, label, false, move || {
                        let mm = mm.clone();
                        crate::rt::spawn_local(async move {
                            mm.submit_review("APPROVE".into(), String::new()).await;
                        });
                    });
                });
            }
            if features.revoke_approval && pr.viewer_approved == Some(true) {
                let mm = m.clone();
                menu.item("Revoke approval", move || {
                    let mm = mm.clone();
                    dialogs::confirm("Revoke your approval?", None, "Revoke approval", false, move || {
                        let mm = mm.clone();
                        crate::rt::spawn_local(async move {
                            mm.revoke_approval().await;
                        });
                    });
                });
            }
            split.set_menu_model(Some(&menu.model));
            menu.attach(&split);
            let mm = m.clone();
            split.connect_clicked(move |_| sheets::review(mm.clone()));
            self.actions.append(&split);
            if features.request_reviewers {
                let rr = icon_button("sy-person-add-symbolic", "Request or re-request review");
                let mm = m.clone();
                rr.connect_clicked(move |_| sheets::reviewers(mm.clone()));
                self.actions.append(&rr);
            }
        }
        if m.features.agent {
            let fix = icon_label_button("sy-sparkles-symbolic", "Fix with agent");
            fix.set_tooltip_text(Some("Send review comments and failing checks to a new agent session"));
            set_label(&fix, "Fix with agent");
            let mm = m.clone();
            fix.connect_clicked(move |_| fix_claude::show(mm.clone()));
            self.actions.append(&fix);
        }
        if pr.is_open() && !pr.is_draft && m.can_write() {
            let merge = icon_label_button("sy-merge-symbolic", "Merge");
            merge.add_css_class("suggested-action");
            merge.set_tooltip_text(Some(&format!("Merge {}", m.features.request_title())));
            set_label(&merge, "Merge");
            let mm = m.clone();
            merge.connect_clicked(move |_| sheets::merge(mm.clone()));
            self.actions.append(&merge);
        }
        let group = hbox(0);
        group.add_css_class("linked");
        if m.features.provider.is_github() {
            let short = super::item_row::short_link_button(&Route::Pr(m.r.clone()));
            short.remove_css_class("flat");
            group.append(&short);
        }
        let open = icon_button("sy-external-symbolic", &if m.features.provider.is_github() { "Open in browser".to_string() } else { format!("Open on {}", m.features.service_title()) });
        open.remove_css_class("flat");
        let url = pr.url.clone();
        open.connect_clicked(move |_| util::open_url(&url));
        group.append(&open);
        let more = self.more_menu(pr);
        group.append(&more.button("view-more-symbolic", "More actions"));
        self.actions.append(&group);
    }

    fn more_menu(self: &Rc<Self>, pr: &PullRequestDetail) -> Menu {
        let mut menu = Menu::new();
        let m = self.model.clone();
        let url = pr.url.clone();
        menu.item("Copy link", move || util::copy(&url));
        let f = m.features;
        if f.provider.is_github() {
            let route = Route::Pr(m.r.clone());
            menu.item("Copy short link", move || super::item_row::copy_short_link(&route));
            let cmd = format!("gh pr checkout {} -R {}", pr.number, m.r.repo.full());
            menu.item(&format!("Copy “gh pr checkout {}”", pr.number), move || util::copy(&cmd));
        } else if f.is_gitlab() {
            let cmd = format!("glab mr checkout {} -R {}", pr.number, m.r.repo.full());
            menu.item(&format!("Copy “glab mr checkout {}”", pr.number), move || util::copy(&cmd));
        }
        let head = pr.head_ref_name.clone();
        menu.item("Copy branch name", move || util::copy(&head));
        menu.section(None);
        if pr.viewer_can_update && f.editing {
            let mm = m.clone();
            menu.item("Edit title and description…", move || sheets::edit(mm.clone()));
        }
        let simple = |mm: Rc<PrModel>, action: PrAction| {
            move || {
                let mm = mm.clone();
                crate::rt::spawn_local(async move {
                    mm.simple(action).await;
                });
            }
        };
        let gitlab = f.is_gitlab();
        let request = f.request_title();
        if pr.is_open() {
            if f.request_reviewers {
                let mm = m.clone();
                menu.item("Request review…", move || sheets::reviewers(mm.clone()));
            }
            if pr.viewer_can_update && f.draft_toggle {
                if pr.is_draft {
                    menu.item(if gitlab { "Mark as ready" } else { "Ready for review" }, simple(m.clone(), PrAction::ReadyForReview));
                } else {
                    menu.item(if gitlab { "Mark as draft" } else { "Convert to draft" }, simple(m.clone(), PrAction::ConvertToDraft));
                }
            }
            let behind = if gitlab { pr.merge_state_status.as_deref() == Some("BEHIND") } else { matches!(pr.merge_state_status.as_deref(), Some("BEHIND") | Some("BLOCKED") | Some("UNSTABLE")) };
            if f.update_branch && behind {
                let label = if gitlab { format!("Rebase onto {}", pr.base_ref_name) } else { format!("Update branch from {}", pr.base_ref_name) };
                menu.item(&label, simple(m.clone(), PrAction::UpdateBranch));
            }
            if pr.auto_merge_request.is_some() {
                let mm = m.clone();
                menu.item("Disable auto-merge", move || {
                    let f = simple(mm.clone(), PrAction::DisableAutoMerge);
                    dialogs::confirm("Disable auto-merge?", None, "Disable", true, f);
                });
            }
            menu.section(None);
            if pr.viewer_can_update {
                let mm = m.clone();
                menu.item(&format!("Close {request}…"), move || {
                    let f = simple(mm.clone(), PrAction::Close);
                    dialogs::confirm(&format!("Close {request} without merging?"), None, &format!("Close {request}"), true, f);
                });
            }
        } else if !pr.merged && pr.viewer_can_update && f.reopen {
            menu.item(&format!("Reopen {request}"), simple(m.clone(), PrAction::Reopen));
        }
        if f.delete_branch && !pr.is_open() && pr.head_ref.is_some() && m.can_write() {
            let mm = m.clone();
            let head = pr.head_ref_name.clone();
            menu.item(&format!("Delete branch {head}…"), move || {
                let mm = mm.clone();
                dialogs::confirm(&format!("Delete branch {head}?"), None, "Delete branch", true, move || {
                    let mm = mm.clone();
                    crate::rt::spawn_local(async move {
                        mm.delete_branch().await;
                    });
                });
            });
        }
        menu
    }
}

pub fn reviewer_badge(r: &model::ReviewerInfo) -> gtk::Box {
    let b = hbox(3);
    b.append(&avatar(r.avatar.as_deref(), 18, None));
    let (icon_name, color, title) = match r.state.as_str() {
        "APPROVED" => ("sy-check-symbolic", "green", "approved"),
        "CHANGES_REQUESTED" => ("sy-plusminus-symbolic", "red", "changes requested"),
        "COMMENTED" => ("sy-comment-symbolic", "muted", "commented"),
        "DISMISSED" => ("sy-x-symbolic", "muted", "dismissed"),
        _ => ("sy-dot-symbolic", "amber", "review pending"),
    };
    b.append(&colored_icon(icon_name, 11, color));
    b.set_tooltip_text(Some(&format!("{}: {title}", r.login)));
    b
}

pub struct MergeStatus {
    pub icon: &'static str,
    pub color: &'static str,
    pub text: String,
    pub ready: bool,
}

pub fn merge_status(pr: &PullRequestDetail, requirements: &[MergeRequirement]) -> MergeStatus {
    let checks = pr.checks();
    let breakdown = merge_readiness::check_breakdown(&checks, None);
    let noun = if breakdown.required_known { "required check" } else { "check" };
    let failed = breakdown.failed_required().len();
    let pending = breakdown.running_required().len();
    let failed_text = if failed == 1 { format!("1 {noun} failed") } else { format!("{failed} {noun}s failed") };
    let pending_text = if pending == 1 { format!("1 {noun} is still running") } else { format!("{pending} {noun}s are still running") };
    let any_failed = checks.iter().filter(|c| c.outcome() == CheckOutcome::Failure).count();
    let any_pending = checks.iter().filter(|c| c.outcome() == CheckOutcome::Pending).count();
    let first = |state: RequirementState| requirements.iter().find(|r| r.state == state).map(|r| r.title.clone());
    let s = |icon: &'static str, color: &'static str, text: String, ready: bool| MergeStatus { icon, color, text, ready };
    if pr.is_draft {
        return s("sy-pr-draft-symbolic", "slate", "Draft — merging is unavailable".into(), false);
    }
    if let Some(entry) = &pr.merge_queue_entry {
        let text = if pr.forge_merge.is_none() { entry.summary() } else { merge_readiness::train_wording(&entry.summary()) };
        return if entry.failing() { s("sy-attention-symbolic", "red", text, false) } else { s("sy-archive-symbolic", "green", text, false) };
    }
    if pr.mergeable == "CONFLICTING" || pr.merge_state_status.as_deref() == Some("DIRTY") {
        return s("sy-attention-symbolic", "red", format!("Has conflicts with {}", pr.base_ref_name), false);
    }
    match pr.merge_state_status.as_deref() {
        Some("BEHIND") => s("sy-down-symbolic", "amber", format!("Branch is behind {}", pr.base_ref_name), false),
        Some("BLOCKED") if pr.merge_blocker.is_some() => {
            let blocker = pr.merge_blocker.clone().unwrap_or_default();
            let pipeline = blocker.starts_with("Pipeline");
            let icon = if pipeline && failed == 0 { "sy-clock-symbolic" } else { "sy-lock-symbolic" };
            s(icon, "amber", if pipeline && failed > 0 { failed_text } else { blocker }, false)
        }
        Some("BLOCKED") => match pr.review_decision.as_deref() {
            Some("CHANGES_REQUESTED") => s("sy-plusminus-symbolic", "red", "Changes requested".into(), false),
            Some("REVIEW_REQUIRED") => s("sy-eye-symbolic", "amber", "Review required".into(), false),
            _ => {
                if failed > 0 {
                    s("sy-x-circle-symbolic", "red", failed_text, false)
                } else if let Some(t) = first(RequirementState::Missing) {
                    s("sy-lock-symbolic", "amber", t, false)
                } else if pending > 0 {
                    s("sy-clock-symbolic", "amber", pending_text, false)
                } else if let Some(t) = first(RequirementState::Pending) {
                    s("sy-clock-symbolic", "amber", t, false)
                } else {
                    s("sy-lock-symbolic", "amber", "Blocked by branch protection".into(), false)
                }
            }
        },
        Some("UNSTABLE") => {
            if any_failed > 0 {
                let t = if any_failed == 1 { "1 check failed".to_string() } else { format!("{any_failed} checks failed") };
                s("sy-attention-symbolic", "amber", format!("Can be merged, but {t}"), true)
            } else if any_pending > 0 {
                let t = if any_pending == 1 { "1 check is still running".to_string() } else { format!("{any_pending} checks are still running") };
                s("sy-clock-symbolic", "amber", t, true)
            } else {
                s("sy-check-circle-symbolic", "green", "Ready to merge".into(), true)
            }
        }
        Some("CLEAN") | Some("HAS_HOOKS") => s("sy-check-circle-symbolic", "green", "Ready to merge".into(), true),
        _ => s("sy-clock-symbolic", "slate", "Checking mergeability…".into(), false),
    }
}

thread_local! {
    static REQUIREMENTS_EXPANDED: Cell<bool> = const { Cell::new(true) };
}

pub fn merge_status_bar(model: &Rc<PrModel>, pr: &PullRequestDetail, on_merge: Rc<dyn Fn()>, on_request_review: Option<Rc<dyn Fn()>>) -> Option<gtk::Box> {
    if !pr.is_open() {
        return None;
    }
    let requirements = model.requirements();
    let st = merge_status(pr, &requirements);
    let outer = vbox(6);
    outer.add_css_class("banner-box");
    outer.add_css_class(st.color);
    let b = hbox(8);
    b.append(&colored_icon(st.icon, 16, st.color));
    b.append(&wrap_label(&st.text, &["sy-text"]));
    if let Some(auto) = &pr.auto_merge_request {
        let method = auto.merge_method.as_deref().map(|m| format!(" ({})", sheets::MergeMethod::from_key(m).map(|x| x.title()).unwrap_or(m))).unwrap_or_default();
        b.append(&label_with(&format!("· auto-merge enabled{method}"), &["fg-green"]));
    }
    let checks = pr.checks();
    if !checks.is_empty() {
        let failed = checks.iter().filter(|c| c.outcome() == CheckOutcome::Failure).count();
        let pending = checks.iter().filter(|c| c.outcome() == CheckOutcome::Pending).count();
        let ok = checks.iter().filter(|c| c.outcome() == CheckOutcome::Success).count();
        let btn = gtk::Button::new();
        btn.add_css_class("flat");
        btn.set_tooltip_text(Some(model.features.checks_title()));
        let c = hbox(6);
        let add = |icon_name: &str, n: usize, color: &str| {
            let x = hbox(2);
            x.append(&colored_icon(icon_name, 12, color));
            x.append(&label_with(&n.to_string(), &[&format!("fg-{color}"), "sy-small"]));
            x
        };
        if failed > 0 {
            c.append(&add("sy-x-symbolic", failed, "red"));
        }
        if pending > 0 {
            c.append(&add("sy-clock-symbolic", pending, "amber"));
        }
        c.append(&add("sy-check-symbolic", ok, "green"));
        btn.set_child(Some(&c));
        let m = model.clone();
        btn.connect_clicked(move |_| m.set_tab(PrTab::Checks));
        b.append(&btn);
    }
    b.append(&spacer());
    if model.features.update_branch && pr.merge_state_status.as_deref() == Some("BEHIND") && (model.can_write() || pr.viewer_can_update) {
        let u = button(model.features.update_branch_title());
        let m = model.clone();
        u.connect_clicked(move |_| {
            let m = m.clone();
            crate::rt::spawn_local(async move {
                if m.clone().simple(PrAction::UpdateBranch).await && m.features.is_gitlab() {
                    app::toast("Rebase started");
                }
            });
        });
        b.append(&u);
    }
    if model.can_write() && !pr.is_draft {
        let mbtn = if st.ready { tinted("Merge…", "green") } else { button("Merge…") };
        mbtn.connect_clicked(move |_| on_merge());
        b.append(&mbtn);
    }
    outer.append(&b);
    if !requirements.is_empty() {
        let list = requirements_list(model, pr, &requirements, on_request_review);
        let expanded = REQUIREMENTS_EXPANDED.with(Cell::get);
        list.set_visible(expanded);
        let toggle = gtk::Button::new();
        toggle.add_css_class("flat");
        let sync = {
            let toggle = toggle.clone();
            move |open: bool| {
                toggle.set_icon_name(if open { "pan-down-symbolic" } else { "pan-end-symbolic" });
                let label = if open { "Hide merge requirements" } else { "Show merge requirements" };
                toggle.set_tooltip_text(Some(label));
                toggle.update_property(&[gtk::accessible::Property::Label(label)]);
            }
        };
        sync(expanded);
        let l = list.clone();
        toggle.connect_clicked(move |_| {
            let open = !REQUIREMENTS_EXPANDED.with(Cell::get);
            REQUIREMENTS_EXPANDED.with(|c| c.set(open));
            l.set_visible(open);
            sync(open);
        });
        b.append(&toggle);
        outer.append(&list);
    }
    Some(outer)
}

fn risk_strip(model: &Rc<PrModel>, risks: &[RiskLabel]) -> gtk::FlowBox {
    let row = gtk::FlowBox::new();
    row.set_selection_mode(gtk::SelectionMode::None);
    row.set_max_children_per_line(40);
    row.set_column_spacing(6);
    row.set_row_spacing(4);
    row.update_property(&[gtk::accessible::Property::Label("Look closer")]);
    row.insert(&label_with("Look closer:", &["sy-muted", "sy-small"]), -1);
    for r in risks {
        let btn = gtk::Button::new();
        btn.add_css_class("flat");
        btn.set_child(Some(&chip(&r.title, if r.strong() { "amber" } else { "muted" }, Some(r.icon()), false)));
        btn.set_valign(gtk::Align::Center);
        btn.set_tooltip_text(Some(&r.tooltip()));
        set_label(&btn, &r.title);
        btn.update_property(&[gtk::accessible::Property::Description(&r.detail)]);
        let first = r.files.first().cloned();
        let m = model.clone();
        btn.connect_clicked(move |_| {
            if let Some(path) = &first {
                m.reveal_file(path);
            }
        });
        row.insert(&btn, -1);
    }
    row
}

fn requirements_list(model: &Rc<PrModel>, pr: &PullRequestDetail, requirements: &[MergeRequirement], on_request_review: Option<Rc<dyn Fn()>>) -> gtk::Box {
    let list = vbox(4);
    list.update_property(&[gtk::accessible::Property::Label("Merge requirements")]);
    let mut ordered: Vec<&MergeRequirement> = requirements.iter().collect();
    ordered.sort_by_key(|r| r.state);
    for r in ordered {
        let (icon_name, color, spoken) = match r.state {
            RequirementState::Satisfied => ("sy-check-circle-symbolic", "green", "met"),
            RequirementState::Missing => ("sy-x-circle-symbolic", "red", "blocking"),
            RequirementState::Pending => ("sy-clock-symbolic", "amber", "in progress"),
            RequirementState::Unknown => ("dialog-question-symbolic", "slate", "unknown"),
            RequirementState::Advisory => ("dialog-information-symbolic", "slate", "doesn’t block"),
        };
        let row = hbox(8);
        let ic = colored_icon(icon_name, 14, color);
        ic.set_valign(gtk::Align::Start);
        row.append(&ic);
        let text = vbox(1);
        text.set_hexpand(true);
        let title = wrap_label(&r.title, &[if r.state == RequirementState::Satisfied { "sy-muted" } else { "sy-text" }]);
        title.set_xalign(0.0);
        text.append(&title);
        if let Some(d) = &r.detail {
            let dl = wrap_label(d, &["sy-muted", "sy-small"]);
            dl.set_xalign(0.0);
            text.append(&dl);
        }
        row.append(&text);
        if let Some(action) = r.action.filter(|_| r.state != RequirementState::Satisfied) {
            let allowed = match action {
                RequirementAction::RequestReview => model.features.request_reviewers && on_request_review.is_some() && (model.can_write() || pr.viewer_did_author),
                RequirementAction::UpdateBranch => false,
                RequirementAction::ReadyForReview => pr.viewer_can_update,
                _ => true,
            };
            if allowed {
                let label = match action {
                    RequirementAction::RequestReview => "Request review",
                    RequirementAction::ShowChecks => "Show checks",
                    RequirementAction::ShowConversation => "Show conversation",
                    RequirementAction::ShowConflicts => "View conflicts",
                    RequirementAction::UpdateBranch => "Update branch",
                    RequirementAction::ReadyForReview if model.features.is_gitlab() => "Mark as ready",
                    RequirementAction::ReadyForReview => "Ready for review",
                };
                let btn = link_button(label);
                btn.set_valign(gtk::Align::Start);
                let m = model.clone();
                let review = on_request_review.clone();
                btn.connect_clicked(move |_| match action {
                    RequirementAction::RequestReview => {
                        if let Some(f) = &review {
                            f();
                        }
                    }
                    RequirementAction::ShowChecks => m.set_tab(PrTab::Checks),
                    RequirementAction::ShowConversation => m.next_unresolved_thread(),
                    RequirementAction::ShowConflicts => {
                        m.set_tab(PrTab::Conversation);
                        m.emit(Change::ScrollBottom);
                    }
                    RequirementAction::UpdateBranch => {
                        let m = m.clone();
                        crate::rt::spawn_local(async move {
                            m.simple(PrAction::UpdateBranch).await;
                        });
                    }
                    RequirementAction::ReadyForReview => {
                        let m = m.clone();
                        crate::rt::spawn_local(async move {
                            m.simple(PrAction::ReadyForReview).await;
                        });
                    }
                });
                row.append(&btn);
            }
        }
        row.update_property(&[gtk::accessible::Property::Description(spoken)]);
        list.append(&row);
    }
    if let Some(ownership) = model.ownership().filter(|o| !o.groups.is_empty() || !o.unowned.is_empty()) {
        let can_request = on_request_review.is_some() && (model.can_write() || pr.viewer_did_author);
        list.append(&code_owners_section(&ownership, on_request_review.filter(|_| can_request)));
    }
    list
}

const OWNER_GROUP_LIMIT: usize = 6;

fn files_count(n: usize) -> String {
    if n == 1 {
        "1 file".to_string()
    } else {
        format!("{n} files")
    }
}

fn owner_label(o: &OwnerEntry) -> gtk::Label {
    let class = match o.status {
        OwnerStatus::Approved => "fg-green",
        OwnerStatus::ChangesRequested => "fg-red",
        OwnerStatus::Requested => "fg-amber",
        OwnerStatus::NotRequested => "sy-text",
    };
    let l = label_with(&format!("@{}", o.handle), &[class]);
    l.set_tooltip_text(Some(&format!("@{}: {}", o.handle, o.status.title())));
    l.update_property(&[gtk::accessible::Property::Label(&format!("{}, {}", o.handle, o.status.title()))]);
    l
}

fn code_owners_section(summary: &OwnershipSummary, on_request_review: Option<Rc<dyn Fn()>>) -> gtk::Box {
    let section = vbox(4);
    section.update_property(&[gtk::accessible::Property::Label("Code owners")]);
    let head = hbox(6);
    head.append(&label_with("Code owners", &["sy-muted", "sy-small", "sy-bold"]));
    head.append(&ellipsized(&summary.source_path, &["sy-dim", "sy-small", "sy-mono"]));
    head.append(&spacer());
    if let Some(f) = on_request_review.filter(|_| !summary.suggestions(&Default::default()).is_empty()) {
        let btn = link_button("Request owners");
        btn.connect_clicked(move |_| f());
        head.append(&btn);
    }
    section.append(&head);
    for group in summary.groups.iter().take(OWNER_GROUP_LIMIT) {
        let row = hbox(8);
        let satisfied = group.satisfied();
        let ic = if satisfied { colored_icon("sy-check-circle-symbolic", 14, "green") } else { colored_icon("sy-person-symbolic", 14, "slate") };
        ic.set_valign(gtk::Align::Start);
        decorative(&ic);
        row.append(&ic);
        let owners = hbox(6);
        for o in &group.owners {
            owners.append(&owner_label(o));
        }
        row.append(&owners);
        let files = label_with(&files_count(group.files.len()), &["sy-muted", "sy-small"]);
        files.set_tooltip_text(Some(&group.files.join("\n")));
        row.append(&files);
        section.append(&row);
    }
    if summary.groups.len() > OWNER_GROUP_LIMIT {
        let more = label_with(&format!("+{} more owner groups", summary.groups.len() - OWNER_GROUP_LIMIT), &["sy-muted", "sy-small"]);
        more.set_xalign(0.0);
        more.set_margin_start(22);
        section.append(&more);
    }
    if !summary.unowned.is_empty() {
        let row = hbox(8);
        let ic = colored_icon("dialog-question-symbolic", 14, "amber");
        decorative(&ic);
        row.append(&ic);
        let l = label_with(&format!("{} without a code owner", files_count(summary.unowned.len())), &["sy-muted", "sy-small"]);
        l.set_tooltip_text(Some(&summary.unowned.join("\n")));
        row.append(&l);
        section.append(&row);
    }
    section
}

pub fn rereview_banner(model: &Rc<PrModel>, pr: &PullRequestDetail, inset: bool, requested: Option<Vec<String>>, sending: bool, send: Rc<dyn Fn(Vec<String>)>) -> Option<gtk::Box> {
    let stale = model.stale_reviews();
    let logins: Vec<String> = stale.iter().map(|s| s.0.clone()).collect();
    let can_act = pr.is_open() && (pr.viewer_did_author || pr.viewer_can_update);
    let b = hbox(8);
    b.add_css_class("banner-box");
    b.add_css_class("sky");
    if inset {
        margins(&b, 6, 16, 0, 16);
    }
    if let Some(req) = requested {
        b.append(&colored_icon("sy-check-symbolic", 14, "green"));
        b.append(&label_with("Requested", &["sy-bold", "sy-text"]));
        b.append(&ellipsized(&format!("· Review re-requested from {}", req.iter().map(|l| format!("@{l}")).collect::<Vec<_>>().join(", ")), &["sy-muted"]));
        return Some(b);
    }
    if !can_act || logins.is_empty() {
        return None;
    }
    b.append(&icon_tile("view-refresh-symbolic", "sky", 18));
    let who = if stale.len() == 1 {
        format!("@{}", stale[0].0)
    } else {
        let names: Vec<String> = stale.iter().map(|s| format!("@{}", s.0)).collect();
        format!("{} and {}", names[..names.len() - 1].join(", "), names[names.len() - 1])
    };
    let counts: Vec<usize> = stale.iter().filter_map(|s| s.1).collect();
    let what = if counts.len() == stale.len() {
        counts.iter().max().map(|n| util::plural(*n as i64, "commit", "commits")).unwrap_or_else(|| "new commits".into())
    } else {
        "new commits".to_string()
    };
    let message = if pr.viewer_did_author {
        format!("You pushed {what} after {who} reviewed")
    } else {
        let mut c = what.chars();
        let cap = c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default();
        format!("{cap} pushed after {who} reviewed")
    };
    let msg = ellipsized(&message, &["sy-text"]);
    msg.set_hexpand(false);
    b.append(&msg);
    if let Some(d) = pr.last_commit_date() {
        b.append(&label_with(&format!("· {}", util::rel(Some(d))), &["sy-muted"]));
    }
    b.append(&spacer());
    let other = button("Other…");
    let m = model.clone();
    other.connect_clicked(move |_| sheets::reviewers(m.clone()));
    b.append(&other);
    let btn = gtk::Button::new();
    btn.add_css_class("tint-sky");
    let c = hbox(5);
    if sending {
        c.append(&spinner(12));
    } else {
        c.append(&icon("view-refresh-symbolic", 12));
    }
    c.append(&gtk::Label::new(Some(&if logins.len() == 1 { "Re-request review".to_string() } else { format!("Re-request review ({})", logins.len()) })));
    btn.set_child(Some(&c));
    btn.set_sensitive(!sending && !model.busy.get());
    btn.connect_clicked(move |_| send(logins.clone()));
    b.append(&btn);
    Some(b)
}

fn shimmer(width: i32, height: i32) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    b.add_css_class("shimmer");
    b.set_size_request(width, height);
    b.set_valign(gtk::Align::Center);
    b
}

fn tab_placeholder() -> gtk::Box {
    let b = hbox(14);
    margins(&b, 10, 20, 10, 20);
    for w in [96, 80, 70, 110] {
        b.append(&shimmer(w, 14));
    }
    let stack = hbox(6);
    stack.append(&icon("sy-stack-symbolic", 14));
    stack.append(&label_with("Stack", &["sy-bold", "sy-text"]));
    b.append(&stack);
    b
}

pub fn stack_strip(model: &Rc<PrModel>, tree: &StackTree, interactive: bool) -> gtk::Box {
    let line = tree.line();
    let index = line.iter().position(|n| n.number == tree.current).unwrap_or(0);
    let ups: Vec<StackNode> = tree.kids(tree.current).iter().filter_map(|n| tree.nodes.get(n).cloned()).collect();
    let b = hbox(6);
    b.add_css_class("stack-strip");
    let show = gtk::Button::new();
    show.add_css_class("flat");
    show.set_hexpand(true);
    let c = hbox(8);
    c.append(&colored_icon("sy-stack-symbolic", 14, "indigo"));
    c.append(&label_with("Stack", &["sy-bold", "sy-text"]));
    c.append(&label_with(&format!("{} of {}", index + 1, line.len()), &["sy-muted"]));
    let pills = hbox(3);
    for s in &line {
        let p = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let current = s.number == tree.current;
        p.set_size_request(if current { 18 } else { 10 }, 5);
        p.set_valign(gtk::Align::Center);
        p.add_css_class(&format!("edge-{}", if current { "indigo" } else { s.visual_state().css() }));
        if !current {
            p.set_opacity(0.55);
        }
        p.set_tooltip_text(Some(&format!("#{} {}", s.number, s.title)));
        pills.append(&p);
    }
    c.append(&pills);
    if tree.count() > line.len() {
        let extra = tree.count() - line.len();
        let l = label_with(&format!("+{extra}"), &["sy-muted", "sy-small"]);
        l.set_tooltip_text(Some(&util::plural(extra as i64, "more pull request on another branch of the stack", "more pull requests on other branches of the stack")));
        c.append(&l);
    }
    c.append(&spacer());
    show.set_child(Some(&c));
    show.set_tooltip_text(Some("Show the whole stack"));
    let m = model.clone();
    show.connect_clicked(move |_| {
        if interactive {
            m.set_tab(PrTab::Stack);
        }
    });
    b.append(&show);
    let repo = model.r.repo.clone();
    let nav = |s: &StackNode, icon_name: &str, help: &str| {
        let btn = gtk::Button::new();
        btn.add_css_class("flat");
        btn.set_child(Some(&icon_label_content(icon_name, &format!("#{}", s.number))));
        btn.set_tooltip_text(Some(&format!("{help}: #{} {}", s.number, s.title)));
        let r = ItemRef { repo: repo.clone(), number: s.number };
        btn.connect_clicked(move |_| app::open(Route::Pr(r.clone()), false));
        btn
    };
    if let Some(down) = tree.parent.get(&tree.current).and_then(|p| tree.nodes.get(p)) {
        b.append(&nav(down, "sy-down-symbolic", "Down the stack"));
    }
    if ups.len() == 1 {
        b.append(&nav(&ups[0], "sy-up-symbolic", "Up the stack"));
    } else if ups.len() > 1 {
        let menu = Menu::new();
        for s in &ups {
            let r = ItemRef { repo: repo.clone(), number: s.number };
            menu.item(&format!("#{} {}", s.number, s.title), move || app::open(Route::Pr(r.clone()), false));
        }
        let mb = gtk::MenuButton::new();
        mb.add_css_class("flat");
        mb.set_child(Some(&icon_label_content("sy-up-symbolic", &ups.len().to_string())));
        mb.set_tooltip_text(Some(&format!("Up the stack: {} pull requests are stacked on this one", ups.len())));
        set_label(&mb, &format!("Up the stack, {} pull requests", ups.len()));
        menu.apply_to(&mb);
        b.append(&mb);
    }
    let more = icon_button("go-next-symbolic", "Show the whole stack");
    let m = model.clone();
    more.connect_clicked(move |_| {
        if interactive {
            m.set_tab(PrTab::Stack);
        }
    });
    b.append(&more);
    b
}
