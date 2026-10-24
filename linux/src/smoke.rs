use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk::glib;

use crate::api::models::*;
use crate::api::GitHubApi;
use crate::app::{self, App, IssueFilter, PrFilter, Section};
use crate::forge::ForgeCapabilities;
use crate::git_accounts::GitProvider;
use crate::ui::pr::model::{Change, PrModel, PrTab};
use crate::ui::pr::stack_tab;

fn step(delay_ms: u64, name: &'static str, f: impl FnOnce() + 'static) {
    glib::timeout_add_local_once(Duration::from_millis(delay_ms), move || {
        println!("smoke: {name}");
        f();
    });
}

const DIFF_ROUNDS: usize = 12;

pub fn rss_kb() -> i64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS:")).and_then(|l| l.split_whitespace().nth(1).and_then(|v| v.parse().ok())))
        .unwrap_or(-1)
}

pub fn inject_stack(m: &PrModel, extra: usize) -> usize {
    let Some(mut current) = m.current_stack_node() else { return 0 };
    let repo = m.r.repo.full();
    let nodes = crate::fixtures::stack_around(&current, &repo, extra);
    current.head_repo = Some(repo.clone());
    crate::stack::store::seed(&m.api, &m.r.repo, nodes.clone());
    let tree = crate::stack::StackTree::build(&current, &nodes, &repo, crate::stack::NODE_LIMIT);
    let count = tree.as_ref().map(|t| t.count()).unwrap_or(0);
    *m.stack.borrow_mut() = tree;
    m.emit(Change::Stack);
    count
}

fn diff_round(m: Rc<PrModel>, middle: String, i: usize, mut sync: Vec<f64>, mut frame: Vec<f64>) {
    if i == DIFF_ROUNDS {
        let half = DIFF_ROUNDS / 2;
        let avg = |v: &[f64]| v.iter().sum::<f64>() / v.len().max(1) as f64;
        let max = |v: &[f64]| v.iter().cloned().fold(0.0, f64::max);
        for (label, range) in [("full rebuild", 0..half), ("splice", half..DIFF_ROUNDS)] {
            let (s, f) = (&sync[range.clone()], &frame[range]);
            println!("smoke: large diff {label}: sync avg {:.1} ms max {:.1} ms, to painted frame avg {:.1} ms max {:.1} ms", avg(s), max(s), avg(f), max(f));
        }
        return;
    }
    if i % 2 == 0 {
        m.collapsed.borrow_mut().insert(middle.clone());
    } else {
        m.collapsed.borrow_mut().remove(&middle);
    }
    let started = Instant::now();
    m.emit(if i < DIFF_ROUNDS / 2 { Change::Files } else { Change::Diff });
    sync.push(started.elapsed().as_secs_f64() * 1000.0);
    let Some(win) = app::main_window() else { return };
    crate::ui::widgets::after_next_paint(&win, move || {
        frame.push(started.elapsed().as_secs_f64() * 1000.0);
        glib::idle_add_local_once(move || diff_round(m, middle, i + 1, sync, frame));
    });
}

fn agent_projects() -> Vec<crate::claude::sessions::Project> {
    let now = chrono::Utc::now();
    let session = |id: &str, title: &str, parent: Option<&str>, mins: i64| crate::claude::sessions::SessionInfo {
        id: id.into(),
        file: std::path::PathBuf::from(format!("/nonexistent/{id}.jsonl")),
        cwd: "/tmp".into(),
        title: title.into(),
        branch: Some("feat-smoke".into()),
        modified: now - chrono::Duration::minutes(mins),
        pr_url: None,
        pr_number: if mins == 0 { Some(7) } else { None },
        model: None,
        lines_added: Some(3),
        lines_removed: Some(1),
        parent_id: parent.map(|p| p.to_string()),
        desktop_id: None,
        archived: false,
    };
    vec![crate::claude::sessions::Project {
        id: "/tmp".into(),
        path: "/tmp".into(),
        sessions: vec![
            session("smoke-root", "Smoke parent session", None, 0),
            session("smoke-child-a", "Smoke sub-session A", Some("smoke-root"), 2),
            session("smoke-child-b", "Smoke sub-session B", Some("smoke-root"), 3),
            session("smoke-old", "Smoke old session", None, 90),
        ],
    }]
}

