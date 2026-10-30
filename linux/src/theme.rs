use std::cell::{Cell, RefCell};
use std::collections::HashSet;


use crate::brand;
use crate::settings;
use crate::signal::Signal;

pub const ACCENTS: &[&str] = &["accent", "sky", "violet", "coral", "green", "red", "amber", "teal", "indigo", "slate", "orange", "muted"];

struct Palette {
    entries: &'static [(&'static str, &'static str)],
}

const BRAND_LIGHT: Palette = Palette {
    entries: &[
        ("window", "#F7F5F0"),
        ("sidebar", "#EFECE5"),
        ("list", "#F3F1EC"),
        ("panel", "#FDFCFA"),
        ("raised", "#FFFFFF"),
        ("sunken", "#F1EEE8"),
        ("bar", "#F5F3EE"),
        ("line", "alpha(#1A2333, 0.08)"),
        ("line_strong", "alpha(#1A2333, 0.15)"),
        ("text", "#1A2333"),
        ("muted", "#5F6B7E"),
        ("dim", "#939AA8"),
        ("accent", "#2A8BC8"),
        ("sky", brand::SKY.0),
        ("violet", brand::VIOLET.0),
        ("coral", brand::CORAL.0),
        ("green", brand::GREEN.0),
        ("red", "#C2412F"),
        ("amber", brand::AMBER.0),
        ("teal", "#23877A"),
        ("indigo", "#4E5BC4"),
        ("slate", "#6B7486"),
        ("orange", "#C8691C"),
        ("selection", "#2F6FE0"),
        ("add_bg", "alpha(#2E8A57, 0.11)"),
        ("del_bg", "alpha(#C2412F, 0.10)"),
        ("hunk_bg", "alpha(#1F7FB8, 0.08)"),
        ("add_text", "#1E5A3A"),
        ("del_text", "#7A2A20"),
        ("hunk_text", "#1F6E9E"),
        ("gutter", "#9AA2B0"),
    ],
};

const BRAND_DARK: Palette = Palette {
    entries: &[
        ("window", "#0C1220"),
        ("sidebar", "#0A0F1B"),
        ("list", "#0E1526"),
        ("panel", "#101828"),
        ("raised", "#152036"),
        ("sunken", "#0A101C"),
        ("bar", "#111A2C"),
        ("line", "alpha(#A0AEC4, 0.10)"),
        ("line_strong", "alpha(#A0AEC4, 0.18)"),
        ("text", "#E6EBF2"),
        ("muted", "#8693A8"),
        ("dim", "#5F6B80"),
        ("accent", "#5BB8EC"),
        ("sky", brand::SKY.1),
        ("violet", brand::VIOLET.1),
        ("coral", brand::CORAL.1),
        ("green", brand::GREEN.1),
        ("red", "#E8746A"),
        ("amber", brand::AMBER.1),
        ("teal", "#56C2B0"),
        ("indigo", "#8C97E8"),
        ("slate", "#939CB0"),
        ("orange", "#F0904A"),
        ("selection", "#2457CF"),
        ("add_bg", "alpha(#5DBE8A, 0.10)"),
        ("del_bg", "alpha(#E8746A, 0.11)"),
        ("hunk_bg", "alpha(#5BB8EC, 0.08)"),
        ("add_text", "#C2E9D2"),
        ("del_text", "#F3C4BE"),
        ("hunk_text", "#8CCBEE"),
        ("gutter", "#4A5670"),
    ],
};

const SYSTEM_LIGHT: Palette = Palette {
    entries: &[
        ("window", "@window_bg_color"),
        ("sidebar", "@window_bg_color"),
        ("list", "@view_bg_color"),
        ("panel", "@view_bg_color"),
        ("raised", "@card_bg_color"),
        ("sunken", "alpha(@window_fg_color, 0.04)"),
        ("bar", "@headerbar_bg_color"),
        ("line", "alpha(@window_fg_color, 0.10)"),
        ("line_strong", "alpha(@window_fg_color, 0.18)"),
        ("text", "@window_fg_color"),
        ("muted", "alpha(@window_fg_color, 0.65)"),
        ("dim", "alpha(@window_fg_color, 0.45)"),
        ("accent", "@accent_color"),
        ("sky", "@blue_4"),
        ("violet", "@purple_4"),
        ("coral", "@red_3"),
        ("green", "@success_color"),
        ("red", "@error_color"),
        ("amber", "@warning_color"),
        ("teal", "mix(@blue_5, @green_5, 0.55)"),
        ("indigo", "mix(@blue_5, @purple_4, 0.4)"),
        ("slate", "@dark_1"),
        ("orange", "@orange_4"),
        ("selection", "@accent_bg_color"),
        ("add_bg", "alpha(@success_color, 0.14)"),
        ("del_bg", "alpha(@error_color, 0.14)"),
        ("hunk_bg", "alpha(@accent_color, 0.08)"),
        ("add_text", "@window_fg_color"),
        ("del_text", "@window_fg_color"),
        ("hunk_text", "alpha(@window_fg_color, 0.65)"),
        ("gutter", "alpha(@window_fg_color, 0.4)"),
    ],
};

