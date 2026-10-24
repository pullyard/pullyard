use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use gtk::gio;
use gtk::glib;
use gtk::prelude::*;

use crate::{brand, settings};

pub const TAB_ACTION: &str = "agent-tab";

pub fn enabled() -> bool {
    settings::read(|s| s.agents_notify)
}

pub fn set_enabled(v: bool) {
    settings::update(|s| s.agents_notify = v);
}

pub fn notification_id(tab: u64) -> String {
    format!("agent-{tab}")
}

pub fn post(tab: u64, title: &str, body: &str) {
    if !enabled() {
        return;
    }
    let Some(app) = gio::Application::default() else {
        return;
    };
    let n = gio::Notification::new(title);
    if !body.is_empty() {
        n.set_body(Some(body));
    }
    n.set_default_action_and_target_value(&format!("app.{TAB_ACTION}"), Some(&tab.to_variant()));
    app.send_notification(Some(&notification_id(tab)), &n);
}

pub fn withdraw(tab: u64) {
    if let Some(app) = gio::Application::default() {
        app.withdraw_notification(&notification_id(tab));
    }
}

pub fn snippet(text: Option<&str>) -> String {
    let Some(text) = text else {
        return String::new();
    };
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 140 {
        format!("{}…", flat.chars().take(140).collect::<String>())
    } else {
        flat
    }
}

pub fn needs_input_body(tool: &str) -> String {
    match tool {
        "AskUserQuestion" => "Claude has a question for you".into(),
        "ExitPlanMode" => "Claude has a plan ready for review".into(),
        "" => "Claude needs your input".into(),
        t => format!("Claude needs permission: {t}"),
    }
}

thread_local! {
    static BADGE: Cell<Option<usize>> = const { Cell::new(None) };
    static BUS: RefCell<Option<gio::DBusConnection>> = const { RefCell::new(None) };
    static BUS_PENDING: Cell<bool> = const { Cell::new(false) };
}

fn object_path() -> String {
    let id: String = brand::APP_ID.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    format!("/com/canonical/unity/launcherentry/{id}")
}

pub fn badge_payload(count: usize) -> glib::Variant {
    let mut props: HashMap<String, glib::Variant> = HashMap::new();
    props.insert("count".into(), (count as i64).to_variant());
    props.insert("count-visible".into(), (count > 0).to_variant());
    (format!("application://{}.desktop", brand::APP_ID), props).to_variant()
}

fn emit_badge(conn: &gio::DBusConnection, count: usize) {
    let _ = conn.emit_signal(None, &object_path(), "com.canonical.Unity.LauncherEntry", "Update", Some(&badge_payload(count)));
}

pub fn set_badge(count: usize) {
    if BADGE.with(|b| b.replace(Some(count))) == Some(count) {
        return;
    }
    if let Some(conn) = BUS.with(|b| b.borrow().clone()) {
        emit_badge(&conn, count);
        return;
    }
    if BUS_PENDING.with(|p| p.replace(true)) {
        return;
    }
    gio::bus_get(gio::BusType::Session, None::<&gio::Cancellable>, |res| {
        BUS_PENDING.with(|p| p.set(false));
        let Ok(conn) = res else { return };
        BUS.with(|b| *b.borrow_mut() = Some(conn.clone()));
        if let Some(n) = BADGE.with(|b| b.get()) {
            emit_badge(&conn, n);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippets_and_bodies() {
        assert_eq!(snippet(Some("  hello \n  world ")), "hello world");
        let long = "x".repeat(200);
        assert_eq!(snippet(Some(&long)).chars().count(), 141);
        assert_eq!(snippet(None), "");
        assert_eq!(needs_input_body("Bash"), "Claude needs permission: Bash");
        assert_eq!(needs_input_body("AskUserQuestion"), "Claude has a question for you");
    }

    #[test]
    fn badge_payload_shape() {
        let v = badge_payload(3);
        assert_eq!(v.type_().as_str(), "(sa{sv})");
        let (uri, props): (String, HashMap<String, glib::Variant>) = v.get().unwrap();
        assert!(uri.starts_with("application://"));
        assert_eq!(props["count"].get::<i64>(), Some(3));
        assert_eq!(props["count-visible"].get::<bool>(), Some(true));
        assert!(object_path().starts_with("/com/canonical/"));
    }
}
