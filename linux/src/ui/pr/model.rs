use std::cell::{Cell, Ref, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::json;

use crate::api::code_owners::{CodeOwnersStatus, OwnershipSummary};
use crate::api::interdiff::{self, DiffScope, ReviewedCommit};
use crate::api::merge_readiness::{self, MergeRequirement, RequirementState, RulesStatus};
use crate::api::models::*;
use crate::api::queries as q;
use crate::api::{ApiError, ErrorKind, GitHubApi};
use crate::conversation_html::{self, Look};
use crate::diff::{DiffAnchor, DiffFile};
use crate::signal::Signal;
use crate::stack::{self, context, StackNode, StackTree};

const FULL_REFRESH_EVERY: Duration = Duration::from_secs(300);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrTab {
    Conversation,
    Commits,
    Checks,
    Files,
    Stack,
    Jira,
}

impl PrTab {
    pub fn id(&self) -> &'static str {
        match self {
            PrTab::Conversation => "conversation",
            PrTab::Commits => "commits",
            PrTab::Checks => "checks",
            PrTab::Files => "files",
            PrTab::Stack => "stack",
            PrTab::Jira => "jira",
        }
    }

    pub fn from_id(id: &str) -> Self {
        match id {
            "commits" => PrTab::Commits,
            "checks" => PrTab::Checks,
            "files" => PrTab::Files,
            "stack" => PrTab::Stack,
            "jira" => PrTab::Jira,
            _ => PrTab::Conversation,
        }
    }
}

#[derive(Clone, Debug)]
pub enum Change {
    Pr,
    Files,
    Busy,
    Stack,
    Tab,
    Diff,
    ScrollBottom,
    Rules,
    Reveal(String),
    ActionError(String),
}

#[derive(Clone)]
pub enum FlatRow {
    Header(usize),
    Line(usize, usize),
    Thread(Box<ReviewThread>),
    Pending(PendingComment),
    Composer(DiffAnchor),
    Note(String),
}

#[derive(Clone)]
pub struct ReviewerInfo {
    pub login: String,
    pub avatar: Option<String>,
    pub state: String,
    pub is_team: bool,
    pub code_owner: bool,
}

pub struct PrModel {
    pub r: ItemRef,
    pub api: GitHubApi,
    pub repo: RefCell<Option<PrRepository>>,
    pub pr: RefCell<Option<PullRequestDetail>>,
    pub viewer_login: RefCell<String>,
    pub not_pr: Cell<bool>,
    pub loading: Cell<bool>,
    pub last_updated: Cell<Option<DateTime<Utc>>>,
    pub refresh_error: RefCell<Option<String>>,
    pub error: RefCell<Option<String>>,
    pub busy: Cell<bool>,
    pub tab: Cell<PrTab>,
    pub stack: RefCell<Option<StackTree>>,
    pub preview: RefCell<Option<StackNode>>,
    pub html: RefCell<String>,
    pub files: RefCell<Vec<DiffFile>>,
    pub files_loaded: Cell<bool>,
    pub files_loading: Cell<bool>,
    pub files_error: RefCell<Option<String>>,
    pub diff_scope: Cell<DiffScope>,
    pub interdiff_files: RefCell<Vec<DiffFile>>,
    pub interdiff_loading: Cell<bool>,
    pub interdiff_error: RefCell<Option<String>>,
    pub interdiff_rebased: Cell<bool>,
    interdiff_key: RefCell<Option<String>>,
    pub viewed: RefCell<HashSet<String>>,
    pub collapsed: RefCell<HashSet<String>>,
    pub pending: RefCell<Vec<PendingComment>>,
    pub composer: RefCell<Option<DiffAnchor>>,
    pub composer_text: RefCell<String>,
    thread_index: RefCell<HashMap<String, Vec<ReviewThread>>>,
    outdated_by_path: RefCell<HashMap<String, Vec<ReviewThread>>>,
    active: Cell<bool>,
    queued: Cell<bool>,
    full_reason: Cell<Option<&'static str>>,
    last_full: Cell<Option<Instant>>,
    stack_fresh: Cell<bool>,
    stack_key: RefCell<Option<String>>,
    reload_files: Cell<bool>,
    files_stale: Cell<bool>,
    pub files_oid: RefCell<Option<String>>,
    merge_rechecks: Cell<u32>,
    recheck_pending: Cell<bool>,
    pub rules_state: RefCell<RulesStatus>,
    rules_key: RefCell<Option<String>>,
    rules_fetched: Cell<Option<Instant>>,
    pub code_owners: RefCell<CodeOwnersStatus>,
    owners_key: RefCell<Option<String>>,
    pub changed_paths: RefCell<Vec<String>>,
    viewed_gen: Cell<u64>,
    pub changed: Signal<Change>,
}

