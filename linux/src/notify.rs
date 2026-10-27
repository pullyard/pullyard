use std::cell::RefCell;

use gtk::gio;
use gtk::glib;
use gtk::prelude::*;

use crate::activity::{self, ActivityEvent, ActivityItem, ActivityTracker, NotifyKind, RecentEvents};
use crate::api::models::SearchItem;
use crate::{app, settings, util};

pub const OPEN_ACTION: &str = "open-activity";
const PREFIX: &str = "activity-";

thread_local! {
    static TRACKER: RefCell<(ActivityTracker, Option<String>)> = RefCell::new((ActivityTracker::default(), None));
    static RECENT: RefCell<Option<RecentEvents>> = const { RefCell::new(None) };
}

pub fn enabled(kind: NotifyKind) -> bool {
    settings::read(|s| match kind {
        NotifyKind::ReviewRequest => s.notify_review_requests,
        NotifyKind::CiFailed => s.notify_ci_failed,
        NotifyKind::ReviewDecision => s.notify_review_decision,
        NotifyKind::AgentInput => s.notify_agent_input.unwrap_or(s.agents_notify),
        NotifyKind::AgentFinished => s.notify_agent_finished.unwrap_or(s.agents_notify),
    })
}

pub fn set_enabled(kind: NotifyKind, on: bool) {
    settings::update(|s| match kind {
        NotifyKind::ReviewRequest => s.notify_review_requests = on,
        NotifyKind::CiFailed => s.notify_ci_failed = on,
        NotifyKind::ReviewDecision => s.notify_review_decision = on,
        NotifyKind::AgentInput => s.notify_agent_input = Some(on),
        NotifyKind::AgentFinished => s.notify_agent_finished = Some(on),
    });
}

pub fn reset() {
    TRACKER.with(|t| *t.borrow_mut() = (ActivityTracker::default(), None));
}

fn activity_item(item: &SearchItem) -> ActivityItem {
    ActivityItem {
        id: item.url.clone(),
        repo: item.repository.name_with_owner.clone(),
        number: item.number,
        title: item.title.clone(),
        updated_at: item.updated_at.timestamp(),
        ci_state: item.ci_state(),
        review_decision: item.review_decision.clone(),
    }
}

fn prs(items: Option<&[SearchItem]>) -> Option<Vec<ActivityItem>> {
    items.map(|list| list.iter().filter(|i| i.is_pr()).map(activity_item).collect())
}

pub fn observe(account: &str, reviews: Option<&[SearchItem]>, review_total: i64, mine: Option<&[SearchItem]>) {
    let reviews = prs(reviews);
    let mine = prs(mine);
    let events = TRACKER.with(|t| {
        let mut t = t.borrow_mut();
        if t.1.as_deref() != Some(account) {
            *t = (ActivityTracker::default(), Some(account.to_string()));
        }
        t.0.update(reviews.as_deref(), review_total, mine.as_deref())
    });
    let mut changed = false;
    for event in events.into_iter().filter(|e| enabled(e.kind())) {
        let fresh = RECENT.with(|r| {
            let mut r = r.borrow_mut();
            let recent = r.get_or_insert_with(|| RecentEvents::new(settings::read(|s| s.notify_recent.clone()), RecentEvents::DEFAULT_LIMIT));
            recent.insert(&event.key())
        });
        if !fresh {
            continue;
        }
        changed = true;
        post(&event, account);
    }
    if changed {
        let keys = RECENT.with(|r| r.borrow().as_ref().map(|r| r.keys().to_vec()).unwrap_or_default());
        settings::update(|s| s.notify_recent = keys);
    }
}

fn post(event: &ActivityEvent, account: &str) {
    let Some(app) = gio::Application::default() else { return };
    let item = event.item();
    let n = gio::Notification::new(&format!("{} · {}{}{}", event.headline(), item.repo, app::number_prefix(), item.number));
    n.set_body(Some(&item.title));
    n.set_default_action_and_target_value(&format!("app.{OPEN_ACTION}"), Some(&activity::target_value(account, &item.id).to_variant()));
    app.send_notification(Some(&format!("{PREFIX}{}", event.key())), &n);
}

pub fn install(app: &adw::Application) {
    let action = gio::SimpleAction::new(OPEN_ACTION, Some(glib::VariantTy::STRING));
    action.connect_activate(|_, v| {
        let Some((account, url)) = v.and_then(|v| v.get::<String>()).and_then(|s| activity::parse_target(&s)) else { return };
        open(&account, &url);
    });
    app.add_action(&action);
}

fn open(account: &str, url: &str) {
    let Some(a) = app::try_get() else { return };
    a.present();
    if a.state.borrow().phase != app::Phase::LoggedIn {
        return;
    }
    if !account.is_empty() && account != app::cache_account() {
        util::open_url(url);
        return;
    }
    let known = {
        let s = a.state.borrow();
        s.review_requests.iter().chain(s.my_prs.iter()).find(|i| i.url == url).map(|i| i.route())
    };
    if let Some(route) = known {
        app::open(route, false);
    } else if let Some(route) = util::parse_github_url(url, false).filter(|_| a.state.borrow().forge.is_none()) {
        app::open(route, false);
    } else {
        util::open_url(url);
    }
}
