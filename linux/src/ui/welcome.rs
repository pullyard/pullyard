use std::cell::{Cell, RefCell};
use std::f64::consts::TAU;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use super::empty_state::keycap;
use super::logo::{animations_enabled, Loader};
use super::widgets::*;
use crate::app::{self, Section};
use crate::{brand, settings};

const PAGES: usize = 5;

const EYEBROWS: [&str; PAGES] = ["Welcome aboard", "Your harbor", "Review at speed", "Merge with confidence", "Agents on deck"];

const TITLES: [&str; PAGES] = ["Pull requests,\nwithout the browser.", "Start every day\non Overview.", "Your keyboard\nis the fast lane.", "Know it's ready\nbefore you merge.", "Hand the fix\nto an agent."];

fn subtitle(page: usize) -> String {
    match page {
        0 => format!("{} is a native home for your reviews. Your token stays on this computer, and everything refreshes on its own.", brand::APP_NAME),
        1 => "See what's waiting for you, what's failing and what's ready to merge — one glance, then jump straight in.".into(),
        2 => "Ctrl+Shift+R writes a review, Ctrl+Shift+A approves, Ctrl+Shift+M merges. Ctrl+K finds everything else.".into(),
        3 => "Every requirement is checked live: reviews, checks, conflicts, branch rules. Merge asks once more before it ships.".into(),
        _ => "Failing checks or review comments? Start an agent from the pull request and keep reviewing while it works.".into(),
    }
}

const SKY: [((f64, f64, f64), (f64, f64, f64)); PAGES] = [
    ((0.043, 0.063, 0.149), (0.106, 0.145, 0.314)),
    ((0.051, 0.071, 0.180), (0.153, 0.137, 0.361)),
    ((0.035, 0.078, 0.176), (0.078, 0.243, 0.380)),
    ((0.047, 0.059, 0.141), (0.176, 0.118, 0.318)),
    ((0.059, 0.051, 0.129), (0.310, 0.149, 0.231)),
];

fn mix(a: (f64, f64, f64), b: (f64, f64, f64), t: f64) -> (f64, f64, f64) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

pub fn sky_at(progress: f64) -> ((f64, f64, f64), (f64, f64, f64)) {
    let p = progress.clamp(0.0, (PAGES - 1) as f64);
    let i = p.floor() as usize;
    let j = (i + 1).min(PAGES - 1);
    let t = p - i as f64;
    (mix(SKY[i].0, SKY[j].0, t), mix(SKY[i].1, SKY[j].1, t))
}

fn star(i: usize) -> (f64, f64, f64, f64) {
    let mut h: u64 = 1469598103934665603 ^ (i as u64).wrapping_mul(0x9E3779B97F4A7C15);
    let mut next = || {
        h ^= h << 13;
        h ^= h >> 7;
        h ^= h << 17;
        (h % 10_000) as f64 / 10_000.0
    };
    (next(), next() * 0.62, 0.5 + next() * 1.3, next() * TAU)
}

struct Voyage {
    progress: Cell<f64>,
    elapsed: Cell<f64>,
    leaving: Cell<f64>,
}

