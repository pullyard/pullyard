use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use adw::prelude::*;

use super::widgets::*;
use crate::git_accounts::{self, GitCredential, GitProvider};
use crate::{app, auth, brand, rt, settings, util};

thread_local! {
    static CURRENT: RefCell<Weak<Login>> = const { RefCell::new(Weak::new()) };
}

struct Login {
    provider: Cell<GitProvider>,
    tabs: Vec<(GitProvider, gtk::ToggleButton)>,
    on_done: Option<Rc<dyn Fn()>>,
    busy: Loader,
    error: gtk::Label,
    error_box: gtk::Box,
    host_card: gtk::Box,
    host_title: gtk::Label,
    host: gtk::Entry,
    cli_card: gtk::Box,
    cli_title: gtk::Label,
    cli_hint: gtk::Label,
    cli_button: gtk::Button,
    token_title: gtk::Label,
    token_hint: gtk::Label,
    email: gtk::Entry,
    token: gtk::PasswordEntry,
    sign: gtk::Button,
    create: gtk::Button,
    one_click_card: gtk::Box,
    one_click_button: gtk::Button,
    one_click_box: gtk::Box,
    one_click_code: gtk::Label,
    one_click_hint: gtk::Label,
    device_card: gtk::Box,
    device_title: gtk::Label,
    device_title_icon: gtk::Box,
    device_help: gtk::Label,
    client: gtk::Entry,
    device_box: gtk::Box,
    code_label: gtk::Label,
    device_hint: gtk::Label,
    get_code: gtk::Button,
    device_uri: RefCell<Option<(String, String)>>,
    cancel: RefCell<Option<tokio::task::AbortHandle>>,
}

fn client_id_for(provider: GitProvider) -> String {
    settings::read(|s| if provider == GitProvider::Github { s.oauth_client_id.clone() } else { s.oauth_client_ids.get(provider.key()).cloned().unwrap_or_default() })
}

fn store_client_id(provider: GitProvider, value: String) {
    if client_id_for(provider) == value {
        return;
    }
    settings::update(|s| {
        if provider == GitProvider::Github {
            s.oauth_client_id = value;
        } else {
            s.oauth_client_ids.insert(provider.key().to_string(), value);
        }
    });
}

impl Login {
    fn set_busy(&self, on: bool) {
        self.busy.set_visible(on);
    }

    fn show_error(&self, msg: Option<&str>) {
        match msg {
            Some(m) => {
                self.error.set_text(m);
                self.error_box.set_visible(true);
            }
            None => self.error_box.set_visible(false),
        }
    }

    fn effective_host(&self) -> String {
        self.provider.get().effective_host(&self.host.text())
    }

    fn can_submit_token(&self) -> bool {
        let has_email = self.provider.get() != GitProvider::Bitbucket || !self.email.text().trim().is_empty();
        !self.token.text().trim().is_empty() && has_email && !self.effective_host().is_empty()
    }

    fn sync_state(&self) {
        let p = self.provider.get();
        let host = self.effective_host();
        self.sign.set_sensitive(self.can_submit_token());
        self.cli_button.set_sensitive(!host.is_empty());
        self.get_code.set_sensitive(!self.client.text().trim().is_empty() && !host.is_empty());
        match p.token_create_url(&host, brand::APP_NAME) {
            Some(_) => {
                self.create.set_label(&p.token_create_label(&host));
                self.create.set_visible(true);
            }
            None => self.create.set_visible(false),
        }
    }

