use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use serde::Deserialize;

use super::sidebar::ui_activate;
use super::widgets::*;
use crate::api::models::{Route, SearchItem};
use crate::app::{self, PrFilter, Section};
use crate::util;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Tile {
    Mine,
    ReadyToMerge,
    Failing,
    ChangesRequested,
    Assigned,
    Mentioned,
    Reviewed,
    Inbox,
}

impl Tile {
    pub const ALL: [Tile; 8] = [Tile::Mine, Tile::ReadyToMerge, Tile::Failing, Tile::ChangesRequested, Tile::Assigned, Tile::Mentioned, Tile::Reviewed, Tile::Inbox];

    pub fn key(&self) -> &'static str {
        match self {
            Tile::Mine => "mine",
            Tile::ReadyToMerge => "readyToMerge",
            Tile::Failing => "failing",
            Tile::ChangesRequested => "changesRequested",
            Tile::Assigned => "assigned",
            Tile::Mentioned => "mentioned",
            Tile::Reviewed => "reviewed",
            Tile::Inbox => "inbox",
        }
    }

    pub fn title(&self) -> &'static str {
        match self {
            Tile::Mine => "My pull requests",
            Tile::ReadyToMerge => "Ready to merge",
            Tile::Failing => "Failing checks",
            Tile::ChangesRequested => "Changes requested",
            Tile::Assigned => "Assigned to me",
            Tile::Mentioned => "Mentioned",
            Tile::Reviewed => "Reviewed by me",
            Tile::Inbox => "Unread inbox",
        }
    }

    fn icon(&self) -> &'static str {
        match self {
            Tile::Mine => "sy-person-symbolic",
            Tile::ReadyToMerge => "sy-merge-symbolic",
            Tile::Failing => "sy-x-circle-symbolic",
            Tile::ChangesRequested => "sy-plusminus-symbolic",
            Tile::Assigned => "sy-clock-symbolic",
            Tile::Mentioned => "sy-at-symbolic",
            Tile::Reviewed => "sy-check-symbolic",
            Tile::Inbox => "sy-bell-symbolic",
        }
    }

    fn tint(&self) -> &'static str {
        match self {
            Tile::Mine => "violet",
            Tile::ReadyToMerge => "green",
            Tile::Failing => "red",
            Tile::ChangesRequested => "amber",
            Tile::Assigned => "teal",
            Tile::Mentioned => "indigo",
            Tile::Reviewed => "sky",
            Tile::Inbox => "slate",
        }
    }

    fn section(&self) -> Section {
        match self {
            Tile::Mine | Tile::ReadyToMerge | Tile::Failing | Tile::ChangesRequested => Section::Prs(PrFilter::Mine),
            Tile::Assigned => Section::Prs(PrFilter::Assigned),
            Tile::Mentioned => Section::Prs(PrFilter::Mentioned),
            Tile::Reviewed => Section::Prs(PrFilter::Reviewed),
            Tile::Inbox => Section::Notifications,
        }
    }

    fn refine(&self) -> Option<&'static str> {
        match self {
            Tile::ReadyToMerge => Some("review:approved status:success"),
            Tile::Failing => Some("status:failure"),
            Tile::ChangesRequested => Some("review:changes_requested"),
            _ => None,
        }
    }

    pub fn query(&self) -> Option<String> {
        let base = |f: PrFilter| format!("{} is:pr is:open archived:false", f.query());
        match self {
            Tile::Mine | Tile::Inbox => None,
            Tile::ReadyToMerge | Tile::Failing | Tile::ChangesRequested => Some(format!("{} {}", base(PrFilter::Mine), self.refine().unwrap_or_default())),
            Tile::Assigned => Some(base(PrFilter::Assigned)),
            Tile::Mentioned => Some(base(PrFilter::Mentioned)),
            Tile::Reviewed => Some(base(PrFilter::Reviewed)),
        }
    }
}

pub fn counts_query() -> (String, serde_json::Value) {
    let kinds: Vec<Tile> = Tile::ALL.into_iter().filter(|t| t.query().is_some()).collect();
    let params = kinds.iter().map(|k| format!("${}: String!", k.key())).collect::<Vec<_>>().join(", ");
    let fields = kinds.iter().map(|k| format!("{0}: search(type: ISSUE, first: 0, query: ${0}) {{ issueCount }}", k.key())).collect::<Vec<_>>().join(" ");
    let mut vars = serde_json::Map::new();
    for k in &kinds {
        vars.insert(k.key().to_string(), serde_json::Value::String(k.query().unwrap_or_default()));
    }
    (format!("query({params}) {{ {fields} }}"), serde_json::Value::Object(vars))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Count {
    issue_count: i64,
}

pub fn greeting(hour: u32) -> &'static str {
    match hour {
        5..=11 => "Good morning",
        12..=17 => "Good afternoon",
        _ => "Good evening",
    }
}