fn draw_backdrop(v: &Voyage, cr: &gtk::cairo::Context, w: f64, h: f64) {
    let (top, bottom) = sky_at(v.progress.get());
    let g = gtk::cairo::LinearGradient::new(0.0, 0.0, 0.0, h);
    g.add_color_stop_rgb(0.0, top.0, top.1, top.2);
    g.add_color_stop_rgb(1.0, bottom.0, bottom.1, bottom.2);
    let _ = cr.set_source(&g);
    let _ = cr.paint();
    let t = v.elapsed.get();
    let streak = v.leaving.get();
    for i in 0..90 {
        let (x, y, r, phase) = star(i);
        let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * (t * 1.3 + phase).sin());
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.75 * twinkle);
        if streak > 0.0 {
            cr.set_line_width(r);
            cr.move_to(x * w, y * h);
            cr.line_to(x * w - streak * 80.0, y * h);
            let _ = cr.stroke();
        } else {
            cr.arc(x * w, y * h, r, 0.0, TAU);
            let _ = cr.fill();
        }
    }
    let shoot = (t % 7.0) / 0.9;
    if shoot < 1.0 && streak == 0.0 {
        let sx = w * (0.25 + 0.5 * ((t / 7.0).floor() * 0.37).fract());
        let sy = h * 0.12;
        let (x, y) = (sx + shoot * 160.0, sy + shoot * 60.0);
        let lg = gtk::cairo::LinearGradient::new(x - 60.0, y - 22.0, x, y);
        lg.add_color_stop_rgba(0.0, 1.0, 1.0, 1.0, 0.0);
        lg.add_color_stop_rgba(1.0, 1.0, 1.0, 1.0, 0.8 * (1.0 - shoot));
        let _ = cr.set_source(&lg);
        cr.set_line_width(1.6);
        cr.move_to(x - 60.0, y - 22.0);
        cr.line_to(x, y);
        let _ = cr.stroke();
    }
    let horizon = h * 0.8;
    for (k, (alpha, amp, speed)) in [(0.22, 6.0, 0.6), (0.14, 9.0, 0.4)].into_iter().enumerate() {
        cr.set_source_rgba(0.49, 0.83, 0.99, alpha);
        cr.set_line_width(2.0);
        let y0 = horizon + k as f64 * 26.0;
        cr.move_to(0.0, y0);
        let mut x = 0.0;
        while x <= w {
            cr.line_to(x, y0 + amp * ((x / 90.0) + t * speed + k as f64).sin());
            x += 8.0;
        }
        let _ = cr.stroke();
    }
    for i in 0..6 {
        let gx = ((i as f64 * 0.17 + t * 0.03) % 1.0) * w;
        let shine = 0.5 + 0.5 * (t * 2.0 + i as f64).sin();
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.18 * shine);
        cr.set_line_width(1.2);
        cr.move_to(gx, horizon + 14.0);
        cr.line_to(gx + 14.0, horizon + 14.0);
        let _ = cr.stroke();
    }
    let ship_x = ship_position(v.progress.get(), w);
    let (vr, vg, vb) = brand::rgb(brand::MARK_VIOLET);
    let (sr, sg, sb) = brand::rgb(brand::MARK_SKY);
    for (k, (r, g2, b)) in [(vr, vg, vb), (sr, sg, sb)].into_iter().enumerate() {
        let lg = gtk::cairo::LinearGradient::new(0.0, 0.0, ship_x, 0.0);
        lg.add_color_stop_rgba(0.0, r, g2, b, 0.0);
        lg.add_color_stop_rgba(1.0, r, g2, b, 0.7);
        let _ = cr.set_source(&lg);
        cr.set_line_width(2.4);
        let y = horizon - 4.0 + k as f64 * 8.0;
        cr.move_to(ship_x * 0.15, y + if k == 0 { -10.0 } else { 10.0 });
        cr.curve_to(ship_x * 0.5, y + if k == 0 { -10.0 } else { 10.0 }, ship_x * 0.7, y, ship_x - 18.0, y);
        let _ = cr.stroke();
    }
}

pub fn ship_position(progress: f64, width: f64) -> f64 {
    width * (0.14 + 0.68 * (progress / (PAGES - 1) as f64).clamp(0.0, 1.0))
}

fn eyebrow_label(text: &str) -> gtk::Label {
    label_with(&text.to_uppercase(), &["welcome-eyebrow"])
}

fn scene_overview(play: bool) -> gtk::Widget {
    let grid = gtk::Grid::new();
    grid.set_column_spacing(12);
    grid.set_row_spacing(12);
    grid.set_column_homogeneous(true);
    let tiles = [("Reviews waiting", "sy-eye-symbolic", "coral", 4), ("Ready to merge", "sy-merge-symbolic", "green", 2), ("Failing checks", "sy-x-circle-symbolic", "red", 1), ("Mentioned", "sy-at-symbolic", "indigo", 3)];
    for (i, (title, glyph, color, n)) in tiles.into_iter().enumerate() {
        let b = vbox(6);
        b.add_css_class("welcome-card");
        b.append(&colored_icon(glyph, 16, color));
        let num = label_with("0", &["welcome-number"]);
        b.append(&num);
        b.append(&label_with(title, &["welcome-muted"]));
        grid.attach(&b, (i % 2) as i32, (i / 2) as i32, 1, 1);
        if play && animations_enabled() {
            let l = num.clone();
            let target = adw::CallbackAnimationTarget::new(move |v| l.set_text(&format!("{}", v.round() as i64)));
            let anim = adw::TimedAnimation::new(&num, 0.0, n as f64, 900 + i as u32 * 150, target);
            anim.set_easing(adw::Easing::EaseOutCubic);
            anim.play();
        } else {
            num.set_text(&n.to_string());
        }
    }
    grid.upcast()
}