    fn select(&self, p: GitProvider) {
        if let Some(h) = self.cancel.borrow_mut().take() {
            h.abort();
        }
        self.provider.set(p);
        for (tp, t) in &self.tabs {
            if *tp == p && !t.is_active() {
                t.set_active(true);
            }
        }
        if settings::read(|s| s.login_provider != p.key()) {
            settings::update(|s| s.login_provider = p.key().to_string());
        }
        self.host_card.set_visible(p.host_editable());
        self.host_title.set_text(&format!("{} server", p.title()));
        self.host.set_placeholder_text(Some(p.host_placeholder()));
        self.host.set_text(p.default_host());
        let cli = p.cli_name().filter(|_| auth::cli_available(p));
        self.cli_card.set_visible(cli.is_some());
        if let Some(name) = cli {
            let (title, cli_label) = if name == "glab" { ("GitLab CLI", "glab") } else { ("GitHub CLI", "gh") };
            self.cli_title.set_text(title);
            self.cli_hint.set_text(&format!("Use the token you're signed in with in {cli_label}."));
            self.cli_button.set_child(Some(&icon_label_content("sy-terminal-symbolic", &format!("Sign in with {cli_label}"))));
        }
        self.token_title.set_text(p.token_title());
        self.token_hint.set_text(p.token_hint());
        self.email.set_visible(p == GitProvider::Bitbucket);
        self.token.set_text("");
        self.token.set_placeholder_text(Some(p.token_placeholder()));
        let one_click = p == GitProvider::Github && auth::built_in_client_id().is_some();
        self.one_click_card.set_visible(one_click);
        self.reset_device();
        self.device_card.set_visible(p.supports_device_flow());
        self.device_title.set_text(if one_click { "Use your own OAuth App" } else { "Sign in via browser (OAuth Device Flow)" });
        if let Some(old) = self.device_title_icon.first_child() {
            self.device_title_icon.remove(&old);
        }
        self.device_title_icon.append(&icon_tile(if one_click { "emblem-system-symbolic" } else { "sy-globe-symbolic" }, "indigo", 22));
        self.device_help.set_text(p.device_help());
        self.client.set_placeholder_text(Some(p.client_id_placeholder()));
        self.client.set_text(&client_id_for(p));
        self.show_error(None);
        self.sync_state();
    }

    fn reset_device(&self) {
        self.device_box.set_visible(false);
        self.device_hint.set_visible(false);
        self.get_code.set_visible(true);
        self.one_click_box.set_visible(false);
        self.one_click_hint.set_visible(false);
        self.one_click_button.set_visible(true);
        self.device_uri.borrow_mut().take();
    }

    fn cancel_device(&self) {
        if let Some(h) = self.cancel.borrow_mut().take() {
            h.abort();
        }
        self.reset_device();
    }

    fn finish(self: &Rc<Self>, credential: GitCredential) {
        let p = self.provider.get();
        let host = self.effective_host();
        let email = if p == GitProvider::Bitbucket { Some(self.email.text().trim().to_string()) } else { None };
        self.set_busy(true);
        self.show_error(None);
        let me = self.clone();
        rt::spawn_local(async move {
            let result = app::get().add_account(p, host, credential, email).await;
            me.set_busy(false);
            match result {
                Ok(()) => {
                    if let Some(done) = &me.on_done {
                        done();
                    }
                }
                Err(e) => me.show_error(Some(&e.message)),
            }
        });
    }

    fn sign_in_with_cli(self: &Rc<Self>) {
        let p = self.provider.get();
        let host = self.effective_host();
        if host.is_empty() {
            return;
        }
        self.set_busy(true);
        self.show_error(None);
        let me = self.clone();
        rt::spawn_local(async move {
            match auth::cli_token(p, host).await {
                Ok(t) => me.finish(GitCredential::token(t)),
                Err(e) => {
                    me.set_busy(false);
                    me.show_error(Some(&e.message));
                }
            }
        });
    }

    fn sign_in_with_token(self: &Rc<Self>) {
        if !self.can_submit_token() {
            return;
        }
        let t = self.token.text().trim().to_string();
        self.finish(GitCredential::token(t));
    }

