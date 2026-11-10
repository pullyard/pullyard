use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;

use crate::claude::accounts::{self, LoginMethod, Status};
use crate::claude::endpoint::{self, AgentEndpoint, Kind, OPENROUTER_ACTIVITY_URL, OPENROUTER_KEYS_URL, OPENROUTER_URL};
use crate::settings::ClaudeProfile;
use crate::ui::dialogs::{self, Sheet};
use crate::ui::menu::Menu;
use crate::ui::widgets::*;
use crate::{app, brand, util};

pub const INSTALL_COMMAND: &str = "curl -fsSL https://claude.ai/install.sh | bash";

pub fn switch_profile(id: &str) {
    if id == accounts::active_id() || !accounts::is_visible(id) {
        return;
    }
    let a = app::get();
    a.claude.close_all_for_profile_switch();
    accounts::set_active(id);
    crate::claude::chat::USAGE.with(|u| {
        let mut u = u.borrow_mut();
        u.windows.clear();
        u.subscription = None;
    });
    let store = accounts::store();
    *store.status.borrow_mut() = Status::Checking;
    store.changed.emit(&());
    let ws = a.claude.clone();
    crate::rt::spawn_local(async move {
        store.refresh().await;
        ws.reload_projects().await;
    });
}

pub fn remove_profile(p: &ClaudeProfile) {
    if p.is_default() {
        return;
    }
    if accounts::active_id() == p.id {
        match accounts::visible().into_iter().find(|o| o.id != p.id) {
            Some(other) => switch_profile(&other.id),
            None => {
                if let Ok(fresh) = accounts::add("Claude", false) {
                    switch_profile(&fresh.id);
                }
            }
        }
    }
    let dir = p.config_dir.clone();
    let id = p.id.clone();
    crate::rt::spawn_local(async move {
        accounts::store().logout(dir).await;
        accounts::remove(&id);
        accounts::store().changed.emit(&());
    });
}

pub fn profile_badge(p: &ClaudeProfile, size: i32) -> gtk::Box {
    let color = if p.is_default() { "coral" } else { crate::theme::palette_for(&p.id) };
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    b.add_css_class("state-dot");
    b.add_css_class(color);
    b.set_size_request(size, size);
    b.set_valign(gtk::Align::Center);
    b.set_halign(gtk::Align::Center);
    b.set_hexpand(false);
    b.set_vexpand(false);
    let l = label_with(&p.initial(), &["sy-bold", &format!("fg-{color}")]);
    l.set_hexpand(true);
    l.set_xalign(0.5);
    b.append(&l);
    b
}

pub fn profile_menu(menu: &mut Menu) {
    menu.section(Some("Claude accounts"));
    let active = accounts::active_id();
    for p in accounts::visible() {
        let text = format!("{}{}{}", if p.id == active { "✓ " } else { "" }, p.label, p.email.as_ref().map(|e| format!(" — {e}")).unwrap_or_default());
        let id = p.id.clone();
        menu.item(&text, move || switch_profile(&id));
    }
    menu.section(None);
    menu.item("Add account…", add_profile_sheet);
    let a = accounts::active();
    if !a.is_default() {
        let label = a.label.clone();
        menu.item(&format!("Remove “{label}”…"), move || {
            let p = accounts::active();
            let p2 = p.clone();
            dialogs::confirm(
                "Remove account?",
                Some(&format!("The app signs out of this account and removes it from the list. Its history folder stays on disk: {}", p.config_dir.clone().unwrap_or_default())),
                &format!("Sign out and remove “{}”", p.label),
                true,
                move || remove_profile(&p2),
            );
        });
    }
}

pub fn profile_switcher() -> gtk::MenuButton {
    let active = accounts::active();
    let b = gtk::MenuButton::new();
    let content = hbox(6);
    content.append(&profile_badge(&active, 18));
    content.append(&label_with(&active.label, &["sy-text"]));
    let n = accounts::visible().len();
    if n > 1 {
        content.append(&label_with(&n.to_string(), &["sy-muted", "sy-tiny"]));
    }
    b.set_child(Some(&content));
    b.add_css_class("flat");
    b.set_tooltip_text(Some("Switch Claude account"));
    let mut menu = Menu::new();
    profile_menu(&mut menu);
    menu.apply_to(&b);
    b
}