thread_local! {
    static COUNTS: RefCell<HashMap<Tile, i64>> = RefCell::new(HashMap::new());
    static LOADED_AT: Cell<Option<chrono::DateTime<chrono::Utc>>> = const { Cell::new(None) };
    static LOADING: Cell<bool> = const { Cell::new(false) };
}

pub fn cached_count(t: Tile) -> Option<i64> {
    let a = app::try_get()?;
    match t {
        Tile::Mine => {
            let s = a.state.borrow();
            s.last_badge_refresh.map(|_| s.my_pr_count)
        }
        Tile::Inbox => Some(a.state.borrow().unread_count as i64),
        _ => COUNTS.with(|c| c.borrow().get(&t).copied()),
    }
}

struct Overview {
    widget: gtk::Widget,
    greeting: gtk::Label,
    summary: gtk::Label,
    hero: gtk::Box,
    tiles: Vec<(Tile, gtk::Label, Cell<i64>)>,
    agents: gtk::Box,
    recent: gtk::Box,
    status: Rc<RefreshStatus>,
}

fn animate_count(label: &gtk::Label, from: i64, to: i64) {
    if from == to || !super::logo::animations_enabled() {
        label.set_text(&util::thousands(to));
        return;
    }
    let l = label.clone();
    let target = adw::CallbackAnimationTarget::new(move |v| l.set_text(&util::thousands(v.round() as i64)));
    let anim = adw::TimedAnimation::new(label, from as f64, to as f64, 600, target);
    anim.set_easing(adw::Easing::EaseOutCubic);
    anim.play();
}

fn item_button(item: &SearchItem) -> gtk::Button {
    let b = gtk::Button::new();
    b.add_css_class("flat");
    let row = hbox(8);
    let state = item.visual_state();
    let glyph = colored_icon(state.compact_icon(), 12, state.css());
    glyph.set_valign(gtk::Align::Start);
    glyph.set_margin_top(3);
    row.append(&glyph);
    let col = vbox(1);
    col.set_hexpand(true);
    let t = ellipsized(&item.title, &["sy-text"]);
    col.append(&t);
    col.append(&ellipsized(&format!("{}#{}", item.repository.name_with_owner, item.number), &["sy-muted", "sy-small", "sy-mono"]));
    row.append(&col);
    if let Some(ci) = ci_chip(item.ci_state().as_deref()) {
        row.append(&ci);
    }
    b.set_child(Some(&row));
    b.set_tooltip_text(Some(&item.title));
    set_label(&b, &item.title);
    let route = item.route();
    b.connect_clicked(move |_| app::open(route.clone(), false));
    b
}

fn card(class: &str) -> gtk::Box {
    let b = vbox(8);
    b.add_css_class("next-card");
    if !class.is_empty() {
        b.add_css_class(class);
    }
    b
}

