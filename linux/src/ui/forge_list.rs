use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use adw::prelude::*;
use chrono::{DateTime, Utc};
use gtk::glib;

use super::item_row::{describe_row, item_menu, item_row};
use super::lists::{group_header, state_toggles, StateFilter};
use super::menu::context_menu;
use super::widgets::*;
use crate::api::models::{Route, SearchItem};
use crate::api::ApiResult;
use crate::app::{self, IssueFilter, PrFilter};
use crate::forge::ForgeClient;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Pulls(PrFilter),
    PullsByProject,
    Issues(IssueFilter),
}

impl Kind {
    pub fn key(&self) -> String {
        match self {
            Kind::Pulls(f) => format!("pr-{}", f.key()),
            Kind::PullsByProject => "pr-grouped".into(),
            Kind::Issues(f) => format!("issue-{}", f.key()),
        }
    }

    pub fn grouped(&self) -> bool {
        *self == Kind::PullsByProject
    }

    pub fn title(&self) -> String {
        match self {
            Kind::Pulls(f) => f.title().into(),
            Kind::PullsByProject => format!("My {}s by project", app::provider().request_short()),
            Kind::Issues(f) => format!("Issues: {}", f.title()),
        }
    }

    async fn fetch(self, forge: ForgeClient, state: StateFilter) -> ApiResult<Vec<SearchItem>> {
        match self {
            Kind::Pulls(f) => forge.pull_requests(f, state).await,
            Kind::PullsByProject => forge.pull_requests(PrFilter::Mine, state).await,
            Kind::Issues(f) => forge.issues(f, state).await,
        }
    }
}

thread_local! {
    static CACHE: RefCell<HashMap<String, (Vec<SearchItem>, DateTime<Utc>)>> = RefCell::new(HashMap::new());
}

pub fn reset_cache() {
    CACHE.with(|c| c.borrow_mut().clear());
}

pub fn cached_items() -> Vec<SearchItem> {
    let prefix = format!("{}\n", app::cache_account());
    CACHE.with(|c| c.borrow().iter().filter(|(k, _)| k.starts_with(&prefix)).flat_map(|(_, (items, _))| items.clone()).collect())
}

fn cache_key(kind: Kind, state: StateFilter) -> String {
    format!("{}\n{}\n{}", app::cache_account(), kind.key(), state.title())
}

fn matches(item: &SearchItem, text: &str) -> bool {
    if text.is_empty() {
        return true;
    }
    let text = text.to_lowercase();
    let author = item.author.as_ref().map(|a| a.login.as_str()).unwrap_or("");
    text.split_whitespace().all(|word| {
        if let Some(repo) = word.strip_prefix("repo:") {
            return item.repository.name_with_owner.to_lowercase().contains(repo);
        }
        if let Some(label) = word.strip_prefix("label:") {
            return item.labels().iter().any(|l| l.name.to_lowercase().contains(label));
        }
        item.title.to_lowercase().contains(word) || item.repository.name_with_owner.to_lowercase().contains(word) || author.to_lowercase().contains(word) || item.number.to_string() == word.trim_start_matches(['#', '!'])
    })
}

struct ForgeList {
    kind: Kind,
    collapsed: RefCell<HashSet<String>>,
    state: Rc<Cell<StateFilter>>,
    items: RefCell<Vec<SearchItem>>,
    loading: Cell<bool>,
    refreshing: Cell<bool>,
    error: RefCell<Option<String>>,
    updated: Cell<Option<DateTime<Utc>>>,
    generation: Cell<u64>,
    text: RefCell<String>,
    list: gtk::ListBox,
    keys: RefCell<Vec<Option<Route>>>,
    title: adw::WindowTitle,
    spinner: Loader,
    status: Rc<RefreshStatus>,
    stack: gtk::Stack,
    rendered: RefCell<String>,
    search: gtk::SearchEntry,
    status_key: RefCell<String>,
    me: RefCell<std::rc::Weak<ForgeList>>,
}

