use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use chrono::{DateTime, Utc};

use super::widgets::*;
use crate::api::models::{ItemRef, RepoRef, Route};
use crate::app::{self, PrFilter};
use crate::stack::{self, StackEntry};
use crate::ui::pr::model::PrTab;
use crate::util;

const MAX_REPOS: usize = 8;

thread_local! {
    static LAST: RefCell<Option<(String, Vec<StackEntry>, DateTime<Utc>)>> = const { RefCell::new(None) };
    static ACTIVE: RefCell<std::rc::Weak<StacksList>> = const { RefCell::new(std::rc::Weak::new()) };
}

pub fn open_first() {
    let Some(me) = ACTIVE.with(|a| a.borrow().upgrade()) else { return };
    let entry = me.entries.borrow().first().cloned();
    if let Some(e) = entry {
        if let Some(row) = me.list.row_at_index(0) {
            me.list.select_row(Some(&row));
        }
        open_entry(&e);
    }
}

fn open_entry(e: &StackEntry) {
    let r = ItemRef { repo: e.repo.clone(), number: e.tree.current };
    if let Some(m) = app::pr_model(&r) {
        match e.tree.nodes.get(&e.tree.current) {
            Some(node) => {
                let nodes = stack::store::memory_nodes(&m.api, &e.repo).unwrap_or_else(|| e.tree.nodes.values().cloned().collect());
                m.seed_stack(node, &nodes);
            }
            None => m.set_tab(PrTab::Stack),
        }
    }
    app::select(Some(Route::Pr(r)));
}

pub fn reset() {
    LAST.with(|l| l.borrow_mut().take());
}

struct StacksList {
    entries: RefCell<Vec<StackEntry>>,
    loading: Cell<bool>,
    loaded: Cell<bool>,
    error: RefCell<Option<String>>,
    updated: Cell<Option<DateTime<Utc>>>,
    generation: Cell<u64>,
    list: gtk::ListBox,
    pages: gtk::Stack,
    title: adw::WindowTitle,
    status: Rc<RefreshStatus>,
}

pub fn build() -> gtk::Widget {
    let list = gtk::ListBox::new();
    list.add_css_class("sy-list");
    list.set_selection_mode(gtk::SelectionMode::Single);
    let pages = gtk::Stack::new();
    pages.add_named(&scrolled(&list), Some("list"));
    pages.add_named(&loading(), Some("loading"));
    pages.add_named(&empty_state("sy-stack-symbolic", "indigo", "No stacked pull requests", Some("Open a pull request on another pull request's branch and it shows up here.")), Some("empty"));
    pages.add_named(&vbox(8), Some("error"));
    let title = adw::WindowTitle::new("Stacks", "");
    let holder: Rc<RefCell<Option<std::rc::Weak<StacksList>>>> = Rc::new(RefCell::new(None));
    let h = holder.clone();
    let status = RefreshStatus::new(false, move || {
        if let Some(me) = h.borrow().as_ref().and_then(|w| w.upgrade()) {
            me.reload(true);
        }
    });
    let me = Rc::new(StacksList {
        entries: RefCell::new(vec![]),
        loading: Cell::new(false),
        loaded: Cell::new(false),
        error: RefCell::new(None),
        updated: Cell::new(None),
        generation: Cell::new(0),
        list: list.clone(),
        pages: pages.clone(),
        title: title.clone(),
        status,
    });
    *holder.borrow_mut() = Some(Rc::downgrade(&me));
    ACTIVE.with(|a| *a.borrow_mut() = Rc::downgrade(&me));
    let content = vbox(0);
    content.append(&pages);
    content.append(&footer(&me.status));
    let tv = adw::ToolbarView::new();
    let hb = adw::HeaderBar::new();
    hb.set_show_end_title_buttons(false);
    hb.set_title_widget(Some(&title));
    hb.pack_end(&me.status.header_button());
    tv.add_top_bar(&hb);
    tv.set_content(Some(&content));

    let w = Rc::downgrade(&me);
    list.connect_row_activated(move |_, row| {
        let Some(me) = w.upgrade() else { return };
        let entry = me.entries.borrow().get(row.index().max(0) as usize).cloned();
        if let Some(e) = entry {
            open_entry(&e);
        }
    });
    let w = Rc::downgrade(&me);
    app::on_refresh(move |_| match w.upgrade() {
        Some(me) => {
            me.reload(true);
            true
        }
        None => false,
    });
    let w = Rc::downgrade(&me);
    app::on_live_visible(&tv, move |_| match w.upgrade() {
        Some(me) => {
            me.reload(false);
            true
        }
        None => false,
    });
    let w = Rc::downgrade(&me);
    app::get().route_changed.connect(move |_| match w.upgrade() {
        Some(me) => {
            me.sync_selection();
            true
        }
        None => false,
    });
    me.restore();
    me.reload(false);
    keep_alive(&tv, me);
    tv.upcast()
}

impl StacksList {
    fn restore(&self) {
        let account = app::cache_account();
        let last = LAST.with(|l| l.borrow().clone()).filter(|l| l.0 == account);
        if let Some((_, entries, at)) = last {
            *self.entries.borrow_mut() = entries;
            self.updated.set(Some(at));
            self.loaded.set(true);
        }
        self.render();
    }