pub fn run(_app: Rc<App>) {
    println!("smoke: window built ({} {})", crate::brand::APP_NAME, crate::brand::VERSION);
    let mut t = 200;
    let mut next = |gap: u64| {
        t += gap;
        t
    };
    step(next(0), "login screen", app::set_smoke_logged_out);
    step(next(400), "main view", || {
        let api = GitHubApi::new("smoke-test-invalid-token");
        app::set_smoke_logged_in(api, RestUser { login: "smoke".into(), name: Some("Smoke Test".into()), avatar_url: None });
    });
    step(next(200), "fixture pr", || {
        let r = ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 };
        if let Some(api) = app::api() {
            let m = crate::ui::pr::model::PrModel::new(r, api);
            let resp: PrDetailResponse = serde_json::from_str(crate::fixtures::PR_DETAIL).expect("fixture");
            let files: Vec<PrFile> = serde_json::from_str(crate::fixtures::PR_FILES).expect("fixture");
            m.inject(resp, files);
            app::insert_pr_model(m);
        }
    });
    let sections = [
        Section::Prs(PrFilter::ReviewRequested),
        Section::Prs(PrFilter::Mine),
        Section::Prs(PrFilter::Assigned),
        Section::Prs(PrFilter::Mentioned),
        Section::Prs(PrFilter::Reviewed),
        Section::MyPrsByRepo,
        Section::Stacks,
        Section::Issues(IssueFilter::Assigned),
        Section::Issues(IssueFilter::Mine),
        Section::Issues(IssueFilter::Mentioned),
        Section::Notifications,
        Section::Repos,
        Section::Projects,
        Section::Claude,
        Section::Prs(PrFilter::Mine),
    ];
    for s in sections {
        step(next(250), "section", move || app::set_section(s));
    }
    let repo = RepoRef::new("octocat", "Hello-World");
    let routes = vec![
        Route::Pr(ItemRef { repo: repo.clone(), number: 1 }),
        Route::Issue(ItemRef { repo: repo.clone(), number: 2 }),
        Route::Repo(repo.clone()),
        Route::Project(ProjectRef { id: "PVT_x".into(), title: "Board".into(), url: "https://github.com/orgs/x/projects/1".into() }),
        Route::Commit(repo.clone(), "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d".into()),
    ];
    for r in routes {
        step(next(400), "route", move || app::select(Some(r)));
    }
    step(next(400), "push route", move || app::open(Route::Pr(ItemRef { repo: RepoRef::new("octocat", "Spoon-Knife"), number: 3 }), true));
    step(next(300), "back", app::back);
    step(next(300), "pr files tab", || {
        if let Some(m) = app::pr_model(&ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 }) {
            m.set_tab(crate::ui::pr::model::PrTab::Files);
            m.set_tab(crate::ui::pr::model::PrTab::Commits);
            m.set_tab(crate::ui::pr::model::PrTab::Checks);
            m.set_tab(crate::ui::pr::model::PrTab::Conversation);
        }
    });
    step(next(300), "fixture pr page", || app::select(Some(Route::Pr(ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 }))));
    let pr = || app::pr_model(&ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 }).expect("model");
    step(next(500), "files tab", move || pr().set_tab(crate::ui::pr::model::PrTab::Files));
    step(next(400), "inline composer and pending", move || {
        let m = pr();
        *m.composer.borrow_mut() = Some(crate::diff::DiffAnchor { path: "src/diff.rs".into(), line: 11, side: "RIGHT".into() });
        m.pending.borrow_mut().push(PendingComment { id: "p1".into(), path: "src/diff.rs".into(), line: 10, side: "RIGHT".into(), body: "Pending **note**".into() });
        m.emit(crate::ui::pr::model::Change::Diff);
        m.reveal_file("README.md");
    });
    let large = || ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 4 };
    step(next(400), "large diff", move || {
        if let Some(api) = app::api() {
            let m = crate::ui::pr::model::PrModel::new(large(), api);
            let resp: PrDetailResponse = serde_json::from_str(crate::fixtures::PR_DETAIL).expect("fixture");
            m.inject(resp, crate::fixtures::large_diff(50));
            app::insert_pr_model(m.clone());
            app::select(Some(Route::Pr(large())));
            m.set_tab(crate::ui::pr::model::PrTab::Files);
        }
    });
    step(next(800), "large diff update", move || {
        let Some(m) = app::pr_model(&large()) else { return };
        let rows = m.flat_rows("").len();
        let changed: i64 = m.files.borrow().iter().map(|f| f.additions + f.deletions).sum();
        println!("smoke: large diff {changed} changed lines, {rows} rows");
        let middle = m.files.borrow().get(25).map(|f| f.id.clone()).unwrap_or_default();
        diff_round(m, middle, 0, vec![], vec![]);
    });
    step(next(3000), "fixture pr page again", || app::select(Some(Route::Pr(ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 }))));
    step(next(400), "commits tab", move || pr().set_tab(crate::ui::pr::model::PrTab::Commits));
    step(next(300), "checks tab", move || pr().set_tab(crate::ui::pr::model::PrTab::Checks));
    step(next(300), "conversation tab", move || pr().set_tab(crate::ui::pr::model::PrTab::Conversation));
    step(next(300), "jira connect form", move || pr().set_tab(PrTab::Jira));
    step(next(300), "jira ticket card", move || {
        let url = pr().pr.borrow().as_ref().map(|p| p.url.clone()).unwrap_or_default();
        crate::settings::update(|s| {
            s.jira_site = "smoke.invalid".into();
            s.jira_has_token = true;
            s.jira_name = Some("Smoke".into());
        });
        crate::jira::remember(&crate::jira::JiraIssue {
            key: "SMOKE-1".into(),
            summary: "Smoke ticket".into(),
            status: "In Progress".into(),
            status_category: "indeterminate".into(),
            kind: Some("Story".into()),
            priority: Some("High".into()),
            assignee: Some("Smoke Test".into()),
            assignee_avatar: None,
            reporter: Some("Octocat".into()),
            description: "First line\n\n• second".repeat(40),
            url: "https://smoke.invalid/browse/SMOKE-1".into(),
            updated: Some(chrono::Utc::now()),
        });
        crate::jira::set_linked(&url, vec!["SMOKE-1".into()]);
        crate::jira::changed();
    });
    step(next(400), "jira cleanup", move || {
        let url = pr().pr.borrow().as_ref().map(|p| p.url.clone()).unwrap_or_default();
        crate::jira::set_linked(&url, vec![]);
        crate::settings::update(|s| {
            s.jira_site.clear();
            s.jira_has_token = false;
            s.jira_name = None;
        });
        crate::jira::changed();
        pr().set_tab(PrTab::Conversation);
    });
    step(next(300), "stack fixture", move || {
        let n = inject_stack(&pr(), 40);
        println!("smoke: stack tree {n} nodes, rss before stack tab {} kB", rss_kb());
    });
    step(next(300), "stack tab list", move || {
        crate::settings::update(|s| {
            s.stack_view = "list".into();
            s.stack_support_asked = true;
        });
        pr().set_tab(PrTab::Stack);
    });
    step(next(700), "stack list rss", || println!("smoke: stack list open, rss {} kB", rss_kb()));
    step(next(200), "agent stack note", move || {
        let Some(t) = stack_tab::last() else { return };
        let key = pr().stack_note_key(t.current());
        let entry = crate::stack::mcp::Entry { key, kind: crate::stack::notes::NoteKind::Question, text: "Added through MCP".into(), created: chrono::Utc::now() };
        let _ = crate::stack::mcp::drop_entry(&crate::stack::mcp::inbox_dir(), &entry);
        crate::stack::notes::import_inbox();
    });
    step(next(200), "stack notes", move || {
        let Some(t) = stack_tab::last() else { return };
        let n = t.current();
        crate::stack::notes::commit(&pr().stack_note_key(n), &[crate::stack::notes::StackNote::new(crate::stack::notes::NoteKind::Decision, "Merge the API first")]);
        t.show_notes(Some(n));
    });
    step(next(400), "stack notes close", || {
        if let Some(t) = stack_tab::last() {
            t.show_notes(None);
        }
    });
    step(next(300), "stack graph", || {
        if let Some(t) = stack_tab::last() {
            t.set_graph(true);
        }
    });
    step(next(800), "stack graph rss", || {
        let cards = stack_tab::last().and_then(|t| t.canvas()).map(|c| c.card_count()).unwrap_or(0);
        println!("smoke: stack graph open, {cards} cards built, rss {} kB", rss_kb());
    });
    step(next(200), "stack zoom out", || {
        if let Some(c) = stack_tab::last().and_then(|t| t.canvas()) {
            c.zoom_by(-0.3);
        }
    });
    step(next(400), "stack fit", || {
        if let Some(c) = stack_tab::last().and_then(|t| t.canvas()) {
            c.fit();
        }
    });
    step(next(500), "stack compact cards", || {
        let cards = stack_tab::last().and_then(|t| t.canvas()).map(|c| c.card_count()).unwrap_or(0);
        println!("smoke: stack graph fitted, {cards} cards built, rss {} kB", rss_kb());
    });
    step(next(200), "stack focus current", || {
        if let Some(c) = stack_tab::last().and_then(|t| t.canvas()) {
            c.focus_current();
            c.actual_size();
        }
    });
    step(next(500), "stack open from graph", || {
        if let Some(t) = stack_tab::last() {
            t.open(9001, false);
        }
    });
    step(next(800), "stack list again", move || {
        app::select(Some(Route::Pr(ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 })));
        pr().set_tab(PrTab::Stack);
        if let Some(t) = stack_tab::last() {
            t.set_graph(false);
        }
    });
    step(next(500), "stack open in place", || {
        if let Some(t) = stack_tab::last() {
            t.open(9002, true);
        }
    });
    step(next(1500), "stack unload", move || {
        app::select(Some(Route::Pr(ItemRef { repo: RepoRef::new("octocat", "Hello-World"), number: 1 })));
        pr().set_tab(PrTab::Conversation);
    });
    step(next(500), "stack unloaded rss", || println!("smoke: stack tab closed, rss {} kB", rss_kb()));
    step(next(200), "stack support dialog", crate::ui::pr::stack_tab::ask_support);
    step(next(300), "text zoom", || {
        crate::text_zoom::zoom_in();
        crate::text_zoom::zoom_in();
        println!("smoke: text zoom {:.1}", crate::text_zoom::scale());
        crate::text_zoom::zoom_out();
        crate::text_zoom::reset();
    });
    step(next(300), "stacks section", || app::set_section(Section::Stacks));
    step(next(400), "back to my prs", || app::set_section(Section::Prs(PrFilter::Mine)));
    step(next(300), "review sheet", move || crate::ui::pr::sheets::review(pr()));
    step(next(300), "merge sheet", move || crate::ui::pr::sheets::merge(pr()));
    step(next(300), "edit sheet", move || crate::ui::pr::sheets::edit(pr()));
    step(next(300), "reviewers sheet", move || crate::ui::pr::sheets::reviewers(pr()));
    step(next(300), "reply sheet", move || {
        let m = pr();
        let t = m.pr.borrow().as_ref().and_then(|p| p.review_threads.nodes.first().cloned());
        if let Some(t) = t {
            crate::ui::pr::sheets::reply(m.clone(), t);
        }
    });
    step(next(300), "fix with claude sheet", move || crate::ui::fix_claude::show(pr()));
    step(next(300), "job log sheet", move || {
        let m = pr();
        let c = m.pr.borrow().as_ref().map(|p| p.checks()[0].clone());
        if let Some(c) = c {
            crate::ui::pr::sheets::job_log(m.api.clone(), m.r.repo.clone(), c, Some(std::rc::Rc::new(|_: Option<String>| {})));
        }
    });
    step(next(300), "fix ci sheet", move || crate::ui::fix_claude::show_ci(pr(), None));
    step(next(300), "open link dialog", crate::ui::main_view::open_link_dialog);
    step(next(300), "preferences", crate::ui::settings::show);
    step(next(300), "diagnostics", || {
        crate::diagnostics::set_enabled(true);
        crate::ui::diagnostics::show();
    });
    step(next(300), "update dialog", || crate::ui::update::show(false));
    step(next(300), "about", crate::ui::main_view::about);
    step(next(300), "theme toggle", || {
        crate::settings::update(|s| s.appearance = "dark".into());
        crate::theme::apply();
        crate::settings::update(|s| s.appearance = "auto".into());
        crate::theme::apply();
    });
    step(next(300), "claude section", || app::set_section(Section::Claude));
    step(next(300), "claude chat tab", || {
        let ws = app::get().claude.clone();
        let tab = ws.new_session("/tmp", None, Some("Smoke chat".into()), None, Some(crate::claude::TabKind::Chat));
        if let Some(chat) = &tab.chat {
            for line in crate::fixtures::CHAT_STREAM {
                chat.feed(line);
            }
        }
    });
    step(next(600), "claude terminal tab", || {
        let ws = app::get().claude.clone();
        ws.new_session("/tmp", None, Some("Smoke terminal".into()), None, Some(crate::claude::TabKind::Terminal));
    });
    step(next(600), "claude select chat", || {
        let ws = app::get().claude.clone();
        let first = ws.tabs.borrow().first().map(|t| t.id);
        if let Some(id) = first {
            ws.select(id);
        }
    });
    step(next(400), "claude chat states", || {
        let ws = app::get().claude.clone();
        let chat = ws.tabs.borrow().iter().find_map(|t| t.chat.clone());
        if let Some(chat) = chat {
            *chat.last_error.borrow_mut() = Some("OAuth token has expired. Please run /login".into());
            chat.expanded.borrow_mut().insert("gtool-5".into(), true);
            chat.expanded.borrow_mut().insert("km4:0".into(), true);
            chat.changed.emit(&crate::claude::chat::Event::Updated("ctool-5".into()));
            chat.changed.emit(&crate::claude::chat::Event::State);
        }
    });
    step(next(400), "claude welcome", || {
        let ws = app::get().claude.clone();
        ws.new_session("/tmp", None, Some("Smoke welcome".into()), None, Some(crate::claude::TabKind::Chat));
    });
    step(next(300), "agents sidebar fixtures", || {
        let store = crate::claude::accounts::store();
        *store.status.borrow_mut() = crate::claude::accounts::Status::LoggedIn(crate::claude::accounts::AccountInfo {
            email: Some("smoke@example.invalid".into()),
            org_name: None,
            subscription: Some("pro".into()),
            method: None,
            provider: None,
        });
        store.changed.emit(&());
        let ws = app::get().claude.clone();
        *ws.projects.borrow_mut() = agent_projects();
        ws.emit(crate::claude::workspace::WsEvent::Projects);
    });
    step(next(400), "agents pin and archive", || {
        crate::claude::prefs::update(|p| {
            p.toggle_pin("smoke-root");
            p.set_archived("smoke-old", true);
        });
        app::get().claude.emit(crate::claude::workspace::WsEvent::Projects);
    });
    step(next(300), "agents unpin and unarchive", || {
        crate::claude::prefs::update(|p| {
            p.toggle_pin("smoke-root");
            p.set_archived("smoke-old", false);
        });
        app::get().claude.emit(crate::claude::workspace::WsEvent::Projects);
    });
    step(next(300), "agents unread indicator", || {
        let ws = app::get().claude.clone();
        if let Some(t) = ws.tabs.borrow().last() {
            t.unread.set(true);
        }
        ws.emit(crate::claude::workspace::WsEvent::TabState);
        println!("smoke: agents attention badge {}", ws.attention_badge());
    });
    step(next(300), "agents cycle tabs", || {
        let ws = app::get().claude.clone();
        ws.cycle_tab(1);
        ws.cycle_tab(-1);
    });
    step(next(300), "agents notifications", || {
        let id = app::get().claude.tabs.borrow().first().map(|t| t.id).unwrap_or(0);
        crate::claude::notifier::post(id, "Smoke finished", "Body");
        crate::claude::notifier::withdraw(id);
        crate::claude::notifier::set_badge(2);
        crate::claude::notifier::set_badge(0);
    });
    step(next(300), "agents quick open", crate::ui::claude::quick_open::show);
    step(next(300), "agents quick open filter", || crate::ui::claude::quick_open::set_query("smoke"));
    step(next(600), "agents quick open search", || {
        println!("smoke: quick open shows {} entries", crate::ui::claude::quick_open::shown_count());
        crate::ui::claude::quick_open::set_query("migrate the schema");
    });
    step(next(900), "agents quick open close", crate::ui::claude::quick_open::close);
    step(next(200), "agents open in", || {
        crate::ui::claude::open_in::when_ready(|| println!("smoke: open in apps {}", crate::ui::claude::open_in::installed().map(|a| a.len()).unwrap_or(0)));
    });
    step(next(400), "deep link", || app::get().handle_url(&format!("{}://section/repos", crate::brand::URL_SCHEME)));
    step(next(300), "gitlab account", || {
        let caps = ForgeCapabilities { pull_filters: PrFilter::ALL.to_vec(), issue_filters: IssueFilter::ALL.to_vec(), inbox_title: Some("To-Do List"), repositories: true };
        app::set_smoke_forge(GitProvider::Gitlab, caps)
    });
    step(next(400), "forge item", || {
        let item: SearchItem = crate::forge::ForgeItem {
            number: 12,
            title: "Smoke merge request".into(),
            url: "https://smoke.invalid/g/app/-/merge_requests/12".into(),
            state: "OPEN",
            draft: false,
            created: chrono::Utc::now(),
            updated: chrono::Utc::now(),
            base: Some("main".into()),
            author: Some("smoke".into()),
            avatar: None,
            repo: "g/app".into(),
            comments: Some(2),
            labels: vec![],
            review: Some("APPROVED".into()),
        }
        .into();
        crate::ui::forge_view::remember(std::slice::from_ref(&item));
        app::select(Some(item.route()));
    });
    let forge_sections: Vec<Section> = PrFilter::ALL
        .iter()
        .map(|f| Section::Prs(*f))
        .chain([Section::MyPrsByRepo, Section::Notifications, Section::Repos])
        .chain(IssueFilter::ALL.iter().map(|f| Section::Issues(*f)))
        .collect();
    for s in forge_sections {
        step(next(250), "forge section", move || app::set_section(s));
    }
    step(next(250), "forge claude section", || app::set_section(Section::Claude));
    step(next(300), "account menu", || {
        crate::ui::accounts::menu();
    });
    step(next(300), "bitbucket account", || {
        let caps = ForgeCapabilities { pull_filters: vec![PrFilter::ReviewRequested, PrFilter::Mine, PrFilter::Reviewed], issue_filters: vec![], inbox_title: None, repositories: true };
        app::set_smoke_forge(GitProvider::Bitbucket, caps)
    });
    step(next(300), "bitbucket repos", || app::set_section(Section::Repos));
    step(next(400), "login providers", || {
        app::set_smoke_logged_out();
        for p in GitProvider::ALL {
            crate::ui::login::select_provider(p);
        }
    });
    step(next(400), "add account sheet", crate::ui::login::add_account_sheet);
    let locked = || {
        let mut a = crate::git_accounts::GitAccount::draft(GitProvider::Gitlab, "smoke.invalid", None);
        a.login = "smoke".into();
        a
    };
    step(next(400), "pin sheets", move || {
        crate::ui::unlock::set_pin_sheet(&locked(), Rc::new(|| {}));
        crate::ui::unlock::unlock_sheet(&locked(), "Enter PIN", Rc::new(|| {}));
    });
    step(next(400), "lock screen", move || app::set_smoke_locked(locked()));
    step(next(1200), "done", || {
        println!("smoke: ok");
        app::finish_smoke(0);
    });
    glib::timeout_add_local_once(Duration::from_secs(90), || {
        eprintln!("smoke: timed out");
        app::finish_smoke(3);
    });
}
