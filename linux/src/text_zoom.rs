use std::cell::Cell;

use crate::settings;
use crate::signal::Signal;

pub const LEVELS: [f64; 8] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5];
const DEFAULT_DPI: i32 = 96 * 1024;

thread_local! {
    static SCALE: Cell<f64> = Cell::new(nearest(settings::read(|s| s.text_zoom)));
    static BASE_DPI: Cell<i32> = const { Cell::new(0) };
    static APPLIED_DPI: Cell<i32> = const { Cell::new(0) };
    static PROVIDER: gtk::CssProvider = gtk::CssProvider::new();
    static CHANGED: Signal<f64> = const { Signal::new() };
}

pub fn nearest(value: f64) -> f64 {
    if !value.is_finite() || value <= 0.0 {
        return 1.0;
    }
    LEVELS.iter().copied().min_by(|a, b| (a - value).abs().total_cmp(&(b - value).abs())).unwrap_or(1.0)
}

pub fn step_up(scale: f64) -> f64 {
    LEVELS.iter().copied().find(|l| *l > scale + 0.001).unwrap_or(scale)
}

pub fn step_down(scale: f64) -> f64 {
    LEVELS.iter().rev().copied().find(|l| *l < scale - 0.001).unwrap_or(scale)
}

pub fn scale() -> f64 {
    SCALE.with(|s| s.get())
}

pub fn on_change(f: impl Fn(&f64) -> bool + 'static) {
    CHANGED.with(|s| s.connect(f));
}

pub fn zoom_in() {
    set(step_up(scale()));
}

pub fn zoom_out() {
    set(step_down(scale()));
}

pub fn reset() {
    set(1.0);
}

fn set(value: f64) {
    if (value - scale()).abs() < 0.001 {
        return;
    }
    SCALE.with(|s| s.set(value));
    settings::update(|s| s.text_zoom = value);
    apply();
    CHANGED.with(|s| s.emit(&value));
}

fn px(base: f64) -> String {
    format!("{:.2}px", base * scale())
}

fn css() -> String {
    format!(
        ".diff-line, .diff-gutter, .code-view, .code-view text, .chat-code {{ font-size: {}; }}\n.blame-gutter, .log-view text {{ font-size: {}; }}\n",
        px(12.0),
        px(11.0)
    )
}

fn apply() {
    PROVIDER.with(|p| p.load_from_string(&css()));
    let Some(settings) = gtk::Settings::default() else { return };
    let base = BASE_DPI.with(|b| b.get());
    if base <= 0 {
        return;
    }
    let dpi = (base as f64 * scale()).round() as i32;
    APPLIED_DPI.with(|a| a.set(dpi));
    if settings.gtk_xft_dpi() != dpi {
        settings.set_gtk_xft_dpi(dpi);
    }
}

pub fn install() {
    let Some(display) = gtk::gdk::Display::default() else { return };
    PROVIDER.with(|p| gtk::style_context_add_provider_for_display(&display, p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 3));
    let Some(settings) = gtk::Settings::default() else { return };
    let current = settings.gtk_xft_dpi();
    BASE_DPI.with(|b| b.set(if current > 0 { current } else { DEFAULT_DPI }));
    settings.connect_gtk_xft_dpi_notify(|s| {
        let value = s.gtk_xft_dpi();
        if value == APPLIED_DPI.with(|a| a.get()) {
            return;
        }
        BASE_DPI.with(|b| b.set(if value > 0 { value } else { DEFAULT_DPI }));
        gtk::glib::idle_add_local_once(apply);
    });
    apply();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_stay_in_range() {
        assert_eq!(step_up(1.0), 1.1);
        assert_eq!(step_down(1.0), 0.9);
        assert_eq!(step_up(1.5), 1.5);
        assert_eq!(step_down(0.8), 0.8);
        assert_eq!(nearest(1.26), 1.3);
        assert_eq!(nearest(7.0), 1.5);
        assert_eq!(nearest(0.0), 1.0);
        assert_eq!(nearest(f64::NAN), 1.0);
    }
}