impl PrModel {
    pub fn new(r: ItemRef, api: GitHubApi) -> Rc<Self> {
        Rc::new(PrModel {
            r,
            api,
            repo: RefCell::new(None),
            pr: RefCell::new(None),
            viewer_login: RefCell::new(String::new()),
            not_pr: Cell::new(false),
            loading: Cell::new(false),
            last_updated: Cell::new(None),
            refresh_error: RefCell::new(None),
            error: RefCell::new(None),
            busy: Cell::new(false),
            tab: Cell::new(PrTab::Conversation),
            stack: RefCell::new(None),
            preview: RefCell::new(None),
            html: RefCell::new(String::new()),
            files: RefCell::new(vec![]),
            files_loaded: Cell::new(false),
            files_loading: Cell::new(false),
            files_error: RefCell::new(None),
            diff_scope: Cell::new(DiffScope::All),
            interdiff_files: RefCell::new(vec![]),
            interdiff_loading: Cell::new(false),
            interdiff_error: RefCell::new(None),
            interdiff_rebased: Cell::new(false),
            interdiff_key: RefCell::new(None),
            viewed: RefCell::new(HashSet::new()),
            collapsed: RefCell::new(HashSet::new()),
            pending: RefCell::new(vec![]),
            composer: RefCell::new(None),
            composer_text: RefCell::new(String::new()),
            thread_index: RefCell::new(HashMap::new()),
            outdated_by_path: RefCell::new(HashMap::new()),
            active: Cell::new(false),
            queued: Cell::new(false),
            full_reason: Cell::new(None),
            last_full: Cell::new(None),
            stack_fresh: Cell::new(false),
            stack_key: RefCell::new(None),
            reload_files: Cell::new(false),
            files_stale: Cell::new(false),
            files_oid: RefCell::new(None),
            merge_rechecks: Cell::new(0),
            recheck_pending: Cell::new(false),
            rules_state: RefCell::new(RulesStatus::Loading),
            rules_key: RefCell::new(None),
            rules_fetched: Cell::new(None),
            code_owners: RefCell::new(CodeOwnersStatus::Loading),
            owners_key: RefCell::new(None),
            changed_paths: RefCell::new(vec![]),
            viewed_gen: Cell::new(0),
            changed: Signal::new(),
        })
    }

    pub fn inject(self: &Rc<Self>, resp: PrDetailResponse, files: Vec<PrFile>) {
        *self.viewer_login.borrow_mut() = resp.viewer.login.clone();
        let Some(mut repo) = resp.repository else { return };
        let Some(pr) = repo.pull_request.take() else { return };
        *self.html.borrow_mut() = conversation_html::render_pr(&pr, Look::current());
        *self.viewed.borrow_mut() = pr.files.as_ref().map(|f| f.viewed_paths()).unwrap_or_default();
        *self.changed_paths.borrow_mut() = changed_paths(&pr);
        self.index_threads(&pr.review_threads.nodes);
        *self.files_oid.borrow_mut() = Some(pr.head_ref_oid.clone());
        *self.repo.borrow_mut() = Some(repo);
        *self.pr.borrow_mut() = Some(pr);
        self.last_updated.set(Some(Utc::now()));
        *self.files.borrow_mut() = files.iter().map(DiffFile::new).collect();
        self.files_loaded.set(true);
        self.emit(Change::Pr);
        self.emit(Change::Files);
    }

    pub fn emit(&self, c: Change) {
        self.changed.emit(&c);
    }

    pub fn set_tab(&self, t: PrTab) {
        if self.tab.get() != t {
            self.tab.set(t);
            self.emit(Change::Tab);
        }
    }

    pub fn can_write(&self) -> bool {
        self.repo.borrow().as_ref().map(|r| r.can_write()).unwrap_or(false)
    }

    pub fn reviewers(&self) -> Vec<ReviewerInfo> {
        let pr = self.pr.borrow();
        let Some(pr) = pr.as_ref() else { return vec![] };
        let mut result: Vec<ReviewerInfo> = pr
            .latest_opinionated_reviews
            .nodes
            .iter()
            .filter_map(|r| r.author.as_ref().map(|a| ReviewerInfo { login: a.login.clone(), avatar: a.avatar_url.clone(), state: r.state.clone(), is_team: false, code_owner: false }))
            .collect();
        let done: HashSet<String> = result.iter().map(|r| r.login.clone()).collect();
        for req in &pr.review_requests.nodes {
            if let Some(r) = &req.requested_reviewer {
                if !done.contains(&r.display()) {
                    result.push(ReviewerInfo { login: r.display(), avatar: r.avatar_url.clone(), state: "PENDING".into(), is_team: r.is_team(), code_owner: req.as_code_owner == Some(true) });
                }
            }
        }
        result
    }

    pub fn requirements(&self) -> Vec<MergeRequirement> {
        let pr = self.pr.borrow();
        match pr.as_ref() {
            Some(pr) => merge_readiness::requirements(pr, &self.rules_state.borrow()),
            None => vec![],
        }
    }

    pub fn ownership(&self) -> Option<OwnershipSummary> {
        let pr = self.pr.borrow();
        let owners = self.code_owners.borrow();
        match (pr.as_ref(), &*owners) {
            (Some(pr), CodeOwnersStatus::Loaded(o)) => Some(OwnershipSummary::build(o, &self.changed_paths.borrow(), pr)),
            _ => None,
        }
    }

    pub fn publish_context(&self) {
        let snapshot = {
            let pr = self.pr.borrow();
            let Some(pr) = pr.as_ref() else { return };
            context_snapshot(&self.r, pr, &self.requirements(), self.ownership().as_ref(), &self.changed_paths.borrow(), self.last_reviewed().as_ref())
        };
        let key = self.stack_note_key(self.r.number);
        let dir = context::default_dir();
        crate::rt::runtime().spawn_blocking(move || {
            let _ = context::write(&snapshot, &key, &dir);
        });
    }

    fn load_more_viewed(self: &Rc<Self>, cursor: Option<String>) {
        let generation = self.viewed_gen.get() + 1;
        self.viewed_gen.set(generation);
        let Some(mut cursor) = cursor else { return };
        let me = self.clone();
        crate::rt::spawn_local(async move {
            for _ in 0..30 {
                let api = me.api.clone();
                let r = me.r.clone();
                let after = cursor.clone();
                let res = crate::rt::run(async move { api.pull_request_files_page(&r, &after).await }).await;
                if me.viewed_gen.get() != generation {
                    return;
                }
                let Ok(Some(page)) = res else { return };
                me.viewed.borrow_mut().extend(page.viewed_paths());
                me.changed_paths.borrow_mut().extend(page.nodes.iter().map(|n| n.path.clone()));
                match page.next_cursor() {
                    Some(next) => cursor = next,
                    None => break,
                }
            }
            me.emit(Change::Diff);
            if matches!(*me.code_owners.borrow(), CodeOwnersStatus::Loaded(_)) {
                me.emit(Change::Rules);
            }
            me.publish_context();
        });
    }