pub fn add_profile_sheet() {
    profile_sheet(None);
}

pub fn edit_endpoint_sheet(profile: ClaudeProfile) {
    profile_sheet(Some(profile));
}

fn profile_sheet(editing: Option<ClaudeProfile>) {
    let editing_endpoint = editing.as_ref().and_then(|p| p.endpoint.clone());
    let sheet = Sheet::new(if editing.is_some() { "Edit endpoint" } else { "New Claude account" }, 500, -1);
    let access: Rc<Cell<Option<Kind>>> = Rc::new(Cell::new(editing_endpoint.as_ref().map(|e| e.kind)));
    let toggles = hbox(0);
    toggles.add_css_class("linked");
    let mut choices: Vec<(gtk::ToggleButton, Option<Kind>)> = vec![];
    let mut first: Option<gtk::ToggleButton> = None;
    for (title, kind) in std::iter::once(("Claude sign-in", None)).chain(Kind::ALL.into_iter().map(|k| (k.title(), Some(k)))) {
        let t = gtk::ToggleButton::with_label(title);
        t.set_hexpand(true);
        match &first {
            Some(f) => t.set_group(Some(f)),
            None => first = Some(t.clone()),
        }
        t.set_active(access.get() == kind);
        toggles.append(&t);
        choices.push((t, kind));
    }
    let intro = wrap_label("", &["sy-muted"]);
    let entry = gtk::Entry::new();
    if editing.is_none() {
        sheet.body.append(&toggles);
        sheet.body.append(&intro);
        sheet.body.append(&entry);
    }
    let fields = vbox(8);
    let base_url = gtk::Entry::new();
    base_url.set_placeholder_text(Some("Base URL, e.g. https://gateway.example.com"));
    base_url.set_text(editing_endpoint.as_ref().map(|e| e.base_url.as_str()).unwrap_or(OPENROUTER_URL));
    fields.append(&base_url);
    let key = gtk::PasswordEntry::new();
    key.set_show_peek_icon(true);
    fields.append(&key);
    let model = gtk::Entry::new();
    model.set_text(editing_endpoint.as_ref().and_then(|e| e.model.as_deref()).unwrap_or(""));
    fields.append(&model);
    fields.append(&wrap_label(
        "The key is stored in the system keyring and passed only to Claude Code for this account. Your Claude sign-in is not used here; Remote Control and plan usage limits are not available.",
        &["sy-muted", "sy-small"],
    ));
    let get_key = link_button("Get an OpenRouter key");
    get_key.set_halign(gtk::Align::Start);
    get_key.connect_clicked(|_| util::open_url(OPENROUTER_KEYS_URL));
    fields.append(&get_key);
    sheet.body.append(&fields);
    let share = gtk::CheckButton::with_label("Use my settings, CLAUDE.md, skills and plugins from the main account");
    let owns_main = accounts::owns_main();
    share.set_active(owns_main);
    share.set_visible(owns_main && editing.is_none());
    sheet.body.append(&share);
    let error = label_with("", &["fg-red", "sy-small"]);
    error.set_visible(false);
    sheet.body.append(&error);
    sheet.add_footer_spacer();
    sheet.cancel_button();
    let create = tinted("Create and sign in", "coral");
    sheet.footer.append(&create);
    let is_edit = editing.is_some();
    let update = {
        let (access, intro, entry, base_url, key, model, fields, get_key, create, error) = (access.clone(), intro.clone(), entry.clone(), base_url.clone(), key.clone(), model.clone(), fields.clone(), get_key.clone(), create.clone(), error.clone());
        Rc::new(move || {
            let kind = access.get();
            intro.set_text(if kind.is_none() {
                "The account gets its own sign-in, session history and limits. Sign-in opens right after."
            } else {
                "Claude Code sends requests to this endpoint with your API key. Usage is billed by the endpoint, not your Claude plan."
            });
            entry.set_placeholder_text(Some(if kind == Some(Kind::OpenRouter) { "Name, e.g. “OpenRouter”" } else { "Name, e.g. “Personal” or “Work”" }));
            fields.set_visible(kind.is_some());
            base_url.set_visible(kind == Some(Kind::Custom));
            get_key.set_visible(kind == Some(Kind::OpenRouter));
            key.set_placeholder_text(Some(if is_edit {
                "API key (leave empty to keep the saved key)"
            } else if kind == Some(Kind::OpenRouter) {
                "OpenRouter API key (sk-or-…)"
            } else {
                "API key"
            }));
            model.set_placeholder_text(Some(if kind == Some(Kind::OpenRouter) { "Model (optional), e.g. anthropic/claude-sonnet-4.5" } else { "Model (optional)" }));
            create.set_label(if is_edit {
                "Save"
            } else if kind.is_none() {
                "Create and sign in"
            } else {
                "Create"
            });
            error.set_visible(false);
        })
    };
    update();
    for (t, kind) in &choices {
        let (access, base_url, update, kind) = (access.clone(), base_url.clone(), update.clone(), *kind);
        t.connect_toggled(move |b| {
            if !b.is_active() {
                return;
            }
            access.set(kind);
            if kind == Some(Kind::OpenRouter) {
                base_url.set_text(OPENROUTER_URL);
            }
            if kind == Some(Kind::Custom) && base_url.text() == OPENROUTER_URL {
                base_url.set_text("");
            }
            update();
        });
    }
    let key_input = key.clone();
    let d = sheet.dialog.clone();
    let e = entry.clone();
    let busy = Rc::new(Cell::new(false));
    let go = Rc::new(move || {
        if busy.get() {
            return;
        }
        error.set_visible(false);
        let fail = {
            let error = error.clone();
            move |msg: &str| {
                error.set_text(msg);
                error.set_visible(true);
            }
        };
        let Some(kind) = access.get() else {
            match accounts::add(&e.text(), owns_main && share.is_active()) {
                Ok(p) => {
                    switch_profile(&p.id);
                    app::set_section(app::Section::Claude);
                    d.close();
                }
                Err(msg) => fail(&msg),
            }
            return;
        };
        if let Some(problem) = AgentEndpoint::problem(&base_url.text()) {
            fail(problem);
            return;
        }
        let trimmed_key = key.text().trim().to_string();
        let trimmed_model = model.text().trim().to_string();
        let endpoint = AgentEndpoint { kind, base_url: AgentEndpoint::normalized(&base_url.text()), model: if trimmed_model.is_empty() { None } else { Some(trimmed_model) } };
        if editing.is_none() && trimmed_key.is_empty() {
            fail("Enter the API key.");
            return;
        }
        busy.set(true);
        let (d, busy, editing) = (d.clone(), busy.clone(), editing.clone());
        let name = e.text().trim().to_string();
        let shared = owns_main && share.is_active();
        crate::rt::spawn_local(async move {
            let result = match &editing {
                Some(p) => accounts::update_endpoint(&p.id, endpoint, &trimmed_key).await.map(|_| None),
                None => accounts::add_endpoint(if name.is_empty() { kind.title() } else { &name }, shared, endpoint, &trimmed_key).await.map(Some),
            };
            busy.set(false);
            match result {
                Ok(Some(p)) => {
                    switch_profile(&p.id);
                    app::set_section(app::Section::Claude);
                    d.close();
                }
                Ok(None) => {
                    crate::rt::spawn_local(async { accounts::store().refresh().await });
                    d.close();
                }
                Err(msg) => fail(&msg),
            }
        });
    });
    let g = go.clone();
    create.connect_clicked(move |_| g());
    let g = go.clone();
    entry.connect_activate(move |_| g());
    let g = go.clone();
    key_input.connect_activate(move |_| g());
    sheet.present();
}

