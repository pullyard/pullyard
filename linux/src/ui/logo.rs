use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, glib, graphene, gsk};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Mode {
    #[default]
    Loop,
    Once,
    Wake,
}

const BOX_X: f32 = 150.0;
const BOX_Y: f32 = 370.0;
const BOX_W: f32 = 750.0;
const BOX_H: f32 = 500.0;

const DRAW: f64 = 1.7;
const HOLD: f64 = 0.5;
const FADE: f64 = 0.55;
pub const ONCE: f64 = 0.9;

fn rgba(r: f32, g: f32, b: f32, a: f32) -> gdk::RGBA {
    gdk::RGBA::new(r, g, b, a)
}

fn violet() -> gdk::RGBA {
    rgba(0.655, 0.545, 0.980, 1.0)
}

fn sky() -> gdk::RGBA {
    rgba(0.220, 0.741, 0.973, 1.0)
}

fn hull_top() -> gdk::RGBA {
    rgba(0.984, 0.443, 0.522, 1.0)
}

fn hull_bottom() -> gdk::RGBA {
    rgba(0.839, 0.122, 0.306, 1.0)
}

fn deck() -> gdk::RGBA {
    rgba(0.996, 0.804, 0.827, 1.0)
}

fn cabin() -> gdk::RGBA {
    rgba(0.973, 0.980, 0.988, 1.0)
}

fn cabin_shade() -> gdk::RGBA {
    rgba(0.886, 0.910, 0.941, 1.0)
}

fn window() -> gdk::RGBA {
    rgba(0.118, 0.161, 0.231, 1.0)
}

fn wave(alpha: f32) -> gdk::RGBA {
    rgba(0.490, 0.827, 0.988, alpha)
}

fn pt(x: f32, y: f32) -> graphene::Point {
    graphene::Point::new(x, y)
}

fn rect(x: f32, y: f32, w: f32, h: f32) -> graphene::Rect {
    graphene::Rect::new(x, y, w, h)
}

fn build(f: impl FnOnce(&gsk::PathBuilder)) -> gsk::Path {
    let b = gsk::PathBuilder::new();
    f(&b);
    b.to_path()
}

fn polygon(points: &[(f32, f32)]) -> gsk::Path {
    build(|b| {
        let (x, y) = points[0];
        b.move_to(x, y);
        for (x, y) in &points[1..] {
            b.line_to(*x, *y);
        }
        b.close();
    })
}

fn rounded(x: f32, y: f32, w: f32, h: f32, r: f32) -> gsk::Path {
    build(|b| b.add_rounded_rect(&gsk::RoundedRect::from_rect(rect(x, y, w, h), r)))
}

pub struct Geometry {
    node_a: gsk::Path,
    node_b: gsk::Path,
    curve_a: gsk::Path,
    curve_b: gsk::Path,
    hull: gsk::Path,
    deck_strip: gsk::Path,
    cabin: gsk::Path,
    cabin_shade: gsk::Path,
    chimney: gsk::Path,
    chimney_top: gsk::Path,
    windows: gsk::Path,
    porthole: gsk::Path,
    wave1: gsk::Path,
    wave2: gsk::Path,
}

impl Geometry {
    fn new() -> Self {
        Geometry {
            node_a: build(|b| b.add_circle(&pt(206.0, 500.0), 34.0)),
            node_b: build(|b| b.add_circle(&pt(206.0, 772.0), 34.0)),
            curve_a: build(|b| {
                b.move_to(240.0, 500.0);
                b.cubic_to(392.0, 500.0, 420.0, 636.0, 520.0, 636.0);
            }),
            curve_b: build(|b| {
                b.move_to(240.0, 772.0);
                b.cubic_to(392.0, 772.0, 420.0, 636.0, 520.0, 636.0);
            }),
            hull: polygon(&[(470.0, 566.0), (866.0, 566.0), (800.0, 728.0), (540.0, 728.0)]),
            deck_strip: polygon(&[(470.0, 566.0), (866.0, 566.0), (857.0, 590.0), (480.0, 590.0)]),
            cabin: rounded(584.0, 462.0, 176.0, 104.0, 16.0),
            cabin_shade: build(|b| b.add_rect(&rect(584.0, 540.0, 176.0, 26.0))),
            chimney: rounded(702.0, 392.0, 40.0, 86.0, 8.0),
            chimney_top: rounded(702.0, 392.0, 40.0, 20.0, 6.0),
            windows: build(|b| {
                b.add_rounded_rect(&gsk::RoundedRect::from_rect(rect(610.0, 488.0, 38.0, 34.0), 8.0));
                b.add_rounded_rect(&gsk::RoundedRect::from_rect(rect(664.0, 488.0, 38.0, 34.0), 8.0));
            }),
            porthole: build(|b| b.add_circle(&pt(770.0, 642.0), 15.0)),
            wave1: build(|b| {
                b.move_to(560.0, 786.0);
                b.cubic_to(620.0, 770.0, 660.0, 802.0, 720.0, 786.0);
                b.cubic_to(780.0, 770.0, 820.0, 770.0, 870.0, 786.0);
            }),
            wave2: build(|b| {
                b.move_to(600.0, 836.0);
                b.cubic_to(650.0, 822.0, 690.0, 848.0, 740.0, 836.0);
                b.cubic_to(790.0, 824.0, 820.0, 822.0, 850.0, 836.0);
            }),
        }
    }
}

