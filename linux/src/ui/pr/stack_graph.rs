use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, glib, graphene, gsk, pango};

use crate::stack::{self, metrics, Edge, EdgeShape, StackGeometry, StackLayout, StackTree, StackViewport, Vec2};

pub type CardFactory = Rc<dyn Fn(i64, bool) -> gtk::Widget>;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct StackCanvas {
        pub tree: RefCell<Option<StackTree>>,
        pub geometry: RefCell<Option<StackGeometry>>,
        pub edges: RefCell<Vec<Edge>>,
        pub view: Cell<Option<StackViewport>>,
        pub size: Cell<(i32, i32)>,
        pub cards: RefCell<HashMap<i64, (gtk::Widget, bool)>>,
        pub pill: RefCell<Option<gtk::Widget>>,
        pub probes: RefCell<Vec<gtk::Widget>>,
        pub factory: RefCell<Option<CardFactory>>,
        pub pill_factory: RefCell<Option<Rc<dyn Fn(&str) -> gtk::Widget>>>,
        pub on_view: RefCell<Option<Rc<dyn Fn(f64)>>>,
        pub animation: RefCell<Option<adw::TimedAnimation>>,
        pub sync_pending: Cell<bool>,
        pub pointer: Cell<(f64, f64)>,
        pub drag_start: Cell<Option<StackViewport>>,
        pub pinch_start: Cell<Option<StackViewport>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StackCanvas {
        const NAME: &'static str = "PyStackCanvas";
        type Type = super::StackCanvas;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("stackcanvas");
        }
    }

    impl ObjectImpl for StackCanvas {
        fn dispose(&self) {
            if let Some(a) = self.animation.borrow_mut().take() {
                a.skip();
            }
            self.cards.borrow_mut().clear();
            self.pill.borrow_mut().take();
            self.probes.borrow_mut().clear();
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for StackCanvas {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            (0, 240, -1, -1)
        }

        fn size_allocate(&self, width: i32, height: i32, _baseline: i32) {
            let obj = self.obj();
            if self.size.get() != (width, height) {
                self.size.set((width, height));
                if let Some(v) = self.view.get() {
                    self.view.set(Some(obj.clamp_view(v)));
                }
                obj.schedule_sync();
            }
            for p in self.probes.borrow().iter() {
                p.allocate(0, 0, -1, None);
            }
            let Some(vp) = obj.viewport() else { return };
            let geometry = self.geometry.borrow();
            let Some(geometry) = geometry.as_ref() else { return };
            let root = self.tree.borrow().as_ref().map(|t| t.root);
            if let (Some(pill), Some(root)) = (self.pill.borrow().as_ref(), root) {
                if let Some(o) = geometry.origin(root) {
                    let at = vp.to_screen(Vec2::new(o.x + (metrics::CARD_WIDTH - metrics::PILL_WIDTH) / 2.0, metrics::PAD));
                    place(pill, at, vp.zoom, metrics::PILL_WIDTH, metrics::PILL_HEIGHT);
                }
            }
            for (number, (card, compact)) in self.cards.borrow().iter() {
                let (Some(o), Some(bottom)) = (geometry.origin(*number), geometry.bottom(*number)) else { continue };
                let height = if *compact { metrics::CARD_HEIGHT } else { bottom - o.y };
                place(card, vp.to_screen(o), vp.zoom, metrics::CARD_WIDTH, height);
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            if let Some(vp) = obj.viewport() {
                let (w, h) = self.size.get();
                obj.draw_edges(snapshot, &vp, w as f64, h as f64);
            }
            if let Some(pill) = self.pill.borrow().as_ref() {
                obj.snapshot_child(pill, snapshot);
            }
            for (card, _) in self.cards.borrow().values() {
                obj.snapshot_child(card, snapshot);
            }
        }
    }

    fn place(w: &gtk::Widget, at: Vec2, zoom: f64, width: f64, height: f64) {
        let (min_h, _, _, _) = w.measure(gtk::Orientation::Vertical, width as i32);
        let (min_w, _, _, _) = w.measure(gtk::Orientation::Horizontal, -1);
        let t = gsk::Transform::new().translate(&graphene::Point::new(at.x as f32, at.y as f32)).scale(zoom as f32, zoom as f32);
        w.allocate((width as i32).max(min_w), (height as i32).max(min_h), -1, Some(t));
    }
}

glib::wrapper! {
    pub struct StackCanvas(ObjectSubclass<imp::StackCanvas>) @extends gtk::Widget, @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl StackCanvas {
    pub fn new(factory: CardFactory, pill_factory: Rc<dyn Fn(&str) -> gtk::Widget>, on_view: Rc<dyn Fn(f64)>) -> Self {
        let me: StackCanvas = glib::Object::new();
        me.add_css_class("stack-canvas");
        me.set_overflow(gtk::Overflow::Hidden);
        me.set_hexpand(true);
        me.set_vexpand(true);
        me.set_focusable(true);
        let imp = me.imp();
        *imp.factory.borrow_mut() = Some(factory);
        *imp.pill_factory.borrow_mut() = Some(pill_factory);
        *imp.on_view.borrow_mut() = Some(on_view);
        let probes: Vec<gtk::Widget> = ["fg-indigo", "sy-dim", "sy-muted"]
            .iter()
            .map(|class| {
                let b = gtk::Box::new(gtk::Orientation::Horizontal, 0);
                b.add_css_class(class);
                b.set_can_target(false);
                b.set_parent(&me);
                b.upcast()
            })
            .collect();
        *imp.probes.borrow_mut() = probes;
        me.install_input();
        let weak = me.downgrade();
        crate::theme::on_change(move |_| match weak.upgrade() {
            Some(me) => {
                me.queue_draw();
                true
            }
            None => false,
        });
        me
    }

    fn install_input(&self) {
        let motion = gtk::EventControllerMotion::new();
        let weak = self.downgrade();
        motion.connect_motion(move |_, x, y| {
            if let Some(me) = weak.upgrade() {
                me.imp().pointer.set((x, y));
            }
        });
        self.add_controller(motion);

        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
        let weak = self.downgrade();
        scroll.connect_scroll(move |c, dx, dy| {
            let Some(me) = weak.upgrade() else { return glib::Propagation::Proceed };
            me.stop_animation();
            let precise = c.unit() == gdk::ScrollUnit::Surface;
            if c.current_event_state().contains(gdk::ModifierType::CONTROL_MASK) {
                let (x, y) = me.imp().pointer.get();
                let factor = (1.0 - dy * if precise { 0.006 } else { 0.1 }).clamp(0.5, 2.0);
                me.update(|v, g, size| v.zoomed(v.zoom * factor, Vec2::new(x, y), g, size));
            } else {
                let k = if precise { 1.0 } else { 48.0 };
                me.update(|v, g, size| v.panned(Vec2::new(-dx * k, -dy * k), g, size));
            }
            glib::Propagation::Stop
        });
        self.add_controller(scroll);

        let zoom = gtk::GestureZoom::new();
        let weak = self.downgrade();
        zoom.connect_begin(move |_, _| {
            if let Some(me) = weak.upgrade() {
                me.stop_animation();
                me.imp().pinch_start.set(me.viewport());
            }
        });
        let weak = self.downgrade();
        zoom.connect_scale_changed(move |g, scale| {
            let Some(me) = weak.upgrade() else { return };
            let Some(start) = me.imp().pinch_start.get() else { return };
            let (x, y) = g.bounding_box_center().unwrap_or(me.imp().pointer.get());
            me.update(|_, geo, size| start.zoomed(start.zoom * scale, Vec2::new(x, y), geo, size));
        });
        let weak = self.downgrade();
        zoom.connect_end(move |_, _| {
            if let Some(me) = weak.upgrade() {
                me.imp().pinch_start.set(None);
            }
        });
        self.add_controller(zoom);

        let drag = gtk::GestureDrag::new();
        let weak = self.downgrade();
        drag.connect_drag_begin(move |_, _, _| {
            if let Some(me) = weak.upgrade() {
                me.stop_animation();
                me.imp().drag_start.set(me.viewport());
            }
        });
        let weak = self.downgrade();
        drag.connect_drag_update(move |_, ox, oy| {
            let Some(me) = weak.upgrade() else { return };
            if me.imp().pinch_start.get().is_some() {
                return;
            }
            let Some(start) = me.imp().drag_start.get() else { return };
            me.update(|_, geo, size| start.panned(Vec2::new(ox, oy), geo, size));
        });
        let weak = self.downgrade();
        drag.connect_drag_end(move |_, _, _| {
            if let Some(me) = weak.upgrade() {
                me.imp().drag_start.set(None);
            }
        });
        self.add_controller(drag);
    }

    pub fn set_tree(&self, tree: &StackTree, noted: HashSet<i64>) {
        let imp = self.imp();
        let same_root = imp.tree.borrow().as_ref().is_some_and(|t| t.root == tree.root && t.base == tree.base);
        let geometry = StackGeometry::new(StackLayout::new(tree), noted);
        *imp.edges.borrow_mut() = stack::edges(tree, &geometry);
        *imp.geometry.borrow_mut() = Some(geometry);
        *imp.tree.borrow_mut() = Some(tree.clone());
        if !same_root {
            if let Some(p) = imp.pill.borrow_mut().take() {
                p.unparent();
            }
            let pill = imp.pill_factory.borrow().as_ref().map(|f| f(&tree.base));
            if let Some(p) = &pill {
                p.insert_after(self, imp.probes.borrow().last());
            }
            *imp.pill.borrow_mut() = pill;
        }
        self.drop_cards();
        if let Some(v) = imp.view.get() {
            imp.view.set(Some(self.clamp_view(v)));
        }
        self.sync_cards();
        self.queue_allocate();
        self.queue_draw();
    }

    pub fn refresh_cards(&self) {
        self.drop_cards();
        self.sync_cards();
        self.queue_allocate();
    }

    pub fn refresh_card(&self, number: i64) {
        let removed = self.imp().cards.borrow_mut().remove(&number);
        if let Some((w, _)) = removed {
            w.unparent();
            self.sync_cards();
            self.queue_allocate();
        }
    }

    fn drop_cards(&self) {
        let cards: Vec<(gtk::Widget, bool)> = self.imp().cards.borrow_mut().drain().map(|(_, v)| v).collect();
        for (w, _) in cards {
            w.unparent();
        }
    }

    fn content(&self) -> Vec2 {
        self.imp().geometry.borrow().as_ref().map(|g| g.size).unwrap_or_default()
    }

    fn size_vec(&self) -> Option<Vec2> {
        let (w, h) = self.imp().size.get();
        (w > 0 && h > 0).then(|| Vec2::new(w as f64, h as f64))
    }

    fn clamp_view(&self, v: StackViewport) -> StackViewport {
        match self.size_vec() {
            Some(size) => v.clamped(self.content(), size),
            None => v,
        }
    }

    fn initial(&self) -> Option<StackViewport> {
        let size = self.size_vec()?;
        let content = self.content();
        let current = self.imp().tree.borrow().as_ref().map(|t| t.current)?;
        let center = self.imp().geometry.borrow().as_ref().and_then(|g| g.center(current));
        Some(match center {
            Some(c) => StackViewport::centered(c, 1.0, content, size),
            None => StackViewport::default().clamped(content, size),
        })
    }

    pub fn viewport(&self) -> Option<StackViewport> {
        if let Some(v) = self.imp().view.get() {
            return Some(v);
        }
        let v = self.initial()?;
        self.imp().view.set(Some(v));
        self.notify_view(v.zoom);
        Some(v)
    }

    fn notify_view(&self, zoom: f64) {
        let f = self.imp().on_view.borrow().clone();
        if let Some(f) = f {
            glib::idle_add_local_once(move || f(zoom));
        }
    }

    fn set_view(&self, v: StackViewport) {
        let imp = self.imp();
        let old = imp.view.get();
        if old == Some(v) {
            return;
        }
        imp.view.set(Some(v));
        if old.map(|o| o.zoom) != Some(v.zoom) {
            self.notify_view(v.zoom);
        }
        self.sync_cards();
        self.queue_allocate();
        self.queue_draw();
    }

    fn update(&self, change: impl FnOnce(StackViewport, Vec2, Vec2) -> StackViewport) {
        let (Some(v), Some(size)) = (self.viewport(), self.size_vec()) else { return };
        let next = change(v, self.content(), size);
        self.set_view(next);
    }

    fn stop_animation(&self) {
        if let Some(a) = self.imp().animation.borrow_mut().take() {
            a.pause();
        }
    }

    pub fn animate(&self, change: impl FnOnce(StackViewport, Vec2, Vec2) -> StackViewport) {
        let (Some(from), Some(size)) = (self.viewport(), self.size_vec()) else { return };
        let to = change(from, self.content(), size);
        self.stop_animation();
        if !adw::is_animations_enabled(self) {
            self.set_view(to);
            return;
        }
        let weak = self.downgrade();
        let target = adw::CallbackAnimationTarget::new(move |t| {
            if let Some(me) = weak.upgrade() {
                me.set_view(from.lerp(&to, t));
            }
        });
        let a = adw::TimedAnimation::new(self, 0.0, 1.0, 220, target);
        a.set_easing(adw::Easing::EaseOutCubic);
        *self.imp().animation.borrow_mut() = Some(a.clone());
        a.play();
    }

    pub fn zoom_by(&self, delta: f64) {
        let Some(size) = self.size_vec() else { return };
        let middle = Vec2::new(size.x / 2.0, size.y / 2.0);
        self.animate(|v, g, s| v.zoomed(v.zoom + delta, middle, g, s));
    }

    pub fn actual_size(&self) {
        let Some(size) = self.size_vec() else { return };
        let middle = Vec2::new(size.x / 2.0, size.y / 2.0);
        self.animate(|v, g, s| v.zoomed(1.0, middle, g, s));
    }

    pub fn fit(&self) {
        self.animate(|_, g, s| StackViewport::fit(g, s));
    }

    pub fn focus_current(&self) {
        let center = {
            let tree = self.imp().tree.borrow();
            let geometry = self.imp().geometry.borrow();
            tree.as_ref().zip(geometry.as_ref()).and_then(|(t, g)| g.center(t.current))
        };
        let Some(center) = center else { return };
        self.animate(|v, g, s| StackViewport::centered(center, v.zoom.max(1.0), g, s));
    }

    fn schedule_sync(&self) {
        let imp = self.imp();
        if imp.sync_pending.replace(true) {
            return;
        }
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(me) = weak.upgrade() {
                me.imp().sync_pending.set(false);
                me.sync_cards();
                me.queue_allocate();
            }
        });
    }

    fn sync_cards(&self) {
        let imp = self.imp();
        let (Some(vp), Some(size)) = (self.viewport(), self.size_vec()) else { return };
        let visible = {
            let tree = imp.tree.borrow();
            let geometry = imp.geometry.borrow();
            let (Some(tree), Some(geometry)) = (tree.as_ref(), geometry.as_ref()) else { return };
            stack::visible_cards(tree, geometry, &vp, size)
        };
        let compact = vp.zoom < stack::COMPACT_BELOW;
        let stale: Vec<i64> = imp.cards.borrow().iter().filter(|(n, (_, c))| !visible.contains(n) || *c != compact).map(|(n, _)| *n).collect();
        for n in stale {
            if let Some((w, _)) = imp.cards.borrow_mut().remove(&n) {
                w.unparent();
            }
        }
        let factory = imp.factory.borrow().clone();
        let Some(factory) = factory else { return };
        let mut missing: Vec<i64> = visible.into_iter().filter(|n| !imp.cards.borrow().contains_key(n)).collect();
        missing.sort_unstable();
        for n in missing {
            let w = factory(n, compact);
            w.set_parent(self);
            imp.cards.borrow_mut().insert(n, (w, compact));
        }
    }

    pub fn card_count(&self) -> usize {
        self.imp().cards.borrow().len()
    }

    fn probe_color(&self, i: usize) -> gdk::RGBA {
        self.imp().probes.borrow().get(i).map(|p| p.color()).unwrap_or(gdk::RGBA::new(0.5, 0.5, 0.5, 1.0))
    }

    fn draw_edges(&self, snapshot: &gtk::Snapshot, vp: &StackViewport, width: f64, height: f64) {
        let edges = self.imp().edges.borrow();
        if edges.is_empty() {
            return;
        }
        let pad = 40.0;
        let lit = gsk::PathBuilder::new();
        let dim = gsk::PathBuilder::new();
        let (mut any_lit, mut any_dim) = (false, false);
        let mut labels: Vec<(Vec2, bool, bool)> = vec![];
        for e in edges.iter() {
            let (lo, hi) = e.shape.bounds();
            let (a, b) = (vp.to_screen(lo), vp.to_screen(hi));
            if b.x < -pad || a.x > width + pad || b.y < -pad || a.y > height + pad {
                continue;
            }
            let builder = if e.lit { &lit } else { &dim };
            append_shape(builder, &e.shape, vp);
            if e.lit {
                any_lit = true;
            } else {
                any_dim = true;
            }
            if let Some((p, from_right)) = e.label {
                labels.push((vp.to_screen(p), from_right, e.lit));
            }
        }
        let z = vp.zoom;
        let indigo = self.probe_color(0);
        let faint = if z < 0.5 { self.probe_color(2) } else { self.probe_color(1) };
        if any_dim {
            let stroke = gsk::Stroke::new(1.1);
            stroke.set_line_cap(gsk::LineCap::Round);
            stroke.set_line_join(gsk::LineJoin::Round);
            stroke.set_dash(&[5.0, 4.0]);
            snapshot.append_stroke(&dim.to_path(), &stroke, &faint);
        }
        if any_lit {
            let stroke = gsk::Stroke::new(1.8);
            stroke.set_line_cap(gsk::LineCap::Round);
            stroke.set_line_join(gsk::LineJoin::Round);
            snapshot.append_stroke(&lit.to_path(), &stroke, &indigo);
        }
        if z < 0.5 || labels.is_empty() {
            return;
        }
        let layout = self.create_pango_layout(Some("stacked on"));
        let mut font = pango::FontDescription::new();
        font.set_absolute_size(10.0 * z * pango::SCALE as f64);
        layout.set_font_description(Some(&font));
        let (lw, lh) = layout.pixel_size();
        let dim_text = self.probe_color(1);
        for (p, from_right, is_lit) in labels {
            let x = p.x + if from_right { -6.0 * z - lw as f64 } else { 6.0 * z };
            let y = p.y - 12.0 * z - lh as f64 / 2.0;
            if x > width + 10.0 || x + (lw as f64) < -10.0 || y > height + 10.0 || y + (lh as f64) < -10.0 {
                continue;
            }
            snapshot.save();
            snapshot.translate(&graphene::Point::new(x as f32, y as f32));
            snapshot.append_layout(&layout, if is_lit { &indigo } else { &dim_text });
            snapshot.restore();
        }
    }
}