    fn load_code_owners(self: &Rc<Self>, base_oid: Option<String>) {
        let Some(base) = base_oid else { return };
        let key = format!("{}|{base}", self.r.repo.full());
        if self.owners_key.borrow().as_deref() == Some(key.as_str()) {
            return;
        }
        *self.owners_key.borrow_mut() = Some(key.clone());
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let api = me.api.clone();
            let repo = me.r.repo.clone();
            let res = crate::rt::run(async move { api.code_owners(&repo, &base).await }).await;
            if me.owners_key.borrow().as_deref() != Some(key.as_str()) {
                return;
            }
            let loaded = res.is_ok();
            match res {
                Ok(Some(owners)) => *me.code_owners.borrow_mut() = CodeOwnersStatus::Loaded(owners),
                Ok(None) => *me.code_owners.borrow_mut() = CodeOwnersStatus::Missing,
                Err(_) => {
                    *me.owners_key.borrow_mut() = None;
                    *me.code_owners.borrow_mut() = CodeOwnersStatus::Failed;
                }
            }
            me.emit(Change::Rules);
            if loaded {
                me.publish_context();
            }
        });
    }

    fn load_rules(self: &Rc<Self>, base: String, force: bool) {
        let key = format!("{}|{base}", self.r.repo.full());
        let fresh = self.rules_fetched.get().map(|t| t.elapsed() < Duration::from_secs(300)).unwrap_or(false);
        let same = self.rules_key.borrow().as_deref() == Some(key.as_str());
        if !force && same && (fresh || *self.rules_state.borrow() == RulesStatus::Loading) {
            return;
        }
        if !same {
            *self.rules_state.borrow_mut() = RulesStatus::Loading;
        }
        *self.rules_key.borrow_mut() = Some(key.clone());
        self.rules_fetched.set(Some(Instant::now()));
        let admin = self.repo.borrow().as_ref().and_then(|r| r.viewer_permission.clone()).as_deref() == Some("ADMIN");
        let me = self.clone();
        crate::rt::spawn_local(async move {
            let api = me.api.clone();
            let repo = me.r.repo.clone();
            let res = crate::rt::run(async move { api.branch_rules(&repo, &base, admin).await }).await;
            if me.rules_key.borrow().as_deref() != Some(key.as_str()) {
                return;
            }
            let loaded = res.is_ok();
            match res {
                Ok(rules) => *me.rules_state.borrow_mut() = RulesStatus::Loaded(rules),
                Err(_) => {
                    me.rules_fetched.set(None);
                    if me.rules_state.borrow().rules().is_none() {
                        *me.rules_state.borrow_mut() = RulesStatus::Failed;
                    }
                }
            }
            me.emit(Change::Rules);
            if loaded {
                me.publish_context();
            }
        });
    }

    pub fn stale_reviews(&self) -> Vec<(String, Option<usize>)> {
        let pr = self.pr.borrow();
        let Some(pr) = pr.as_ref() else { return vec![] };
        if !pr.is_open() {
            return vec![];
        }
        let viewer = self.viewer_login.borrow().clone();
        let pending: HashSet<String> = pr.review_requests.nodes.iter().filter_map(|r| r.requested_reviewer.as_ref().map(|x| x.display())).collect();
        let oids: Vec<&str> = pr.all_commits.nodes.iter().map(|c| c.commit.oid.as_str()).collect();
        pr.latest_opinionated_reviews
            .nodes
            .iter()
            .filter_map(|r| {
                let login = r.author.as_ref()?.login.clone();
                if login == viewer || login.ends_with("[bot]") || pending.contains(&login) {
                    return None;
                }
                let oid = r.commit.as_ref()?.oid.clone();
                if oid == pr.head_ref_oid {
                    return None;
                }
                let after = oids.iter().rposition(|o| *o == oid).map(|i| oids.len() - 1 - i).filter(|n| *n > 0);
                Some((login, after))
            })
            .collect()
    }

    pub fn reviewers_to_rerequest(&self) -> Vec<String> {
        self.stale_reviews().into_iter().map(|s| s.0).collect()
    }

    pub fn thread_count(&self, path: &str) -> usize {
        self.pr.borrow().as_ref().map(|p| p.review_threads.nodes.iter().filter(|t| t.path == path).count()).unwrap_or(0)
    }

    pub fn load(self: &Rc<Self>, full: bool) {
        if full {
            self.stack_fresh.set(true);
            self.reload_files.set(true);
        }
        self.force_full(if full { "refresh" } else { "load" });
    }

    pub fn open(self: &Rc<Self>) {
        if self.pr.borrow().is_some() {
            self.refresh_live();
        } else {
            self.load(false);
        }
    }

    pub fn refresh_live(self: &Rc<Self>) {
        self.start();
    }

    fn force_full(self: &Rc<Self>, reason: &'static str) {
        self.full_reason.set(Some(reason));
        self.start();
    }

    fn fetch_reason(&self, forced: Option<&'static str>) -> Option<&'static str> {
        if self.pr.borrow().is_none() {
            return Some("first");
        }
        if forced.is_some() {
            return forced;
        }
        if !self.last_full.get().is_some_and(|t| t.elapsed() < FULL_REFRESH_EVERY) {
            return Some("stale");
        }
        if !self.pr.borrow().as_ref().is_some_and(|p| p.light.is_known()) {
            return Some("no baseline");
        }
        None
    }

    fn start(self: &Rc<Self>) {
        if self.active.get() {
            self.queued.set(true);
            return;
        }
        let me = self.clone();
        crate::rt::spawn_local(async move {
            loop {
                me.active.set(true);
                me.queued.set(false);
                let reason = me.fetch_reason(me.full_reason.take());
                match reason {
                    Some(reason) => me.clone().fetch(reason).await,
                    None => me.clone().check().await,
                }
                me.active.set(false);
                if !me.queued.get() || (reason.is_some() && me.full_reason.get().is_none()) {
                    me.queued.set(false);
                    break;
                }
            }
        });
    }

    async fn check(self: Rc<Self>) {
        self.loading.set(true);
        self.emit(Change::Busy);
        let api = self.api.clone();
        let r = self.r.clone();
        let res = crate::rt::run(async move { api.pull_request_light(&r).await }).await;
        self.loading.set(false);
        let current = self.pr.borrow().as_ref().map(|p| p.light.clone().normalized());
        match res {
            Ok(Some(light)) if current.as_ref() == Some(&light.clone().normalized()) => {
                *self.refresh_error.borrow_mut() = None;
                self.last_updated.set(Some(Utc::now()));
                self.emit(Change::Busy);
                self.schedule_merge_recheck(light.merge_unknown());
            }
            Ok(_) => self.fetch("changed").await,
            Err(e) if !e.is_transient() && e.kind != ErrorKind::RateLimited => self.fetch("pulse error").await,
            Err(e) => {
                *self.refresh_error.borrow_mut() = Some(e.message);
                self.emit(Change::Busy);
            }
        }
    }

    async fn fetch(self: Rc<Self>, reason: &'static str) {
        self.loading.set(true);
        self.emit(Change::Busy);
        let api = self.api.clone();
        let r = self.r.clone();
        let note = format!("full: {reason}");
        let res = crate::rt::run(crate::diagnostics::with_note(note, async move { api.pull_request(&r).await })).await;
        self.loading.set(false);
        match res {
            Ok(resp) => {
                *self.viewer_login.borrow_mut() = resp.viewer.login.clone();
                let Some(mut repo) = resp.repository else {
                    self.not_pr.set(true);
                    self.emit(Change::Pr);
                    return;
                };
                let Some(pr) = repo.pull_request.take() else {
                    self.not_pr.set(true);
                    self.emit(Change::Pr);
                    return;
                };
                let html = conversation_html::render_pr(&pr, Look::current());
                *self.html.borrow_mut() = html;
                *self.viewed.borrow_mut() = pr.files.as_ref().map(|f| f.viewed_paths()).unwrap_or_default();
                let viewed_cursor = pr.files.as_ref().and_then(|f| f.next_cursor());
                *self.changed_paths.borrow_mut() = changed_paths(&pr);
                let base = pr.base_ref_name.clone();
                let base_oid = pr.base_tip_oid().map(str::to_string);
                self.index_threads(&pr.review_threads.nodes);
                let head = pr.head_ref_oid.clone();
                let stack_key = stack_cache_key(&pr);
                let recheck = pr.is_open() && (pr.merge_state_status.as_deref() == Some("UNKNOWN") || pr.mergeable == "UNKNOWN");
                let files_stale = self.reload_files.replace(false) || self.files_oid.borrow().as_deref() != Some(head.as_str());
                if files_stale && self.files_loaded.get() {
                    self.files_stale.set(true);
                }
                *self.repo.borrow_mut() = Some(repo);
                *self.pr.borrow_mut() = Some(pr);
                if self.diff_scope.get() == DiffScope::SinceReview {
                    if self.last_reviewed().is_none() {
                        self.set_diff_scope(DiffScope::All);
                    } else {
                        let me = self.clone();
                        crate::rt::spawn_local(async move { me.load_interdiff(false).await });
                    }
                }
                *self.error.borrow_mut() = None;
                *self.refresh_error.borrow_mut() = None;
                self.last_updated.set(Some(Utc::now()));
                self.last_full.set(Some(Instant::now()));
                *self.preview.borrow_mut() = None;
                self.load_more_viewed(viewed_cursor);
                self.load_rules(base, reason == "refresh");
                self.load_code_owners(base_oid);
                self.emit(Change::Pr);
                self.publish_context();
                if self.stack_fresh.get() || self.stack_key.borrow().as_deref() != Some(stack_key.as_str()) {
                    let force = self.stack_fresh.replace(false);
                    let me = self.clone();
                    crate::rt::spawn_local(async move { me.load_stack(force).await });
                }
                self.schedule_merge_recheck(recheck);
            }
            Err(e) => {
                if self.pr.borrow().is_none() {
                    *self.error.borrow_mut() = Some(e.message);
                } else {
                    *self.refresh_error.borrow_mut() = Some(e.message);
                }
                self.emit(Change::Pr);
            }
        }
    }

    pub fn rerender_html(&self) {
        if let Some(pr) = self.pr.borrow().as_ref() {
            *self.html.borrow_mut() = conversation_html::render_pr(pr, Look::current());
        }
        self.emit(Change::Pr);
    }

    fn schedule_merge_recheck(self: &Rc<Self>, unknown: bool) {
        if !unknown {
            self.merge_rechecks.set(0);
            return;
        }
        if self.merge_rechecks.get() >= 5 || self.recheck_pending.get() {
            return;
        }
        self.merge_rechecks.set(self.merge_rechecks.get() + 1);
        self.recheck_pending.set(true);
        let delay = self.merge_rechecks.get() as u64 * 2;
        let weak = Rc::downgrade(self);
        gtk::glib::timeout_add_local_once(Duration::from_secs(delay), move || {
            if let Some(me) = weak.upgrade() {
                me.recheck_pending.set(false);
                me.refresh_live();
            }
        });
    }

    pub async fn load_stack(self: Rc<Self>, force: bool) {
        let Some(key) = self.pr.borrow().as_ref().map(stack_cache_key) else { return };
        *self.stack_key.borrow_mut() = Some(key);
        if let Some((nodes, fresh)) = stack::store::cached(&self.api, &self.r.repo).await {
            self.apply_stack(&nodes);
            if !force && fresh {
                return;
            }
        }
        if let Some(nodes) = stack::store::fetch(&self.api, &self.r.repo).await {
            self.apply_stack(&nodes);
        }
    }

    pub fn current_stack_node(&self) -> Option<StackNode> {
        let pr = self.pr.borrow();
        let pr = pr.as_ref()?;
        Some(StackNode {
            number: pr.number,
            title: pr.title.clone(),
            state: pr.state.clone(),
            is_draft: pr.is_draft,
            head_ref_name: pr.head_ref_name.clone(),
            base_ref_name: pr.base_ref_name.clone(),
            head_repo: pr.head_repository.as_ref().map(|h| h.name_with_owner.clone()),
            author: pr.author.as_ref().map(|a| a.login.clone()),
            updated_at: None,
            review_decision: None,
            ci: None,
            commit_oid: None,
            commit_headline: None,
        })
    }

    pub fn apply_stack(&self, nodes: &[StackNode]) {
        let Some(current) = self.current_stack_node() else { return };
        let tree = StackTree::build(&current, nodes, &self.r.repo.full(), stack::NODE_LIMIT);
        let none = tree.is_none();
        if *self.stack.borrow() != tree {
            *self.stack.borrow_mut() = tree;
            self.emit(Change::Stack);
        }
        if none && self.tab.get() == PrTab::Stack {
            self.set_tab(PrTab::Conversation);
        }
    }

    pub fn seed_stack(&self, node: &StackNode, nodes: &[StackNode]) {
        if self.pr.borrow().is_some() {
            self.tab.set(PrTab::Stack);
            return;
        }
        *self.preview.borrow_mut() = Some(node.clone());
        *self.stack.borrow_mut() = StackTree::build(node, nodes, &self.r.repo.full(), stack::NODE_LIMIT);
        self.tab.set(PrTab::Stack);
    }

    pub fn stack_note_key(&self, number: i64) -> String {
        stack::notes::key(&crate::app::cache_account(), self.api.host(), &self.r.repo, number)
    }

    pub fn ensure_files(self: &Rc<Self>) {
        if self.pr.borrow().is_none() || self.files_loading.get() || (self.files_loaded.get() && !self.files_stale.get()) {
            return;
        }
        let me = self.clone();
        crate::rt::spawn_local(async move { me.load_files(true).await });
    }

    pub fn refresh_stale_files(self: &Rc<Self>) {
        if self.files_loaded.get() && self.files_stale.get() {
            self.ensure_files();
        }
    }

    pub async fn load_files(self: Rc<Self>, force: bool) {
        if !force && (self.files_loaded.get() || self.files_loading.get()) {
            return;
        }
        self.files_loading.set(true);
        self.files_stale.set(false);
        let oid = self.pr.borrow().as_ref().map(|p| p.head_ref_oid.clone());
        let api = self.api.clone();
        let r = self.r.clone();
        let res = crate::rt::run(async move { api.pull_request_files(&r).await.map(|raw| raw.iter().map(DiffFile::new).collect::<Vec<_>>()) }).await;
        self.files_loading.set(false);
        match res {
            Ok(parsed) => {
                if !self.files_loaded.get() {
                    let viewed = self.viewed.borrow().clone();
                    *self.collapsed.borrow_mut() = parsed.iter().filter(|f| viewed.contains(&f.id) || f.lines.len() > 1500).map(|f| f.id.clone()).collect();
                }
                let head = self.pr.borrow().as_ref().map(|p| p.head_ref_oid.clone());
                if head.is_some() && head != oid {
                    self.files_stale.set(true);
                }
                *self.files.borrow_mut() = parsed;
                *self.files_oid.borrow_mut() = oid;
                self.files_loaded.set(true);
                *self.files_error.borrow_mut() = None;
            }
            Err(e) => *self.files_error.borrow_mut() = Some(e.message),
        }
        self.emit(Change::Files);
    }

    pub fn last_reviewed(&self) -> Option<ReviewedCommit> {
        let pr = self.pr.borrow();
        interdiff::last_reviewed(pr.as_ref()?, &self.viewer_login.borrow())
    }

    pub fn displayed_files(&self) -> Ref<'_, Vec<DiffFile>> {
        match self.diff_scope.get() {
            DiffScope::SinceReview => self.interdiff_files.borrow(),
            DiffScope::All => self.files.borrow(),
        }
    }

    pub fn set_diff_scope(self: &Rc<Self>, scope: DiffScope) {
        if self.diff_scope.replace(scope) == scope {
            return;
        }
        self.emit(Change::Files);
        if scope == DiffScope::SinceReview {
            let me = self.clone();
            crate::rt::spawn_local(async move { me.load_interdiff(false).await });
        }
    }

    pub async fn load_interdiff(self: Rc<Self>, force: bool) {
        let head = self.pr.borrow().as_ref().map(|p| p.head_ref_oid.clone());
        let (Some(head), Some(reviewed)) = (head, self.last_reviewed()) else {
            self.set_diff_scope(DiffScope::All);
            return;
        };
        let key = format!("{}...{head}", reviewed.oid);
        if (!force && self.interdiff_key.borrow().as_deref() == Some(key.as_str())) || self.interdiff_loading.get() {
            return;
        }
        self.interdiff_loading.set(true);
        self.emit(Change::Files);
        let api = self.api.clone();
        let repo = self.r.repo.clone();
        let base = reviewed.oid.clone();
        let res = crate::rt::run(async move {
            api.compare(&repo, &base, &head).await.map(|c| {
                let behind = c.behind_by.unwrap_or(0);
                (c.files.unwrap_or_default().iter().map(DiffFile::new).collect::<Vec<_>>(), behind)
            })
        })
        .await;
        self.interdiff_loading.set(false);
        match res {
            Ok((parsed, behind)) => {
                {
                    let mut collapsed = self.collapsed.borrow_mut();
                    for f in &parsed {
                        collapsed.remove(&f.id);
                    }
                }
                *self.interdiff_files.borrow_mut() = parsed;
                *self.interdiff_key.borrow_mut() = Some(key);
                *self.interdiff_error.borrow_mut() = None;
                self.interdiff_rebased.set(reviewed.rewritten() || behind > 0);
            }
            Err(e) => *self.interdiff_error.borrow_mut() = Some(e.message),
        }
        self.emit(Change::Files);
    }

    fn index_threads(&self, threads: &[ReviewThread]) {
        let mut idx: HashMap<String, Vec<ReviewThread>> = HashMap::new();
        let mut outdated: HashMap<String, Vec<ReviewThread>> = HashMap::new();
        for t in threads {
            match t.line {
                Some(line) => idx.entry(format!("{}|{}|{line}", t.path, t.diff_side)).or_default().push(t.clone()),
                None => outdated.entry(t.path.clone()).or_default().push(t.clone()),
            }
        }
        *self.thread_index.borrow_mut() = idx;
        *self.outdated_by_path.borrow_mut() = outdated;
    }

    pub fn flat_rows(&self, filter: &str) -> Vec<FlatRow> {
        let files = self.displayed_files();
        let since_review = self.diff_scope.get() == DiffScope::SinceReview;
        let collapsed = self.collapsed.borrow();
        let pending = self.pending.borrow();
        let composer = self.composer.borrow().clone();
        let index = self.thread_index.borrow();
        let outdated = self.outdated_by_path.borrow();
        let mut out = vec![];
        for (fi, file) in files.iter().enumerate() {
            if !filter.is_empty() && !crate::util::contains_ci(&file.id, filter) {
                continue;
            }
            out.push(FlatRow::Header(fi));
            if collapsed.contains(&file.id) {
                continue;
            }
            if !file.has_patch {
                out.push(FlatRow::Note("Diff unavailable (binary or too large)".into()));
                continue;
            }
            if since_review {
                out.extend((0..file.lines.len()).map(|li| FlatRow::Line(fi, li)));
                continue;
            }
            let file_pending: Vec<&PendingComment> = pending.iter().filter(|p| p.path == file.id).collect();
            for (li, line) in file.lines.iter().enumerate() {
                out.push(FlatRow::Line(fi, li));
                if !line.commentable() {
                    continue;
                }
                let mut keys = vec![];
                if let (Some(n), true) = (line.new_line, line.kind != crate::diff::LineKind::Del) {
                    keys.push(format!("{}|RIGHT|{n}", file.id));
                }
                if let (Some(o), true) = (line.old_line, line.kind != crate::diff::LineKind::Add) {
                    keys.push(format!("{}|LEFT|{o}", file.id));
                }
                for k in keys {
                    if let Some(ts) = index.get(&k) {
                        for t in ts {
                            out.push(FlatRow::Thread(Box::new(t.clone())));
                        }
                    }
                }
                if let Some(anchor) = line.anchor_line() {
                    for p in &file_pending {
                        if p.line == anchor && p.side == line.anchor_side() {
                            out.push(FlatRow::Pending((*p).clone()));
                        }
                    }
                    if let Some(c) = &composer {
                        if c.path == file.id && c.line == anchor && c.side == line.anchor_side() {
                            out.push(FlatRow::Composer(c.clone()));
                        }
                    }
                }
            }
            if let Some(ts) = outdated.get(&file.id) {
                if !ts.is_empty() {
                    out.push(FlatRow::Note("Outdated comments".into()));
                    for t in ts {
                        out.push(FlatRow::Thread(Box::new(t.clone())));
                    }
                }
            }
        }
        out
    }

    pub fn reveal_file(self: &Rc<Self>, path: &str) {
        self.set_tab(PrTab::Files);
        self.collapsed.borrow_mut().remove(path);
        self.emit(Change::Diff);
        self.emit(Change::Reveal(path.to_string()));
        self.ensure_files();
    }

    pub async fn run<F, Fut>(self: &Rc<Self>, reload: bool, op: F) -> bool
    where
        F: FnOnce(GitHubApi) -> Fut,
        Fut: std::future::Future<Output = Result<(), ApiError>> + Send + 'static,
    {
        self.busy.set(true);
        self.emit(Change::Busy);
        let fut = op(self.api.clone());
        let res = crate::rt::run(fut).await;
        self.busy.set(false);
        self.emit(Change::Busy);
        match res {
            Ok(()) => {
                if reload {
                    self.force_full("mutation");
                }
                true
            }
            Err(e) => {
                self.emit(Change::ActionError(e.message));
                false
            }
        }
    }

    fn pr_id(&self) -> Option<String> {
        self.pr.borrow().as_ref().map(|p| p.id.clone())
    }

    pub async fn comment(self: Rc<Self>, body: String) -> bool {
        let Some(id) = self.pr_id() else { return false };
        let ok = self.run(true, move |api| async move { api.add_comment(&id, &body).await }).await;
        if ok {
            self.emit(Change::ScrollBottom);
        }
        ok
    }

    pub async fn submit_review(self: Rc<Self>, event: String, body: String) -> bool {
        let Some(id) = self.pr_id() else { return false };
        let comments = self.pending.borrow().clone();
        let ok = self.run(true, move |api| async move { api.add_review(&id, &event, Some(body), &comments).await }).await;
        if ok {
            self.pending.borrow_mut().clear();
            self.emit(Change::Diff);
            self.emit(Change::ScrollBottom);
        }
        ok
    }

    pub async fn add_inline(self: Rc<Self>, anchor: DiffAnchor, body: String, immediately: bool) -> bool {
        let c = PendingComment { id: uuid::Uuid::new_v4().to_string(), path: anchor.path.clone(), line: anchor.line, side: anchor.side.clone(), body };
        if immediately {
            let Some(id) = self.pr_id() else { return false };
            let ok = self.run(true, move |api| async move { api.add_review(&id, "COMMENT", None, &[c]).await }).await;
            if ok {
                *self.composer.borrow_mut() = None;
                self.composer_text.borrow_mut().clear();
                self.emit(Change::Diff);
            }
            return ok;
        }
        self.pending.borrow_mut().push(c);
        *self.composer.borrow_mut() = None;
        self.composer_text.borrow_mut().clear();
        self.emit(Change::Diff);
        true
    }

    pub async fn reply(self: Rc<Self>, thread_id: String, body: String) -> bool {
        self.run(true, move |api| async move { api.mutate(q::REPLY_THREAD, json!({ "id": thread_id, "b": body })).await }).await
    }

    pub async fn set_resolved(self: Rc<Self>, thread_id: String, resolved: bool) -> bool {
        let query = if resolved { q::RESOLVE_THREAD } else { q::UNRESOLVE_THREAD };
        self.run(true, move |api| async move { api.mutate(query, json!({ "id": thread_id })).await }).await
    }

    fn invalidate_stack(&self) {
        stack::store::invalidate(&self.api, &self.r.repo);
        self.stack_fresh.set(true);
    }

    pub async fn merge(self: Rc<Self>, method: String, title: Option<String>, body: Option<String>, delete_branch: bool) -> bool {
        let Some(pr) = self.pr.borrow().clone() else { return false };
        self.invalidate_stack();
        self.run(true, move |api| async move {
            api.mutate(q::MERGE, json!({ "id": pr.id, "m": method, "t": title, "b": body })).await?;
            if delete_branch {
                if let Some(head) = pr.head_repository.as_ref() {
                    let _ = api.delete_branch(&head.name_with_owner, &pr.head_ref_name).await;
                }
            }
            Ok(())
        })
        .await
    }

    pub async fn enable_auto_merge(self: Rc<Self>, method: String) -> bool {
        let Some(id) = self.pr_id() else { return false };
        self.run(true, move |api| async move { api.mutate(q::ENABLE_AUTO_MERGE, json!({ "id": id, "m": method })).await }).await
    }

    pub async fn simple(self: Rc<Self>, mutation: &'static str) -> bool {
        let Some(id) = self.pr_id() else { return false };
        self.invalidate_stack();
        self.run(true, move |api| async move { api.mutate(mutation, json!({ "id": id })).await }).await
    }

    pub async fn edit(self: Rc<Self>, title: String, body: String) -> bool {
        let Some(id) = self.pr_id() else { return false };
        self.run(true, move |api| async move { api.mutate(q::EDIT_PR, json!({ "id": id, "t": title, "b": body })).await }).await
    }

    pub async fn request_reviewers(self: Rc<Self>, logins: Vec<String>) -> bool {
        let r = self.r.clone();
        self.run(true, move |api| async move { api.request_reviewers(&r, &logins).await }).await
    }

    pub async fn delete_branch(self: Rc<Self>) -> bool {
        let Some(pr) = self.pr.borrow().clone() else { return false };
        let Some(head) = pr.head_repository.clone() else { return false };
        self.run(true, move |api| async move { api.delete_branch(&head.name_with_owner, &pr.head_ref_name).await }).await
    }

    pub async fn toggle_viewed(self: Rc<Self>, path: String) {
        let Some(id) = self.pr_id() else { return };
        let viewed = self.viewed.borrow().contains(&path);
        if viewed {
            self.viewed.borrow_mut().remove(&path);
        } else {
            self.viewed.borrow_mut().insert(path.clone());
            self.collapsed.borrow_mut().insert(path.clone());
        }
        self.emit(Change::Diff);
        let query = if viewed { q::UNMARK_VIEWED } else { q::MARK_VIEWED };
        self.run(false, move |api| async move { api.mutate(query, json!({ "id": id, "p": path })).await }).await;
    }

    pub async fn rerun_failed(self: Rc<Self>) -> bool {
        let runs: HashSet<i64> = self.pr.borrow().as_ref().map(|p| p.checks().iter().filter(|c| c.outcome() == CheckOutcome::Failure).filter_map(|c| c.run_id()).collect()).unwrap_or_default();
        let repo = self.r.repo.clone();
        self.run(true, move |api| async move {
            for id in runs {
                api.rerun_failed_jobs(&repo, id).await?;
            }
            Ok(())
        })
        .await
    }
}