thread_local! {
    static GEOMETRY: Geometry = Geometry::new();
}

fn clamp01(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

fn stage(progress: f64, from: f64, to: f64) -> f64 {
    let t = clamp01((progress - from) / (to - from));
    if t < 0.5 {
        4.0 * t * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
    }
}

fn ease_in_out(t: f64) -> f64 {
    if t < 0.5 {
        2.0 * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(2) / 2.0
    }
}

pub fn loop_frame(elapsed: f64) -> (f64, f64) {
    let cycle = DRAW + HOLD + FADE;
    let t = elapsed.rem_euclid(cycle);
    let progress = (t / DRAW).min(1.0);
    let erase = if t > DRAW + HOLD { (t - DRAW - HOLD) / FADE } else { 0.0 };
    (progress, ease_in_out(clamp01(erase)))
}

fn trimmed(path: &gsk::Path, from: f64, to: f64) -> Option<gsk::Path> {
    let from = clamp01(from);
    let to = clamp01(to);
    if to <= from + 0.0005 {
        return None;
    }
    if from <= 0.0 && to >= 1.0 {
        return Some(path.clone());
    }
    let measure = gsk::PathMeasure::new(path);
    let length = measure.length();
    let start = measure.point(length * from as f32)?;
    let end = measure.point(length * to as f32)?;
    let b = gsk::PathBuilder::new();
    b.add_segment(path, &start, &end);
    Some(b.to_path())
}

fn stroke_part(snapshot: &gtk::Snapshot, path: &gsk::Path, from: f64, to: f64, width: f32, color: &gdk::RGBA) {
    let Some(p) = trimmed(path, from, to) else {
        return;
    };
    let stroke = gsk::Stroke::new(width);
    stroke.set_line_cap(gsk::LineCap::Round);
    stroke.set_line_join(gsk::LineJoin::Round);
    snapshot.append_stroke(&p, &stroke, color);
}

fn fill(snapshot: &gtk::Snapshot, path: &gsk::Path, color: &gdk::RGBA) {
    snapshot.append_fill(path, gsk::FillRule::Winding, color);
}

pub fn draw_mark(snapshot: &gtk::Snapshot, width: f32, height: f32, progress: f64, erase: f64) {
    let scale = (width / BOX_W).min(height / BOX_H);
    let dx = width / 2.0 - (BOX_X + BOX_W / 2.0) * scale;
    let dy = height / 2.0 - (BOX_Y + BOX_H / 2.0) * scale;
    snapshot.save();
    snapshot.translate(&pt(dx, dy));
    snapshot.scale(scale, scale);
    let nodes = stage(progress, 0.00, 0.22);
    let curves = stage(progress, 0.14, 0.48);
    let hull_line = stage(progress, 0.40, 0.68);
    let hull_fill = stage(progress, 0.58, 0.78);
    let cabin_t = stage(progress, 0.66, 0.86);
    let waves = stage(progress, 0.74, 1.00);
    let tail = clamp01(erase);
    GEOMETRY.with(|g| {
        stroke_part(snapshot, &g.node_a, tail, nodes, 18.0, &violet());
        stroke_part(snapshot, &g.node_b, tail, nodes, 18.0, &sky());
        stroke_part(snapshot, &g.curve_a, tail, curves, 24.0, &violet());
        stroke_part(snapshot, &g.curve_b, tail, curves, 24.0, &sky());
        let fill_alpha = (hull_fill * (1.0 - tail)) as f32;
        if fill_alpha > 0.001 {
            snapshot.push_opacity(fill_alpha as f64);
            snapshot.push_fill(&g.hull, gsk::FillRule::Winding);
            snapshot.append_linear_gradient(&rect(470.0, 566.0, 396.0, 162.0), &pt(668.0, 566.0), &pt(668.0, 728.0), &[gsk::ColorStop::new(0.0, hull_top()), gsk::ColorStop::new(1.0, hull_bottom())]);
            snapshot.pop();
            fill(snapshot, &g.deck_strip, &deck());
            fill(snapshot, &g.porthole, &deck());
            snapshot.pop();
        }
        let line_alpha = 1.0 - hull_fill * 0.85;
        if line_alpha > 0.001 {
            snapshot.push_opacity(line_alpha);
            stroke_part(snapshot, &g.hull, tail, hull_line, 14.0, &hull_top());
            snapshot.pop();
        }
        let cabin_alpha = cabin_t * (1.0 - tail);
        if cabin_alpha > 0.001 {
            snapshot.save();
            snapshot.translate(&pt(0.0, 566.0));
            snapshot.scale(1.0, (0.6 + 0.4 * cabin_t) as f32);
            snapshot.translate(&pt(0.0, -566.0));
            snapshot.push_opacity(cabin_alpha);
            fill(snapshot, &g.chimney, &cabin_shade());
            fill(snapshot, &g.chimney_top, &hull_top());
            fill(snapshot, &g.cabin, &cabin());
            fill(snapshot, &g.cabin_shade, &cabin_shade());
            fill(snapshot, &g.windows, &window());
            snapshot.pop();
            snapshot.restore();
        }
        stroke_part(snapshot, &g.wave1, tail, waves, 12.0, &wave(0.55));
        stroke_part(snapshot, &g.wave2, tail, (waves - 0.15).max(0.0) / 0.85, 10.0, &wave(0.32));
    });
    snapshot.restore();
}

pub fn wake_phase(elapsed: f64, i: usize) -> f64 {
    (elapsed * 1.6 - i as f64 * 0.22).rem_euclid(1.0)
}

pub fn draw_wake(snapshot: &gtk::Snapshot, width: f32, height: f32, elapsed: f64, still: bool) {
    let colors = [sky(), rgba(0.43, 0.65, 0.98, 1.0), violet()];
    let unit = (width / 20.0).min(height / 12.0);
    let ox = (width - 20.0 * unit) / 2.0;
    let oy = (height - 12.0 * unit) / 2.0;
    for (i, c) in colors.iter().enumerate() {
        let p = if still { 0.5 } else { wake_phase(elapsed, i) };
        let lift = (p * std::f64::consts::PI).sin() as f32;
        let x = ox + unit * 20.0 * (0.12 + 0.3 * i as f32);
        let y = oy + unit * (12.0 * 0.62 - lift * 12.0 * 0.28);
        let path = build(|b| {
            b.move_to(x - 3.0 * unit, y);
            b.quad_to(x, y - 3.0 * unit, x + 3.0 * unit, y);
        });
        let stroke = gsk::Stroke::new(2.0 * unit);
        stroke.set_line_cap(gsk::LineCap::Round);
        let mut color = *c;
        color.set_alpha(0.45 + 0.55 * lift);
        snapshot.append_stroke(&path, &stroke, &color);
    }
}

pub fn animations_enabled() -> bool {
    gtk::Settings::default().map(|s| s.is_gtk_enable_animations()).unwrap_or(true)
}

mod imp {
    use std::cell::{Cell, RefCell};

    use super::*;

    #[derive(Default)]
    pub struct Loader {
        pub mode: Cell<Mode>,
        pub width: Cell<i32>,
        pub height: Cell<i32>,
        pub spinning: Cell<bool>,
        pub start: Cell<Option<i64>>,
        pub elapsed: Cell<f64>,
        pub last_draw: Cell<i64>,
        pub tick: RefCell<Option<gtk::TickCallbackId>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Loader {
        const NAME: &'static str = "PyLogoLoader";
        type Type = super::Loader;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_accessible_role(gtk::AccessibleRole::Img);
        }
    }

    impl ObjectImpl for Loader {
        fn dispose(&self) {
            self.stop();
        }
    }

    impl Loader {
        pub fn finished(&self) -> bool {
            self.mode.get() == Mode::Once && self.elapsed.get() >= ONCE
        }

        pub fn start(&self) {
            if self.tick.borrow().is_some() || !self.spinning.get() || self.finished() {
                return;
            }
            let obj = self.obj();
            if !obj.is_mapped() {
                return;
            }
            if !animations_enabled() {
                if self.mode.get() == Mode::Once {
                    self.elapsed.set(ONCE);
                }
                obj.queue_draw();
                return;
            }
            let id = obj.add_tick_callback(|w, clock| {
                let imp = w.imp();
                let now = clock.frame_time();
                let start = match imp.start.get() {
                    Some(s) => s,
                    None => {
                        let s = now - (imp.elapsed.get() * 1_000_000.0) as i64;
                        imp.start.set(Some(s));
                        s
                    }
                };
                imp.elapsed.set((now - start) as f64 / 1_000_000.0);
                let interval = if imp.mode.get() == Mode::Once { 0 } else { 30_000 };
                if now - imp.last_draw.get() >= interval {
                    imp.last_draw.set(now);
                    w.queue_draw();
                }
                if imp.finished() {
                    imp.tick.borrow_mut().take();
                    w.queue_draw();
                    return glib::ControlFlow::Break;
                }
                glib::ControlFlow::Continue
            });
            *self.tick.borrow_mut() = Some(id);
        }

        pub fn stop(&self) {
            if let Some(id) = self.tick.borrow_mut().take() {
                id.remove();
            }
            self.start.set(None);
        }
    }

    impl WidgetImpl for Loader {
        fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            let v = if orientation == gtk::Orientation::Horizontal { self.width.get() } else { self.height.get() };
            (v, v, -1, -1)
        }

        fn map(&self) {
            self.parent_map();
            self.start();
        }

        fn unmap(&self) {
            self.stop();
            self.parent_unmap();
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let w = obj.width() as f32;
            let h = obj.height() as f32;
            if w <= 0.0 || h <= 0.0 {
                return;
            }
            let still = !self.spinning.get() || !animations_enabled();
            match self.mode.get() {
                Mode::Wake => draw_wake(snapshot, w, h, self.elapsed.get(), still),
                Mode::Once => {
                    let p = if still { 1.0 } else { (self.elapsed.get() / ONCE).min(1.0) };
                    draw_mark(snapshot, w, h, p, 0.0);
                }
                Mode::Loop => {
                    if still {
                        snapshot.push_opacity(0.8);
                        draw_mark(snapshot, w, h, 1.0, 0.0);
                        snapshot.pop();
                    } else {
                        let (p, e) = loop_frame(self.elapsed.get());
                        draw_mark(snapshot, w, h, p, e);
                    }
                }
            }
        }
    }
}