fn append_shape(b: &gsk::PathBuilder, shape: &EdgeShape, vp: &StackViewport) {
    let s = |p: Vec2| {
        let q = vp.to_screen(p);
        (q.x as f32, q.y as f32)
    };
    match *shape {
        EdgeShape::Line(from, to) => {
            let (fx, fy) = s(from);
            let (tx, ty) = s(to);
            b.move_to(fx, fy);
            b.line_to(tx, ty);
        }
        EdgeShape::Curve(from, to) => {
            let mid = (from.y + to.y) / 2.0;
            let (fx, fy) = s(from);
            let (c1x, c1y) = s(Vec2::new(from.x, mid));
            let (c2x, c2y) = s(Vec2::new(to.x, mid));
            let (tx, ty) = s(to);
            b.move_to(fx, fy);
            b.cubic_to(c1x, c1y, c2x, c2y, tx, ty);
        }
        EdgeShape::Elbow(from, to, bus) => {
            let (fx, fy) = s(from);
            b.move_to(fx, fy);
            let dx = to.x - from.x;
            if dx.abs() <= 1.0 {
                let (tx, ty) = s(to);
                b.line_to(tx, ty);
                return;
            }
            let r = EdgeShape::elbow_radius(from, to, bus);
            let sign = if dx > 0.0 { 1.0 } else { -1.0 };
            let p1 = s(Vec2::new(from.x, bus - r));
            let c1 = s(Vec2::new(from.x, bus));
            let p2 = s(Vec2::new(from.x + sign * r, bus));
            let p3 = s(Vec2::new(to.x - sign * r, bus));
            let c2 = s(Vec2::new(to.x, bus));
            let p4 = s(Vec2::new(to.x, bus + r));
            let end = s(to);
            b.line_to(p1.0, p1.1);
            b.quad_to(c1.0, c1.1, p2.0, p2.1);
            b.line_to(p3.0, p3.1);
            b.quad_to(c2.0, c2.1, p4.0, p4.1);
            b.line_to(end.0, end.1);
        }
    }
}