impl ForgeList {
    fn reload(self: &Rc<Self>, silent: bool) {
        let Some(forge) = app::forge() else { return };
        let kind = self.kind;
        let state = self.state.get();
        let key = cache_key(kind, state);
        let gen = self.generation.get() + 1;
        self.generation.set(gen);
        if !silent {
            match CACHE.with(|c| c.borrow().get(&key).cloned()) {
                Some((items, at)) => {
                    *self.items.borrow_mut() = items;
                    self.updated.set(Some(at));
                }
                None => {
                    self.items.borrow_mut().clear();
                    self.updated.set(None);
                    self.loading.set(true);
                }
            }
            *self.error.borrow_mut() = None;
        }
        self.refreshing.set(true);
        self.render();
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let result = crate::rt::run(kind.fetch(forge, state)).await;
            if gen != me.generation.get() {
                return;
            }
            match result {
                Ok(items) => {
                    super::forge_view::remember(&items);
                    let now = Utc::now();
                    CACHE.with(|c| c.borrow_mut().insert(key, (items.clone(), now)));
                    *me.items.borrow_mut() = items;
                    me.updated.set(Some(now));
                    *me.error.borrow_mut() = None;
                }
                Err(e) => *me.error.borrow_mut() = Some(e.message),
            }
            me.loading.set(false);
            me.refreshing.set(false);
            me.render();
        });
    }

    fn render(&self) {
        let text = self.text.borrow().clone();
        let items: Vec<SearchItem> = self.items.borrow().iter().filter(|i| matches(i, &text)).cloned().collect();
        self.title.set_subtitle(&if items.is_empty() { String::new() } else { items.len().to_string() });
        let loading = self.loading.get();
        self.spinner.set_visible(self.refreshing.get() && !items.is_empty());
        let err = self.error.borrow().clone();
        self.status.update(self.updated.get(), self.refreshing.get(), if items.is_empty() { None } else { err.clone() });
        if items.is_empty() {
            if loading {
                self.stack.set_visible_child_name("loading");
            } else if let Some(e) = err {
                if let Some(page) = self.stack.child_by_name("error").and_downcast::<gtk::Box>() {
                    let weak = self.me.borrow().clone();
                    set_status(&page, &error_state(&e, Some(Box::new(move || {
                        if let Some(me) = weak.upgrade() {
                            me.reload(false);
                        }
                    }))));
                }
                self.status_key.borrow_mut().clear();
                self.stack.set_visible_child_name("error");
            } else {
                self.show_empty(&text);
                self.stack.set_visible_child_name("empty");
            }
            self.list.remove_all();
            self.keys.borrow_mut().clear();
            self.rendered.borrow_mut().clear();
            return;
        }
        self.stack.set_visible_child_name("list");
        let mut sig = serde_json::to_string(&items).unwrap_or_default();
        for item in &items {
            sig.push('|');
            sig.push_str(&crate::util::rel(Some(item.updated_at)));
        }
        if self.kind.grouped() {
            let mut collapsed: Vec<String> = self.collapsed.borrow().iter().cloned().collect();
            collapsed.sort();
            sig.push_str(&format!("|{}|{}", collapsed.join(","), text.is_empty()));
        }
        if *self.rendered.borrow() != sig {
            *self.rendered.borrow_mut() = sig;
            rebuild_rows(&self.list, || {
                let keys = if self.kind.grouped() { self.grouped_rows(&items, text.is_empty()) } else { items.iter().map(|i| self.append_item(i, true)).collect() };
                *self.keys.borrow_mut() = keys;
            });
        }
        self.sync_selection();
    }

    fn show_empty(&self, filter: &str) {
        let Some(page) = self.stack.child_by_name("empty").and_downcast::<gtk::Box>() else { return };
        let state = self.state.get();
        let key = format!("{filter}|{}", state.title());
        if *self.status_key.borrow() == key && page.first_child().is_some() {
            return;
        }
        *self.status_key.borrow_mut() = key;
        if filter.is_empty() {
            let noun = app::provider().request_title().to_lowercase();
            let copy = match self.kind {
                Kind::Pulls(f) => super::empty_copy::prs(f, &noun, state),
                Kind::PullsByProject => super::empty_copy::prs(PrFilter::Mine, &noun, state),
                Kind::Issues(f) => super::empty_copy::issues(f, state),
            };
            set_status(&page, &empty_note(&copy.title, Some(&copy.message)));
        } else {
            let entry = self.search.clone();
            set_status(&page, &no_matches(filter, move || entry.set_text("")));
        }
    }

    fn append_item(&self, item: &SearchItem, show_repo: bool) -> Option<Route> {
        let row = gtk::ListBoxRow::new();
        row.set_child(Some(&item_row(item, show_repo)));
        describe_row(&row, item);
        let it = item.clone();
        context_menu(&row, move || item_menu(&it));
        self.list.append(&row);
        Some(item.route())
    }

    fn grouped_rows(&self, items: &[SearchItem], text_empty: bool) -> Vec<Option<Route>> {
        let mut keys = vec![];
        for (repo, group) in group_by_repo(items) {
            let open = !self.collapsed.borrow().contains(&repo) || !text_empty;
            let row = gtk::ListBoxRow::new();
            row.set_widget_name(&format!("group:{repo}"));
            row.set_child(Some(&group_header(&repo, group.len(), open)));
            row.set_selectable(false);
            set_label(&row, &format!("{repo}, {} items", group.len()));
            set_expanded(&row, open);
            self.list.append(&row);
            keys.push(None);
            if open {
                for item in group {
                    keys.push(self.append_item(item, false));
                }
            }
        }
        keys
    }

    fn sync_selection(&self) {
        let route = app::get().state.borrow().route.clone();
        let keys = self.keys.borrow();
        match route.and_then(|r| keys.iter().position(|k| k.as_ref() == Some(&r))) {
            Some(i) => {
                if let Some(row) = self.list.row_at_index(i as i32) {
                    self.list.select_row(Some(&row));
                }
            }
            None => self.list.unselect_all(),
        }
    }
}