    fn start_device(self: &Rc<Self>, built_in: Option<&str>) {
        let p = self.provider.get();
        let host = self.effective_host();
        let id = built_in.map(str::to_string).unwrap_or_else(|| self.client.text().trim().to_string());
        if id.is_empty() || host.is_empty() {
            return;
        }
        self.show_error(None);
        self.cancel_device();
        let (row, code_label, hint, start) = if built_in.is_some() {
            (self.one_click_box.clone(), self.one_click_code.clone(), self.one_click_hint.clone(), self.one_click_button.clone())
        } else {
            (self.device_box.clone(), self.code_label.clone(), self.device_hint.clone(), self.get_code.clone())
        };
        start.set_sensitive(false);
        let endpoint = auth::Endpoint::for_provider(p, &host);
        let keep_refresh = p == GitProvider::Gitlab;
        let (tx, rx) = async_channel::bounded::<Result<auth::DeviceCode, String>>(1);
        let (ttx, trx) = async_channel::bounded::<Result<auth::DeviceToken, String>>(1);
        let client_id = id.clone();
        let task = rt::runtime().spawn(async move {
            match auth::device_start(client_id.clone(), endpoint.clone()).await {
                Ok(code) => {
                    let _ = tx.send(Ok(code.clone())).await;
                    let r = auth::device_poll(client_id, code, endpoint).await.map_err(|e| e.message);
                    let _ = ttx.send(r).await;
                }
                Err(e) => {
                    let _ = tx.send(Err(e.message)).await;
                }
            }
        });
        *self.cancel.borrow_mut() = Some(task.abort_handle());
        let me = self.clone();
        rt::spawn_local(async move {
            let first = rx.recv().await;
            start.set_sensitive(true);
            match first {
                Ok(Ok(code)) => {
                    code_label.set_text(&code.user_code);
                    row.set_visible(true);
                    start.set_visible(false);
                    hint.set_text(&format!("The code is copied. Paste it at {} — you'll be signed in automatically.", code.verification_uri));
                    hint.set_visible(true);
                    util::copy(&code.user_code);
                    util::open_url(&code.verification_uri);
                    *me.device_uri.borrow_mut() = Some((code.user_code.clone(), code.verification_uri.clone()));
                    match trx.recv().await {
                        Ok(Ok(token)) if me.provider.get() == p => {
                            let credential = if keep_refresh { token.credential(Some(id)) } else { GitCredential::token(token.access_token) };
                            me.finish(credential);
                        }
                        Ok(Ok(_)) => {}
                        Ok(Err(e)) => me.show_error(Some(&e)),
                        Err(_) => return,
                    }
                    row.set_visible(false);
                    start.set_visible(true);
                    hint.set_visible(false);
                }
                Ok(Err(e)) => me.show_error(Some(&e)),
                Err(_) => {}
            }
        });
    }
}

fn card_title(title: &str, icon_name: &str, color: &str) -> (gtk::Box, gtk::Label) {
    let b = hbox(8);
    b.append(&icon_tile(icon_name, color, 22));
    let l = label_with(title, &["heading"]);
    b.append(&l);
    (b, l)
}

fn card() -> gtk::Box {
    let c = vbox(8);
    c.add_css_class("sy-card");
    c
}

type Refill = Rc<RefCell<Option<Rc<dyn Fn()>>>>;

const SIGN_IN_AGAIN: &str = "Sign in again";

fn prefill(a: &git_accounts::GitAccount) {
    let Some(l) = CURRENT.with(|c| c.borrow().upgrade()) else { return };
    l.select(a.provider);
    if a.provider.host_editable() {
        l.host.set_text(&a.host);
    }
    if let Some(email) = &a.email {
        l.email.set_text(email);
    }
    l.show_error(Some(&format!("Sign in again to {} as @{}.", a.host, a.login)));
    l.token.grab_focus();
}

async fn switch_then(id: String, refill: Weak<RefCell<Option<Rc<dyn Fn()>>>>, done: Option<Rc<dyn Fn()>>) {
    app::get().switch_account(id).await;
    if app::get().state.borrow().phase == app::Phase::LoggedIn {
        if let Some(d) = done {
            d();
        }
    } else if let Some(f) = refill.upgrade().and_then(|r| r.borrow().clone()) {
        f();
    }
}

fn continue_with(a: &git_accounts::GitAccount, refill: Weak<RefCell<Option<Rc<dyn Fn()>>>>, on_done: Option<Rc<dyn Fn()>>) {
    let target = a.clone();
    let other = app::account().is_some_and(|current| current.id != a.id);
    let run = move || {
        let target = target.clone();
        let refill = refill.clone();
        let done = on_done.clone();
        rt::spawn_local(async move {
            if !crate::account_lock::is_protected(&target.id).await {
                switch_then(target.id.clone(), refill, done).await;
                return;
            }
            let id = target.id.clone();
            super::unlock::unlock_sheet(
                &target,
                "Enter PIN",
                Rc::new(move || {
                    let (id, refill, done) = (id.clone(), refill.clone(), done.clone());
                    rt::spawn_local(async move { switch_then(id, refill, done).await });
                }),
            );
        });
    };
    if other && app::claude_running() {
        super::dialogs::confirm(&format!("Switch to {}?", a.subtitle()), Some(app::CLAUDE_SWITCH_NOTE), "Switch", false, run);
    } else {
        run();
    }
}