    fn reload(self: &Rc<Self>, force: bool) {
        let Some(api) = app::api() else { return };
        let gen = self.generation.get() + 1;
        self.generation.set(gen);
        self.loading.set(true);
        self.render();
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let account = app::cache_account();
            let query = [PrFilter::Mine.query().as_str(), "is:pr", "is:open", "archived:false", "sort:updated-desc"].join(" ");
            let a = api.clone();
            let result = crate::rt::run(async move { a.search(&query, None).await }).await;
            if gen != me.generation.get() {
                return;
            }
            match result {
                Ok(r) => {
                    let mut repos: Vec<(RepoRef, bool, Vec<i64>)> = vec![];
                    for item in r.nodes.iter().filter(|i| i.is_pr()) {
                        let Some(repo) = RepoRef::from_full(&item.repository.name_with_owner) else { continue };
                        let stacked = item.stacked_on().is_some();
                        match repos.iter_mut().find(|x| x.0 == repo) {
                            Some(x) => {
                                x.1 |= stacked;
                                x.2.push(item.number);
                            }
                            None => repos.push((repo, stacked, vec![item.number])),
                        }
                    }
                    let picked: Vec<(RepoRef, bool, Vec<i64>)> = repos.iter().filter(|r| r.1).chain(repos.iter().filter(|r| !r.1)).take(MAX_REPOS).cloned().collect();
                    let mut found: Vec<StackEntry> = vec![];
                    for (repo, _, numbers) in picked {
                        let Some(nodes) = stack::store::nodes(&api, &repo, force).await else { continue };
                        if gen != me.generation.get() {
                            return;
                        }
                        found.extend(StackEntry::collect(&repo, &numbers, &nodes));
                    }
                    found.sort_by(|a, b| b.updated.cmp(&a.updated));
                    let now = Utc::now();
                    LAST.with(|l| *l.borrow_mut() = Some((account, found.clone(), now)));
                    *me.entries.borrow_mut() = found;
                    *me.error.borrow_mut() = None;
                    me.updated.set(Some(now));
                }
                Err(e) => *me.error.borrow_mut() = Some(e.message),
            }
            me.loading.set(false);
            me.loaded.set(true);
            me.render();
        });
    }

    fn render(&self) {
        let entries = self.entries.borrow().clone();
        self.title.set_subtitle(&if entries.is_empty() { String::new() } else { entries.len().to_string() });
        let err = self.error.borrow().clone();
        self.status.update(self.updated.get(), self.loading.get(), if entries.is_empty() { None } else { err.clone() });
        if entries.is_empty() {
            if let Some(e) = err {
                if let Some(page) = self.pages.child_by_name("error").and_downcast::<gtk::Box>() {
                    clear(&page);
                    let l = wrap_label(&e, &["fg-red", "sy-small"]);
                    pad(&l, 12);
                    page.append(&l);
                }
                self.pages.set_visible_child_name("error");
            } else if self.loading.get() || !self.loaded.get() {
                self.pages.set_visible_child_name("loading");
            } else {
                self.pages.set_visible_child_name("empty");
            }
            self.list.remove_all();
            return;
        }
        self.pages.set_visible_child_name("list");
        rebuild_rows(&self.list, || {
            for e in &entries {
                let row = gtk::ListBoxRow::new();
                row.set_child(Some(&entry_row(e)));
                self.list.append(&row);
            }
        });
        self.sync_selection();
    }

    fn sync_selection(&self) {
        let route = app::get().state.borrow().route.clone();
        let entries = self.entries.borrow();
        let index = match route {
            Some(Route::Pr(r)) => entries.iter().position(|e| e.repo == r.repo && e.tree.nodes.contains_key(&r.number)),
            _ => None,
        };
        match index.and_then(|i| self.list.row_at_index(i as i32)) {
            Some(row) => self.list.select_row(Some(&row)),
            None => self.list.unselect_all(),
        }
    }
}

fn entry_row(e: &StackEntry) -> gtk::Box {
    let nodes = e.tree.ordered();
    let b = vbox(4);
    b.add_css_class("stack-entry");
    margins(&b, 4, 0, 4, 0);
    let top = hbox(6);
    top.append(&colored_icon("sy-stack-symbolic", 14, "indigo"));
    let root = e.tree.nodes.get(&e.tree.root).map(|n| format!("#{} {}", n.number, n.title)).unwrap_or_default();
    let t = ellipsized(&root, &["sy-bold", "sy-text"]);
    t.set_hexpand(true);
    top.append(&t);
    b.append(&top);
    let meta = ellipsized(&format!("{} · on {} · {}", e.repo.full(), e.tree.base, util::rel(e.updated)), &["sy-muted", "sy-small"]);
    b.append(&meta);
    let bottom = hbox(6);
    let caps = hbox(3);
    caps.set_valign(gtk::Align::Center);
    for n in &nodes {
        let c = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let status = n.status();
        c.add_css_class("stack-entry-capsule");
        c.add_css_class(&format!("edge-{}", status.color()));
        c.set_size_request(12, 5);
        c.set_opacity(if e.mine.contains(&n.number) { 0.9 } else { 0.4 });
        c.set_tooltip_text(Some(&format!("#{} {} — {}", n.number, n.title, status.title())));
        caps.append(&c);
    }
    bottom.append(&caps);
    bottom.append(&label_with(&util::plural(nodes.len() as i64, "PR", "PRs"), &["sy-muted", "sy-small"]));
    if e.mine.len() < nodes.len() {
        bottom.append(&label_with(&format!("· {} yours", e.mine.len()), &["sy-dim", "sy-small"]));
    }
    let failing = nodes.iter().filter(|n| n.status().needs_attention()).count();
    if failing > 0 {
        let f = hbox(3);
        f.append(&colored_icon("sy-attention-symbolic", 12, "red"));
        f.append(&label_with(&failing.to_string(), &["fg-red", "sy-small"]));
        f.set_tooltip_text(Some(&util::plural(failing as i64, "pull request needs attention", "pull requests need attention")));
        bottom.append(&f);
    }
    b.append(&bottom);
    b
}
