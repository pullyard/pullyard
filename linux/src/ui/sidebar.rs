use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;

use super::menu::Menu;
use super::widgets::*;
use crate::app::{self, IssueFilter, PrFilter, Section};
use crate::{brand, updater};

struct Row {
    section: Section,
    title: String,
    list: gtk::ListBox,
    row: gtk::ListBoxRow,
    count: gtk::Label,
}

pub struct Sidebar {
    pub widget: gtk::Widget,
    rows: RefCell<Vec<Row>>,
    column: gtk::Box,
    update_row: gtk::Button,
    update_label: gtk::Label,
    footer: gtk::Box,
    today: gtk::Button,
    today_lines: gtk::Box,
}

fn sidebar_icon(icon_name: &str) -> gtk::Box {
    let b = fixed_box(&[], 20, 20);
    let i = icon(icon_name, 15);
    i.add_css_class("sy-sidebar-glyph");
    centered_in(&b, &i, 20, 20);
    decorative(&b);
    b
}

impl Sidebar {
    pub fn new() -> Rc<Self> {
        let column = vbox(0);
        let scroll = scrolled(&column);

        let update_row = gtk::Button::new();
        update_row.add_css_class("flat");
        update_row.add_css_class("update-row");
        let ub = hbox(8);
        ub.append(&colored_icon("sy-download-symbolic", 14, "sky"));
        let update_label = label_with("", &["sy-text"]);
        update_label.set_hexpand(true);
        ub.append(&update_label);
        ub.append(&icon("go-next-symbolic", 12));
        update_row.set_child(Some(&ub));
        update_row.set_visible(false);
        update_row.set_tooltip_text(Some(&format!("A new version of {} is available", brand::APP_NAME)));
        update_row.connect_clicked(|_| updater::present());

        let footer = hbox(8);
        footer.add_css_class("user-footer");

        let today = gtk::Button::new();
        today.add_css_class("next-card");
        today.add_css_class("sy-today");
        let tb = vbox(4);
        tb.append(&label_with("TODAY", &["sy-eyebrow"]));
        let today_lines = vbox(2);
        tb.append(&today_lines);
        today.set_child(Some(&tb));
        margins(&today, 0, 8, 8, 8);
        today.set_tooltip_text(Some("Open Overview (Ctrl+Alt+0)"));
        today.connect_clicked(|_| app::set_section(Section::Overview));

        let bottom = vbox(0);
        bottom.append(&today);
        bottom.append(&update_row);
        bottom.append(&footer);

        let tv = adw::ToolbarView::new();
        let hb = adw::HeaderBar::new();
        hb.set_title_widget(Some(&adw::WindowTitle::new(brand::APP_NAME, "")));
        let menu = Menu::new();
        menu.item("Command Palette…", || ui_activate("command-palette"));
        menu.item("Open by Link…", || ui_activate("open-link"));
        menu.item("Refresh", || ui_activate("refresh"));
        let mut menu = menu;
        menu.section(None);
        menu.item("Zoom In", || ui_activate("zoom-in"));
        menu.item("Zoom Out", || ui_activate("zoom-out"));
        menu.item("Actual Size", || ui_activate("zoom-reset"));
        menu.section(None);
        menu.item("Preferences", || ui_activate("preferences"));
        menu.item("Keyboard Shortcuts", || ui_activate("show-shortcuts"));
        menu.item("Welcome Tour", super::welcome::show);
        menu.item("Check for Updates…", || ui_activate("check-updates"));
        menu.item("Buy Me a Pizza…", || ui_activate("donate"));
        menu.item(&format!("About {}", brand::APP_NAME), || ui_activate("about"));
        menu.section(None);
        menu.item("Quit", || ui_activate("quit"));
        let mb = menu.button("open-menu-symbolic", "Main menu");
        mb.set_primary(true);
        hb.pack_end(&mb);
        hb.pack_start(&super::inbox::button());
        tv.add_top_bar(&hb);
        tv.set_content(Some(&scroll));
        tv.add_bottom_bar(&bottom);
        tv.add_css_class("sy-sidebar-pane");

        let me = Rc::new(Sidebar { widget: tv.upcast(), rows: RefCell::new(vec![]), column, update_row, update_label, footer, today, today_lines });
        me.rebuild();
        let weak = Rc::downgrade(&me);
        app::get().section_changed.connect(move |s| match weak.upgrade() {
            Some(me) => {
                me.sync_selection(*s);
                true
            }
            None => false,
        });
        let weak = Rc::downgrade(&me);
        app::on_badges(move |_| match weak.upgrade() {
            Some(me) => {
                me.update_counts();
                true
            }
            None => false,
        });
        let weak = Rc::downgrade(&me);
        app::get().claude.changed.connect(move |_| match weak.upgrade() {
            Some(me) => {
                me.update_counts();
                true
            }
            None => false,
        });
        let weak = Rc::downgrade(&me);
        updater::on_change(move |_| match weak.upgrade() {
            Some(me) => {
                me.update_update_row();
                true
            }
            None => false,
        });
        let weak = Rc::downgrade(&me);
        app::get().phase_changed.connect(move |_| match weak.upgrade() {
            Some(me) => {
                me.build_footer();
                me.update_counts();
                true
            }
            None => false,
        });
        let weak = Rc::downgrade(&me);
        app::get().account_changed.connect(move |_| match weak.upgrade() {
            Some(me) => {
                me.rebuild();
                me.build_footer();
                true
            }
            None => false,
        });
        me.update_counts();
        me.update_update_row();
        me.build_footer();
        keep_alive(&me.widget, me.clone());
        me
    }