impl Overview {
    fn new() -> Rc<Self> {
        let column = vbox(22);
        column.set_margin_top(28);
        column.set_margin_bottom(28);
        column.set_margin_start(32);
        column.set_margin_end(32);
        let clamp = adw::Clamp::new();
        clamp.set_maximum_size(980);
        clamp.set_child(Some(&column));

        let header = hbox(12);
        let greeting = label_with("", &["sy-display"]);
        greeting.set_hexpand(true);
        greeting.set_ellipsize(gtk::pango::EllipsizeMode::End);
        header.append(&greeting);
        let summary = label_with("", &["sy-muted", "sy-meta-num"]);
        summary.set_valign(gtk::Align::End);
        header.append(&summary);
        column.append(&header);

        let hero = vbox(10);
        column.append(&hero);

        let grid = gtk::Grid::new();
        grid.set_column_spacing(14);
        grid.set_row_spacing(14);
        grid.set_column_homogeneous(true);
        let mut tiles = vec![];
        for (i, t) in Tile::ALL.into_iter().enumerate() {
            let b = gtk::Button::new();
            b.add_css_class("next-card");
            let inner = vbox(6);
            let top = hbox(8);
            top.append(&icon_tile(t.icon(), t.tint(), 26));
            top.append(&spacer());
            inner.append(&top);
            let n = label_with("–", &["sy-title", "sy-meta-num"]);
            inner.append(&n);
            inner.append(&ellipsized(t.title(), &["sy-muted", "sy-small"]));
            b.set_child(Some(&inner));
            set_label(&b, t.title());
            b.connect_clicked(move |_| app::set_section(t.section()));
            grid.attach(&b, (i % 4) as i32, (i / 4) as i32, 1, 1);
            tiles.push((t, n, Cell::new(-1)));
        }
        column.append(&grid);

        let agents = card("");
        column.append(&agents);
        let recent = vbox(8);
        column.append(&recent);

        let scroll = scrolled(&clamp);
        let holder: Rc<RefCell<Option<std::rc::Weak<Overview>>>> = Rc::new(RefCell::new(None));
        let h = holder.clone();
        let status = RefreshStatus::new(true, move || {
            if let Some(me) = h.borrow().as_ref().and_then(|w| w.upgrade()) {
                me.load(true);
            }
        });
        let (tv, hb, _) = toolbar_page("Overview", "", &scroll);
        hb.pack_end(&status.detail_pill());
        tv.add_css_class("sy-panel-pane");
        tv.add_css_class("empty-hero");
        let me = Rc::new(Overview { widget: tv.upcast(), greeting, summary, hero, tiles, agents, recent, status });
        *holder.borrow_mut() = Some(Rc::downgrade(&me));
        let w = Rc::downgrade(&me);
        app::on_badges(move |_| match w.upgrade() {
            Some(me) => {
                me.render();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        app::get().claude.changed.connect(move |_| match w.upgrade() {
            Some(me) => {
                me.render_agents();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        app::get().account_changed.connect(move |_| match w.upgrade() {
            Some(me) => {
                COUNTS.with(|c| c.borrow_mut().clear());
                LOADED_AT.with(|c| c.set(None));
                me.load(true);
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        app::on_refresh(move |_| match w.upgrade() {
            Some(me) => {
                me.load(true);
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        me.widget.connect_map(move |_| {
            if let Some(me) = w.upgrade() {
                me.render();
                me.load(false);
            }
        });
        me.render();
        me
    }

    fn load(self: &Rc<Self>, force: bool) {
        let Some(api) = app::api() else { return };
        if LOADING.with(|l| l.get()) {
            return;
        }
        let fresh = LOADED_AT.with(|c| c.get()).is_some_and(|t| (chrono::Utc::now() - t).num_seconds() < 120);
        if !force && fresh && COUNTS.with(|c| !c.borrow().is_empty()) {
            return;
        }
        LOADING.with(|l| l.set(true));
        self.status.update(LOADED_AT.with(|c| c.get()), true, None);
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let (query, vars) = counts_query();
            let res = crate::rt::run(async move { api.graphql::<HashMap<String, Option<Count>>>("overviewCounts", &query, vars, false).await }).await;
            LOADING.with(|l| l.set(false));
            let error = match res {
                Ok(map) => {
                    COUNTS.with(|c| {
                        let mut c = c.borrow_mut();
                        for t in Tile::ALL {
                            if let Some(Some(n)) = map.get(t.key()) {
                                c.insert(t, n.issue_count);
                            }
                        }
                    });
                    LOADED_AT.with(|c| c.set(Some(chrono::Utc::now())));
                    None
                }
                Err(e) => Some(e.message),
            };
            me.status.update(LOADED_AT.with(|c| c.get()), false, error);
            me.render();
        });
    }

    fn render(&self) {
        let a = app::get();
        let (user, rr, rr_count) = {
            let s = a.state.borrow();
            (s.user.clone(), s.review_requests.clone(), s.review_request_count)
        };
        let name = user.as_ref().map(|u| u.name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| u.login.clone())).unwrap_or_default();
        let first = name.split_whitespace().next().unwrap_or("").to_string();
        let hour = chrono::Timelike::hour(&chrono::Local::now());
        self.greeting.set_text(&if first.is_empty() { greeting(hour).to_string() } else { format!("{}, {first}", greeting(hour)) });
        let running = a.claude.running_count();
        let mut parts = vec![if rr_count == 1 { "1 review waiting".to_string() } else { format!("{rr_count} reviews waiting") }];
        if running > 0 {
            parts.push(util::plural(running as i64, "agent running", "agents running"));
        }
        let unread = a.state.borrow().unread_count;
        if unread > 0 {
            parts.push(format!("{unread} unread"));
        }
        self.summary.set_text(&parts.join(" · "));
        self.render_hero(&rr, rr_count);
        for (t, label, shown) in &self.tiles {
            match cached_count(*t) {
                Some(n) => {
                    let from = shown.get().max(0);
                    if shown.get() != n {
                        animate_count(label, from, n);
                        shown.set(n);
                    }
                }
                None => label.set_text("–"),
            }
        }
        self.render_agents();
        self.render_recent(&rr);
    }

    fn render_hero(&self, rr: &[SearchItem], count: i64) {
        clear(&self.hero);
        let c = card("");
        if rr.is_empty() {
            let row = hbox(16);
            row.append(&Loader::hero(96, "overview-calm"));
            let texts = vbox(4);
            texts.set_valign(gtk::Align::Center);
            texts.append(&label_with("Calm waters", &["sy-display"]));
            texts.append(&wrap_label("No reviews are waiting for you. New requests land here first.", &["sy-muted"]));
            row.append(&texts);
            c.append(&row);
        } else {
            let head = hbox(8);
            head.append(&colored_icon("sy-eye-symbolic", 14, "sky"));
            let title = if count == 1 { "1 review waiting for you".to_string() } else { format!("{count} reviews waiting for you") };
            let t = label_with(&title, &["sy-heading", "sy-text"]);
            t.set_hexpand(true);
            head.append(&t);
            let all = link_button("Show all");
            all.connect_clicked(|_| app::set_section(Section::Prs(PrFilter::ReviewRequested)));
            head.append(&all);
            c.append(&head);
            for item in rr.iter().take(5) {
                c.append(&item_button(item));
            }
        }
        self.hero.append(&c);
    }

    fn render_agents(&self) {
        clear(&self.agents);
        let a = app::get();
        let running = a.claude.running_count();
        let attention = a.claude.attention_count();
        let row = hbox(10);
        row.append(&icon_tile("sy-sparkles-symbolic", "coral", 30));
        let texts = vbox(2);
        texts.set_hexpand(true);
        texts.append(&label_with("Agents", &["sy-heading", "sy-text"]));
        let line = if attention > 0 {
            format!("{} · {}", util::plural(attention as i64, "session needs you", "sessions need you"), util::plural(running as i64, "running", "running"))
        } else if running > 0 {
            util::plural(running as i64, "session running", "sessions running")
        } else {
            "No sessions running. Hand review comments or failing checks to an agent.".to_string()
        };
        texts.append(&wrap_label(&line, &["sy-muted", "sy-small"]));
        row.append(&texts);
        if running > 0 || attention > 0 {
            let open = tinted("Open Agents", "coral");
            open.set_valign(gtk::Align::Center);
            open.connect_clicked(|_| app::set_section(Section::Claude));
            row.append(&open);
        } else {
            let new = button("New session");
            new.set_valign(gtk::Align::Center);
            new.connect_clicked(|_| ui_activate("agents-new-session"));
            row.append(&new);
        }
        self.agents.append(&row);
    }

    fn render_recent(&self, rr: &[SearchItem]) {
        clear(&self.recent);
        let shown: Vec<Route> = rr.iter().take(5).map(|i| i.route()).collect();
        let recent: Vec<Route> = app::recent_routes().into_iter().filter(|r| !shown.contains(r)).take(8).collect();
        if recent.is_empty() {
            return;
        }
        self.recent.append(&label_with("RECENTLY OPENED", &["sy-eyebrow"]));
        let flow = gtk::FlowBox::new();
        flow.set_selection_mode(gtk::SelectionMode::None);
        flow.set_max_children_per_line(8);
        flow.set_column_spacing(6);
        flow.set_row_spacing(6);
        for r in recent {
            let Some(text) = r.short_link() else { continue };
            let b = gtk::Button::new();
            b.add_css_class("status-chip-button");
            b.set_child(Some(&status_chip(&text, "slate", Some(if matches!(r, Route::Issue(_)) { "sy-issue-symbolic" } else { "sy-pr-symbolic" }))));
            b.set_tooltip_text(Some(&format!("Open {text}")));
            set_label(&b, &format!("Open {text}"));
            b.connect_clicked(move |_| app::open(r.clone(), false));
            flow.insert(&b, -1);
        }
        self.recent.append(&flow);
    }
}

pub fn build() -> gtk::Widget {
    let o = Overview::new();
    let w = o.widget.clone();
    keep_alive(&w, o);
    w
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_query_has_one_field_per_searchable_tile() {
        let (q, vars) = counts_query();
        assert!(q.starts_with("query($readyToMerge: String!"));
        assert!(q.contains("failing: search(type: ISSUE, first: 0, query: $failing) { issueCount }"));
        assert!(!q.contains("inbox:"));
        assert!(!q.contains("mine:"));
        assert_eq!(vars.as_object().map(|o| o.len()), Some(6));
        assert!(vars["failing"].as_str().unwrap_or("").ends_with("status:failure"));
    }

    #[test]
    fn greeting_follows_time_of_day() {
        assert_eq!(greeting(8), "Good morning");
        assert_eq!(greeting(14), "Good afternoon");
        assert_eq!(greeting(22), "Good evening");
        assert_eq!(greeting(3), "Good evening");
    }
}