fn stack_cache_key(pr: &PullRequestDetail) -> String {
    format!("{}|{}|{}|{}|{}|{}", pr.number, pr.state, pr.is_draft, pr.head_repository.as_ref().map(|h| h.name_with_owner.as_str()).unwrap_or(""), pr.head_ref_name, pr.base_ref_name)
}

pub fn context_snapshot(r: &ItemRef, pr: &PullRequestDetail, requirements: &[MergeRequirement], ownership: Option<&OwnershipSummary>, files: &[String], reviewed: Option<&ReviewedCommit>) -> context::Snapshot {
    let merge_status = if pr.is_open() {
        super::merge_status(pr, requirements).text
    } else if pr.merged {
        "Merged".to_string()
    } else {
        let lower = pr.state.to_lowercase();
        let mut chars = lower.chars();
        chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
    };
    let requirement_label = |s: RequirementState| match s {
        RequirementState::Satisfied => "met",
        RequirementState::Missing => "blocking",
        RequirementState::Pending => "in progress",
        RequirementState::Unknown => "unknown",
        RequirementState::Advisory => "does not block",
    };
    let outcome_label = |o: CheckOutcome| match o {
        CheckOutcome::Failure => "failure",
        CheckOutcome::Pending => "pending",
        CheckOutcome::Neutral => "neutral",
        CheckOutcome::Skipped => "skipped",
        CheckOutcome::Success => "success",
    };
    let mut reviews: Vec<context::Review> = pr.latest_opinionated_reviews.nodes.iter().filter_map(|rv| rv.author.as_ref().map(|a| context::Review { login: a.login.clone(), state: rv.state.clone() })).collect();
    reviews.extend(pr.review_requests.nodes.iter().filter_map(|q| q.requested_reviewer.as_ref().map(|x| context::Review { login: x.display(), state: "REVIEW_REQUESTED".into() })));
    context::Snapshot {
        repo: r.repo.full(),
        number: pr.number,
        title: pr.title.clone(),
        url: pr.url.clone(),
        state: pr.state.clone(),
        is_draft: pr.is_draft,
        author: pr.author.as_ref().map(|a| a.login.clone()),
        base_ref: pr.base_ref_name.clone(),
        head_ref: pr.head_ref_name.clone(),
        head_oid: pr.head_ref_oid.clone(),
        body: pr.body.clone(),
        merge_status,
        requirements: requirements.iter().map(|q| context::Requirement { state: requirement_label(q.state).into(), title: q.title.clone(), detail: q.detail.clone() }).collect(),
        checks: pr
            .checks()
            .iter()
            .map(|c| context::Check {
                name: c.workflow_name().map(|w| format!("{w} / {}", c.title())).unwrap_or_else(|| c.title()),
                outcome: outcome_label(c.outcome()).into(),
                required: c.is_required,
                url: c.link(),
            })
            .collect(),
        reviews,
        threads: pr
            .review_threads
            .nodes
            .iter()
            .map(|t| context::Thread {
                path: t.path.clone(),
                line: t.line.or(t.original_line),
                resolved: t.is_resolved,
                outdated: t.is_outdated,
                comments: t.comments.nodes.iter().map(|c| context::Comment { author: c.author.as_ref().map(|a| a.login.clone()).unwrap_or_else(|| "ghost".into()), body: c.body.clone() }).collect(),
            })
            .collect(),
        files: files.to_vec(),
        code_owners: ownership.map(|o| o.groups.iter().map(|g| context::OwnerGroup { owners: g.owners.iter().map(|e| format!("@{}", e.handle)).collect(), files: g.files.clone() }).collect()),
        unowned_files: ownership.map(|o| o.unowned.clone()),
        reviewed_oid: reviewed.map(|x| x.oid.clone()),
        commits_since_review: reviewed.and_then(|x| x.commits_since).map(|n| n as i64),
        captured: Utc::now(),
    }
}