const SYSTEM_DARK: Palette = Palette {
    entries: &[
        ("window", "@window_bg_color"),
        ("sidebar", "@window_bg_color"),
        ("list", "@view_bg_color"),
        ("panel", "@view_bg_color"),
        ("raised", "@card_bg_color"),
        ("sunken", "alpha(@window_fg_color, 0.04)"),
        ("bar", "@headerbar_bg_color"),
        ("line", "alpha(@window_fg_color, 0.10)"),
        ("line_strong", "alpha(@window_fg_color, 0.18)"),
        ("text", "@window_fg_color"),
        ("muted", "alpha(@window_fg_color, 0.65)"),
        ("dim", "alpha(@window_fg_color, 0.45)"),
        ("accent", "@accent_color"),
        ("sky", "@blue_2"),
        ("violet", "@purple_2"),
        ("coral", "@red_1"),
        ("green", "@success_color"),
        ("red", "@error_color"),
        ("amber", "@warning_color"),
        ("teal", "mix(@blue_2, @green_2, 0.55)"),
        ("indigo", "mix(@blue_2, @purple_1, 0.4)"),
        ("slate", "@light_5"),
        ("orange", "@orange_2"),
        ("selection", "@accent_bg_color"),
        ("add_bg", "alpha(@success_color, 0.14)"),
        ("del_bg", "alpha(@error_color, 0.14)"),
        ("hunk_bg", "alpha(@accent_color, 0.08)"),
        ("add_text", "@window_fg_color"),
        ("del_text", "@window_fg_color"),
        ("hunk_text", "alpha(@window_fg_color, 0.65)"),
        ("gutter", "alpha(@window_fg_color, 0.4)"),
    ],
};

thread_local! {
    static PALETTE_PROVIDER: gtk::CssProvider = gtk::CssProvider::new();
    static APP_PROVIDER: gtk::CssProvider = gtk::CssProvider::new();
    static DYNAMIC_PROVIDER: gtk::CssProvider = gtk::CssProvider::new();
    static DYNAMIC: RefCell<(HashSet<String>, String)> = RefCell::new((HashSet::new(), String::new()));
    static DYNAMIC_PENDING: Cell<bool> = const { Cell::new(false) };
    static CHANGED: Signal<()> = Signal::new();
}

pub fn is_brand() -> bool {
    settings::read(|s| s.theme_style != "system")
}

pub fn is_dark() -> bool {
    adw::StyleManager::default().is_dark()
}

pub fn is_high_contrast() -> bool {
    adw::StyleManager::default().is_high_contrast()
}

fn brand_active() -> bool {
    is_brand() && !is_high_contrast()
}

pub fn on_change(f: impl Fn(&()) -> bool + 'static) {
    CHANGED.with(|s| s.connect(f));
}

fn libadwaita_has_css_vars() -> bool {
    adw::major_version() > 1 || adw::minor_version() >= 6
}

fn current_palette() -> &'static Palette {
    match (brand_active(), is_dark()) {
        (true, false) => &BRAND_LIGHT,
        (true, true) => &BRAND_DARK,
        (false, false) => &SYSTEM_LIGHT,
        (false, true) => &SYSTEM_DARK,
    }
}

pub fn token_hex(name: &str) -> Option<&'static str> {
    current_palette().entries.iter().find(|(k, _)| *k == name).map(|(_, v)| *v).filter(|v| v.starts_with('#'))
}

