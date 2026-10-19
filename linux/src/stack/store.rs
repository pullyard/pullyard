use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::time::Duration;

use chrono::{DateTime, Utc};

use super::StackNode;
use crate::api::models::RepoRef;
use crate::api::GitHubApi;

pub const TTL: Duration = Duration::from_secs(120);
const MEMORY_LIMIT: usize = 24;

type Waiter = async_channel::Sender<Option<Vec<StackNode>>>;

thread_local! {
    static MEMORY: RefCell<HashMap<String, (Vec<StackNode>, DateTime<Utc>)>> = RefCell::new(HashMap::new());
    static FETCHES: RefCell<HashMap<String, Vec<Waiter>>> = RefCell::new(HashMap::new());
    static GENERATION: Cell<u64> = const { Cell::new(0) };
}

fn account() -> String {
    crate::app::cache_account()
}

fn key(api: &GitHubApi, repo: &RepoRef) -> String {
    format!("{}|{}|{}", account(), api.host(), repo.full().to_lowercase())
}

fn disk_key(api: &GitHubApi, repo: &RepoRef) -> String {
    format!("stack|{}|{}", api.host(), repo.full())
}

fn fresh(at: DateTime<Utc>) -> bool {
    Utc::now().signed_duration_since(at).to_std().is_ok_and(|age| age < TTL)
}

fn remember(k: String, nodes: Vec<StackNode>, at: DateTime<Utc>) {
    MEMORY.with(|m| {
        let mut m = m.borrow_mut();
        if m.len() >= MEMORY_LIMIT && !m.contains_key(&k) {
            if let Some(oldest) = m.iter().min_by_key(|(_, v)| v.1).map(|(k, _)| k.clone()) {
                m.remove(&oldest);
            }
        }
        m.insert(k, (nodes, at));
    });
}

pub fn memory_nodes(api: &GitHubApi, repo: &RepoRef) -> Option<Vec<StackNode>> {
    let k = key(api, repo);
    MEMORY.with(|m| m.borrow().get(&k).map(|v| v.0.clone()))
}

pub async fn cached(api: &GitHubApi, repo: &RepoRef) -> Option<(Vec<StackNode>, bool)> {
    let k = key(api, repo);
    if let Some((nodes, at)) = MEMORY.with(|m| m.borrow().get(&k).cloned()) {
        return Some((nodes, fresh(at)));
    }
    let gen = GENERATION.with(|g| g.get());
    let (nodes, saved) = crate::list_cache::load_value::<Vec<StackNode>>(&account(), &disk_key(api, repo)).await?;
    if gen != GENERATION.with(|g| g.get()) {
        return None;
    }
    if MEMORY.with(|m| !m.borrow().contains_key(&k)) {
        remember(k, nodes.clone(), saved);
    }
    Some((nodes, fresh(saved)))
}

pub async fn nodes(api: &GitHubApi, repo: &RepoRef, force: bool) -> Option<Vec<StackNode>> {
    if !force {
        if let Some((nodes, true)) = cached(api, repo).await {
            return Some(nodes);
        }
    }
    fetch(api, repo).await
}

pub async fn fetch(api: &GitHubApi, repo: &RepoRef) -> Option<Vec<StackNode>> {
    let k = key(api, repo);
    let running = FETCHES.with(|f| {
        let mut f = f.borrow_mut();
        match f.get_mut(&k) {
            Some(waiters) => {
                let (tx, rx) = async_channel::bounded(1);
                waiters.push(tx);
                Some(rx)
            }
            None => {
                f.insert(k.clone(), vec![]);
                None
            }
        }
    });
    if let Some(rx) = running {
        return rx.recv().await.ok().flatten();
    }
    let gen = GENERATION.with(|g| g.get());
    let (a, r) = (api.clone(), repo.clone());
    let result = crate::rt::run(async move { a.open_stack_nodes(&r, 3).await }).await.ok();
    if gen != GENERATION.with(|g| g.get()) {
        return None;
    }
    let waiters = FETCHES.with(|f| f.borrow_mut().remove(&k)).unwrap_or_default();
    if let Some(nodes) = &result {
        let changed = MEMORY.with(|m| m.borrow().get(&k).is_none_or(|v| v.0 != *nodes));
        if changed {
            crate::list_cache::store_value(&account(), &disk_key(api, repo), nodes.clone());
        }
        remember(k, nodes.clone(), Utc::now());
    }
    for w in waiters {
        let _ = w.try_send(result.clone());
    }
    result
}

pub fn seed(api: &GitHubApi, repo: &RepoRef, nodes: Vec<StackNode>) {
    remember(key(api, repo), nodes, Utc::now());
}

pub fn invalidate(api: &GitHubApi, repo: &RepoRef) {
    let k = key(api, repo);
    MEMORY.with(|m| m.borrow_mut().remove(&k));
}

pub fn reset() {
    GENERATION.with(|g| g.set(g.get() + 1));
    MEMORY.with(|m| m.borrow_mut().clear());
    FETCHES.with(|f| f.borrow_mut().clear());
}