    fn rebuild(&self) {
        clear(&self.column);
        let mut rows = vec![];
        for (group, items) in groups() {
            let list = gtk::ListBox::new();
            list.add_css_class("sy-sidebar-list");
            list.set_selection_mode(gtk::SelectionMode::Single);
            if group == "Issues" {
                let collapsed = crate::settings::read(|s| s.issues_collapsed);
                let head = gtk::Button::new();
                head.add_css_class("flat");
                head.add_css_class("sy-section-toggle");
                let hb = hbox(4);
                hb.append(&label_with(&group, &["sy-section-title"]));
                let chevron = icon(if collapsed { "pan-end-symbolic" } else { "pan-down-symbolic" }, 10);
                chevron.add_css_class("sy-dim");
                hb.append(&chevron);
                head.set_child(Some(&hb));
                set_expanded(&head, !collapsed);
                set_label(&head, "Issues");
                list.set_visible(!collapsed);
                let l = list.clone();
                head.connect_clicked(move |b| {
                    let show = !l.is_visible();
                    l.set_visible(show);
                    chevron.set_icon_name(Some(if show { "pan-down-symbolic" } else { "pan-end-symbolic" }));
                    set_expanded(b, show);
                    crate::settings::update(|s| s.issues_collapsed = !show);
                });
                self.column.append(&head);
            } else if group.is_empty() {
                list.set_margin_top(6);
            } else {
                self.column.append(&label_with(&group, &["sy-section-title"]));
            }
            for (section, title, icon_name, _tint) in items {
                let b = hbox(8);
                b.append(&sidebar_icon(icon_name));
                let l = ellipsized(&title, &["sy-text"]);
                l.set_hexpand(true);
                b.append(&l);
                let count = label_with("", &["sy-sidebar-badge"]);
                count.set_valign(gtk::Align::Center);
                count.set_visible(false);
                b.append(&count);
                let row = gtk::ListBoxRow::new();
                row.set_child(Some(&b));
                list.append(&row);
                let r = row.clone();
                list.connect_row_activated(move |_, activated| {
                    if activated == &r {
                        app::set_section(section);
                    }
                });
                let spoken = if matches!(section, Section::Prs(_) | Section::Issues(_)) && !group.is_empty() { format!("{group}: {title}") } else { title.clone() };
                set_label(&row, &spoken);
                row.set_tooltip_text(Some(&spoken));
                rows.push(Row { section, title: spoken, list: list.clone(), row, count });
            }
            self.column.append(&list);
        }
        *self.rows.borrow_mut() = rows;
        self.sync_selection(app::section());
        self.update_counts();
    }