fn staggered(container: &gtk::Box, rows: Vec<gtk::Widget>, step_ms: u64, play: bool) {
    for (i, r) in rows.into_iter().enumerate() {
        let rev = gtk::Revealer::new();
        rev.set_transition_type(gtk::RevealerTransitionType::Crossfade);
        rev.set_transition_duration(240);
        rev.set_child(Some(&r));
        container.append(&rev);
        if play && animations_enabled() {
            let rv = rev.clone();
            glib::timeout_add_local_once(std::time::Duration::from_millis(200 + i as u64 * step_ms), move || rv.set_reveal_child(true));
        } else {
            rev.set_reveal_child(true);
        }
    }
}

fn scene_keys(play: bool) -> gtk::Widget {
    let b = vbox(10);
    let keys = [("Ctrl+Shift+R", "Write review"), ("Ctrl+Shift+A", "Approve"), ("Ctrl+Shift+M", "Merge"), ("Ctrl+L", "Open by link"), ("Ctrl+K", "Command palette")];
    let rows = keys
        .into_iter()
        .map(|(k, t)| {
            let r = hbox(12);
            let cap = keycap(k);
            cap.set_size_request(120, -1);
            r.append(&cap);
            r.append(&label_with(t, &["welcome-text"]));
            r.upcast()
        })
        .collect();
    staggered(&b, rows, 260, play);
    b.upcast()
}

fn scene_merge(play: bool) -> gtk::Widget {
    let b = vbox(10);
    b.add_css_class("welcome-card");
    let items = ["Approved by 2 reviewers", "All 12 checks passing", "No conflicts with main", "Branch rules satisfied"];
    let rows = items
        .into_iter()
        .map(|t| {
            let r = hbox(10);
            r.append(&colored_icon("sy-check-circle-symbolic", 15, "green"));
            r.append(&label_with(t, &["welcome-text"]));
            r.upcast()
        })
        .collect();
    staggered(&b, rows, 380, play);
    let merged = status_chip("Merged into main", "violet", Some("sy-merge-symbolic"));
    merged.set_margin_top(6);
    let rev = gtk::Revealer::new();
    rev.set_transition_type(gtk::RevealerTransitionType::SlideUp);
    rev.set_child(Some(&merged));
    b.append(&rev);
    if play && animations_enabled() {
        let rv = rev.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(200 + 4 * 380 + 300), move || rv.set_reveal_child(true));
    } else {
        rev.set_reveal_child(true);
    }
    b.upcast()
}

fn scene_agents(play: bool) -> gtk::Widget {
    let b = vbox(8);
    b.add_css_class("welcome-card");
    let head = hbox(8);
    head.append(&Loader::wake(14));
    head.append(&label_with("Agent running · 1m", &["welcome-coral"]));
    b.append(&head);
    let lines = ["Reading 3 review comments…", "Updating sync_engine.rs", "Running tests · 48 passed", "Pushed fix to the branch"];
    let rows = lines.into_iter().map(|l| label_with(&format!("› {l}"), &["welcome-log"]).upcast()).collect();
    staggered(&b, rows, 520, play);
    b.upcast()
}

fn scene(page: usize, play: bool) -> gtk::Widget {
    let w: gtk::Widget = match page {
        0 => {
            let l = Loader::once(220);
            l.set_duration(1.6);
            l.upcast()
        }
        1 => scene_overview(play),
        2 => scene_keys(play),
        3 => scene_merge(play),
        _ => scene_agents(play),
    };
    w.set_halign(gtk::Align::Center);
    w.set_valign(gtk::Align::Center);
    w.set_size_request(320, -1);
    w
}

struct Tour {
    dialog: adw::Dialog,
    page: Cell<usize>,
    texts: gtk::Stack,
    scenes: gtk::Stack,
    back: gtk::Button,
    next: gtk::Button,
    skip: gtk::Button,
    dots: Vec<gtk::Box>,
    voyage: Rc<Voyage>,
    sky: gtk::DrawingArea,
    anim: RefCell<Option<adw::TimedAnimation>>,
}