pub fn group_by_repo(items: &[SearchItem]) -> Vec<(String, Vec<&SearchItem>)> {
    let mut order: Vec<(String, Vec<&SearchItem>)> = vec![];
    for item in items {
        let repo = &item.repository.name_with_owner;
        match order.iter_mut().find(|(r, _)| r == repo) {
            Some((_, group)) => group.push(item),
            None => order.push((repo.clone(), vec![item])),
        }
    }
    order
}

pub fn build(kind: Kind) -> gtk::Widget {
    let list = gtk::ListBox::new();
    list.add_css_class("sy-list");
    list.set_selection_mode(gtk::SelectionMode::Single);
    let title = adw::WindowTitle::new(&kind.title(), "");
    let spinner = spinner(14);
    spinner.set_visible(false);
    let stack = gtk::Stack::new();
    let search = gtk::SearchEntry::new();
    let (toggles, state) = state_toggles(|_| {});
    let holder: Rc<RefCell<Option<std::rc::Weak<ForgeList>>>> = Rc::new(RefCell::new(None));
    let h = holder.clone();
    let status = RefreshStatus::new(false, move || {
        if let Some(me) = h.borrow().as_ref().and_then(|w| w.upgrade()) {
            me.reload(false);
        }
    });
    let me = Rc::new(ForgeList {
        kind,
        collapsed: RefCell::new(HashSet::new()),
        state,
        items: RefCell::new(vec![]),
        loading: Cell::new(false),
        refreshing: Cell::new(false),
        error: RefCell::new(None),
        updated: Cell::new(None),
        generation: Cell::new(0),
        text: RefCell::new(String::new()),
        list: list.clone(),
        keys: RefCell::new(vec![]),
        title: title.clone(),
        spinner: spinner.clone(),
        status,
        stack: stack.clone(),
        rendered: RefCell::new(String::new()),
        search: search.clone(),
        status_key: RefCell::new(String::new()),
        me: RefCell::new(std::rc::Weak::new()),
    });
    *holder.borrow_mut() = Some(Rc::downgrade(&me));
    *me.me.borrow_mut() = Rc::downgrade(&me);

    let mut child = toggles.first_child();
    while let Some(w) = child {
        if let Ok(t) = w.clone().downcast::<gtk::ToggleButton>() {
            let weak = Rc::downgrade(&me);
            t.connect_toggled(move |t| {
                if t.is_active() {
                    if let Some(me) = weak.upgrade() {
                        glib::idle_add_local_once(move || me.reload(false));
                    }
                }
            });
        }
        child = w.next_sibling();
    }

    search.set_placeholder_text(Some("Filter: text, repo:name, label:bug"));
    search.set_hexpand(true);
    let weak = Rc::downgrade(&me);
    search.connect_search_changed(move |e| {
        if let Some(me) = weak.upgrade() {
            *me.text.borrow_mut() = e.text().trim().to_string();
            me.render();
        }
    });

    let weak = Rc::downgrade(&me);
    list.connect_row_activated(move |_, row| {
        let Some(me) = weak.upgrade() else { return };
        let route = me.keys.borrow().get(row.index().max(0) as usize).cloned().flatten();
        match route {
            Some(route) => app::select(Some(route)),
            None => {
                if let Some(group) = row.widget_name().strip_prefix("group:") {
                    let g = group.to_string();
                    let mut c = me.collapsed.borrow_mut();
                    if !c.remove(&g) {
                        c.insert(g);
                    }
                    drop(c);
                    me.render();
                }
            }
        }
    });

    stack.add_named(&scrolled(&list), Some("list"));
    stack.add_named(&loading(), Some("loading"));
    stack.add_named(&vbox(0), Some("empty"));
    stack.add_named(&vbox(0), Some("error"));

    let toggles_bar = hbox(0);
    margins(&toggles_bar, 6, 10, 6, 10);
    toggles.set_hexpand(true);
    toggles_bar.append(&toggles);

    let content = vbox(0);
    content.append(&toggles_bar);
    content.append(&line());
    content.append(&stack);
    content.append(&footer(&me.status));

    let tv = adw::ToolbarView::new();
    let hb = adw::HeaderBar::new();
    hb.set_show_end_title_buttons(false);
    hb.set_title_widget(Some(&title));
    hb.pack_end(&me.status.header_button());
    hb.pack_end(&spinner);
    let search_bar = gtk::SearchBar::new();
    search_bar.set_child(Some(&search));
    search_bar.connect_entry(&search);
    let search_btn = gtk::ToggleButton::new();
    search_btn.set_icon_name("system-search-symbolic");
    search_btn.set_tooltip_text(Some("Filter"));
    set_label(&search_btn, "Filter");
    search_btn.bind_property("active", &search_bar, "search-mode-enabled").bidirectional().build();
    hb.pack_start(&search_btn);
    tv.add_top_bar(&hb);
    tv.add_top_bar(&search_bar);
    tv.set_content(Some(&content));

    let weak = Rc::downgrade(&me);
    app::on_refresh(move |_| match weak.upgrade() {
        Some(me) => {
            me.reload(true);
            true
        }
        None => false,
    });
    let weak = Rc::downgrade(&me);
    app::on_live_visible(&tv, move |_| match weak.upgrade() {
        Some(me) => {
            me.reload(true);
            true
        }
        None => false,
    });
    let weak = Rc::downgrade(&me);
    app::get().route_changed.connect(move |_| match weak.upgrade() {
        Some(me) => {
            me.sync_selection();
            true
        }
        None => false,
    });
    me.reload(false);
    keep_alive(&tv, me);
    tv.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item() -> SearchItem {
        serde_json::from_value(serde_json::json!({
            "__typename": "PullRequest",
            "number": 12,
            "title": "Add caching layer",
            "url": "https://gitlab.com/g/app/-/merge_requests/12",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z",
            "author": { "login": "alice" },
            "repository": { "nameWithOwner": "g/app" },
            "labels": { "nodes": [{ "name": "backend", "color": "ff0000" }] },
            "forge": true
        }))
        .unwrap()
    }

    #[test]
    fn groups_keep_first_seen_order() {
        let mut a = item();
        a.repository.name_with_owner = "z/last".into();
        let b = item();
        let mut c = item();
        c.repository.name_with_owner = "z/last".into();
        let items = vec![a, b, c];
        let groups = group_by_repo(&items);
        assert_eq!(groups.iter().map(|(r, g)| (r.as_str(), g.len())).collect::<Vec<_>>(), [("z/last", 2), ("g/app", 1)]);
        assert_eq!(Kind::Issues(IssueFilter::Mine).key(), "issue-mine");
        assert!(Kind::PullsByProject.grouped());
    }

    #[test]
    fn local_filter() {
        let i = item();
        assert!(i.forge);
        assert!(matches(&i, ""));
        assert!(matches(&i, "caching"));
        assert!(matches(&i, "repo:app label:back"));
        assert!(matches(&i, "!12"));
        assert!(matches(&i, "alice"));
        assert!(!matches(&i, "label:docs"));
    }
}