    fn sync_selection(&self, s: Section) {
        for r in self.rows.borrow().iter() {
            if r.section == s {
                r.list.select_row(Some(&r.row));
            } else if r.list.selected_row().as_ref() == Some(&r.row) {
                r.list.unselect_row(&r.row);
            }
        }
    }

    fn update_counts(&self) {
        let a = app::get();
        let (rr, mine, unread) = {
            let s = a.state.borrow();
            (s.review_request_count, s.my_pr_count, s.unread_count)
        };
        let attention = a.claude.attention_count();
        let running = a.claude.running_count();
        self.render_today(rr, running, attention, unread);
        for r in self.rows.borrow().iter() {
            let (n, urgent, noun): (i64, bool, &str) = match r.section {
                Section::Notifications => (unread as i64, false, "unread"),
                Section::Prs(PrFilter::ReviewRequested) => (rr, rr > 0, "waiting for your review"),
                Section::Prs(PrFilter::Mine) => (mine, false, "open"),
                Section::Claude => {
                    if attention > 0 {
                        (attention as i64, true, "need you")
                    } else {
                        (running as i64, false, "running")
                    }
                }
                _ => (0, false, ""),
            };
            let shown = if r.section == Section::Notifications && app::provider().is_github() { crate::list_sort::capped(n.max(0) as usize, crate::api::NOTIFICATION_PAGE_SIZE) } else { n.to_string() };
            r.count.set_text(&if n > 0 { shown.clone() } else { String::new() });
            r.count.set_visible(n > 0);
            if urgent {
                r.count.add_css_class("attention");
            } else {
                r.count.remove_css_class("attention");
            }
            set_label(&r.row, &if n > 0 { format!("{}, {shown} {noun}", r.title) } else { r.title.clone() });
            r.row.set_tooltip_text(Some(&if n > 0 { format!("{} ({shown})", r.title) } else { r.title.clone() }));
        }
    }

    fn render_today(&self, reviews: i64, running: usize, attention: usize, unread: usize) {
        clear(&self.today_lines);
        let github = app::provider().is_github();
        self.today.set_visible(github && app::get().state.borrow().phase == app::Phase::LoggedIn);
        let line = |glyph: &str, color: &str, text: String| {
            let b = hbox(6);
            b.append(&colored_icon(glyph, 11, color));
            b.append(&ellipsized(&text, &["sy-text", "sy-small", "sy-meta-num"]));
            b
        };
        let mut spoken = vec![];
        let reviews_text = if reviews == 0 { "No reviews waiting".to_string() } else { crate::util::plural(reviews, "review waiting", "reviews waiting") };
        spoken.push(reviews_text.clone());
        self.today_lines.append(&line("sy-eye-symbolic", if reviews > 0 { "sky" } else { "muted" }, reviews_text));
        if attention > 0 {
            let t = crate::util::plural(attention as i64, "agent needs you", "agents need you");
            spoken.push(t.clone());
            self.today_lines.append(&line("sy-sparkles-symbolic", "coral", t));
        } else if running > 0 {
            let t = crate::util::plural(running as i64, "agent running", "agents running");
            spoken.push(t.clone());
            self.today_lines.append(&line("sy-sparkles-symbolic", "coral", t));
        }
        if unread > 0 {
            let t = format!("{unread} unread");
            spoken.push(t.clone());
            self.today_lines.append(&line("sy-bell-symbolic", "amber", t));
        }
        set_label(&self.today, &format!("Today: {}. Open Overview", spoken.join(", ")));
    }