fn saved_accounts(on_done: Option<Rc<dyn Fn()>>) -> gtk::Box {
    let c = card();
    let fill: Refill = Rc::new(RefCell::new(None));
    let weak_card = c.downgrade();
    let filler = Rc::downgrade(&fill);
    let refill: Rc<dyn Fn()> = Rc::new(move || {
        let Some(target) = weak_card.upgrade() else { return };
        clear(&target);
        let accounts = git_accounts::accounts();
        target.set_visible(!accounts.is_empty());
        if accounts.is_empty() {
            return;
        }
        target.append(&card_title("Your accounts", "sy-person-symbolic", "green").0);
        for a in accounts {
            let row = hbox(10);
            let display = a.display_name();
            row.append(&avatar(a.avatar_url.as_deref(), 24, Some(&display)));
            let texts = vbox(0);
            texts.set_hexpand(true);
            texts.append(&ellipsized(&display, &["sy-text", "sy-bold"]));
            texts.append(&ellipsized(&format!("{} · {}", a.provider.title(), a.subtitle()), &["sy-muted", "sy-small"]));
            row.append(&texts);
            let go = button("Continue");
            go.set_valign(gtk::Align::Center);
            let weak_go = go.downgrade();
            let probe = a.clone();
            rt::spawn_local(async move {
                if !git_accounts::has_credential(&probe).await {
                    if let Some(g) = weak_go.upgrade() {
                        g.set_label(SIGN_IN_AGAIN);
                    }
                }
            });
            let filler = filler.clone();
            let done = on_done.clone();
            go.connect_clicked(move |b| {
                if b.label().as_deref() == Some(SIGN_IN_AGAIN) {
                    prefill(&a);
                } else {
                    continue_with(&a, filler.clone(), done.clone());
                }
            });
            row.append(&go);
            target.append(&row);
        }
    });
    *fill.borrow_mut() = Some(refill.clone());
    refill();
    keep_alive(&c, fill);
    c
}

fn stage<W: IsA<gtk::Widget>>(child: &W, delay: f64) -> gtk::Revealer {
    let r = gtk::Revealer::new();
    r.set_transition_type(gtk::RevealerTransitionType::Crossfade);
    r.set_transition_duration(450);
    r.set_child(Some(child));
    if !super::logo::animations_enabled() {
        r.set_reveal_child(true);
        return r;
    }
    let weak = r.downgrade();
    gtk::glib::timeout_add_local_once(std::time::Duration::from_secs_f64(delay), move || {
        if let Some(r) = weak.upgrade() {
            r.set_reveal_child(true);
        }
    });
    r
}

fn welcome_hero(pace: f64) -> gtk::Box {
    let b = vbox(10);
    let mark = Loader::once(210);
    mark.set_duration(1.7);
    mark.set_halign(gtk::Align::Center);
    decorative(&mark);
    b.append(&mark);
    let t = label_with(brand::APP_NAME, &["onboarding-title"]);
    t.set_xalign(0.5);
    b.append(&stage(&t, 1.15 * pace));
    let s = label_with(brand::TAGLINE, &["onboarding-tagline"]);
    s.set_xalign(0.5);
    b.append(&stage(&s, 1.3 * pace));
    b
}

const FEATURES: [(&str, &str, &str, &str); 3] = [
    ("sy-bell-symbolic", "sky", "Inbox for reviews", "Review requests, mentions and your PRs in one live list."),
    ("sy-merge-symbolic", "violet", "Review & merge", "Diffs, threads and checks — no browser tab needed."),
    ("sy-sparkles-symbolic", "coral", "Fix with agent", "Hand a failing check or review comment to an agent."),
];

