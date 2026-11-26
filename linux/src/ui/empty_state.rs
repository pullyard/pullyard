use std::rc::Rc;

use adw::prelude::*;

use super::widgets::*;
use crate::api::models::{Route, SearchItem};
use crate::app;
use crate::settings;

pub fn keycap(key: &str) -> gtk::Label {
    let l = label_with(key, &["keycap"]);
    l.set_valign(gtk::Align::Center);
    l
}

pub fn shortcut_hint(key: &str, text: &str) -> gtk::Box {
    let b = hbox(6);
    b.append(&keycap(key));
    b.append(&label_with(text, &["sy-muted", "sy-small"]));
    b
}

pub fn harbor_waves(width: i32, height: i32) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::new();
    area.set_content_width(width);
    area.set_content_height(height);
    area.add_css_class("harbor-waves");
    area.set_halign(gtk::Align::Center);
    decorative(&area);
    area.set_draw_func(|a, cr, w, h| {
        let c = a.color();
        let (w, h) = (w as f64, h as f64);
        for (i, y) in [h * 0.35, h * 0.8].into_iter().enumerate() {
            let inset = if i == 0 { 0.0 } else { w * 0.12 };
            let span = w - inset * 2.0;
            cr.move_to(inset, y);
            let steps = 4;
            for s in 0..steps {
                let x0 = inset + span * s as f64 / steps as f64;
                let x1 = inset + span * (s + 1) as f64 / steps as f64;
                let dip = if s % 2 == 0 { -4.0 } else { 4.0 };
                let (cx, cy) = ((x0 + x1) / 2.0, y + dip);
                let (px, py) = cr.current_point().unwrap_or((x0, y));
                cr.curve_to(px + 2.0 / 3.0 * (cx - px), py + 2.0 / 3.0 * (cy - py), x1 + 2.0 / 3.0 * (cx - x1), y + 2.0 / 3.0 * (cy - y), x1, y);
            }
            let alpha = if i == 0 { 1.0 } else { 0.6 };
            cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, c.alpha() as f64 * alpha);
            cr.set_line_width(2.0);
            cr.set_line_cap(gtk::cairo::LineCap::Round);
            let _ = cr.stroke();
        }
    });
    area
}

pub fn hero_mark(key: &str, size: i32) -> gtk::Overlay {
    let overlay = gtk::Overlay::new();
    let base = vbox(0);
    base.set_size_request(-1, (size as f32 * 500.0 / 750.0) as i32 + 30);
    overlay.set_child(Some(&base));
    let waves = harbor_waves(200, 22);
    waves.set_valign(gtk::Align::End);
    overlay.add_overlay(&waves);
    let mark = Loader::hero(size, key);
    mark.set_halign(gtk::Align::Center);
    mark.set_valign(gtk::Align::Start);
    overlay.add_overlay(&mark);
    overlay.set_halign(gtk::Align::Center);
    overlay
}

pub struct EmptyState<'a> {
    pub key: &'a str,
    pub title: &'a str,
    pub message: &'a str,
    pub shortcuts: &'a [(&'a str, &'a str)],
    pub aurora: bool,
    pub next_up: bool,
}

pub fn build(spec: EmptyState) -> gtk::Widget {
    let column = vbox(14);
    column.set_valign(gtk::Align::Center);
    column.set_halign(gtk::Align::Center);
    pad(&column, 32);
    column.append(&hero_mark(spec.key, 96));
    let title = label_with(spec.title, &["sy-display"]);
    title.set_xalign(0.5);
    title.set_justify(gtk::Justification::Center);
    title.set_wrap(true);
    column.append(&title);
    let message = wrap_label(spec.message, &["sy-muted"]);
    message.set_xalign(0.5);
    message.set_justify(gtk::Justification::Center);
    message.set_max_width_chars(48);
    column.append(&message);
    if !spec.shortcuts.is_empty() {
        let keys = hbox(16);
        keys.set_halign(gtk::Align::Center);
        keys.set_margin_top(6);
        for (k, t) in spec.shortcuts {
            keys.append(&shortcut_hint(k, t));
        }
        column.append(&keys);
    }
    if spec.next_up {
        let extra = vbox(14);
        extra.set_margin_top(18);
        extra.set_halign(gtk::Align::Center);
        if let Some(panel) = next_up_panel() {
            extra.append(&panel);
        }
        if let Some(list) = first_run_checklist() {
            extra.append(&list);
        }
        column.append(&extra);
    }
    let scroll = scrolled(&column);
    if spec.aurora && crate::theme::is_brand() {
        scroll.add_css_class("empty-hero");
    }
    scroll.upcast()
}

fn next_card(title: &str, glyph: &str, color: &str) -> gtk::Box {
    let card = vbox(6);
    card.add_css_class("next-card");
    card.set_size_request(220, -1);
    card.set_valign(gtk::Align::Start);
    let head = hbox(5);
    head.append(&colored_icon(glyph, 10, color));
    let t = label_with(&title.to_uppercase(), &["sy-eyebrow"]);
    t.add_css_class(&format!("ink-{color}"));
    head.append(&t);
    card.append(&head);
    card
}