impl Tour {
    fn go(self: &Rc<Self>, page: usize) {
        let page = page.min(PAGES - 1);
        let from = self.page.replace(page);
        let forward = page >= from;
        let transition = if !animations_enabled() {
            gtk::StackTransitionType::Crossfade
        } else if forward {
            gtk::StackTransitionType::SlideLeft
        } else {
            gtk::StackTransitionType::SlideRight
        };
        self.texts.set_transition_type(transition);
        self.scenes.set_transition_type(transition);
        let name = format!("p{page}");
        if let Some(old) = self.scenes.child_by_name(&name) {
            self.scenes.remove(&old);
        }
        self.scenes.add_named(&scene(page, true), Some(&name));
        self.texts.set_visible_child_name(&name);
        self.scenes.set_visible_child_name(&name);
        self.back.set_sensitive(page > 0);
        self.skip.set_visible(page < PAGES - 1);
        self.next.set_label(if page == PAGES - 1 { "Set sail" } else { "Next" });
        if page == PAGES - 1 {
            self.next.add_css_class("welcome-cta");
        } else {
            self.next.remove_css_class("welcome-cta");
        }
        for (i, d) in self.dots.iter().enumerate() {
            if i == page {
                d.add_css_class("active");
            } else {
                d.remove_css_class("active");
            }
        }
        let v = self.voyage.clone();
        let sky = self.sky.clone();
        let target = adw::CallbackAnimationTarget::new(move |p| {
            v.progress.set(p);
            sky.queue_draw();
        });
        let anim = adw::TimedAnimation::new(&self.sky, self.voyage.progress.get(), page as f64, 700, target);
        anim.set_easing(adw::Easing::EaseInOutCubic);
        anim.play();
        *self.anim.borrow_mut() = Some(anim);
    }

    fn finish(self: &Rc<Self>, sail: bool) {
        settings::update(|s| s.welcome_tour_seen = true);
        if !sail || !animations_enabled() {
            self.dialog.close();
            if sail {
                app::set_section(Section::Overview);
            }
            return;
        }
        let v = self.voyage.clone();
        let sky = self.sky.clone();
        let target = adw::CallbackAnimationTarget::new(move |p| {
            v.leaving.set(p);
            sky.queue_draw();
        });
        let anim = adw::TimedAnimation::new(&self.sky, 0.0, 1.0, 450, target);
        anim.set_easing(adw::Easing::EaseInCubic);
        let d = self.dialog.clone();
        anim.connect_done(move |_| {
            d.close();
            app::set_section(Section::Overview);
        });
        anim.play();
        *self.anim.borrow_mut() = Some(anim);
    }
}