fn palette_css() -> String {
    let brand = brand_active();
    let palette = current_palette();
    let mut css = String::new();
    for (k, v) in palette.entries {
        css.push_str(&format!("@define-color sy_{k} {v};\n"));
    }
    let dark = is_dark();
    for (name, pair) in [("sky", brand::SKY), ("violet", brand::VIOLET), ("coral", brand::CORAL), ("green", brand::GREEN), ("amber", brand::AMBER)] {
        css.push_str(&format!("@define-color sy_brand_{name} {};\n", brand::pick(pair, dark)));
    }
    let (mark_violet, mark_sky, mark_coral) = (brand::MARK_VIOLET, brand::MARK_SKY, brand::MARK_CORAL);
    css.push_str(&format!("@define-color sy_mark_violet {mark_violet};\n@define-color sy_mark_sky {mark_sky};\n@define-color sy_mark_coral {mark_coral};\n"));
    if is_high_contrast() {
        css.push_str("@define-color sy_line alpha(@sy_text, 0.45);\n@define-color sy_line_strong alpha(@sy_text, 0.65);\n@define-color sy_muted alpha(@sy_text, 0.85);\n@define-color sy_dim alpha(@sy_text, 0.72);\n");
    }
    css.push_str("@define-color sy_hover alpha(@sy_text, 0.05);\n@define-color sy_ring @sy_line_strong;\n@define-color sy_on_accent @accent_fg_color;\n");
    if brand {
        let overrides = [
            ("window_bg_color", "@sy_window", "--window-bg-color"),
            ("window_fg_color", "@sy_text", "--window-fg-color"),
            ("view_bg_color", "@sy_panel", "--view-bg-color"),
            ("view_fg_color", "@sy_text", "--view-fg-color"),
            ("headerbar_bg_color", "@sy_bar", "--headerbar-bg-color"),
            ("headerbar_fg_color", "@sy_text", "--headerbar-fg-color"),
            ("sidebar_bg_color", "@sy_sidebar", "--sidebar-bg-color"),
            ("sidebar_fg_color", "@sy_text", "--sidebar-fg-color"),
            ("secondary_sidebar_bg_color", "@sy_list", "--secondary-sidebar-bg-color"),
            ("card_bg_color", "@sy_raised", "--card-bg-color"),
            ("card_fg_color", "@sy_text", "--card-fg-color"),
            ("popover_bg_color", "@sy_raised", "--popover-bg-color"),
            ("popover_fg_color", "@sy_text", "--popover-fg-color"),
            ("dialog_bg_color", "@sy_panel", "--dialog-bg-color"),
            ("dialog_fg_color", "@sy_text", "--dialog-fg-color"),
            ("accent_bg_color", "@sy_accent", "--accent-bg-color"),
            ("accent_color", "@sy_accent", "--accent-color"),
            ("destructive_bg_color", "@sy_red", "--destructive-bg-color"),
            ("success_color", "@sy_green", "--success-color"),
            ("warning_color", "@sy_amber", "--warning-color"),
            ("error_color", "@sy_red", "--error-color"),
        ];
        for (name, value, _) in overrides {
            css.push_str(&format!("@define-color {name} {value};\n"));
        }
        if libadwaita_has_css_vars() {
            css.push_str(":root {\n");
            for (_, value, var) in overrides {
                css.push_str(&format!("  {var}: {value};\n"));
            }
            css.push_str("}\n");
        }
    }
    css
}