fn next_item(item: &SearchItem) -> gtk::Button {
    let b = gtk::Button::new();
    b.add_css_class("flat");
    let row = hbox(6);
    let state = item.visual_state();
    let glyph = colored_icon(state.compact_icon(), 10, state.css());
    glyph.set_valign(gtk::Align::Start);
    glyph.set_margin_top(3);
    row.append(&glyph);
    let col = vbox(1);
    let t = wrap_label(&item.title, &["sy-text", "sy-small"]);
    t.set_lines(2);
    t.set_ellipsize(gtk::pango::EllipsizeMode::End);
    t.set_max_width_chars(26);
    col.append(&t);
    col.append(&ellipsized(&format!("{}#{}", item.repository.name_with_owner, item.number), &["sy-muted", "sy-tiny", "sy-mono"]));
    row.append(&col);
    b.set_child(Some(&row));
    b.set_tooltip_text(Some(&item.title));
    set_label(&b, &item.title);
    let route = item.route();
    b.connect_clicked(move |_| app::open(route.clone(), false));
    b
}

pub fn needs_attention(item: &SearchItem) -> bool {
    matches!(item.ci_state().as_deref(), Some("FAILURE") | Some("ERROR")) || item.review_decision.as_deref() == Some("CHANGES_REQUESTED")
}

fn next_up_panel() -> Option<gtk::Box> {
    let a = app::try_get()?;
    let (reviews, mine) = {
        let s = a.state.borrow();
        (s.review_requests.iter().take(3).cloned().collect::<Vec<_>>(), s.my_prs.clone())
    };
    let attention: Vec<SearchItem> = mine.into_iter().filter(needs_attention).take(3).collect();
    let shown: Vec<Route> = reviews.iter().chain(attention.iter()).map(|i| i.route()).collect();
    let recent: Vec<Route> = app::recent_routes().into_iter().filter(|r| !shown.contains(r)).take(3).collect();
    if reviews.is_empty() && attention.is_empty() && recent.is_empty() {
        return None;
    }
    let row = hbox(12);
    row.set_halign(gtk::Align::Center);
    if !reviews.is_empty() {
        let c = next_card("Your turn", "sy-eye-symbolic", "sky");
        for i in &reviews {
            c.append(&next_item(i));
        }
        row.append(&c);
    }
    if !attention.is_empty() {
        let c = next_card("Needs attention", "sy-attention-symbolic", "amber");
        for i in &attention {
            c.append(&next_item(i));
        }
        row.append(&c);
    }
    if !recent.is_empty() {
        let c = next_card("Recent", "sy-clock-symbolic", "muted");
        for r in recent {
            let Some(text) = r.short_link() else { continue };
            let b = gtk::Button::with_label(&text);
            b.add_css_class("flat");
            b.add_css_class("sy-mono");
            if let Some(l) = b.child().and_downcast::<gtk::Label>() {
                l.set_xalign(0.0);
                l.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            }
            b.connect_clicked(move |_| app::open(r.clone(), false));
            c.append(&b);
        }
        row.append(&c);
    }
    Some(row)
}

struct Step {
    title: &'static str,
    detail: &'static str,
    done: bool,
    action: Rc<dyn Fn()>,
}

fn first_run_checklist() -> Option<gtk::Box> {
    if settings::read(|s| s.checklist_dismissed) {
        return None;
    }
    let steps = [
        Step {
            title: "Take the Welcome Tour",
            detail: "Five short scenes: Overview, keys, merging and Agents",
            done: settings::read(|s| s.welcome_tour_seen),
            action: Rc::new(super::welcome::show),
        },
        Step {
            title: "Connect Agents",
            detail: "Fix review comments and failing checks with an agent",
            done: crate::claude::accounts::store().is_logged_in(),
            action: Rc::new(|| app::set_section(app::Section::Claude)),
        },
        Step { title: "Link Jira", detail: "Optional · see tickets next to the pull request", done: crate::jira::is_configured(), action: Rc::new(super::settings::show) },
    ];
    if steps.iter().all(|s| s.done) {
        return None;
    }
    let card = vbox(8);
    card.add_css_class("next-card");
    card.set_size_request(420, -1);
    let head = hbox(6);
    let t = label_with("GET SET UP", &["sy-eyebrow", "ink-coral"]);
    t.set_hexpand(true);
    head.append(&t);
    let close = icon_button("window-close-symbolic", "Hide this checklist");
    let c = card.clone();
    close.connect_clicked(move |_| {
        settings::update(|s| s.checklist_dismissed = true);
        c.set_visible(false);
    });
    head.append(&close);
    card.append(&head);
    for step in steps {
        let row = hbox(10);
        let glyph = if step.done { colored_icon("sy-check-circle-symbolic", 14, "green") } else { colored_icon("sy-dot-symbolic", 14, "muted") };
        glyph.set_valign(gtk::Align::Start);
        row.append(&glyph);
        let col = vbox(1);
        col.set_hexpand(true);
        let title = label_with(step.title, &[if step.done { "sy-muted" } else { "sy-text" }]);
        if step.done {
            title.set_attributes(Some(&{
                let attrs = gtk::pango::AttrList::new();
                attrs.insert(gtk::pango::AttrInt::new_strikethrough(true));
                attrs
            }));
        }
        col.append(&title);
        col.append(&wrap_label(step.detail, &["sy-muted", "sy-small"]));
        row.append(&col);
        if !step.done {
            let b = button("Set up");
            b.set_valign(gtk::Align::Center);
            let f = step.action.clone();
            b.connect_clicked(move |_| f());
            row.append(&b);
        }
        card.append(&row);
    }
    Some(card)
}
