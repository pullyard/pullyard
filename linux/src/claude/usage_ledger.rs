use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::PathBuf;

use chrono::{Days, NaiveDate};
use serde::{Deserialize, Serialize};

const KEEP: usize = 120;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Day {
    pub cost: f64,
    pub turns: u64,
}

pub struct UsageLedger {
    days: BTreeMap<String, Day>,
    file: Option<PathBuf>,
}

impl UsageLedger {
    pub fn new(file: Option<PathBuf>) -> Self {
        let days: BTreeMap<String, Day> = file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        UsageLedger { days, file }
    }

    pub fn key(date: NaiveDate) -> String {
        date.format("%Y-%m-%d").to_string()
    }

    pub fn is_empty(&self) -> bool {
        self.days.is_empty()
    }

    pub fn record(&mut self, cost: f64, date: NaiveDate) {
        let day = self.days.entry(Self::key(date)).or_default();
        day.cost += cost.max(0.0);
        day.turns += 1;
        while self.days.len() > KEEP {
            self.days.pop_first();
        }
        self.save();
    }

    pub fn total(&self, last_days: u64, today: NaiveDate) -> Day {
        let mut sum = Day::default();
        for offset in 0..last_days.max(1) {
            let Some(date) = today.checked_sub_days(Days::new(offset)) else { continue };
            if let Some(day) = self.days.get(&Self::key(date)) {
                sum.cost += day.cost;
                sum.turns += day.turns;
            }
        }
        sum
    }

    pub fn clear(&mut self) {
        self.days.clear();
        self.save();
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec(&self.days) {
            let tmp = file.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, file);
            }
        }
    }
}

thread_local! {
    static LEDGER: RefCell<Option<UsageLedger>> = const { RefCell::new(None) };
}

fn default_file() -> Option<PathBuf> {
    if cfg!(test) {
        None
    } else {
        Some(crate::settings::data_dir().join("agent-usage.json"))
    }
}

fn with<T>(f: impl FnOnce(&mut UsageLedger) -> T) -> T {
    LEDGER.with(|l| {
        let mut l = l.borrow_mut();
        f(l.get_or_insert_with(|| UsageLedger::new(default_file())))
    })
}

fn today() -> NaiveDate {
    chrono::Local::now().date_naive()
}

pub fn record(cost: f64) {
    with(|l| l.record(cost, today()));
}

pub fn total(last_days: u64) -> Day {
    with(|l| l.total(last_days, today()))
}

pub fn is_empty() -> bool {
    with(|l| l.is_empty())
}

pub fn clear() {
    with(|l| l.clear());
}

pub fn summary(day: Day) -> String {
    if day.turns == 0 {
        "—".to_string()
    } else {
        format!("${:.2} · {} turn{}", day.cost, day.turns, if day.turns == 1 { "" } else { "s" })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("pullyard-{name}-{}.json", uuid::Uuid::new_v4()))
    }

    fn day(offset: u64) -> NaiveDate {
        let now = chrono::DateTime::from_timestamp(1_800_000_000, 0).expect("timestamp").date_naive();
        now.checked_sub_days(Days::new(offset)).expect("date")
    }

    #[test]
    fn records_per_day_and_persists() {
        let file = temp_file("ledger");
        let mut ledger = UsageLedger::new(Some(file.clone()));
        ledger.record(0.5, day(0));
        ledger.record(0.25, day(0));
        ledger.record(1.0, day(3));
        ledger.record(-4.0, day(40));
        assert_eq!(ledger.total(1, day(0)), Day { cost: 0.75, turns: 2 });
        assert_eq!(ledger.total(7, day(0)), Day { cost: 1.75, turns: 3 });
        assert_eq!(ledger.total(30, day(0)).turns, 3);
        assert_eq!(ledger.total(0, day(0)).turns, 2);
        let mut reloaded = UsageLedger::new(Some(file.clone()));
        assert_eq!(reloaded.total(60, day(0)), Day { cost: 1.75, turns: 4 });
        reloaded.clear();
        assert!(UsageLedger::new(Some(file.clone())).is_empty());
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn keeps_a_bounded_number_of_days() {
        let mut ledger = UsageLedger::new(None);
        for offset in 0..(KEEP as u64 + 30) {
            ledger.record(0.01, day(offset));
        }
        assert_eq!(ledger.days.len(), KEEP);
        assert!(ledger.days.contains_key(&UsageLedger::key(day(0))));
        assert!(!ledger.days.contains_key(&UsageLedger::key(day(KEEP as u64))));
    }

    #[test]
    fn ignores_a_corrupt_file() {
        let file = temp_file("ledger-bad");
        std::fs::write(&file, b"not json").expect("write");
        assert!(UsageLedger::new(Some(file.clone())).is_empty());
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn formats_totals() {
        assert_eq!(UsageLedger::key(day(0)), "2027-01-15");
        assert_eq!(summary(Day::default()), "—");
        assert_eq!(summary(Day { cost: 0.5, turns: 1 }), "$0.50 · 1 turn");
        assert_eq!(summary(Day { cost: 12.5, turns: 7 }), "$12.50 · 7 turns");
    }
}