pub fn show() {
    let Some(window) = app::main_window() else { return };
    let dialog = adw::Dialog::new();
    dialog.set_content_width(860);
    dialog.set_content_height(560);
    dialog.set_title(&format!("Welcome to {}", brand::APP_NAME));
    dialog.add_css_class("welcome-tour");

    let voyage = Rc::new(Voyage { progress: Cell::new(0.0), elapsed: Cell::new(0.0), leaving: Cell::new(0.0) });
    let sky = gtk::DrawingArea::new();
    sky.set_hexpand(true);
    sky.set_vexpand(true);
    decorative(&sky);
    let v = voyage.clone();
    sky.set_draw_func(move |_, cr, w, h| draw_backdrop(&v, cr, w as f64, h as f64));
    let v = voyage.clone();
    sky.add_tick_callback(move |w, clock| {
        if animations_enabled() {
            v.elapsed.set(clock.frame_time() as f64 / 1_000_000.0);
            w.queue_draw();
        }
        glib::ControlFlow::Continue
    });

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&sky));

    let ship = Loader::once(64);
    ship.set_halign(gtk::Align::Start);
    ship.set_valign(gtk::Align::End);
    ship.set_margin_bottom(84);
    decorative(&ship);
    overlay.add_overlay(&ship);
    overlay.set_measure_overlay(&ship, false);

    let layout = vbox(0);
    let top = hbox(0);
    margins(&top, 16, 20, 0, 20);
    top.append(&spacer());
    let skip = flat("Skip");
    skip.add_css_class("welcome-link");
    top.append(&skip);
    layout.append(&top);

    let body = hbox(40);
    body.set_vexpand(true);
    margins(&body, 0, 56, 96, 56);
    let texts = gtk::Stack::new();
    texts.set_hexpand(true);
    texts.set_valign(gtk::Align::Center);
    texts.set_transition_duration(360);
    for p in 0..PAGES {
        let col = vbox(16);
        col.append(&eyebrow_label(EYEBROWS[p]));
        let t = label_with(TITLES[p], &["welcome-title"]);
        t.set_wrap(true);
        col.append(&t);
        let s = wrap_label(&subtitle(p), &["welcome-subtitle"]);
        s.set_max_width_chars(42);
        col.append(&s);
        texts.add_named(&col, Some(&format!("p{p}")));
        set_label(&col, &format!("{}. {}", TITLES[p].replace('\n', " "), subtitle(p)));
    }
    body.append(&texts);
    let scenes = gtk::Stack::new();
    scenes.set_transition_duration(360);
    scenes.set_size_request(340, 320);
    scenes.set_valign(gtk::Align::Center);
    body.append(&scenes);
    layout.append(&body);

    let bottom = hbox(10);
    margins(&bottom, 0, 24, 22, 24);
    let back = icon_button("go-previous-symbolic", "Back");
    back.add_css_class("welcome-link");
    bottom.append(&back);
    bottom.append(&spacer());
    let dot_box = hbox(6);
    dot_box.set_valign(gtk::Align::Center);
    let mut dots = vec![];
    for i in 0..PAGES {
        let d = fixed_box(&["welcome-dot"], 8, 8);
        set_label(&d, &format!("Page {}", i + 1));
        dot_box.append(&d);
        dots.push(d);
    }
    bottom.append(&dot_box);
    bottom.append(&spacer());
    let next = suggested("Next");
    next.add_css_class("pill");
    bottom.append(&next);
    layout.append(&bottom);
    overlay.add_overlay(&layout);

    dialog.set_child(Some(&overlay));
    let tour = Rc::new(Tour { dialog: dialog.clone(), page: Cell::new(0), texts, scenes, back: back.clone(), next: next.clone(), skip: skip.clone(), dots, voyage, sky: sky.clone(), anim: RefCell::new(None) });

    let s = ship.clone();
    let v = tour.voyage.clone();
    ship.add_tick_callback(move |w, _| {
        let width = w.parent().map(|p| p.width()).unwrap_or(0) as f64;
        let x = (ship_position(v.progress.get(), width) - s.width() as f64 * 0.6).max(0.0);
        let bob = if animations_enabled() { (v.elapsed.get() * 1.4).sin() * 3.0 } else { 0.0 };
        s.set_margin_start(x as i32);
        s.set_margin_bottom((84.0 + bob) as i32);
        s.set_opacity(1.0 - v.leaving.get());
        glib::ControlFlow::Continue
    });

    let t = tour.clone();
    next.connect_clicked(move |_| {
        let p = t.page.get();
        if p + 1 >= PAGES {
            t.finish(true);
        } else {
            t.go(p + 1);
        }
    });
    let t = tour.clone();
    back.connect_clicked(move |_| {
        let p = t.page.get();
        if p > 0 {
            t.go(p - 1);
        }
    });
    let t = tour.clone();
    skip.connect_clicked(move |_| t.finish(false));
    dialog.connect_closed(|_| settings::update(|s| s.welcome_tour_seen = true));

    let keys = gtk::EventControllerKey::new();
    let t = tour.clone();
    keys.connect_key_pressed(move |_, key, _, _| {
        let p = t.page.get();
        match key {
            gtk::gdk::Key::Right => {
                if p + 1 < PAGES {
                    t.go(p + 1);
                }
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Left => {
                if p > 0 {
                    t.go(p - 1);
                }
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => {
                if p + 1 >= PAGES {
                    t.finish(true);
                } else {
                    t.go(p + 1);
                }
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    dialog.add_controller(keys);

    tour.go(0);
    keep_alive(&dialog, tour.clone());
    dialog.present(Some(&window));
    next.grab_focus();
}

pub fn maybe_show() {
    if settings::read(|s| s.welcome_tour_seen) || crate::tour::active() || crate::demo::is_on() {
        return;
    }
    glib::timeout_add_local_once(std::time::Duration::from_millis(700), || {
        if !settings::read(|s| s.welcome_tour_seen) {
            show();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sky_blends_between_pages() {
        assert_eq!(sky_at(0.0), SKY[0]);
        assert_eq!(sky_at(4.0), SKY[4]);
        assert_eq!(sky_at(9.0), SKY[4]);
        let (top, _) = sky_at(0.5);
        assert!((top.0 - (SKY[0].0 .0 + SKY[1].0 .0) / 2.0).abs() < 1e-9);
    }

    #[test]
    fn ship_sails_left_to_right() {
        assert!(ship_position(0.0, 1000.0) < ship_position(2.0, 1000.0));
        assert!(ship_position(4.0, 1000.0) <= 820.0 + 1e-9);
    }

    #[test]
    fn five_pages_have_copy() {
        for p in 0..PAGES {
            assert!(!EYEBROWS[p].is_empty() && !TITLES[p].is_empty() && !subtitle(p).is_empty());
        }
    }
}
