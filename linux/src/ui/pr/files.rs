use std::cell::{Cell, RefCell};
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

use super::diff_view::{self, DiffSelection, HScroll, OnComment, RowLine, RowOpts, Side};
use super::model::{Change, FlatRow, PrModel};
use crate::api::models::{PendingComment, RepoRef, ReviewThread};
use crate::diff::{DiffAnchor, DiffFile, DiffLine, LineKind};
use crate::diff_layout::{self, SplitRow};
use crate::ui::composer::Composer;
use crate::ui::menu::Menu;
use crate::ui::widgets::*;
use crate::util;

pub struct FilesTab {
    pub widget: gtk::Stack,
    model: Rc<PrModel>,
    store: gio::ListStore,
    rows: RefCell<Vec<ViewRow>>,
    row_keys: RefCell<Vec<RowKey>>,
    rows_open: Cell<Option<bool>>,
    rows_mode: Cell<Option<(bool, bool)>>,
    diff_scroll: gtk::ScrolledWindow,
    hscroll: Rc<HScroll>,
    selection: Rc<DiffSelection>,
    split_fits: Cell<bool>,
    split_toggle: gtk::ToggleButton,
    unified_toggle: gtk::ToggleButton,
    bound: RefCell<Vec<(glib::WeakRef<adw::Bin>, glib::BoxedAnyObject)>>,
    nav_index: Cell<Option<usize>>,
    keys: RefCell<Option<(glib::WeakRef<gtk::Window>, gtk::EventControllerKey)>>,
    rows_filter: RefCell<String>,
    file_list_sig: Cell<Option<u64>>,
    view: gtk::ListView,
    file_list: gtk::ListBox,
    file_keys: RefCell<Vec<String>>,
    side: gtk::Box,
    filter: RefCell<String>,
    viewed_label: gtk::Label,
    expanded_threads: RefCell<std::collections::HashMap<String, bool>>,
    pending_reveal: RefCell<Option<String>>,
    suppress_select: Cell<bool>,
}

#[derive(PartialEq)]
enum RowKey {
    Header(usize, bool, bool),
    Line(usize, usize),
    Split(usize, Option<usize>, Option<usize>),
    Other(String),
}

#[derive(Clone)]
enum ViewRow {
    Flat(FlatRow),
    Split(usize, Option<usize>, Option<usize>),
}

type Segment = Vec<(usize, Vec<FlatRow>)>;

fn flush_segment(out: &mut Vec<ViewRow>, files: &[DiffFile], fi: Option<usize>, segment: &mut Segment) {
    let taken = std::mem::take(segment);
    let Some(file) = fi.and_then(|fi| files.get(fi)) else {
        for (_, extras) in taken {
            out.extend(extras.into_iter().map(ViewRow::Flat));
        }
        return;
    };
    let fi = fi.unwrap_or_default();
    let kinds: Vec<LineKind> = taken.iter().map(|(li, _)| file.lines.get(*li).map(|l| l.kind).unwrap_or(LineKind::Meta)).collect();
    for row in diff_layout::pair_kinds(&kinds) {
        match row {
            SplitRow::Full(i) => {
                out.push(ViewRow::Flat(FlatRow::Line(fi, taken[i].0)));
                out.extend(taken[i].1.iter().cloned().map(ViewRow::Flat));
            }
            SplitRow::Pair(a, b) => {
                out.push(ViewRow::Split(fi, a.map(|i| taken[i].0), b.map(|i| taken[i].0)));
                if let Some(a) = a {
                    out.extend(taken[a].1.iter().cloned().map(ViewRow::Flat));
                }
                if let Some(b) = b.filter(|b| Some(*b) != a) {
                    out.extend(taken[b].1.iter().cloned().map(ViewRow::Flat));
                }
            }
        }
    }
}

fn split_rows(flat: Vec<FlatRow>, files: &[DiffFile]) -> Vec<ViewRow> {
    let mut out = Vec::with_capacity(flat.len());
    let mut segment_file: Option<usize> = None;
    let mut segment: Segment = vec![];
    for row in flat {
        match row {
            FlatRow::Line(fi, li) => {
                if segment_file != Some(fi) {
                    flush_segment(&mut out, files, segment_file, &mut segment);
                    segment_file = Some(fi);
                }
                segment.push((li, vec![]));
            }
            FlatRow::Header(_) => {
                flush_segment(&mut out, files, segment_file, &mut segment);
                segment_file = None;
                out.push(ViewRow::Flat(row));
            }
            other => match segment.last_mut() {
                Some(last) => last.1.push(other),
                None => out.push(ViewRow::Flat(other)),
            },
        }
    }
    flush_segment(&mut out, files, segment_file, &mut segment);
    out
}

fn nav_button(icon_name: &str, title: &str, key: &str) -> gtk::Button {
    let b = icon_button(icon_name, &format!("{title} ({key})"));
    b.update_property(&[gtk::accessible::Property::Label(title)]);
    b
}

fn is_text_input(w: &gtk::Widget) -> bool {
    w.is::<gtk::Editable>()
        || w.is::<gtk::Text>()
        || w.is::<gtk::TextView>()
        || w.is::<vte4::Terminal>()
        || w.is::<webkit6::WebView>()
        || w.ancestor(vte4::Terminal::static_type()).is_some()
        || w.ancestor(webkit6::WebView::static_type()).is_some()
        || w.ancestor(gtk::TextView::static_type()).is_some()
        || w.ancestor(adw::Dialog::static_type()).is_some()
        || w.ancestor(gtk::Popover::static_type()).is_some()
}

fn blame_target(m: &PrModel) -> Option<(RepoRef, String)> {
    let oid = m.files_oid.borrow().clone().or_else(|| m.pr.borrow().as_ref().map(|p| p.head_ref_oid.clone()))?;
    Some((m.r.repo.clone(), oid)).filter(|(_, oid)| !oid.is_empty())
}

