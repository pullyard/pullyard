use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{glib, graphene, pango};

use crate::diff::{DiffFile, DiffLine, LineKind};
use crate::diff_layout::{self, MAX_HIGHLIGHT_LENGTH, MAX_HIGHLIGHT_LINES};
use crate::settings;
use crate::signal::Signal;
use crate::syntax::{self, Token};
use crate::ui::widgets::*;

type Spans = Rc<Vec<(usize, usize, Token)>>;

thread_local! {
    static PREFS: Signal<()> = const { Signal::new() };
    static SPANS: RefCell<HashMap<(String, String), Spans>> = RefCell::new(HashMap::new());
    static CSS_DONE: Cell<bool> = const { Cell::new(false) };
}

pub fn wrap() -> bool {
    settings::read(|s| s.diff_wrap)
}

pub fn split() -> bool {
    settings::read(|s| s.diff_split)
}

pub fn set_wrap(on: bool) {
    if wrap() != on {
        settings::update(|s| s.diff_wrap = on);
        PREFS.with(|p| p.emit(&()));
    }
}

pub fn set_split(on: bool) {
    if split() != on {
        settings::update(|s| s.diff_split = on);
        PREFS.with(|p| p.emit(&()));
    }
}

pub fn on_prefs(f: impl Fn(&()) -> bool + 'static) {
    PREFS.with(|p| p.connect(f));
}

pub fn file_ext(f: &DiffFile) -> String {
    if f.lines.len() > MAX_HIGHLIGHT_LINES {
        return String::new();
    }
    let ext = syntax::ext_for_path(&f.id);
    if syntax::supports(&ext) {
        ext
    } else {
        String::new()
    }
}

fn spans_for(ext: &str, code: &str) -> Spans {
    let key = (ext.to_string(), code.to_string());
    if let Some(s) = SPANS.with(|c| c.borrow().get(&key).cloned()) {
        return s;
    }
    let spans: Spans = Rc::new(syntax::tokens(code, ext));
    SPANS.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() > 4000 {
            c.clear();
        }
        c.insert(key, spans.clone());
    });
    spans
}

fn rgb(hex: &str) -> Option<(u16, u16, u16)> {
    let h = hex.trim_start_matches('#');
    if h.len() < 6 {
        return None;
    }
    let channel = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok().map(|v| v as u16 * 257);
    Some((channel(0)?, channel(2)?, channel(4)?))
}

fn token_rgb(token: Token) -> Option<(u16, u16, u16)> {
    let dark = crate::theme::is_dark();
    let (name, light_hex, dark_hex) = match token {
        Token::Keyword => ("coral", "#D8513F", "#EE6F5F"),
        Token::Number => ("violet", "#6B55D6", "#9D8CF0"),
        Token::Str => ("green", "#2E8A57", "#5DBE8A"),
        Token::Comment => return None,
    };
    crate::theme::token_hex(name).and_then(rgb).or_else(|| rgb(if dark { dark_hex } else { light_hex }))
}

fn attributes(spans: &[(usize, usize, Token)], shift: usize) -> pango::AttrList {
    let list = pango::AttrList::new();
    for &(start, end, token) in spans {
        let (s, e) = ((start + shift) as u32, (end + shift) as u32);
        match token_rgb(token) {
            Some((r, g, b)) => {
                let mut a = pango::AttrColor::new_foreground(r, g, b);
                a.set_start_index(s);
                a.set_end_index(e);
                list.insert(a);
            }
            None => {
                let mut a = pango::AttrInt::new_foreground_alpha((0.55 * 65535.0) as u16);
                a.set_start_index(s);
                a.set_end_index(e);
                list.insert(a);
            }
        }
    }
    list
}