pub fn account_card(info: &accounts::AccountInfo, compact: bool) -> gtk::Box {
    let profile = accounts::active();
    let card = hbox(10);
    card.add_css_class("sy-card-flat");
    pad(&card, if compact { 8 } else { 14 });
    card.append(&profile_badge(&profile, if compact { 26 } else { 34 }));
    let col = vbox(1);
    col.set_hexpand(true);
    let top = hbox(5);
    let endpoint = profile.endpoint.clone();
    let title = endpoint.as_ref().map(|e| e.display_name()).or_else(|| info.email.clone()).unwrap_or_else(|| "Signed in".into());
    let email = ellipsized(&title, &["sy-text", if compact { "sy-bold" } else { "heading" }]);
    top.append(&email);
    if accounts::visible().len() > 1 {
        top.append(&chip(&profile.label, "muted", None, false));
    }
    col.append(&top);
    let sub = hbox(5);
    if let Some(e) = &endpoint {
        let model = ellipsized(&e.model_name().unwrap_or_else(|| "Default models".into()), &["sy-muted", "sy-small"]);
        model.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        sub.append(&model);
        if !endpoint::has_key(&profile.id) {
            sub.append(&colored_icon("sy-attention-symbolic", 12, "amber"));
            sub.append(&label_with("API key missing", &["fg-amber", "sy-small"]));
        }
    }
    if let Some(org) = &info.org_name {
        sub.append(&ellipsized(org, &["sy-muted", "sy-small"]));
    }
    if let Some(plan) = &info.subscription {
        sub.append(&chip(plan, "coral", None, false));
    } else if endpoint.is_none() && (info.method.as_deref() == Some("console") || info.provider.as_deref() != Some("firstParty")) {
        let label = if info.provider.as_deref() == Some("firstParty") { "API".to_string() } else { info.provider.clone().unwrap_or_else(|| "API".into()) };
        sub.append(&label_with(&label, &["sy-muted", "sy-tiny"]));
    }
    col.append(&sub);
    card.append(&col);
    let mut menu = Menu::new();
    profile_menu(&mut menu);
    menu.section(None);
    if let Some(e) = &endpoint {
        let p = profile.clone();
        menu.item("Edit endpoint…", move || edit_endpoint_sheet(p.clone()));
        if e.kind == Kind::OpenRouter {
            menu.item("OpenRouter activity", || util::open_url(OPENROUTER_ACTIVITY_URL));
        }
    } else {
        menu.item("Sign out of this account…", || {
            let body = if accounts::active().is_default() {
                "This also signs out Claude Code in the terminal. You can sign in again afterwards, including with another account.".to_string()
            } else {
                format!("Signs out only “{}”. Other accounts are not affected.", accounts::active().label)
            };
            dialogs::confirm("Sign out of Claude Code?", Some(&body), "Sign out", true, || {
                let a = app::get();
                a.claude.sleep_all();
                crate::rt::spawn_local(async { accounts::store().logout(None).await });
            });
        });
        menu.section(None);
        menu.item("Usage page", || util::open_url("https://claude.ai/settings/usage"));
    }
    menu.item("Refresh status", || crate::rt::spawn_local(async { accounts::store().refresh().await }));
    card.append(&menu.button("view-more-symbolic", "Account"));
    card
}