const APP_CSS: &str = r#"
.sy-text { color: @sy_text; }
.sy-muted { color: @sy_muted; }
.sy-dim { color: @sy_dim; }
.sy-mono { font-family: monospace; }
.sy-small { font-size: 0.85em; }
.sy-tiny { font-size: 0.78em; }
.sy-bold { font-weight: 600; }
.sy-title { font-size: 1.45em; font-weight: 700; }
.sy-title-num { font-size: 1.45em; color: @sy_dim; }
.sy-heading { font-weight: 600; }
.sy-sidebar-pane { background-color: @sy_sidebar; }
.sy-list-pane { background-color: @sy_list; }
.sy-panel-pane { background-color: @sy_panel; }
.sy-bar { background-color: @sy_bar; border-bottom: 1px solid @sy_line; }
.sy-bar-top { background-color: @sy_bar; border-top: 1px solid @sy_line; }
.sy-sunken { background-color: @sy_sunken; border-radius: 8px; }
.sy-raised { background-color: @sy_raised; border-radius: 10px; }
.sy-line { background-color: @sy_line; min-height: 1px; min-width: 1px; }
.sy-card { background-color: @sy_raised; border-radius: 12px; padding: 14px; }
.sy-card-flat { background-color: @sy_raised; border-radius: 10px; }
list.sy-list, listview.sy-list { background-color: transparent; }
list.sy-list > row { padding: 8px 12px; margin: 0 8px; border-bottom: 1px solid @sy_line; }
list.sy-list > row:selected { background-color: alpha(@sy_text, 0.10); border-radius: 10px; border-bottom-color: transparent; }
list.sy-list:focus-within > row:selected { background-color: @sy_selection; color: @sy_on_accent; }
list.sy-list:focus-within > row:selected .sy-muted, list.sy-list:focus-within > row:selected .sy-dim { color: alpha(@sy_on_accent, 0.75); }
list.sy-list:focus-within > row:selected .sy-text { color: @sy_on_accent; }
list.sy-plain > row { padding: 4px 10px; }
list.sy-sidebar-list { background-color: transparent; }
list.sy-sidebar-list > row { padding: 5px 8px; margin: 1px 6px; border-radius: 7px; }
list.sy-sidebar-list > row:selected { background-color: alpha(@sy_text, 0.07); box-shadow: inset 3px 0 @sy_accent; }
.sy-section-title { font-size: 0.86em; font-weight: 600; color: @sy_dim; margin: 12px 14px 4px 16px; }
.sy-count { color: @sy_muted; font-feature-settings: "tnum"; }
.chip { padding: 1px 7px; border-radius: 999px; font-size: 0.82em; font-weight: 500; }
.chip.mono { font-family: monospace; font-weight: 400; }
.state-dot { min-width: 22px; min-height: 22px; border-radius: 999px; }
.state-pill { padding: 3px 10px; border-radius: 999px; font-weight: 600; color: @sy_on_accent; }
.icon-tile { border-radius: 6px; }
.banner-box { border-radius: 10px; padding: 6px 10px; min-height: 28px; }
.banner-button { min-height: 24px; padding: 2px 12px; border-radius: 6px; font-size: 0.92em; font-weight: 600; }
.diff-view { background-color: @sy_panel; }
.diff-line { font-family: monospace; font-size: 12px; padding: 0; }
.diff-line.add { background-color: @sy_add_bg; }
.diff-line.del { background-color: @sy_del_bg; }
.diff-line.hunk { background-color: @sy_hunk_bg; color: @sy_muted; }
.diff-line.meta { color: @sy_muted; }
.diff-gutter { color: @sy_dim; font-family: monospace; font-size: 12px; }
.diff-gutter.commentable:hover { color: @sy_accent; }
.diff-file-header { background-color: @sy_raised; border-top: 1px solid @sy_line; border-bottom: 1px solid @sy_line; padding: 6px 12px; margin-top: 8px; }
.diff-note { color: @sy_muted; font-size: 0.85em; padding: 8px 12px; }
.inline-card { background-color: @sy_raised; border-radius: 10px; margin: 6px 12px 6px 108px; }
.inline-card.pending { background-color: alpha(@sy_amber, 0.08); border: 1px solid alpha(@sy_amber, 0.4); }
.inline-card.composer { border: 1px solid alpha(@sy_accent, 0.5); padding: 10px; }
.composer-box { background-color: @sy_sunken; border-radius: 8px; padding: 4px; }
.composer-box textview, .composer-box textview text { background-color: transparent; }
.code-view, .code-view text { background-color: @sy_sunken; font-family: monospace; font-size: 12px; }
.blame-gutter { font-family: monospace; font-size: 11px; color: @sy_muted; background-color: alpha(@sy_text, 0.03); border-right: 1px solid @sy_line; }
.log-view text { font-family: monospace; font-size: 11px; }
.refresh-footer { border-top: 1px solid @sy_line; padding: 3px; font-size: 0.82em; color: @sy_muted; }
.tab-strip { padding: 4px 12px 0 12px; }
.tab-strip button { border-radius: 0; padding: 6px 10px; border-bottom: 2px solid transparent; background: none; box-shadow: none; }
.tab-strip button.active { border-bottom-color: @sy_accent; color: @sy_text; }
.tab-strip button:not(.active) { color: @sy_muted; }
.tab-badge { font-size: 0.78em; padding: 0 6px; border-radius: 999px; background-color: alpha(@sy_text, 0.08); }
.stack-strip { background-color: alpha(@sy_indigo, 0.06); border-radius: 9px; padding: 1px 4px; }
.stack-canvas { background-color: @sy_sunken; }
.stack-card { background-color: @sy_raised; border-radius: 10px; border: 1px solid @sy_line_strong; padding: 7px 10px; }
.stack-card.current { border: 2px solid @sy_indigo; padding: 6px 9px; }
.stack-card.compact { padding: 0; border-width: 3px; border-radius: 12px; }
.stack-card.compact.current { border-width: 8px; }
.stack-card .stack-status-bar { border-radius: 0; min-width: 14px; }
.stack-compact-num { font-size: 40px; font-weight: 700; }
.stack-compact-status { font-size: 26px; font-weight: 600; }
.stack-commit { background-color: @sy_sunken; border-radius: 5px; padding: 3px 6px; font-family: monospace; font-size: 0.82em; color: @sy_muted; }
.stack-pill { font-size: 0.74em; padding: 1px 7px; }
.stack-base-pill { background-color: @sy_raised; border: 1px solid @sy_line_strong; border-radius: 999px; padding: 0 12px; }
.stack-zoom-bar { background-color: @sy_raised; border: 1px solid @sy_line_strong; border-radius: 8px; padding: 2px 4px; }
.stack-zoom-bar button { min-height: 22px; min-width: 22px; padding: 2px 4px; }
.stack-sticky { background-color: alpha(@sy_amber, 0.16); border: 1px solid alpha(@sy_amber, 0.45); border-radius: 5px; padding: 6px 9px; }
.stack-sticky:hover { background-color: alpha(@sy_amber, 0.22); border-color: alpha(@sy_amber, 0.8); }
.stack-sticky .stack-dot { border-radius: 999px; min-width: 6px; min-height: 6px; }
.stack-note-btn { padding: 1px 3px; border-radius: 5px; }
.stack-note-btn:hover { background-color: alpha(@sy_text, 0.06); }
.stack-notes-panel { background-color: @sy_raised; border: 1px solid @sy_line_strong; border-radius: 10px; padding: 14px; box-shadow: 0 4px 12px alpha(black, 0.18); }
.stack-note-text { border: 1px solid @sy_line_strong; border-radius: 6px; padding: 6px; }
.stack-note-text, .stack-note-text text { background-color: alpha(@sy_amber, 0.10); }
listview.stack-list { background-color: transparent; padding: 12px; }
listview.stack-list > row { padding: 0; margin: 1px 0; background: none; }
.stack-row { border-radius: 7px; padding: 7px 10px; }
.stack-row:hover { background-color: @sy_line; }
.stack-row.current { background-color: alpha(@sy_indigo, 0.12); box-shadow: inset 0 0 0 1px alpha(@sy_indigo, 0.5); }
.stack-row.opening { box-shadow: inset 0 0 0 1px alpha(@sy_indigo, 0.5); }
.stack-base-row { padding: 6px 10px; }
.stack-entry .stack-entry-capsule { min-width: 12px; min-height: 5px; border-radius: 3px; }
.shimmer { background-color: alpha(@sy_text, 0.08); border-radius: 6px; animation: sy-shimmer 1.1s ease-in-out infinite alternate; }
.shimmer.wide { border-radius: 9px; }
@keyframes sy-shimmer { from { opacity: 0.45; } to { opacity: 1; } }
.chat-scroller { background-color: @sy_panel; }
.chat-user { background-color: @sy_raised; border-radius: 10px; padding: 12px; }
.chat-tool { background-color: @sy_raised; border-radius: 10px; }
.chat-tool.error { border: 1px solid alpha(@sy_red, 0.5); }
.chat-tool.denied { border: 1px solid alpha(@sy_amber, 0.5); }
.chat-permission { background-color: @sy_raised; border-left: 3px solid @sy_amber; border-radius: 8px; padding: 12px; }
.chat-error { background-color: @sy_raised; border-left: 3px solid @sy_amber; border-radius: 8px; padding: 12px; }
.chat-welcome { background-color: alpha(@sy_coral, 0.06); border-radius: 12px; padding: 16px; }
.chat-composer { background-color: @sy_raised; border-radius: 12px; padding: 10px; margin: 12px; }
.chat-composer textview, .chat-composer textview text { background-color: transparent; }
.chat-code { background-color: @sy_sunken; border-radius: 8px; padding: 8px; font-family: monospace; font-size: 12px; }
.chat-notice { color: @sy_dim; font-size: 0.82em; }
.chat-output-scroll { background-color: @sy_sunken; border-radius: 8px; }
.chat-output, .chat-output text { background-color: transparent; color: inherit; font-size: 12px; }
.chat-tool-summary { color: alpha(@sy_text, 0.72); }
.chat-step-title { color: alpha(@sy_text, 0.86); }
.chat-command-hint { color: @sy_muted; font-family: monospace; font-size: 0.9em; }
.chat-stop { min-width: 20px; min-height: 20px; padding: 0; border-radius: 999px; color: @sy_red; background-color: alpha(@sy_red, 0.14); transition: background-color 200ms ease-out, color 200ms ease-out; }
.chat-stop:hover { color: white; background-color: alpha(@sy_red, 0.9); }
.chat-user-edit { box-shadow: inset 0 0 0 1px alpha(@sy_violet, 0.45); }
.chat-user-edit textview, .chat-user-edit textview text { background-color: transparent; }
.chat-actions { opacity: 0; transition: opacity 200ms ease-out; min-height: 22px; }
.chat-actions.shown { opacity: 1; }
.chat-actions button { min-height: 22px; min-width: 24px; padding: 0 4px; border-radius: 6px; color: @sy_muted; }
.chat-actions button:hover { color: @sy_text; background-color: alpha(@sy_text, 0.08); }
.chat-group-head, .chat-step-head { padding: 4px 8px; min-height: 26px; }
.chat-group-steps { border: 1px solid @sy_line; border-radius: 10px; }
.chat-jump { min-width: 40px; min-height: 40px; padding: 0; border-radius: 999px; background-color: @sy_raised; border: 1.5px solid alpha(@sy_violet, 0.45); box-shadow: 0 3px 9px alpha(black, 0.2); transition: transform 200ms ease-out, box-shadow 200ms ease-out, border-color 200ms ease-out; }
.chat-jump:hover { transform: translateY(-2px) scale(1.06); box-shadow: 0 6px 14px alpha(black, 0.32); border-color: @sy_sky; }
.chat-jump:active { transform: scale(0.92); }
.chat-jump.fresh { animation: sy-jump-pulse 1.6s ease-in-out infinite; }
@keyframes sy-jump-pulse { 0% { border-color: alpha(@sy_violet, 0.45); } 50% { border-color: @sy_sky; } 100% { border-color: alpha(@sy_violet, 0.45); } }
.chat-jump-badge { background-color: @sy_violet; color: @sy_on_accent; border-radius: 9px; min-width: 18px; min-height: 18px; padding: 0 5px; font-size: 10px; font-weight: 700; border: 2px solid @sy_panel; }
.chat-pr-card { background-color: alpha(@sy_violet, 0.08); border: 1px solid alpha(@sy_violet, 0.25); border-radius: 10px; padding: 12px; }
.chat-todo { background-color: alpha(@sy_text, 0.03); border: 1px solid @sy_line; border-radius: 10px; }
.chat-todo-head { padding: 6px 10px; border-radius: 10px; }
.chat-todo-progress trough, .chat-todo-progress progress { min-height: 4px; border-radius: 2px; }
.chat-suggestion { padding: 10px 12px; border-radius: 10px; background-color: alpha(@sy_text, 0.035); border: 1px solid @sy_line; min-height: 24px; }
.chat-suggestion:hover { background-color: alpha(@sy_text, 0.07); border-color: alpha(@sy_violet, 0.45); }
.claude-tab { padding: 4px 10px; border-radius: 8px; background-color: alpha(@sy_text, 0.04); border: 1px solid @sy_line; }
.claude-tab.selected { background-color: alpha(@sy_accent, 0.14); border-color: alpha(@sy_accent, 0.45); }
.project-column { background-color: @sy_sunken; border-radius: 12px; }
.project-column.drop-target { background-color: alpha(@sy_accent, 0.10); border: 2px solid @sy_accent; }
.project-card { background-color: @sy_raised; border-radius: 8px; padding: 10px; }
.splash-title { font-size: 32px; font-weight: 700; }
.login-title { font-size: 28px; font-weight: 700; }
.user-code { font-family: monospace; font-size: 22px; font-weight: 700; padding: 4px 10px; background-color: @sy_sunken; border-radius: 8px; }
.update-row { background-color: alpha(@sy_sky, 0.12); border-radius: 8px; padding: 8px 10px; margin: 0 8px 8px 8px; }
.user-footer { border-top: 1px solid @sy_line; padding: 10px; }
.new-row { background-color: alpha(@sy_accent, 0.10); }
.jira-panel { background-color: @sy_raised; border: 1px solid @sy_line; border-radius: 12px; padding: 16px; }
.jira-card { background-color: @sy_raised; border: 1px solid @sy_line; border-radius: 14px; padding: 18px; }
.jira-link-panel { background-color: alpha(@sy_text, 0.04); border-radius: 10px; padding: 12px; }
.jira-empty { padding: 36px 0; }
.jira-summary { font-size: 1.2em; font-weight: 600; }
.jira-desc { background-color: @sy_sunken; border-radius: 10px; padding: 12px; }
.jira-chip { background-color: alpha(@sy_text, 0.05); border-radius: 999px; padding: 4px 8px; }
.jira-status { padding: 4px 10px; border-radius: 999px; font-size: 0.82em; font-weight: 700; }
.jira-dot { border-radius: 999px; min-width: 6px; min-height: 6px; }
flowbox.jira-meta > flowboxchild { padding: 0; }
button.jira-row { padding: 11px 14px; border-radius: 10px; background-color: alpha(@sy_text, 0.03); border: 1px solid @sy_line; box-shadow: none; }
button.jira-row:hover { background-color: alpha(@sy_text, 0.06); }
button.jira-parent { padding: 0 2px; min-height: 0; }
menubutton.jira-status-menu > button { padding: 0; min-height: 0; background: none; box-shadow: none; }
.sy-status { min-width: 220px; }
.sy-unread-dot { background-color: @sy_sky; border-radius: 999px; min-width: 7px; min-height: 7px; }
.sy-status-title { font-weight: 600; color: @sy_text; }
.sy-status-message { color: @sy_muted; }
.sy-avatar-ring { border-radius: 999px; box-shadow: 0 0 0 1px @sy_ring; }
list.sy-list > row:hover:not(:selected) { background-color: @sy_hover; border-radius: 10px; }
.sy-row-title { font-weight: 500; color: @sy_text; }
.sy-row-meta { color: @sy_muted; font-size: 0.85em; }
.sy-row-meta .sy-dim { color: @sy_dim; }
.sy-sidebar-glyph { color: @sy_muted; }
list.sy-sidebar-list > row:selected .sy-sidebar-glyph { color: @sy_text; }
.sy-sidebar-badge { padding: 0 7px; min-width: 10px; border-radius: 999px; background-color: alpha(@sy_text, 0.07); color: @sy_muted; font-size: 0.8em; font-weight: 600; font-feature-settings: "tnum"; }
.sy-sidebar-badge.attention { background-color: @sy_accent; color: @sy_on_accent; }
button.comment-send:disabled { background-color: alpha(@sy_text, 0.08); color: @sy_dim; }
.onboarding { background-color: @sy_window; background-image: linear-gradient(135deg, alpha(@sy_mark_violet, 0.12), alpha(@sy_mark_sky, 0.08) 45%, alpha(@sy_mark_coral, 0.10)); background-size: 260% 260%; animation: sy-drift 24s ease-in-out infinite alternate; }
@keyframes sy-drift { from { background-position: 0% 30%; } to { background-position: 100% 70%; } }
.onboarding-title { font-size: 32px; font-weight: 700; color: @sy_text; }
.onboarding-tagline { font-size: 1.05em; color: @sy_muted; }
.onboarding-card { background-color: alpha(@sy_raised, 0.86); border: 1px solid @sy_line; border-radius: 12px; padding: 12px 14px; }
.onboarding-card .sy-status-message { font-size: 0.88em; }
"#;