    fn update_update_row(&self) {
        match updater::available_version() {
            Some(v) => {
                self.update_label.set_text(&format!("Update to {v}"));
                self.update_row.set_visible(true);
            }
            None => self.update_row.set_visible(false),
        }
    }

    fn build_footer(&self) {
        clear(&self.footer);
        let user = app::get().state.borrow().user.clone();
        let Some(user) = user else { return };
        let display = user.name.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| user.login.clone());
        self.footer.append(&avatar(user.avatar_url.as_deref(), 24, Some(&display)));
        let texts = vbox(0);
        texts.set_hexpand(true);
        texts.append(&ellipsized(&display, &["sy-text", "sy-bold"]));
        let subtitle = app::account().map(|a| a.subtitle()).unwrap_or_else(|| format!("@{}", user.login));
        texts.append(&ellipsized(&subtitle, &["sy-muted", "sy-small"]));
        self.footer.append(&texts);
        self.footer.append(&super::accounts::menu_button());
        let settings = icon_button("emblem-system-symbolic", "Preferences");
        settings.connect_clicked(|_| ui_activate("preferences"));
        self.footer.append(&settings);
    }
}

pub type Group = (String, Vec<(Section, String, &'static str, &'static str)>);

pub fn groups() -> Vec<Group> {
    let provider = app::provider();
    let agents = (Section::Claude, "Agents".to_string(), "sy-sparkles-symbolic", "coral");
    if provider.is_github() {
        return vec![
            (
                String::new(),
                vec![
                    (Section::Overview, "Overview".into(), "sy-gauge-symbolic", "sky"),
                    (Section::Notifications, "Notifications".into(), "sy-bell-symbolic", "amber"),
                    agents,
                ],
            ),
            (
                "Pull requests".into(),
                PrFilter::ALL
                    .iter()
                    .map(|f| (Section::Prs(*f), f.title().to_string(), f.icon(), f.tint()))
                    .chain(std::iter::once((Section::MyPrsByRepo, "My PRs by project".to_string(), "sy-folder-symbolic", "coral")))
                    .chain(std::iter::once((Section::Stacks, "Stacks".to_string(), "sy-stack-symbolic", "indigo")))
                    .collect(),
            ),
            ("Issues".into(), IssueFilter::ALL.iter().map(|f| (Section::Issues(*f), f.title().to_string(), f.icon(), f.tint())).collect()),
            (
                "Code".into(),
                vec![(Section::Repos, "Repositories".into(), "sy-repo-symbolic", "teal"), (Section::Projects, "Projects".into(), "sy-project-symbolic", "indigo")],
            ),
        ];
    }
    let caps = app::forge_caps();
    let mut top = vec![];
    if let Some(inbox) = caps.inbox_title {
        top.push((Section::Notifications, inbox.to_string(), "sy-bell-symbolic", "amber"));
    }
    top.push(agents);
    let mut out: Vec<Group> = vec![(String::new(), top)];
    let mut pulls: Vec<(Section, String, &'static str, &'static str)> = caps.pull_filters.iter().map(|f| (Section::Prs(*f), f.title().to_string(), f.icon(), f.tint())).collect();
    if caps.pull_filters.contains(&PrFilter::Mine) {
        pulls.push((Section::MyPrsByRepo, format!("My {}s by project", provider.request_short()), "sy-folder-symbolic", "coral"));
    }
    out.push((provider.requests_title().into(), pulls));
    if !caps.issue_filters.is_empty() {
        out.push(("Issues".into(), caps.issue_filters.iter().map(|f| (Section::Issues(*f), f.title().to_string(), f.icon(), f.tint())).collect()));
    }
    if caps.repositories {
        out.push(("Code".into(), vec![(Section::Repos, provider.repositories_title().to_string(), "sy-repo-symbolic", "teal")]));
    }
    out
}

pub fn ui_activate(name: &str) {
    let a = app::get();
    gtk::prelude::ActionGroupExt::activate_action(&a.gtk_app, name, None);
}