glib::wrapper! {
    pub struct Loader(ObjectSubclass<imp::Loader>) @extends gtk::Widget, @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Loader {
    pub fn new(mode: Mode, width: i32, height: i32) -> Self {
        let l: Loader = glib::Object::new();
        let imp = l.imp();
        imp.mode.set(mode);
        imp.width.set(width.max(1));
        imp.height.set(height.max(1));
        imp.spinning.set(true);
        l.update_property(&[gtk::accessible::Property::Label(if mode == Mode::Wake { "Running" } else { "Loading" })]);
        l
    }

    pub fn logo(size: i32) -> Self {
        Self::new(Mode::Loop, size, (size as f32 * BOX_H / BOX_W).round() as i32)
    }

    pub fn once(size: i32) -> Self {
        Self::new(Mode::Once, size, (size as f32 * BOX_H / BOX_W).round() as i32)
    }

    pub fn wake(height: i32) -> Self {
        Self::new(Mode::Wake, (height as f32 * 20.0 / 12.0).round() as i32, height)
    }

    pub fn set_spinning(&self, on: bool) {
        let imp = self.imp();
        if imp.spinning.replace(on) == on {
            return;
        }
        if on {
            imp.start();
        } else {
            imp.stop();
        }
        self.queue_draw();
    }

    pub fn is_spinning(&self) -> bool {
        self.imp().spinning.get()
    }

    pub fn is_animating(&self) -> bool {
        self.imp().tick.borrow().is_some()
    }

    pub fn is_finished(&self) -> bool {
        self.imp().finished()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_ease_from_zero_to_one() {
        assert_eq!(stage(0.0, 0.1, 0.5), 0.0);
        assert_eq!(stage(1.0, 0.1, 0.5), 1.0);
        assert!((stage(0.3, 0.1, 0.5) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn loop_draws_holds_then_erases() {
        let (p, e) = loop_frame(0.85);
        assert!((p - 0.5).abs() < 1e-9);
        assert_eq!(e, 0.0);
        let (p, e) = loop_frame(DRAW + 0.2);
        assert_eq!((p, e), (1.0, 0.0));
        let (p, e) = loop_frame(DRAW + HOLD + FADE - 0.001);
        assert_eq!(p, 1.0);
        assert!(e > 0.99);
        let (p, _) = loop_frame(DRAW + HOLD + FADE + 0.1);
        assert!(p < 0.1);
    }

    #[test]
    fn wake_waves_are_staggered() {
        let a = wake_phase(1.0, 0);
        let b = wake_phase(1.0, 1);
        assert!((a - b - 0.22).rem_euclid(1.0) < 1e-9);
        assert!((0.0..1.0).contains(&wake_phase(0.0, 2)));
    }
}