fn color_css() -> String {
    let mut css = String::new();
    for name in ACCENTS {
        css.push_str(&format!(
            ".fg-{name} {{ color: @sy_{name}; }}\n.bg-{name} {{ background-color: alpha(@sy_{name}, 0.12); }}\n.tile-{name} {{ background-color: alpha(@sy_{name}, 0.14); color: @sy_{name}; }}\n.chip.{name} {{ background-color: alpha(@sy_{name}, 0.12); color: @sy_{name}; }}\n.state-dot.{name} {{ background-color: alpha(@sy_{name}, 0.15); color: @sy_{name}; }}\n.state-pill.{name} {{ background-color: @sy_{name}; }}\n.banner-box.{name} {{ background-color: alpha(@sy_{name}, 0.08); }}\nbutton.tint-{name} {{ background-color: @sy_{name}; color: @sy_on_accent; }}\n.edge-{name} {{ background-color: @sy_{name}; min-width: 3px; border-radius: 2px; }}\n.jira-status.{name} {{ background-color: alpha(@sy_{name}, 0.14); color: @sy_{name}; }}\n.jira-status.{name} .jira-dot {{ background-color: @sy_{name}; }}\n"
        ));
    }
    css
}

pub fn apply() {
    let manager = adw::StyleManager::default();
    let scheme = match settings::read(|s| s.appearance.clone()).as_str() {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    };
    manager.set_color_scheme(scheme);
    reload_palette();
}