pub fn build() -> gtk::Widget {
    let column = vbox(18);
    pad(&column, 36);
    column.set_halign(gtk::Align::Center);
    let tile = icon_tile("sy-sparkles-symbolic", "coral", 56);
    column.append(&tile);
    let t = label_with("Agents", &["login-title", "sy-text"]);
    t.set_xalign(0.5);
    column.append(&t);
    let sub = label_with("Runs Claude Code, installed on this computer", &["sy-muted"]);
    sub.set_xalign(0.5);
    column.append(&sub);
    let switcher = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    switcher.set_halign(gtk::Align::Center);
    column.append(&switcher);
    let content = vbox(10);
    column.append(&content);
    let clamp = adw::Clamp::new();
    clamp.set_maximum_size(520);
    clamp.set_child(Some(&column));
    let scroll = scrolled(&clamp);
    scroll.add_css_class("sy-panel-pane");
    let method = Rc::new(Cell::new(LoginMethod::ClaudeAi));
    let email = Rc::new(RefCell::new(String::new()));
    let render = {
        let content_w = content.downgrade();
        let switcher_w = switcher.downgrade();
        let method = method.clone();
        let email = email.clone();
        Rc::new(move || -> bool {
            let (Some(content), Some(switcher)) = (content_w.upgrade(), switcher_w.upgrade()) else { return false };
            clear(&switcher);
            switcher.append(&profile_switcher());
            clear(&content);
            let store = accounts::store();
            let status = store.status.borrow().clone();
            match status {
                Status::NotInstalled => content.append(&install_card()),
                Status::Unknown | Status::Checking => content.append(&spinner(18)),
                Status::LoggedOut => content.append(&login_card(method.clone(), email.clone())),
                Status::LoggedIn(info) => content.append(&account_card(&info, false)),
            }
            true
        })
    };
    render();
    let r = render.clone();
    accounts::store().changed.connect(move |_| r());
    crate::rt::spawn_local(async { accounts::store().refresh().await });
    scroll.upcast()
}