fn welcome_features(pace: f64) -> gtk::Box {
    let row = hbox(10);
    row.set_homogeneous(true);
    for (i, (icon_name, color, title, detail)) in FEATURES.iter().enumerate() {
        let card = vbox(8);
        card.add_css_class("onboarding-card");
        let tile = icon_tile(icon_name, color, 28);
        tile.set_halign(gtk::Align::Start);
        decorative(&tile);
        card.append(&tile);
        card.append(&label_with(title, &["sy-bold", "sy-text"]));
        let d = wrap_label(detail, &["sy-status-message"]);
        d.set_max_width_chars(18);
        card.append(&d);
        card.set_accessible_role(gtk::AccessibleRole::Group);
        set_label(&card, &format!("{title}. {detail}"));
        row.append(&stage(&card, (1.5 + i as f64 * 0.1) * pace));
    }
    row
}

pub fn form(embedded: bool, on_done: Option<Rc<dyn Fn()>>) -> gtk::Box {
    let outer = vbox(22);
    let column = vbox(18);
    let pace = if git_accounts::accounts().is_empty() { 1.0 } else { 0.5 };

    if !embedded {
        outer.append(&welcome_hero(pace));
        outer.append(&welcome_features(pace));
        column.append(&saved_accounts(on_done.clone()));
    }

    let tabs_box = hbox(0);
    tabs_box.add_css_class("linked");
    tabs_box.set_halign(gtk::Align::Fill);
    let mut tabs = vec![];
    let mut first: Option<gtk::ToggleButton> = None;
    for p in GitProvider::ALL {
        let t = gtk::ToggleButton::with_label(p.short_title());
        t.set_hexpand(true);
        t.set_tooltip_text(Some(p.title()));
        match &first {
            Some(g) => t.set_group(Some(g)),
            None => first = Some(t.clone()),
        }
        tabs_box.append(&t);
        tabs.push((p, t));
    }
    column.append(&tabs_box);

    let host_card = card();
    let (title, host_title) = card_title("Server", "sy-globe-symbolic", "teal");
    host_card.append(&title);
    let host = gtk::Entry::new();
    host_card.append(&host);
    column.append(&host_card);

    let one_click_card = card();
    one_click_card.append(&card_title("Sign in with GitHub", "sy-globe-symbolic", "indigo").0);
    one_click_card.append(&wrap_label("Opens github.com in your browser. Enter the code shown here and you're in — no token to copy.", &["sy-muted", "sy-small"]));
    let one_click_button = icon_label_button("sy-external-symbolic", "Sign in with GitHub");
    one_click_button.add_css_class("suggested-action");
    one_click_button.add_css_class("pill");
    one_click_card.append(&one_click_button);
    let one_click_box = hbox(12);
    let one_click_code = label_with("", &["user-code", "sy-text"]);
    one_click_code.set_selectable(true);
    one_click_box.append(&one_click_code);
    let one_click_open = suggested("Copy and open");
    one_click_open.set_valign(gtk::Align::Center);
    one_click_box.append(&one_click_open);
    one_click_box.append(&spinner(12));
    one_click_box.append(&spacer());
    let one_click_cancel = link_button("Cancel");
    one_click_cancel.set_valign(gtk::Align::Center);
    one_click_box.append(&one_click_cancel);
    one_click_box.set_visible(false);
    one_click_card.append(&one_click_box);
    let one_click_hint = wrap_label("", &["sy-muted", "sy-tiny"]);
    one_click_hint.set_visible(false);
    one_click_card.append(&one_click_hint);
    one_click_card.set_visible(false);
    column.append(&one_click_card);

    let cli_card = card();
    let (title, cli_title) = card_title("GitHub CLI", "sy-terminal-symbolic", "sky");
    cli_card.append(&title);
    let cli_hint = wrap_label("", &["sy-muted", "sy-small"]);
    cli_card.append(&cli_hint);
    let cli_button = icon_label_button("sy-terminal-symbolic", "Sign in with gh");
    cli_button.add_css_class("suggested-action");
    cli_button.add_css_class("pill");
    cli_card.append(&cli_button);
    column.append(&cli_card);

    let token_card = card();
    let (title, token_title) = card_title("Personal Access Token", "sy-key-symbolic", "amber");
    token_card.append(&title);
    let token_hint = wrap_label("", &["sy-muted", "sy-small"]);
    token_card.append(&token_hint);
    let email = gtk::Entry::new();
    email.set_placeholder_text(Some("Atlassian account email"));
    email.set_input_purpose(gtk::InputPurpose::Email);
    token_card.append(&email);
    let row = hbox(8);
    let token = gtk::PasswordEntry::new();
    token.set_show_peek_icon(true);
    token.set_hexpand(true);
    let sign = suggested("Sign in");
    row.append(&token);
    row.append(&sign);
    token_card.append(&row);
    let create = link_button("Create a token");
    create.set_halign(gtk::Align::Start);
    token_card.append(&create);
    column.append(&token_card);

    let device_card = card();
    let expander = gtk::Expander::new(None);
    let device_title_row = hbox(8);
    let device_title_icon = hbox(0);
    device_title_icon.append(&icon_tile("sy-globe-symbolic", "indigo", 22));
    let device_title = label_with("Sign in via browser (OAuth Device Flow)", &["heading"]);
    device_title_row.append(&device_title_icon);
    device_title_row.append(&device_title);
    expander.set_label_widget(Some(&device_title_row));
    let inner = vbox(8);
    inner.set_margin_top(8);
    let device_help = wrap_label("", &["sy-muted", "sy-small"]);
    inner.append(&device_help);
    let client = gtk::Entry::new();
    inner.append(&client);
    let device_box = hbox(12);
    let code_label = label_with("", &["user-code", "sy-text"]);
    code_label.set_selectable(true);
    device_box.append(&code_label);
    let copy_open = suggested("Copy and open");
    copy_open.set_valign(gtk::Align::Center);
    device_box.append(&copy_open);
    device_box.append(&spinner(12));
    device_box.append(&spacer());
    let device_cancel = link_button("Cancel");
    device_cancel.set_valign(gtk::Align::Center);
    device_box.append(&device_cancel);
    device_box.set_visible(false);
    inner.append(&device_box);
    let device_hint = wrap_label("", &["sy-muted", "sy-tiny"]);
    device_hint.set_visible(false);
    inner.append(&device_hint);
    let get_code = button("Get code");
    get_code.set_halign(gtk::Align::Start);
    inner.append(&get_code);
    expander.set_child(Some(&inner));
    device_card.append(&expander);
    column.append(&device_card);

    let busy = spinner(16);
    busy.set_visible(false);
    busy.set_halign(gtk::Align::Center);
    column.append(&busy);
    let error = wrap_label("", &["fg-red"]);
    error.set_selectable(true);
    let error_box = hbox(8);
    error_box.add_css_class("banner-box");
    error_box.add_css_class("red");
    error_box.append(&colored_icon("sy-attention-symbolic", 16, "red"));
    error_box.append(&error);
    error_box.set_visible(false);
    column.append(&error_box);

    let login = Rc::new(Login {
        provider: Cell::new(GitProvider::Github),
        tabs,
        on_done,
        busy,
        error,
        error_box,
        host_card,
        host_title,
        host,
        cli_card,
        cli_title,
        cli_hint,
        cli_button,
        token_title,
        token_hint,
        email,
        token,
        sign,
        create,
        one_click_card,
        one_click_button,
        one_click_box,
        one_click_code,
        one_click_hint,
        device_card,
        device_title,
        device_title_icon,
        device_help,
        client,
        device_box,
        code_label,
        device_hint,
        get_code,
        device_uri: RefCell::new(None),
        cancel: RefCell::new(None),
    });

    for (p, t) in &login.tabs {
        let weak = Rc::downgrade(&login);
        let p = *p;
        t.connect_toggled(move |t| {
            if let Some(l) = weak.upgrade().filter(|l| t.is_active() && l.provider.get() != p) {
                l.select(p);
            }
        });
    }
    let weak = Rc::downgrade(&login);
    let sync = move || {
        if let Some(l) = weak.upgrade() {
            l.sync_state();
        }
    };
    let s = sync.clone();
    login.host.connect_changed(move |_| s());
    let s = sync.clone();
    login.email.connect_changed(move |_| s());
    let s = sync.clone();
    login.token.connect_changed(move |_| s());
    let weak = Rc::downgrade(&login);
    login.client.connect_changed(move |e| {
        if let Some(l) = weak.upgrade() {
            store_client_id(l.provider.get(), e.text().trim().to_string());
            l.sync_state();
        }
    });
    let weak = Rc::downgrade(&login);
    login.cli_button.connect_clicked(move |_| {
        if let Some(l) = weak.upgrade() {
            l.sign_in_with_cli();
        }
    });
    let weak = Rc::downgrade(&login);
    login.sign.connect_clicked(move |_| {
        if let Some(l) = weak.upgrade() {
            l.sign_in_with_token();
        }
    });
    let weak = Rc::downgrade(&login);
    login.token.connect_activate(move |_| {
        if let Some(l) = weak.upgrade() {
            l.sign_in_with_token();
        }
    });
    let weak = Rc::downgrade(&login);
    login.create.connect_clicked(move |_| {
        if let Some(l) = weak.upgrade() {
            if let Some(url) = l.provider.get().token_create_url(&l.effective_host(), brand::APP_NAME) {
                util::open_url(&url);
            }
        }
    });
    let weak = Rc::downgrade(&login);
    login.get_code.connect_clicked(move |_| {
        if let Some(l) = weak.upgrade() {
            l.start_device(None);
        }
    });
    let weak = Rc::downgrade(&login);
    login.one_click_button.connect_clicked(move |_| {
        if let (Some(l), Some(id)) = (weak.upgrade(), auth::built_in_client_id()) {
            l.start_device(Some(id));
        }
    });
    for b in [&copy_open, &one_click_open] {
        let weak = Rc::downgrade(&login);
        b.connect_clicked(move |_| {
            if let Some((code, uri)) = weak.upgrade().and_then(|l| l.device_uri.borrow().clone()) {
                util::copy(&code);
                util::open_url(&uri);
            }
        });
    }
    for b in [&device_cancel, &one_click_cancel] {
        let weak = Rc::downgrade(&login);
        b.connect_clicked(move |_| {
            if let Some(l) = weak.upgrade() {
                l.cancel_device();
            }
        });
    }

    let initial = settings::read(|s| GitProvider::from_key(&s.login_provider)).unwrap_or(GitProvider::Github);
    login.select(initial);
    if let Some((_, t)) = login.tabs.iter().find(|(p, _)| *p == initial) {
        t.set_active(true);
    }
    CURRENT.with(|c| *c.borrow_mut() = Rc::downgrade(&login));
    let weak = Rc::downgrade(&login);
    column.connect_destroy(move |_| {
        if let Some(l) = weak.upgrade() {
            if let Some(h) = l.cancel.borrow_mut().take() {
                h.abort();
            }
        }
    });
    keep_alive(&column, login);
    if embedded {
        return column;
    }
    outer.append(&stage(&column, 1.95 * pace));
    outer
}

pub fn select_provider(p: GitProvider) {
    if let Some(l) = CURRENT.with(|c| c.borrow().upgrade()) {
        l.select(p);
    }
}

pub fn build() -> gtk::Widget {
    let column = form(false, None);
    pad(&column, 40);
    column.set_halign(gtk::Align::Center);
    column.set_size_request(480, -1);

    let clamp = adw::Clamp::new();
    clamp.set_maximum_size(640);
    clamp.set_child(Some(&column));
    let scroll = scrolled(&clamp);
    let page = vbox(0);
    page.add_css_class("onboarding");
    let tv = adw::ToolbarView::new();
    let hb = adw::HeaderBar::new();
    hb.set_show_title(false);
    tv.add_top_bar(&hb);
    tv.set_content(Some(&scroll));
    page.append(&tv);
    tv.set_vexpand(true);
    page.upcast()
}

pub fn add_account_sheet() {
    let sheet = super::dialogs::Sheet::new("Add account", 560, 680);
    let d = sheet.dialog.clone();
    let done: Rc<dyn Fn()> = Rc::new(move || {
        d.close();
    });
    sheet.body.append(&form(true, Some(done)));
    sheet.add_footer_spacer();
    sheet.cancel_button();
    sheet.present();
}