fn reload_palette() {
    PALETTE_PROVIDER.with(|p| p.load_from_string(&palette_css()));
    CHANGED.with(|s| s.emit(&()));
}

pub fn install() {
    let Some(display) = gtk::gdk::Display::default() else { return };
    PALETTE_PROVIDER.with(|p| gtk::style_context_add_provider_for_display(&display, p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION));
    APP_PROVIDER.with(|p| {
        p.load_from_string(&format!("{APP_CSS}\n{}", color_css()));
        gtk::style_context_add_provider_for_display(&display, p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    });
    DYNAMIC_PROVIDER.with(|p| gtk::style_context_add_provider_for_display(&display, p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 2));
    adw::StyleManager::default().connect_dark_notify(|_| reload_palette());
    adw::StyleManager::default().connect_high_contrast_notify(|_| reload_palette());
    apply();
}

pub fn hex_class(hex: &str) -> String {
    let h = crate::util::clean_hex(hex).to_lowercase();
    let h = if h.len() == 3 { h.chars().flat_map(|c| [c, c]).collect() } else { h };
    let class = format!("hex-{h}");
    let schedule = DYNAMIC.with(|d| {
        let mut d = d.borrow_mut();
        if !d.0.insert(h.clone()) {
            return false;
        }
        d.1.push_str(&format!(
            ".{class}.label-chip {{ background-color: alpha(#{h}, 0.22); border: 1px solid alpha(#{h}, 0.7); border-radius: 999px; padding: 0 7px; font-size: 0.78em; font-weight: 500; }}\n.{class}.dot {{ background-color: #{h}; border-radius: 999px; min-width: 8px; min-height: 8px; }}\n.{class}.fg {{ color: #{h}; }}\n"
        ));
        !DYNAMIC_PENDING.replace(true)
    });
    if schedule {
        gtk::glib::idle_add_local_full(gtk::glib::Priority::HIGH_IDLE, || {
            flush_dynamic();
            gtk::glib::ControlFlow::Break
        });
    }
    class
}

fn flush_dynamic() {
    DYNAMIC_PENDING.set(false);
    DYNAMIC.with(|d| {
        let d = d.borrow();
        DYNAMIC_PROVIDER.with(|p| p.load_from_string(&d.1));
    });
}

const PROJECT_COLORS: &[&str] = &["sky", "violet", "coral", "orange", "teal", "green", "indigo", "amber"];

pub fn palette_for(path: &str) -> &'static str {
    let mut h: u64 = 1469598103934665603;
    for b in path.bytes() {
        h = (h ^ b as u64).wrapping_mul(1099511628211);
    }
    PROJECT_COLORS[(h % PROJECT_COLORS.len() as u64) as usize]
}

pub fn branch_color(branch: &str) -> &'static str {
    let b = branch.to_lowercase();
    if ["main", "master", "develop", "dev", "staging", "release"].contains(&b.as_str()) {
        return "slate";
    }
    if b.starts_with("feat") || b.starts_with("feature") {
        return "green";
    }
    if b.starts_with("fix") || b.starts_with("hotfix") || b.starts_with("bug") {
        return "amber";
    }
    if b.starts_with("chore") || b.starts_with("refactor") || b.starts_with("docs") {
        return "teal";
    }
    let re = regex::Regex::new("^[a-z]+-[0-9]+").expect("regex");
    if re.is_match(&b) {
        return "violet";
    }
    "muted"
}

pub fn project_color(name: &str) -> &'static str {
    match name {
        "BLUE" => "sky",
        "GREEN" => "green",
        "YELLOW" => "amber",
        "ORANGE" => "coral",
        "RED" => "red",
        "PINK" => "coral",
        "PURPLE" => "violet",
        _ => "slate",
    }
}