pub fn ensure_css() {
    if CSS_DONE.with(|d| d.replace(true)) {
        return;
    }
    let Some(display) = gtk::gdk::Display::default() else { return };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(
        "diffcode { padding: 0; }\n.diff-filler { background-color: @sy_line; }\n.diff-split-right { border-left: 1px solid @sy_line_strong; }\n.diff-review-bar { border-bottom: 1px solid @sy_line; padding: 4px 12px; }\n.diff-review-bar button.flat { min-height: 24px; min-width: 24px; padding: 2px; }\n.diff-selected { background-image: image(alpha(@accent_bg_color, 0.28)); }\n",
    );
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
}

pub struct HScroll {
    pub adjustment: gtk::Adjustment,
    pub bar: gtk::Scrollbar,
    clips: RefCell<Vec<glib::WeakRef<DiffCode>>>,
    columns: Cell<usize>,
    char_width: Cell<f64>,
    page: Cell<i32>,
    pending: Cell<bool>,
    enabled: Cell<bool>,
}

impl HScroll {
    pub fn new() -> Rc<Self> {
        let adjustment = gtk::Adjustment::new(0.0, 0.0, 0.0, 8.0, 80.0, 0.0);
        let bar = gtk::Scrollbar::new(gtk::Orientation::Horizontal, Some(&adjustment));
        bar.set_visible(false);
        bar.update_property(&[gtk::accessible::Property::Label("Horizontal scroll")]);
        let me = Rc::new(HScroll {
            adjustment: adjustment.clone(),
            bar,
            clips: RefCell::new(vec![]),
            columns: Cell::new(0),
            char_width: Cell::new(0.0),
            page: Cell::new(0),
            pending: Cell::new(false),
            enabled: Cell::new(false),
        });
        let w = Rc::downgrade(&me);
        adjustment.connect_value_changed(move |_| {
            if let Some(me) = w.upgrade() {
                me.redraw();
            }
        });
        me
    }

    pub fn reset(self: &Rc<Self>, columns: usize, enabled: bool) {
        self.columns.set(columns);
        self.enabled.set(enabled);
        if !enabled {
            self.adjustment.set_value(0.0);
        }
        self.schedule();
    }

    fn offset(&self) -> f64 {
        if self.enabled.get() {
            self.adjustment.value()
        } else {
            0.0
        }
    }

    fn register(&self, code: &DiffCode) {
        let mut clips = self.clips.borrow_mut();
        if clips.len() > 400 {
            clips.retain(|w| w.upgrade().is_some());
        }
        clips.push(code.downgrade());
    }

    fn observe(self: &Rc<Self>, width: i32, char_width: f64) {
        if width == self.page.get() && (char_width - self.char_width.get()).abs() < 0.01 {
            return;
        }
        self.page.set(width);
        if char_width > 0.0 {
            self.char_width.set(char_width);
        }
        self.schedule();
    }

