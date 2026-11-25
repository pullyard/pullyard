use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Utc};

use crate::settings;
use crate::signal::Signal;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Snooze {
    Hour,
    Tomorrow,
    Monday,
}

impl Snooze {
    pub const ALL: [Snooze; 3] = [Snooze::Hour, Snooze::Tomorrow, Snooze::Monday];

    pub fn title(&self) -> &'static str {
        match self {
            Snooze::Hour => "For an hour",
            Snooze::Tomorrow => "Until tomorrow, 9:00",
            Snooze::Monday => "Until Monday, 9:00",
        }
    }

    pub fn until(&self, now: DateTime<Local>) -> DateTime<Local> {
        let nine = |days: i64| {
            let d = (now + Duration::days(days)).date_naive();
            let t = d.and_hms_opt(9, 0, 0).unwrap_or_default();
            Local.from_local_datetime(&t).earliest().unwrap_or(now + Duration::days(days))
        };
        match self {
            Snooze::Hour => now + Duration::hours(1),
            Snooze::Tomorrow => nine(1),
            Snooze::Monday => {
                let ahead = (7 - now.weekday().num_days_from_monday() as i64) % 7;
                nine(if ahead == 0 { 7 } else { ahead })
            }
        }
    }
}

thread_local! {
    static CHANGED: Signal<()> = const { Signal::new() };
}

pub fn on_change(f: impl Fn(&()) -> bool + 'static) {
    CHANGED.with(|s| s.connect(f));
}

fn changed() {
    CHANGED.with(|s| s.emit(&()));
}

pub fn has_news(seen: Option<i64>, updated: DateTime<Utc>) -> bool {
    seen.is_some_and(|s| updated.timestamp() > s)
}

pub fn seen(key: &str) -> Option<i64> {
    settings::read(|s| s.queue_seen.get(key).copied())
}

pub fn mark_seen(key: &str, at: DateTime<Utc>) {
    let ts = at.timestamp();
    if seen(key).is_some_and(|s| s >= ts) {
        return;
    }
    settings::update(|s| {
        s.queue_seen.insert(key.to_string(), ts);
        if s.queue_seen.len() > 600 {
            let mut entries: Vec<(String, i64)> = s.queue_seen.drain().collect();
            entries.sort_by_key(|(_, t)| -t);
            entries.truncate(400);
            s.queue_seen = entries.into_iter().collect();
        }
    });
    changed();
}

pub fn is_snoozed(until: Option<i64>, now: DateTime<Utc>) -> bool {
    until.is_some_and(|u| u > now.timestamp())
}

pub fn snoozed_until(key: &str) -> Option<i64> {
    settings::read(|s| s.queue_snoozed.get(key).copied()).filter(|u| *u > Utc::now().timestamp())
}

pub fn snooze(key: &str, until: DateTime<Local>) {
    let now = Utc::now().timestamp();
    settings::update(|s| {
        s.queue_snoozed.retain(|_, u| *u > now);
        s.queue_snoozed.insert(key.to_string(), until.with_timezone(&Utc).timestamp());
    });
    changed();
}

pub fn wake(key: &str) {
    if settings::read(|s| s.queue_snoozed.contains_key(key)) {
        settings::update(|s| {
            s.queue_snoozed.remove(key);
        });
        changed();
    }
}

pub fn wake_label(until: i64) -> String {
    match Local.timestamp_opt(until, 0).single() {
        Some(t) if t.date_naive() == Local::now().date_naive() => format!("until {}", t.format("%H:%M")),
        Some(t) => format!("until {}", t.format("%a %H:%M")),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(y: i32, m: u32, d: u32, h: u32) -> DateTime<Local> {
        Local.with_ymd_and_hms(y, m, d, h, 30, 0).earliest().unwrap()
    }

    #[test]
    fn snooze_presets() {
        let wed = at(2026, 11, 25, 14);
        assert_eq!(Snooze::Hour.until(wed), wed + Duration::hours(1));
        let t = Snooze::Tomorrow.until(wed);
        assert_eq!((t.day(), t.format("%H:%M").to_string()), (26, "09:00".to_string()));
        let m = Snooze::Monday.until(wed);
        assert_eq!(m.weekday(), chrono::Weekday::Mon);
        assert_eq!(m.day(), 30);
        let mon = at(2026, 11, 30, 8);
        assert_eq!(Snooze::Monday.until(mon).day(), 7);
    }

    #[test]
    fn news_only_after_a_visit() {
        let now = Utc::now();
        assert!(!has_news(None, now));
        assert!(has_news(Some(now.timestamp() - 60), now));
        assert!(!has_news(Some(now.timestamp() + 1), now));
    }

    #[test]
    fn snooze_expires() {
        let now = Utc::now();
        assert!(is_snoozed(Some(now.timestamp() + 30), now));
        assert!(!is_snoozed(Some(now.timestamp() - 30), now));
        assert!(!is_snoozed(None, now));
    }
}