fn status_label(f: &DiffFile) -> gtk::Label {
    let l = label_with(f.status_letter(), &["sy-mono", "sy-bold", "sy-tiny", &format!("fg-{}", f.status_css())]);
    l.set_width_chars(1);
    l
}

pub fn line_widget(line: &DiffLine, commentable: bool) -> gtk::Box {
    diff_view::line_row(line, &RowOpts { wrap: true, commentable, ..Default::default() }, None)
}

impl FilesTab {
    pub fn new(model: Rc<PrModel>) -> Rc<Self> {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let factory = gtk::SignalListItemFactory::new();
        let selection = gtk::NoSelection::new(Some(store.clone()));
        let view = gtk::ListView::new(Some(selection), Some(factory.clone()));
        view.add_css_class("diff-view");
        diff_view::ensure_css();
        let diff_scroll = gtk::ScrolledWindow::new();
        diff_scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        diff_scroll.set_child(Some(&view));
        diff_scroll.set_hexpand(true);
        diff_scroll.set_vexpand(true);
        let hscroll = HScroll::new();
        hscroll.attach_wheel(&diff_scroll);

        let review_bar = hbox(10);
        review_bar.add_css_class("diff-review-bar");
        let file_nav = hbox(2);
        let prev_file = nav_button("go-up-symbolic", "Previous file", "P");
        let next_file = nav_button("go-down-symbolic", "Next file", "N");
        file_nav.append(&prev_file);
        file_nav.append(&next_file);
        review_bar.append(&file_nav);
        let hunk_nav = hbox(2);
        let prev_hunk = nav_button("go-top-symbolic", "Previous hunk", "[");
        let next_hunk = nav_button("go-bottom-symbolic", "Next hunk", "]");
        hunk_nav.append(&prev_hunk);
        hunk_nav.append(&next_hunk);
        review_bar.append(&hunk_nav);
        review_bar.append(&spacer());
        review_bar.append(&diff_view::wrap_check());
        let layout_box = hbox(0);
        layout_box.add_css_class("linked");
        let unified_toggle = gtk::ToggleButton::with_label("Unified");
        let split_toggle = gtk::ToggleButton::with_label("Split");
        split_toggle.set_group(Some(&unified_toggle));
        unified_toggle.set_active(true);
        layout_box.append(&unified_toggle);
        layout_box.append(&split_toggle);
        layout_box.update_property(&[gtk::accessible::Property::Label("Diff layout")]);
        review_bar.append(&layout_box);

        let diff_column = vbox(0);
        diff_column.append(&review_bar);
        diff_column.append(&diff_scroll);
        diff_column.append(&hscroll.bar);
        let diff_area = adw::BreakpointBin::new();
        diff_area.set_size_request(320, 200);
        diff_area.set_child(Some(&diff_column));
        let breakpoint = adw::Breakpoint::new(adw::BreakpointCondition::new_length(adw::BreakpointConditionLengthType::MinWidth, diff_layout::SPLIT_MIN_WIDTH as f64, adw::LengthUnit::Px));

        let side = vbox(0);
        side.add_css_class("sy-list-pane");
        side.set_size_request(260, -1);
        let filter_row = hbox(6);
        pad(&filter_row, 8);
        let filter = gtk::SearchEntry::new();
        filter.set_placeholder_text(Some("Filter files"));
        filter.set_hexpand(true);
        let viewed_label = label_with("", &["sy-muted", "sy-small"]);
        viewed_label.set_tooltip_text(Some("Viewed"));
        filter_row.append(&filter);
        filter_row.append(&viewed_label);
        side.append(&filter_row);
        let file_list = gtk::ListBox::new();
        file_list.add_css_class("sy-list");
        file_list.add_css_class("sy-plain");
        side.append(&scrolled(&file_list));

        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_start_child(Some(&side));
        paned.set_end_child(Some(&diff_area));
        paned.set_resize_start_child(false);
        paned.set_shrink_start_child(false);
        paned.set_position(260);

        let widget = gtk::Stack::new();
        widget.add_named(&loading(), Some("loading"));
        widget.add_named(&paned, Some("files"));
        widget.add_named(&vbox(0), Some("error"));

        let me = Rc::new(FilesTab {
            widget,
            model: model.clone(),
            store,
            rows: RefCell::new(vec![]),
            row_keys: RefCell::new(vec![]),
            rows_open: Cell::new(None),
            rows_mode: Cell::new(None),
            diff_scroll,
            hscroll,
            selection: DiffSelection::new(&view),
            split_fits: Cell::new(false),
            split_toggle: split_toggle.clone(),
            unified_toggle: unified_toggle.clone(),
            bound: RefCell::new(vec![]),
            nav_index: Cell::new(None),
            keys: RefCell::new(None),
            rows_filter: RefCell::new(String::new()),
            file_list_sig: Cell::new(None),
            view,
            file_list: file_list.clone(),
            file_keys: RefCell::new(vec![]),
            side,
            filter: RefCell::new(String::new()),
            viewed_label,
            expanded_threads: RefCell::new(std::collections::HashMap::new()),
            pending_reveal: RefCell::new(None),
            suppress_select: Cell::new(false),
        });

        factory.connect_setup(|_, item| {
            if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                item.set_activatable(false);
                item.set_selectable(false);
                item.set_focusable(false);
                item.set_child(Some(&adw::Bin::new()));
            }
        });
        let w = Rc::downgrade(&me);
        factory.connect_bind(move |_, item| {
            let Some(me) = w.upgrade() else { return };
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let Some(obj) = item.item().and_downcast::<glib::BoxedAnyObject>() else { return };
            let row = obj.borrow::<ViewRow>().clone();
            let widget = me.row_widget(&row, item);
            if let Some(bin) = item.child().and_downcast::<adw::Bin>() {
                bin.set_child(Some(&widget));
                let mut bound = me.bound.borrow_mut();
                bound.retain(|(b, _)| b.upgrade().is_some_and(|b| b != bin));
                bound.push((bin.downgrade(), obj));
            }
        });
        let w = Rc::downgrade(&me);
        factory.connect_unbind(move |_, item| {
            if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                if let Some(bin) = item.child().and_downcast::<adw::Bin>() {
                    bin.set_child(None::<&gtk::Widget>);
                    if let Some(me) = w.upgrade() {
                        me.bound.borrow_mut().retain(|(b, _)| b.upgrade().is_some_and(|b| b != bin));
                    }
                }
            }
        });

        let w = Rc::downgrade(&me);
        me.selection.set_source(Rc::new(move |pos, side| {
            let Some(me) = w.upgrade() else { return RowLine::Other };
            let rows = me.rows.borrow();
            let files = me.model.files.borrow();
            let line = |fi: usize, li: Option<usize>| li.and_then(|li| files.get(fi).and_then(|f| f.lines.get(li))).cloned().map(RowLine::Line).unwrap_or(RowLine::Other);
            match rows.get(pos as usize) {
                Some(ViewRow::Flat(FlatRow::Header(_))) => RowLine::Header,
                Some(ViewRow::Flat(FlatRow::Line(fi, li))) => line(*fi, Some(*li)),
                Some(ViewRow::Split(fi, a, b)) => line(*fi, if side == Side::Right { *b } else { *a }),
                _ => RowLine::Other,
            }
        }));
        let w = Rc::downgrade(&me);
        breakpoint.connect_apply(move |_| {
            if let Some(me) = w.upgrade() {
                me.set_split_fits(true);
            }
        });
        let w = Rc::downgrade(&me);
        breakpoint.connect_unapply(move |_| {
            if let Some(me) = w.upgrade() {
                me.set_split_fits(false);
            }
        });
        diff_area.add_breakpoint(breakpoint);
        let w = Rc::downgrade(&me);
        prev_file.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.perform('p');
            }
        });
        let w = Rc::downgrade(&me);
        next_file.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.perform('n');
            }
        });
        let w = Rc::downgrade(&me);
        prev_hunk.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.perform('[');
            }
        });
        let w = Rc::downgrade(&me);
        next_hunk.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.perform(']');
            }
        });
        let w = Rc::downgrade(&me);
        split_toggle.connect_toggled(move |t| {
            let Some(me) = w.upgrade() else { return };
            let on = t.is_active();
            if me.split_fits.get() && on != diff_view::split() {
                glib::idle_add_local_once(move || diff_view::set_split(on));
            }
        });
        let w = Rc::downgrade(&me);
        diff_view::on_prefs(move |_| match w.upgrade() {
            Some(me) => {
                me.sync_layout_toggle();
                me.rebuild();
                true
            }
            None => false,
        });
        let w = Rc::downgrade(&me);
        crate::theme::on_change(move |_| match w.upgrade() {
            Some(me) => {
                me.rebind_all();
                true
            }
            None => false,
        });
        me.sync_layout_toggle();
        me.install_keys();

        let w = Rc::downgrade(&me);
        filter.connect_search_changed(move |e| {
            if let Some(me) = w.upgrade() {
                *me.filter.borrow_mut() = e.text().to_string();
                me.rebuild();
            }
        });
        let w = Rc::downgrade(&me);
        file_list.connect_row_selected(move |_, row| {
            let Some(me) = w.upgrade() else { return };
            if me.suppress_select.get() {
                return;
            }
            let Some(row) = row else { return };
            let path = me.file_keys.borrow().get(row.index().max(0) as usize).cloned();
            if let Some(p) = path {
                let m = me.model.clone();
                glib::idle_add_local_once(move || m.reveal_file(&p));
            }
        });
        let w = Rc::downgrade(&me);
        model.changed.connect(move |c| match w.upgrade() {
            Some(me) => {
                match c {
                    Change::Files => {
                        me.rows_open.set(None);
                        me.file_list_sig.set(None);
                        me.rebuild();
                    }
                    Change::Diff | Change::Pr => me.rebuild(),
                    Change::Reveal(p) => me.reveal(p),
                    _ => {}
                }
                true
            }
            None => false,
        });
        me.rebuild();
        me
    }

    fn rebuild(self: &Rc<Self>) {
        let _span = crate::diagnostics::ui_span("pr.diff");
        let started = std::time::Instant::now();
        let m = &self.model;
        if !m.files_loaded.get() {
            if let Some(e) = m.files_error.borrow().clone() {
                let mm = m.clone();
                let err = error_state(
                    &e,
                    Some(Box::new(move || {
                        let mm = mm.clone();
                        crate::rt::spawn_local(async move { mm.load_files(true).await });
                    })),
                );
                if let Some(old) = self.widget.child_by_name("error") {
                    self.widget.remove(&old);
                }
                self.widget.add_named(&err, Some("error"));
                self.widget.set_visible_child_name("error");
            } else {
                self.widget.set_visible_child_name("loading");
            }
            return;
        }
        self.widget.set_visible_child_name("files");
        let filter = self.filter.borrow().clone();
        let flat = m.flat_rows(&filter);
        let wrap = diff_view::wrap();
        let split = self.split_active();
        let rows: Vec<ViewRow> = if split { split_rows(flat, &m.files.borrow()) } else { flat.into_iter().map(ViewRow::Flat).collect() };
        let keys: Vec<RowKey> = rows.iter().map(|r| self.row_key(r)).collect();
        let open = Some(m.pr.borrow().as_ref().map(|p| p.is_open()).unwrap_or(false));
        let old = self.row_keys.replace(vec![]);
        let n = self.store.n_items() as usize;
        let mode = Some((wrap, split));
        let full = self.rows_open.get() != open || self.rows_mode.get() != mode || old.len() != n || self.rows_filter.borrow().as_str() != filter;
        if full || !wrap {
            let longest = if wrap { 0 } else { self.longest_columns(&rows) };
            self.hscroll.reset(longest, !wrap);
        }
        let (prefix, suffix) = if full {
            (0, 0)
        } else {
            let prefix = old.iter().zip(&keys).take_while(|(a, b)| a == b).count();
            let room = old.len().min(keys.len()) - prefix;
            let suffix = old.iter().rev().zip(keys.iter().rev()).take(room).take_while(|(a, b)| a == b).count();
            (prefix, suffix)
        };
        let removed = n - prefix - suffix;
        let objs: Vec<glib::BoxedAnyObject> = rows[prefix..rows.len() - suffix].iter().map(|r| glib::BoxedAnyObject::new(r.clone())).collect();
        if removed > 0 || !objs.is_empty() {
            self.selection.clear();
            self.store.splice(prefix as u32, removed as u32, &objs);
            if crate::diagnostics::enabled() {
                after_next_paint(&self.view, move || crate::diagnostics::ui_elapsed("pr.diff.frame", started));
            }
        }
        self.rows_open.set(open);
        self.rows_mode.set(mode);
        *self.rows_filter.borrow_mut() = filter;
        *self.row_keys.borrow_mut() = keys;
        *self.rows.borrow_mut() = rows;
        self.rebuild_file_list();
        if let Some(p) = self.pending_reveal.borrow_mut().take() {
            let me = self.clone();
            glib::idle_add_local_once(move || me.reveal(&p));
        }
    }

    fn split_active(&self) -> bool {
        self.split_fits.get() && diff_view::split()
    }

    fn set_split_fits(self: &Rc<Self>, fits: bool) {
        if self.split_fits.replace(fits) == fits {
            return;
        }
        let me = self.clone();
        glib::idle_add_local_once(move || {
            me.sync_layout_toggle();
            me.rows_mode.set(None);
            me.rebuild();
        });
    }

    fn sync_layout_toggle(&self) {
        let fits = self.split_fits.get();
        let active = self.split_active();
        if self.split_toggle.is_active() != active {
            if active {
                self.split_toggle.set_active(true);
            } else {
                self.unified_toggle.set_active(true);
            }
        }
        self.split_toggle.set_sensitive(fits);
        let parent = self.split_toggle.parent();
        let tip = if fits { "Unified or side-by-side diff (S)" } else { "Widen the window to use split view" };
        for w in [Some(self.split_toggle.clone().upcast::<gtk::Widget>()), Some(self.unified_toggle.clone().upcast()), parent].into_iter().flatten() {
            w.set_tooltip_text(Some(tip));
        }
    }

    fn rebind_all(&self) {
        let n = self.store.n_items();
        if n > 0 {
            self.store.items_changed(0, n, n);
        }
    }

    fn longest_columns(&self, rows: &[ViewRow]) -> usize {
        let files = self.model.files.borrow();
        let line = |fi: usize, li: Option<usize>| li.and_then(|li| files.get(fi).and_then(|f| f.lines.get(li))).map(diff_layout::display_columns).unwrap_or(0);
        rows.iter()
            .map(|r| match r {
                ViewRow::Flat(FlatRow::Line(fi, li)) => line(*fi, Some(*li)),
                ViewRow::Split(fi, a, b) => line(*fi, *a).max(line(*fi, *b)),
                _ => 0,
            })
            .max()
            .unwrap_or(0)
    }

    fn row_opts(&self, file: &DiffFile, item: &gtk::ListItem) -> RowOpts {
        let open = self.model.pr.borrow().as_ref().map(|p| p.is_open()).unwrap_or(false);
        RowOpts { ext: diff_view::file_ext(file), wrap: diff_view::wrap(), commentable: open, scroll: Some(self.hscroll.clone()), select: Some((self.selection.clone(), item.clone())) }
    }

    fn comment_handler(&self, file: &DiffFile) -> Option<OnComment> {
        let m = self.model.clone();
        let path = file.id.clone();
        Some(Rc::new(move |line: &DiffLine| {
            let Some(anchor) = line.anchor_line() else { return };
            *m.composer.borrow_mut() = Some(DiffAnchor { path: path.clone(), line: anchor, side: line.anchor_side().to_string() });
            m.composer_text.borrow_mut().clear();
            m.emit(Change::Diff);
        }))
    }

    fn install_keys(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        self.widget.connect_map(move |widget| {
            let Some(me) = w.upgrade() else { return };
            let Some(window) = widget.root().and_downcast::<gtk::Window>() else { return };
            me.remove_keys();
            let keys = gtk::EventControllerKey::new();
            let weak = Rc::downgrade(&me);
            keys.connect_key_pressed(move |_, key, _, state| match weak.upgrade() {
                Some(me) if me.handle_key(key, state) => glib::Propagation::Stop,
                _ => glib::Propagation::Proceed,
            });
            window.add_controller(keys.clone());
            *me.keys.borrow_mut() = Some((window.downgrade(), keys));
        });
        let w = Rc::downgrade(self);
        self.widget.connect_unmap(move |_| {
            if let Some(me) = w.upgrade() {
                me.remove_keys();
            }
        });
    }

    fn remove_keys(&self) {
        if let Some((window, keys)) = self.keys.borrow_mut().take() {
            if let Some(window) = window.upgrade() {
                window.remove_controller(&keys);
            }
        }
    }

    fn handle_key(self: &Rc<Self>, key: gtk::gdk::Key, state: gtk::gdk::ModifierType) -> bool {
        use gtk::gdk::ModifierType as M;
        if state.intersects(M::CONTROL_MASK | M::ALT_MASK | M::SUPER_MASK | M::META_MASK) {
            return false;
        }
        let Some(c) = key.to_unicode().filter(|c| matches!(c, 'n' | 'p' | '[' | ']' | 'v' | 'w' | 's')) else { return false };
        if !self.widget.is_drawable() || self.widget.visible_child_name().as_deref() != Some("files") {
            return false;
        }
        let focus = self.widget.root().and_downcast::<gtk::Window>().and_then(|w| gtk::prelude::GtkWindowExt::focus(&w));
        if focus.as_ref().is_some_and(is_text_input) {
            return false;
        }
        self.perform(c)
    }

    fn perform(self: &Rc<Self>, key: char) -> bool {
        match key {
            'n' => self.step_file(1),
            'p' => self.step_file(-1),
            ']' => self.jump_hunk(1),
            '[' => self.jump_hunk(-1),
            'v' => {
                let Some(path) = self.current_file() else { return false };
                let m = self.model.clone();
                crate::rt::spawn_local(async move { m.toggle_viewed(path).await });
            }
            'w' => diff_view::set_wrap(!diff_view::wrap()),
            's' => {
                if !self.split_fits.get() {
                    return false;
                }
                diff_view::set_split(!self.split_active());
            }
            _ => return false,
        }
        true
    }

    fn index_of(&self, obj: &glib::BoxedAnyObject) -> Option<usize> {
        (0..self.store.n_items()).find(|i| self.store.item(*i).as_ref() == Some(obj.upcast_ref::<glib::Object>())).map(|i| i as usize)
    }

    fn bound_bin(&self, index: usize) -> Option<adw::Bin> {
        let obj = self.store.item(index as u32)?;
        self.bound.borrow().iter().find(|(_, o)| o.upcast_ref::<glib::Object>() == &obj).and_then(|(b, _)| b.upgrade())
    }

    fn index_visible(&self, index: usize) -> bool {
        let Some(bin) = self.bound_bin(index) else { return false };
        let Some(bounds) = bin.compute_bounds(&self.diff_scroll) else { return false };
        bin.is_mapped() && bounds.y() + bounds.height() > 0.0 && bounds.y() < self.diff_scroll.height() as f32
    }

    fn top_index(&self) -> Option<usize> {
        let mut current = self.diff_scroll.pick(24.0, 2.0, gtk::PickFlags::DEFAULT);
        while let Some(w) = current {
            if let Some(bin) = w.downcast_ref::<adw::Bin>() {
                let obj = self.bound.borrow().iter().find(|(b, _)| b.upgrade().as_ref() == Some(bin)).map(|(_, o)| o.clone());
                if let Some(obj) = obj {
                    return self.index_of(&obj);
                }
            }
            if w == *self.diff_scroll.upcast_ref::<gtk::Widget>() {
                break;
            }
            current = w.parent();
        }
        None
    }

    fn current_index(&self) -> Option<usize> {
        let len = self.rows.borrow().len();
        if len == 0 {
            return None;
        }
        if let Some(i) = self.nav_index.get().filter(|i| *i < len && self.index_visible(*i)) {
            return Some(i);
        }
        Some(self.top_index().unwrap_or(0).min(len - 1))
    }

    fn header_at_or_before(&self, index: usize) -> Option<(usize, usize)> {
        let rows = self.rows.borrow();
        rows.iter().take(index + 1).enumerate().rev().find_map(|(i, r)| match r {
            ViewRow::Flat(FlatRow::Header(fi)) => Some((i, *fi)),
            _ => None,
        })
    }

    fn current_file(&self) -> Option<String> {
        let files = self.model.files.borrow();
        let fi = self
            .current_index()
            .and_then(|i| self.header_at_or_before(i))
            .map(|(_, fi)| fi)
            .or_else(|| self.rows.borrow().iter().find_map(|r| if let ViewRow::Flat(FlatRow::Header(fi)) = r { Some(*fi) } else { None }))?;
        files.get(fi).map(|f| f.id.clone())
    }

    fn scroll_to_top(self: &Rc<Self>, index: usize) {
        self.nav_index.set(Some(index));
        self.view.scroll_to(index as u32, gtk::ListScrollFlags::NONE, None);
        let w = Rc::downgrade(self);
        after_next_paint(&self.view, move || {
            let Some(me) = w.upgrade() else { return };
            let Some(bin) = me.bound_bin(index) else { return };
            let Some(bounds) = bin.compute_bounds(&me.diff_scroll) else { return };
            let adj = me.diff_scroll.vadjustment();
            adj.set_value(adj.value() + bounds.y() as f64);
        });
    }

    fn step_file(self: &Rc<Self>, step: i64) {
        let headers: Vec<(usize, usize)> = self
            .rows
            .borrow()
            .iter()
            .enumerate()
            .filter_map(|(i, r)| match r {
                ViewRow::Flat(FlatRow::Header(fi)) => Some((i, *fi)),
                _ => None,
            })
            .collect();
        if headers.is_empty() {
            return;
        }
        let current = self.current_index().and_then(|i| self.header_at_or_before(i)).and_then(|(row, _)| headers.iter().position(|(r, _)| *r == row));
        let target = match current {
            Some(p) => (p as i64 + step).clamp(0, headers.len() as i64 - 1) as usize,
            None => 0,
        };
        let fi = headers[target].1;
        let Some(path) = self.model.files.borrow().get(fi).map(|f| f.id.clone()) else { return };
        if self.model.collapsed.borrow_mut().remove(&path) {
            self.model.emit(Change::Diff);
        }
        let index = self.rows.borrow().iter().position(|r| matches!(r, ViewRow::Flat(FlatRow::Header(i)) if *i == fi));
        if let Some(index) = index {
            self.scroll_to_top(index);
        }
        let position = self.file_keys.borrow().iter().position(|k| *k == path);
        if let Some(row) = position.and_then(|p| self.file_list.row_at_index(p as i32)) {
            self.suppress_select.set(true);
            self.file_list.select_row(Some(&row));
            self.suppress_select.set(false);
        }
    }

    fn jump_hunk(self: &Rc<Self>, step: i64) {
        let Some(current) = self.current_index() else { return };
        let target = {
            let rows = self.rows.borrow();
            let files = self.model.files.borrow();
            let is_hunk = |r: &ViewRow| matches!(r, ViewRow::Flat(FlatRow::Line(fi, li)) if files.get(*fi).and_then(|f| f.lines.get(*li)).is_some_and(|l| l.kind == LineKind::Hunk));
            if step > 0 {
                (current + 1..rows.len()).find(|i| is_hunk(&rows[*i]))
            } else {
                (0..current).rev().find(|i| is_hunk(&rows[*i]))
            }
        };
        if let Some(t) = target {
            self.scroll_to_top(t);
        }
    }

    fn row_key(&self, row: &ViewRow) -> RowKey {
        let row = match row {
            ViewRow::Flat(r) => r,
            ViewRow::Split(fi, a, b) => return RowKey::Split(*fi, *a, *b),
        };
        match row {
            FlatRow::Header(fi) => {
                let files = self.model.files.borrow();
                let id = files.get(*fi).map(|f| f.id.as_str()).unwrap_or("");
                RowKey::Header(*fi, self.model.collapsed.borrow().contains(id), self.model.viewed.borrow().contains(id))
            }
            FlatRow::Line(fi, li) => RowKey::Line(*fi, *li),
            FlatRow::Thread(t) => RowKey::Other(format!("t{:?}{:?}", self.expanded_threads.borrow().get(&t.id), t)),
            FlatRow::Pending(p) => RowKey::Other(format!("p{p:?}")),
            FlatRow::Composer(a) => RowKey::Other(format!("c{a:?}")),
            FlatRow::Note(text) => RowKey::Other(format!("n{text}")),
        }
    }

    fn rebuild_file_list(&self) {
        let m = &self.model;
        let files = m.files.borrow();
        let viewed = m.viewed.borrow();
        let filter = self.filter.borrow().clone();
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        filter.hash(&mut hasher);
        for f in files.iter() {
            (&f.id, f.status_letter(), viewed.contains(&f.id), m.thread_count(&f.id) > 0).hash(&mut hasher);
        }
        let sig = Some(hasher.finish());
        if self.file_list_sig.get() == sig {
            return;
        }
        self.file_list_sig.set(sig);
        let viewed_count = files.iter().filter(|f| viewed.contains(&f.id)).count();
        self.viewed_label.set_text(&format!("{viewed_count}/{}", files.len()));
        self.suppress_select.set(true);
        self.file_list.remove_all();
        let mut keys = vec![];
        for f in files.iter().filter(|f| filter.is_empty() || util::contains_ci(&f.id, &filter)) {
            let b = hbox(6);
            b.append(&status_label(f));
            let col = vbox(0);
            col.set_hexpand(true);
            col.append(&ellipsized(&util::last_component(&f.id), &["sy-text"]));
            let dir = label_with(&util::parent_path(&f.id), &["sy-muted", "sy-tiny"]);
            dir.set_ellipsize(gtk::pango::EllipsizeMode::Start);
            col.append(&dir);
            b.append(&col);
            if m.thread_count(&f.id) > 0 {
                b.append(&colored_icon("sy-comment-symbolic", 11, "muted"));
            }
            if viewed.contains(&f.id) {
                b.append(&colored_icon("sy-check-symbolic", 12, "green"));
            }
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&b));
            self.file_list.append(&row);
            keys.push(f.id.clone());
        }
        *self.file_keys.borrow_mut() = keys;
        self.suppress_select.set(false);
    }

    fn reveal(self: &Rc<Self>, path: &str) {
        let files = self.model.files.borrow();
        let idx = self.rows.borrow().iter().position(|r| matches!(r, ViewRow::Flat(FlatRow::Header(i)) if files.get(*i).map(|f| f.id.as_str()) == Some(path)));
        drop(files);
        match idx {
            Some(i) => self.view.scroll_to(i as u32, gtk::ListScrollFlags::NONE, Some(gtk::ScrollInfo::new())),
            None => *self.pending_reveal.borrow_mut() = Some(path.to_string()),
        }
    }

    fn row_widget(self: &Rc<Self>, row: &ViewRow, item: &gtk::ListItem) -> gtk::Widget {
        let row = match row {
            ViewRow::Flat(r) => r,
            ViewRow::Split(fi, a, b) => {
                let files = self.model.files.borrow();
                let Some(file) = files.get(*fi) else { return vbox(0).upcast() };
                let left = a.and_then(|i| file.lines.get(i));
                let right = b.and_then(|i| file.lines.get(i));
                let opts = self.row_opts(file, item);
                return diff_view::split_row(left, right, &opts, self.comment_handler(file)).upcast();
            }
        };
        match row {
            FlatRow::Header(fi) => {
                let f = self.model.files.borrow().get(*fi).cloned();
                match f {
                    Some(f) => self.header(&f).upcast(),
                    None => vbox(0).upcast(),
                }
            }
            FlatRow::Line(fi, li) => {
                let files = self.model.files.borrow();
                let Some(file) = files.get(*fi) else { return vbox(0).upcast() };
                let Some(line) = file.lines.get(*li) else { return vbox(0).upcast() };
                let opts = self.row_opts(file, item);
                diff_view::line_row(line, &opts, self.comment_handler(file)).upcast()
            }
            FlatRow::Thread(t) => self.thread_card(t).upcast(),
            FlatRow::Pending(p) => self.pending_card(p).upcast(),
            FlatRow::Composer(a) => self.composer_card(a).upcast(),
            FlatRow::Note(text) => label_with(text, &["diff-note"]).upcast(),
        }
    }

    fn header(self: &Rc<Self>, f: &DiffFile) -> gtk::Box {
        let m = &self.model;
        let collapsed = m.collapsed.borrow().contains(&f.id);
        let b = hbox(8);
        b.add_css_class("diff-file-header");
        let toggle = icon_button(if collapsed { "pan-end-symbolic" } else { "pan-down-symbolic" }, if collapsed { "Expand" } else { "Collapse" });
        let mm = m.clone();
        let id = f.id.clone();
        toggle.connect_clicked(move |_| {
            {
                let mut c = mm.collapsed.borrow_mut();
                if !c.remove(&id) {
                    c.insert(id.clone());
                }
            }
            mm.emit(Change::Diff);
        });
        b.append(&toggle);
        b.append(&status_label(f));
        let name = match &f.previous_filename {
            Some(p) => format!("{p} → {}", f.id),
            None => f.id.clone(),
        };
        let l = label_with(&name, &["sy-mono", "sy-bold", "sy-text"]);
        l.set_ellipsize(gtk::pango::EllipsizeMode::Start);
        l.set_selectable(true);
        b.append(&l);
        b.append(&diff_stat(f.additions, f.deletions));
        b.append(&spacer());
        let is_viewed = m.viewed.borrow().contains(&f.id);
        let viewed = gtk::CheckButton::with_label("Viewed");
        viewed.set_active(is_viewed);
        viewed.set_tooltip_text(Some("Mark file as viewed (V)"));
        let mm = m.clone();
        let id = f.id.clone();
        viewed.connect_toggled(move |_| {
            let mm = mm.clone();
            let id = id.clone();
            glib::idle_add_local_once(move || {
                crate::rt::spawn_local(async move { mm.toggle_viewed(id).await });
            });
        });
        b.append(&viewed);
        let menu = Menu::new();
        let id = f.id.clone();
        menu.item("Copy file path", move || util::copy(&id));
        if f.status != "removed" {
            let mm = m.clone();
            let id = f.id.clone();
            menu.item("Blame", move || match blame_target(&mm) {
                Some((repo, git_ref)) => crate::ui::repos::open_blame(repo, git_ref, id.clone()),
                None => crate::app::toast("Blame unavailable for this file"),
            });
        }
        let side = self.side.clone();
        menu.item(if self.side.is_visible() { "Hide file list" } else { "Show file list" }, move || side.set_visible(!side.is_visible()));
        let mm = m.clone();
        menu.item("Collapse all", move || {
            let all: std::collections::HashSet<String> = mm.files.borrow().iter().map(|f| f.id.clone()).collect();
            *mm.collapsed.borrow_mut() = all;
            mm.emit(Change::Diff);
        });
        let mm = m.clone();
        menu.item("Expand all", move || {
            mm.collapsed.borrow_mut().clear();
            mm.emit(Change::Diff);
        });
        let mut menu = menu;
        menu.section(None);
        for (label, key) in [("Next file (N)", 'n'), ("Previous file (P)", 'p'), ("Next hunk (])", ']'), ("Previous hunk ([)", '[')] {
            let w = Rc::downgrade(self);
            menu.item(label, move || {
                if let Some(me) = w.upgrade() {
                    me.perform(key);
                }
            });
        }
        let mm = m.clone();
        let id = f.id.clone();
        menu.item(if is_viewed { "Mark as not viewed (V)" } else { "Mark as viewed (V)" }, move || {
            let mm = mm.clone();
            let id = id.clone();
            crate::rt::spawn_local(async move { mm.toggle_viewed(id).await });
        });
        menu.section(None);
        menu.item(if diff_view::wrap() { "Don't wrap lines (W)" } else { "Wrap lines (W)" }, || diff_view::set_wrap(!diff_view::wrap()));
        if self.split_fits.get() {
            let w = Rc::downgrade(self);
            menu.item(if self.split_active() { "Unified view (S)" } else { "Split view (S)" }, move || {
                if let Some(me) = w.upgrade() {
                    me.perform('s');
                }
            });
        } else {
            menu.disabled("Split view (S)");
        }
        let more = menu.button("view-more-symbolic", "File actions");
        more.update_property(&[gtk::accessible::Property::Label("File actions")]);
        b.append(&more);
        b
    }

    fn thread_card(self: &Rc<Self>, t: &ReviewThread) -> gtk::Box {
        let open = self.expanded_threads.borrow().get(&t.id).copied().unwrap_or(!t.is_resolved);
        let card = vbox(0);
        card.add_css_class("inline-card");
        let head = hbox(6);
        margins(&head, 5, 10, 5, 10);
        let toggle = icon_button(if open { "pan-down-symbolic" } else { "pan-end-symbolic" }, "Toggle thread");
        let w = Rc::downgrade(self);
        let id = t.id.clone();
        toggle.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.expanded_threads.borrow_mut().insert(id.clone(), !open);
                me.rebuild();
            }
        });
        head.append(&toggle);
        head.append(&icon("sy-comment-symbolic", 12));
        head.append(&label_with(&util::plural(t.comments.nodes.len() as i64, "comment", "comments"), &["sy-small"]));
        if t.is_outdated {
            head.append(&label_with("outdated", &["sy-muted", "sy-tiny"]));
        }
        if t.is_resolved {
            head.append(&label_with("resolved", &["fg-green", "sy-tiny"]));
        }
        head.append(&spacer());
        let m = self.model.clone();
        if t.is_resolved && t.viewer_can_unresolve {
            let b = button("Unresolve");
            let id = t.id.clone();
            b.connect_clicked(move |_| {
                let m = m.clone();
                let id = id.clone();
                crate::rt::spawn_local(async move {
                    m.set_resolved(id, false).await;
                });
            });
            head.append(&b);
        } else if !t.is_resolved && t.viewer_can_resolve {
            let b = button("Resolve");
            let id = t.id.clone();
            b.connect_clicked(move |_| {
                let m = m.clone();
                let id = id.clone();
                crate::rt::spawn_local(async move {
                    m.set_resolved(id, true).await;
                });
            });
            head.append(&b);
        }
        card.append(&head);
        if open {
            card.append(&line());
            for c in &t.comments.nodes {
                let row = hbox(8);
                margins(&row, 6, 10, 6, 10);
                let av = avatar(c.author.as_ref().and_then(|a| a.avatar_url.as_deref()), 20, None);
                av.set_valign(gtk::Align::Start);
                row.append(&av);
                let col = vbox(2);
                col.set_hexpand(true);
                let meta = hbox(4);
                meta.append(&label_with(c.author.as_ref().map(|a| a.login.as_str()).unwrap_or("ghost"), &["sy-bold", "sy-small", "sy-text"]));
                meta.append(&label_with(&format!("· {}", util::rel(Some(c.created_at))), &["sy-muted", "sy-small"]));
                col.append(&meta);
                col.append(&crate::ui::markdown::inline_label(&c.body));
                row.append(&col);
                card.append(&row);
            }
            if t.viewer_can_reply {
                card.append(&line());
                let reply_box = vbox(6);
                pad(&reply_box, 8);
                let composer = Composer::new("Reply", 50);
                let actions = hbox(6);
                actions.set_halign(gtk::Align::End);
                let cancel = button("Cancel");
                let send = suggested("Reply");
                actions.append(&cancel);
                actions.append(&send);
                reply_box.append(&composer.widget);
                reply_box.append(&actions);
                reply_box.set_visible(false);
                let start = link_button("Reply…");
                start.set_halign(gtk::Align::Start);
                margins(&start, 4, 6, 4, 6);
                let rb = reply_box.clone();
                let st = start.clone();
                let comp = Rc::downgrade(&composer);
                start.connect_clicked(move |_| {
                    rb.set_visible(true);
                    st.set_visible(false);
                    if let Some(c) = comp.upgrade() {
                        c.grab_focus();
                    }
                });
                let rb = reply_box.clone();
                let st = start.clone();
                cancel.connect_clicked(move |_| {
                    rb.set_visible(false);
                    st.set_visible(true);
                });
                let m = self.model.clone();
                let id = t.id.clone();
                let weak_comp = Rc::downgrade(&composer);
                let go = Rc::new(move || {
                    let Some(comp) = weak_comp.upgrade() else { return };
                    if comp.is_blank() || m.busy.get() {
                        return;
                    }
                    let body = comp.text();
                    let m = m.clone();
                    let id = id.clone();
                    crate::rt::spawn_local(async move {
                        m.reply(id, body).await;
                    });
                });
                let g = go.clone();
                send.connect_clicked(move |_| g());
                let g = go.clone();
                composer.on_submit(move || g());
                card.append(&start);
                card.append(&reply_box);
                keep_alive(&card, composer);
            }
        }
        card.set_size_request(-1, -1);
        card
    }

    fn pending_card(self: &Rc<Self>, p: &PendingComment) -> gtk::Box {
        let card = hbox(8);
        card.add_css_class("inline-card");
        card.add_css_class("pending");
        pad(&card, 10);
        card.append(&chip("pending", "amber", None, false));
        let body = crate::ui::markdown::inline_label(&p.body);
        body.set_hexpand(true);
        card.append(&body);
        let del = icon_button("user-trash-symbolic", "Delete pending comment");
        let m = self.model.clone();
        let id = p.id.clone();
        del.connect_clicked(move |_| {
            m.pending.borrow_mut().retain(|x| x.id != id);
            m.emit(Change::Diff);
        });
        card.append(&del);
        card
    }

    fn composer_card(self: &Rc<Self>, a: &DiffAnchor) -> gtk::Box {
        let card = vbox(6);
        card.add_css_class("inline-card");
        card.add_css_class("composer");
        let composer = Composer::new(&format!("Comment on line {} (Markdown)", a.line), 70);
        composer.set_text(&self.model.composer_text.borrow());
        let m = self.model.clone();
        let c2 = Rc::downgrade(&composer);
        composer.on_changed(move || {
            if let Some(c) = c2.upgrade() {
                *m.composer_text.borrow_mut() = c.text();
            }
        });
        card.append(&composer.widget);
        let actions = hbox(6);
        let cancel = button("Cancel");
        let m = self.model.clone();
        cancel.connect_clicked(move |_| {
            *m.composer.borrow_mut() = None;
            m.composer_text.borrow_mut().clear();
            m.emit(Change::Diff);
        });
        actions.append(&cancel);
        actions.append(&spacer());
        let add = button("Add to review");
        add.set_tooltip_text(Some("Save as pending and submit with the review (Ctrl+Enter)"));
        let single = suggested("Add single comment");
        actions.append(&add);
        actions.append(&single);
        card.append(&actions);
        let submit = {
            let m = self.model.clone();
            let weak_comp = Rc::downgrade(&composer);
            let a = a.clone();
            Rc::new(move |immediately: bool| {
                let Some(comp) = weak_comp.upgrade() else { return };
                if comp.is_blank() {
                    return;
                }
                let body = comp.text();
                let m = m.clone();
                let a = a.clone();
                crate::rt::spawn_local(async move {
                    m.add_inline(a, body, immediately).await;
                });
            })
        };
        let s = submit.clone();
        add.connect_clicked(move |_| s(false));
        let s = submit.clone();
        single.connect_clicked(move |_| s(true));
        let s = submit.clone();
        composer.on_submit(move || s(false));
        let comp = Rc::downgrade(&composer);
        glib::idle_add_local_once(move || {
            if let Some(c) = comp.upgrade() {
                c.grab_focus();
            }
        });
        keep_alive(&card, composer);
        card
    }
}

impl Drop for FilesTab {
    fn drop(&mut self) {
        self.remove_keys();
    }
}