fn card() -> gtk::Box {
    let c = vbox(10);
    c.add_css_class("sy-card");
    c
}

fn install_card() -> gtk::Box {
    let c = card();
    c.append(&label_with("Claude Code isn't installed", &["heading"]));
    c.append(&wrap_label("Install the CLI from a terminal, then press “Check again”.", &["sy-muted"]));
    let cmd = selectable(label_with(INSTALL_COMMAND, &["sy-mono"]));
    pad(&cmd, 8);
    c.append(&frame(&cmd, "sy-sunken"));
    let row = hbox(6);
    let copy = button("Copy command");
    copy.connect_clicked(|_| util::copy(INSTALL_COMMAND));
    let docs = button("Docs");
    docs.connect_clicked(|_| util::open_url("https://code.claude.com/docs/en/setup"));
    row.append(&copy);
    row.append(&docs);
    row.append(&spacer());
    let again = tinted("Check again", "coral");
    again.connect_clicked(|_| {
        crate::host::forget("claude");
        crate::rt::spawn_local(async { accounts::store().refresh().await });
    });
    row.append(&again);
    c.append(&row);
    c
}

fn login_card(method: Rc<Cell<LoginMethod>>, email: Rc<RefCell<String>>) -> gtk::Box {
    let store = accounts::store();
    let c = card();
    c.append(&label_with("Sign in to Claude", &["heading"]));
    c.append(&wrap_label(
        &format!(
            "Sign-in runs in a terminal window, so the code from the sign-in page goes straight to Claude Code, never through {}. The account is shared with Claude Code in the terminal.",
            brand::APP_NAME
        ),
        &["sy-muted"],
    ));
    if store.logging_in.get() {
        let row = hbox(8);
        row.append(&spinner(14));
        row.append(&wrap_label("Finish the sign-in in the terminal window…", &["sy-text"]));
        c.append(&row);
        let actions = hbox(6);
        let again = button("Open terminal again");
        let (m, e) = (method.clone(), email.clone());
        again.connect_clicked(move |_| {
            let address = e.borrow().clone();
            accounts::store().login_in_terminal(m.get(), &address);
        });
        let check = button("Check again");
        check.connect_clicked(|_| accounts::store().check_login_now());
        let cancel = button("Cancel");
        cancel.connect_clicked(|_| accounts::store().cancel_login());
        actions.append(&again);
        actions.append(&check);
        actions.append(&spacer());
        actions.append(&cancel);
        c.append(&actions);
    } else {
        let mut first: Option<gtk::CheckButton> = None;
        for m in LoginMethod::ALL {
            let r = gtk::CheckButton::with_label(m.title());
            if let Some(f) = &first {
                r.set_group(Some(f));
            } else {
                first = Some(r.clone());
            }
            r.set_active(method.get() == m);
            let mm = method.clone();
            r.connect_toggled(move |b| {
                if b.is_active() {
                    mm.set(m);
                }
            });
            c.append(&r);
        }
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("Email (optional)"));
        entry.set_text(&email.borrow());
        let e = email.clone();
        entry.connect_changed(move |en| *e.borrow_mut() = en.text().to_string());
        c.append(&entry);
        let row = hbox(0);
        row.append(&spacer());
        let go = tinted("Sign in", "coral");
        go.set_tooltip_text(Some("Opens “claude auth login” in a terminal"));
        let (m, e) = (method.clone(), email.clone());
        let start = Rc::new(move || {
            let address = e.borrow().clone();
            accounts::store().login_in_terminal(m.get(), &address);
        });
        let st = start.clone();
        go.connect_clicked(move |_| st());
        entry.connect_activate(move |_| start());
        row.append(&go);
        c.append(&row);
    }
    if let Some(e) = store.login_error.borrow().clone() {
        c.append(&selectable(wrap_label(&e, &["fg-red", "sy-small"])));
    }
    c
}