    fn schedule(self: &Rc<Self>) {
        if self.pending.replace(true) {
            return;
        }
        let w = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(me) = w.upgrade() {
                me.pending.set(false);
                me.update();
            }
        });
    }

    fn update(&self) {
        let page = self.page.get().max(1) as f64;
        let upper = self.columns.get() as f64 * self.char_width.get() + 12.0;
        let enabled = self.enabled.get() && self.char_width.get() > 0.0 && upper > page;
        let value = if enabled { self.adjustment.value().min(upper - page).max(0.0) } else { 0.0 };
        self.adjustment.configure(value, 0.0, upper.max(page), (self.char_width.get() * 3.0).max(1.0), page * 0.9, page);
        self.bar.set_visible(enabled);
        self.redraw();
    }

    fn redraw(&self) {
        for w in self.clips.borrow().iter() {
            if let Some(c) = w.upgrade() {
                c.queue_draw();
            }
        }
    }

    pub fn scroll_by(&self, delta: f64) -> bool {
        if !self.bar.is_visible() {
            return false;
        }
        let a = &self.adjustment;
        let max = (a.upper() - a.page_size()).max(0.0);
        a.set_value((a.value() + delta).clamp(0.0, max));
        true
    }

    pub fn attach_wheel(self: &Rc<Self>, widget: &impl IsA<gtk::Widget>) {
        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
        scroll.set_propagation_phase(gtk::PropagationPhase::Capture);
        let w = Rc::downgrade(self);
        scroll.connect_scroll(move |c, dx, dy| {
            let Some(me) = w.upgrade() else { return glib::Propagation::Proceed };
            let shift = c.current_event_state().contains(gtk::gdk::ModifierType::SHIFT_MASK);
            let (dx, dy) = if shift && dx == 0.0 { (dy, 0.0) } else { (dx, dy) };
            if dx == 0.0 || dx.abs() <= dy.abs() {
                return glib::Propagation::Proceed;
            }
            let step = if c.unit() == gtk::gdk::ScrollUnit::Wheel { me.char_width.get().max(6.0) * 6.0 } else { 1.0 };
            if me.scroll_by(dx * step) {
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        widget.add_controller(scroll);
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct DiffCode {
        pub text: RefCell<String>,
        pub attrs: RefCell<Option<pango::AttrList>>,
        pub code: Cell<bool>,
        pub wrap: Cell<bool>,
        pub scroll: RefCell<Option<Rc<HScroll>>>,
        pub layout: RefCell<Option<(pango::Layout, u32)>>,
        pub char_width: Cell<f64>,
        pub configured: Cell<i32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DiffCode {
        const NAME: &'static str = "PyDiffCode";
        type Type = super::DiffCode;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("diffcode");
            klass.set_accessible_role(gtk::AccessibleRole::Label);
        }
    }

    impl ObjectImpl for DiffCode {}

    impl WidgetImpl for DiffCode {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            if self.wrap.get() {
                gtk::SizeRequestMode::HeightForWidth
            } else {
                gtk::SizeRequestMode::ConstantSize
            }
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let layout = self.layout();
            if orientation == gtk::Orientation::Horizontal {
                self.configure(&layout, -1);
                let (w, _) = layout.pixel_size();
                return (0, w, -1, -1);
            }
            self.configure(&layout, if self.wrap.get() { for_size } else { -1 });
            let (_, h) = layout.pixel_size();
            (h, h, -1, -1)
        }

        fn size_allocate(&self, width: i32, _height: i32, _baseline: i32) {
            let layout = self.layout();
            self.configure(&layout, width);
            if !self.wrap.get() {
                if let Some(s) = self.scroll.borrow().as_ref() {
                    s.observe(width, self.char_width.get());
                }
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let layout = self.layout();
            self.configure(&layout, if self.wrap.get() { obj.width() } else { -1 });
            let x = if self.wrap.get() { 0.0 } else { self.scroll.borrow().as_ref().map(|s| s.offset()).unwrap_or(0.0) };
            snapshot.save();
            snapshot.translate(&graphene::Point::new(-x as f32, 0.0));
            snapshot.append_layout(&layout, &obj.color());
            snapshot.restore();
        }
    }

    impl DiffCode {
        pub fn layout(&self) -> pango::Layout {
            let obj = self.obj();
            let context = obj.pango_context();
            let serial = context.serial();
            if let Some((layout, s)) = self.layout.borrow().as_ref() {
                if *s == serial {
                    return layout.clone();
                }
            }
            let layout = obj.create_pango_layout(Some(&self.text.borrow()));
            if let Some(attrs) = self.attrs.borrow().as_ref() {
                layout.set_attributes(Some(attrs));
            }
            layout.set_wrap(pango::WrapMode::WordChar);
            let probe = obj.create_pango_layout(Some("0000000000"));
            let (w, _) = probe.size();
            self.char_width.set(w as f64 / pango::SCALE as f64 / 10.0);
            self.configured.set(i32::MIN);
            *self.layout.borrow_mut() = Some((layout.clone(), serial));
            layout
        }

        pub fn configure(&self, layout: &pango::Layout, width: i32) {
            let width = if self.wrap.get() && width > 0 { width } else { -1 };
            if self.configured.replace(width) == width {
                return;
            }
            if width <= 0 {
                layout.set_width(-1);
                layout.set_indent(0);
                return;
            }
            layout.set_width(width * pango::SCALE);
            let cw = self.char_width.get();
            if !self.code.get() || cw <= 0.0 {
                layout.set_indent(0);
                return;
            }
            let text = self.text.borrow();
            let body = text.get(1..).unwrap_or("");
            let limit = (width as f64 / cw / 2.0) as i64;
            let columns = diff_layout::hanging_columns(body, limit);
            layout.set_indent(-((columns as f64 * cw * pango::SCALE as f64) as i32));
        }
    }
}

glib::wrapper! {
    pub struct DiffCode(ObjectSubclass<imp::DiffCode>) @extends gtk::Widget, @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl DiffCode {
    pub fn new(line: &DiffLine, ext: &str, wrap: bool, scroll: Option<&Rc<HScroll>>) -> Self {
        let me: DiffCode = glib::Object::new();
        me.add_css_class("diff-line");
        me.set_hexpand(true);
        me.set_valign(gtk::Align::Start);
        me.set_overflow(gtk::Overflow::Hidden);
        let text = diff_layout::display_text(line);
        let code = diff_layout::is_code(line.kind);
        let imp = me.imp();
        if code && !ext.is_empty() && text.len() > 1 && text.chars().count() <= MAX_HIGHLIGHT_LENGTH {
            let spans = spans_for(ext, &text[1..]);
            if !spans.is_empty() {
                *imp.attrs.borrow_mut() = Some(attributes(&spans, 1));
            }
        }
        me.update_property(&[gtk::accessible::Property::Label(&text)]);
        *imp.text.borrow_mut() = text;
        imp.code.set(code);
        imp.wrap.set(wrap);
        imp.configured.set(i32::MIN);
        if let Some(s) = scroll.filter(|_| !wrap) {
            s.register(&me);
            *imp.scroll.borrow_mut() = Some(s.clone());
        }
        me
    }
}

#[derive(Clone, Default)]
pub struct RowOpts {
    pub ext: String,
    pub wrap: bool,
    pub commentable: bool,
    pub scroll: Option<Rc<HScroll>>,
    pub select: Option<(Rc<DiffSelection>, gtk::ListItem)>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Side {
    Unified,
    Left,
    Right,
}

pub enum RowLine {
    Header,
    Line(DiffLine),
    Other,
}

pub type LineSource = Rc<dyn Fn(u32, Side) -> RowLine>;

type Cell3 = (glib::WeakRef<gtk::Widget>, glib::WeakRef<gtk::ListItem>, Side);

pub struct DiffSelection {
    view: gtk::ListView,
    anchor: Cell<Option<u32>>,
    focus: Cell<Option<u32>>,
    side: Cell<Side>,
    source: RefCell<Option<LineSource>>,
    cells: RefCell<Vec<Cell3>>,
}

fn code_lines(lines: impl Iterator<Item = DiffLine>) -> Vec<String> {
    lines.filter(|l| diff_layout::is_code(l.kind)).map(|l| l.text).collect()
}

fn copy_lines(lines: Vec<String>) -> bool {
    if lines.is_empty() {
        return false;
    }
    crate::util::copy(&lines.join("\n"));
    crate::app::toast(&crate::util::plural(lines.len() as i64, "line copied", "lines copied"));
    true
}

impl DiffSelection {
    pub fn new(view: &gtk::ListView) -> Rc<Self> {
        let me = Rc::new(DiffSelection {
            view: view.clone(),
            anchor: Cell::new(None),
            focus: Cell::new(None),
            side: Cell::new(Side::Unified),
            source: RefCell::new(None),
            cells: RefCell::new(vec![]),
        });
        let shortcuts = gtk::ShortcutController::new();
        let w = Rc::downgrade(&me);
        let action = gtk::CallbackAction::new(move |_, _| match w.upgrade() {
            Some(me) if me.copy_selection() => glib::Propagation::Stop,
            _ => glib::Propagation::Proceed,
        });
        shortcuts.add_shortcut(gtk::Shortcut::new(gtk::ShortcutTrigger::parse_string("<Control>c|<Control>Insert"), Some(action)));
        view.add_controller(shortcuts);
        me
    }

    pub fn set_source(&self, f: LineSource) {
        *self.source.borrow_mut() = Some(f);
    }

    fn line_at(&self, pos: u32, side: Side) -> RowLine {
        match self.source.borrow().clone() {
            Some(f) => f(pos, side),
            None => RowLine::Other,
        }
    }

    pub fn range(&self) -> Option<(u32, u32)> {
        let (a, f) = (self.anchor.get()?, self.focus.get()?);
        Some((a.min(f), a.max(f)))
    }

    pub fn clear(&self) {
        if self.anchor.replace(None).is_some() {
            self.focus.set(None);
            self.refresh();
        }
    }

    fn selected(&self, pos: u32, side: Side) -> bool {
        side == self.side.get() && self.range().is_some_and(|(a, b)| pos >= a && pos <= b)
    }

    fn refresh(&self) {
        let mut cells = self.cells.borrow_mut();
        cells.retain(|(w, item, _)| w.upgrade().is_some() && item.upgrade().is_some());
        for (w, item, side) in cells.iter() {
            let (Some(w), Some(item)) = (w.upgrade(), item.upgrade()) else { continue };
            let on = item.position() != gtk::INVALID_LIST_POSITION && self.selected(item.position(), *side);
            if on != w.has_css_class("diff-selected") {
                if on {
                    w.add_css_class("diff-selected");
                } else {
                    w.remove_css_class("diff-selected");
                }
            }
        }
    }

    fn selection_text(&self) -> Vec<String> {
        let Some((a, b)) = self.range() else { return vec![] };
        let side = self.side.get();
        code_lines((a..=b).filter_map(|pos| match self.line_at(pos, side) {
            RowLine::Line(l) => Some(l),
            _ => None,
        }))
    }

    pub fn copy_selection(&self) -> bool {
        copy_lines(self.selection_text())
    }

    fn hunk_text(&self, pos: u32, side: Side) -> Vec<String> {
        let mut start = pos;
        while start > 0 {
            match self.line_at(start, side) {
                RowLine::Header => {
                    start += 1;
                    break;
                }
                RowLine::Line(l) if l.kind == LineKind::Hunk => break,
                _ => start -= 1,
            }
        }
        let mut lines = vec![];
        let mut i = start;
        loop {
            match self.line_at(i, side) {
                RowLine::Header => break,
                RowLine::Line(l) if l.kind == LineKind::Hunk && i != start => break,
                RowLine::Line(l) => lines.push(l),
                RowLine::Other => {}
            }
            i += 1;
            if i >= self.view.model().map(|m| m.n_items()).unwrap_or(0) {
                break;
            }
        }
        code_lines(lines.into_iter())
    }

    fn position_at(&self, x: f64, y: f64) -> Option<u32> {
        let mut current = self.view.pick(x, y, gtk::PickFlags::DEFAULT);
        let cells = self.cells.borrow();
        while let Some(w) = current {
            if let Some((_, item, _)) = cells.iter().find(|(c, _, _)| c.upgrade().as_ref() == Some(&w)) {
                return item.upgrade().map(|i| i.position()).filter(|p| *p != gtk::INVALID_LIST_POSITION);
            }
            if w == *self.view.upcast_ref::<gtk::Widget>() {
                break;
            }
            current = w.parent();
        }
        None
    }

    fn announce(&self) {
        let Some((a, b)) = self.range() else { return };
        let n = b - a + 1;
        let text = if n == 1 { "1 line selected. Press Control C to copy.".to_string() } else { format!("{n} lines selected. Press Control C to copy.") };
        self.view.announce(&text, gtk::AccessibleAnnouncementPriority::Low);
    }

    pub fn attach(self: &Rc<Self>, highlight: &impl IsA<gtk::Widget>, code: &impl IsA<gtk::Widget>, item: &gtk::ListItem, side: Side, line: Option<&DiffLine>) {
        let highlight = highlight.upcast_ref::<gtk::Widget>();
        {
            let mut cells = self.cells.borrow_mut();
            if cells.len() > 400 {
                cells.retain(|(w, i, _)| w.upgrade().is_some() && i.upgrade().is_some());
            }
            cells.push((highlight.downgrade(), item.downgrade(), side));
        }
        if item.position() != gtk::INVALID_LIST_POSITION && self.selected(item.position(), side) {
            highlight.add_css_class("diff-selected");
        }
        let drag = gtk::GestureDrag::new();
        drag.set_button(1);
        let (w, it) = (Rc::downgrade(self), item.downgrade());
        drag.connect_drag_begin(move |g, _, _| {
            let (Some(me), Some(item)) = (w.upgrade(), it.upgrade()) else { return };
            let pos = item.position();
            if pos == gtk::INVALID_LIST_POSITION {
                return;
            }
            let shift = g.current_event_state().contains(gtk::gdk::ModifierType::SHIFT_MASK);
            if !(shift && me.anchor.get().is_some() && me.side.get() == side) {
                me.anchor.set(Some(pos));
                me.side.set(side);
            }
            me.focus.set(Some(pos));
            if let Some(widget) = g.widget() {
                widget.set_focusable(true);
                if !widget.grab_focus() {
                    me.view.grab_focus();
                }
            }
            me.refresh();
        });
        let w = Rc::downgrade(self);
        drag.connect_drag_update(move |g, dx, dy| {
            let Some(me) = w.upgrade() else { return };
            let (Some((sx, sy)), Some(widget)) = (g.start_point(), g.widget()) else { return };
            let Some(p) = widget.compute_point(&me.view, &graphene::Point::new((sx + dx) as f32, (sy + dy) as f32)) else { return };
            if let Some(pos) = me.position_at(p.x() as f64, p.y() as f64) {
                if me.focus.get() != Some(pos) {
                    me.focus.set(Some(pos));
                    me.refresh();
                }
            }
        });
        let w = Rc::downgrade(self);
        drag.connect_drag_end(move |_, _, _| {
            if let Some(me) = w.upgrade() {
                me.announce();
            }
        });
        code.add_controller(drag);
        let (w, it) = (Rc::downgrade(self), item.downgrade());
        let line = line.cloned();
        crate::ui::menu::context_menu(code, move || {
            let m = crate::ui::menu::Menu::ctx();
            if let Some(l) = line.clone().filter(|l| diff_layout::is_code(l.kind)) {
                m.item("Copy line", move || {
                    copy_lines(vec![l.text.clone()]);
                });
            }
            let (Some(me), Some(item)) = (w.upgrade(), it.upgrade()) else { return m };
            let pos = item.position();
            if !me.selection_text().is_empty() {
                let me2 = me.clone();
                m.item("Copy selected lines", move || {
                    me2.copy_selection();
                });
            } else {
                m.disabled("Copy selected lines");
            }
            if pos != gtk::INVALID_LIST_POSITION {
                let me2 = me.clone();
                m.item("Copy hunk", move || {
                    copy_lines(me2.hunk_text(pos, side));
                });
            }
            m
        });
    }
}

pub type OnComment = Rc<dyn Fn(&DiffLine)>;

fn kind_class(w: &gtk::Box, kind: LineKind) {
    match kind {
        LineKind::Add => w.add_css_class("add"),
        LineKind::Del => w.add_css_class("del"),
        LineKind::Hunk => w.add_css_class("hunk"),
        LineKind::Meta => w.add_css_class("meta"),
        LineKind::Context => {}
    }
}

fn gutter_label(text: &str, chars: i32, line: &DiffLine, can_comment: bool, on_comment: Option<&OnComment>) -> gtk::Label {
    let gutter = label_with(text, &["diff-gutter"]);
    gutter.set_width_chars(chars);
    gutter.set_xalign(1.0);
    gutter.set_valign(gtk::Align::Start);
    if can_comment {
        gutter.add_css_class("commentable");
        gutter.set_tooltip_text(Some("Comment on this line"));
        if let Some(f) = on_comment {
            let f = f.clone();
            let l = line.clone();
            on_click_widget(&gutter, move || f(&l));
        }
    }
    gutter
}

pub fn line_row(line: &DiffLine, opts: &RowOpts, on_comment: Option<OnComment>) -> gtk::Box {
    let row = hbox(0);
    row.add_css_class("diff-line");
    kind_class(&row, line.kind);
    if line.kind == LineKind::Hunk {
        let t = label_with(&line.text, &["diff-line"]);
        t.set_margin_start(110);
        t.set_margin_top(3);
        t.set_margin_bottom(3);
        t.set_ellipsize(gtk::pango::EllipsizeMode::End);
        t.set_xalign(0.0);
        t.set_hexpand(true);
        row.append(&t);
        if let Some((sel, item)) = &opts.select {
            sel.attach(&row, &t, item, Side::Unified, Some(line));
        }
        return row;
    }
    let can = opts.commentable && line.commentable();
    row.append(&gutter_label(&line.gutter(opts.commentable), 14, line, can, on_comment.as_ref()));
    let code = DiffCode::new(line, &opts.ext, opts.wrap, opts.scroll.as_ref());
    code.set_margin_start(6);
    code.set_margin_end(8);
    row.append(&code);
    if let Some((sel, item)) = &opts.select {
        sel.attach(&row, &code, item, Side::Unified, Some(line));
    }
    row
}

fn split_side(line: Option<&DiffLine>, old: bool, opts: &RowOpts, on_comment: Option<&OnComment>) -> gtk::Box {
    let side = hbox(0);
    side.set_hexpand(true);
    let which = if old { Side::Left } else { Side::Right };
    let Some(line) = line else {
        side.add_css_class("diff-filler");
        if let Some((sel, item)) = &opts.select {
            sel.attach(&side, &side, item, which, None);
        }
        return side;
    };
    side.add_css_class("diff-line");
    kind_class(&side, line.kind);
    let n = if old { line.old_line } else { line.new_line };
    let can = opts.commentable && line.commentable();
    let text = format!("{:>5}{}", n.map(|n| n.to_string()).unwrap_or_default(), if can { " +" } else { "  " });
    side.append(&gutter_label(&text, 7, line, can, on_comment));
    let code = DiffCode::new(line, &opts.ext, opts.wrap, opts.scroll.as_ref());
    code.set_margin_start(4);
    code.set_margin_end(8);
    side.append(&code);
    if let Some((sel, item)) = &opts.select {
        sel.attach(&side, &code, item, which, Some(line));
    }
    side
}

pub fn split_row(left: Option<&DiffLine>, right: Option<&DiffLine>, opts: &RowOpts, on_comment: Option<OnComment>) -> gtk::Box {
    let row = hbox(0);
    row.set_homogeneous(true);
    row.append(&split_side(left, true, opts, on_comment.as_ref()));
    let r = split_side(right, false, opts, on_comment.as_ref());
    r.add_css_class("diff-split-right");
    row.append(&r);
    row
}

pub fn longest_columns<'a>(lines: impl Iterator<Item = &'a DiffLine>) -> usize {
    lines.map(diff_layout::display_columns).max().unwrap_or(0)
}

pub fn wrap_check() -> gtk::CheckButton {
    let wrap_check = gtk::CheckButton::with_label("Wrap lines");
    wrap_check.set_active(wrap());
    wrap_check.set_tooltip_text(Some("Wrap long lines (W)"));
    wrap_check.connect_toggled(|c| {
        let on = c.is_active();
        glib::idle_add_local_once(move || set_wrap(on));
    });
    let weak = wrap_check.downgrade();
    on_prefs(move |_| match weak.upgrade() {
        Some(c) => {
            if c.is_active() != wrap() {
                c.set_active(wrap());
            }
            true
        }
        None => false,
    });
    wrap_check
}
