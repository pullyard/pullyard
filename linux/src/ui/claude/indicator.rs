use std::cell::{Cell, RefCell};
use std::f64::consts::PI;
use std::rc::Rc;

use adw::prelude::*;
use gtk::cairo;
use gtk::glib;

use crate::claude::Indicator;

fn violet() -> (f64, f64, f64) {
    crate::brand::rgb(crate::brand::MARK_VIOLET)
}

fn sky() -> (f64, f64, f64) {
    crate::brand::rgb(crate::brand::MARK_SKY)
}

fn hull_top() -> (f64, f64, f64) {
    crate::brand::rgb(crate::brand::MARK_CORAL)
}

fn hull_bottom() -> (f64, f64, f64) {
    crate::brand::rgb(crate::brand::MARK_CORAL_DEEP)
}
const SIZE: i32 = 16;

fn animations_enabled() -> bool {
    gtk::Settings::default().map(|s| s.is_gtk_enable_animations()).unwrap_or(true)
}

fn ease(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

fn draw_spinner(cr: &cairo::Context, w: f64, h: f64, phase: f64) {
    let (cx, cy) = (w / 2.0, h / 2.0);
    let r = 4.0;
    cr.set_line_width(2.0);
    cr.set_source_rgba(violet().0, violet().1, violet().2, 0.2);
    cr.arc(cx, cy, r, 0.0, 2.0 * PI);
    let _ = cr.stroke();
    let start = -phase * 2.0 * PI - PI / 2.0;
    let end = start + 0.34 * 2.0 * PI;
    let grad = cairo::LinearGradient::new(cx - r, cy, cx + r, cy);
    grad.add_color_stop_rgb(0.0, sky().0, sky().1, sky().2);
    grad.add_color_stop_rgb(1.0, violet().0, violet().1, violet().2);
    let _ = cr.set_source(&grad);
    cr.set_line_cap(cairo::LineCap::Round);
    cr.arc(cx, cy, r, start, end);
    let _ = cr.stroke();
}

fn draw_done(cr: &cairo::Context, w: f64, h: f64) {
    let (cx, cy) = (w / 2.0, h / 2.0);
    let r = 4.0;
    let ring = cairo::LinearGradient::new(cx - r, cy - r, cx + r, cy + r);
    ring.add_color_stop_rgb(0.0, violet().0, violet().1, violet().2);
    ring.add_color_stop_rgb(0.5, sky().0, sky().1, sky().2);
    ring.add_color_stop_rgb(1.0, violet().0, violet().1, violet().2);
    let _ = cr.set_source(&ring);
    cr.set_line_width(2.0);
    cr.arc(cx, cy, r, 0.0, 2.0 * PI);
    let _ = cr.stroke();
    let dot = cairo::LinearGradient::new(cx - 2.0, cy - 2.0, cx + 2.0, cy + 2.0);
    dot.add_color_stop_rgb(0.0, violet().0, violet().1, violet().2);
    dot.add_color_stop_rgb(1.0, sky().0, sky().1, sky().2);
    let _ = cr.set_source(&dot);
    cr.arc(cx, cy, 2.0, 0.0, 2.0 * PI);
    let _ = cr.fill();
}

fn draw_waiting(cr: &cairo::Context, w: f64, h: f64, phase: Option<f64>) {
    let (cx, cy) = (w / 2.0, h / 2.0);
    let r = 6.0;
    if let Some(p) = phase {
        let t = ease(p);
        let pr = (r * (1.0 + 0.7 * t)).min(w / 2.0);
        cr.set_source_rgba(hull_top().0, hull_top().1, hull_top().2, 0.3 * (1.0 - t));
        cr.arc(cx, cy, pr, 0.0, 2.0 * PI);
        let _ = cr.fill();
    } else {
        cr.set_source_rgba(hull_top().0, hull_top().1, hull_top().2, 0.3);
        cr.arc(cx, cy, r + 1.0, 0.0, 2.0 * PI);
        let _ = cr.fill();
    }
    let hull = cairo::LinearGradient::new(cx, cy - r, cx, cy + r);
    hull.add_color_stop_rgb(0.0, hull_top().0, hull_top().1, hull_top().2);
    hull.add_color_stop_rgb(1.0, hull_bottom().0, hull_bottom().1, hull_bottom().2);
    let _ = cr.set_source(&hull);
    cr.arc(cx, cy, r, 0.0, 2.0 * PI);
    let _ = cr.fill();
    cr.set_source_rgb(1.0, 1.0, 1.0);
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    cr.set_font_size(9.0);
    if let Ok(ext) = cr.text_extents("?") {
        cr.move_to(cx - ext.width() / 2.0 - ext.x_bearing(), cy - ext.height() / 2.0 - ext.y_bearing());
        let _ = cr.show_text("?");
    }
}

struct State {
    kind: Cell<Indicator>,
    tick: RefCell<Option<gtk::TickCallbackId>>,
    started: Cell<i64>,
}

#[derive(Clone)]
pub struct Dot {
    pub area: gtk::DrawingArea,
    state: Rc<State>,
}

impl Dot {
    pub fn new(kind: Indicator) -> Dot {
        let area = gtk::DrawingArea::new();
        area.set_content_width(SIZE);
        area.set_content_height(SIZE);
        area.set_valign(gtk::Align::Center);
        area.set_halign(gtk::Align::Center);
        let state = Rc::new(State { kind: Cell::new(Indicator::None), tick: RefCell::new(None), started: Cell::new(glib::monotonic_time()) });
        let st = state.clone();
        area.set_draw_func(move |_, cr, width, height| {
            let (fw, fh) = (width as f64, height as f64);
            let animate = animations_enabled();
            let elapsed = (glib::monotonic_time() - st.started.get()) as f64 / 1_000_000.0;
            match st.kind.get() {
                Indicator::None => {}
                Indicator::Working => draw_spinner(cr, fw, fh, if animate { elapsed.fract() } else { 0.0 }),
                Indicator::Done => draw_done(cr, fw, fh),
                Indicator::Waiting => draw_waiting(cr, fw, fh, if animate { Some((elapsed / 1.4).fract()) } else { None }),
            }
        });
        let st = state.clone();
        area.connect_map(move |a| sync_ticking(a, &st));
        let st = state.clone();
        area.connect_unmap(move |_| stop(&st));
        let dot = Dot { area, state };
        dot.set(kind);
        dot
    }

    pub fn kind(&self) -> Indicator {
        self.state.kind.get()
    }

    pub fn set(&self, kind: Indicator) {
        let changed = self.state.kind.replace(kind) != kind;
        self.area.set_visible(kind != Indicator::None);
        let help = kind.help();
        self.area.set_tooltip_text(if help.is_empty() { None } else { Some(help) });
        self.area.update_property(&[gtk::accessible::Property::Label(help)]);
        if changed {
            self.state.started.set(glib::monotonic_time());
            self.area.queue_draw();
        }
        sync_ticking(&self.area, &self.state);
    }
}

fn stop(state: &State) {
    if let Some(id) = state.tick.borrow_mut().take() {
        id.remove();
    }
}

fn sync_ticking(area: &gtk::DrawingArea, state: &State) {
    let animated = matches!(state.kind.get(), Indicator::Working | Indicator::Waiting) && animations_enabled();
    if !animated || !area.is_mapped() {
        stop(state);
        return;
    }
    if state.tick.borrow().is_some() {
        return;
    }
    let last = Cell::new(0i64);
    let id = area.add_tick_callback(move |area, clock| {
        let now = clock.frame_time();
        if now - last.get() >= 33_000 {
            last.set(now);
            area.queue_draw();
        }
        glib::ControlFlow::Continue
    });
    *state.tick.borrow_mut() = Some(id);
}

pub fn dot(kind: Indicator) -> gtk::Widget {
    Dot::new(kind).area.upcast()
}

pub fn tree_guide(last: bool) -> gtk::Widget {
    let area = gtk::DrawingArea::new();
    area.set_content_width(12);
    area.set_vexpand(true);
    area.set_valign(gtk::Align::Fill);
    area.set_margin_start(10);
    area.set_draw_func(move |a, cr, _w, h| {
        let color = a.color();
        cr.set_source_rgba(color.red() as f64, color.green() as f64, color.blue() as f64, 0.28);
        cr.set_line_width(1.0);
        let x = 0.5;
        let h = h as f64;
        let mid = h / 2.0;
        cr.move_to(x, 0.0);
        if last {
            cr.line_to(x, mid - 6.0);
            cr.curve_to(x, mid - 2.0, x + 2.0, mid, x + 8.0, mid);
        } else {
            cr.line_to(x, h);
            cr.move_to(x, mid);
            cr.line_to(x + 8.0, mid);
        }
        let _ = cr.stroke();
    });
    area.upcast()
}