fn changed_paths(pr: &PullRequestDetail) -> Vec<String> {
    pr.files.as_ref().map(|f| f.nodes.iter().map(|n| n.path.clone()).collect()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_snapshot_maps_model() {
        let check = json!({ "__typename": "CheckRun", "databaseId": 1, "name": "build", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": true,
            "checkSuite": { "workflowRun": { "databaseId": 9, "workflow": { "name": "CI" } } } });
        let comment = json!({ "id": "c", "author": { "login": "bob", "avatarUrl": "" }, "body": "fix", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z" });
        let mut value = json!({
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED", "body": "b", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main",
            "headRefOid": "h", "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false
        });
        let extra = json!({
            "labels": { "nodes": [] }, "assignees": { "nodes": [] },
            "reviewRequests": { "nodes": [{ "requestedReviewer": { "__typename": "Team", "name": "Core", "combinedSlug": "o/core" } }] },
            "latestOpinionatedReviews": { "nodes": [] },
            "lastCommit": { "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": [check] } } } }] },
            "allCommits": { "nodes": [] }, "timelineItems": { "nodes": [] },
            "reviewThreads": { "nodes": [{ "id": "t", "isResolved": false, "isOutdated": false, "path": "a", "line": 2, "diffSide": "RIGHT", "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true,
                "comments": { "nodes": [comment] } }] }
        });
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            value[k] = v;
        }
        let pr: PullRequestDetail = serde_json::from_value(value).unwrap();
        let r = ItemRef { repo: RepoRef { owner: "o".into(), name: "r".into() }, number: 7 };
        let reqs = merge_readiness::requirements(&pr, &RulesStatus::Loading);
        let s = context_snapshot(&r, &pr, &reqs, None, &["a".to_string()], None);
        assert_eq!(s.checks, vec![context::Check { name: "CI / build".into(), outcome: "failure".into(), required: Some(true), url: None }]);
        assert_eq!(s.reviews, vec![context::Review { login: "o/core".into(), state: "REVIEW_REQUESTED".into() }]);
        assert_eq!(s.threads[0].comments, vec![context::Comment { author: "bob".into(), body: "fix".into() }]);
        assert_eq!(s.merge_status, "1 required check failed");
        assert_eq!(s.repo, "o/r");
        assert!(s.code_owners.is_none());
    }
}
