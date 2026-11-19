use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;

use super::claude::auth_view;
use super::dialogs;
use super::widgets::*;
use crate::claude::accounts::{self, Status};
use crate::claude::{prompt_library, usage_ledger, ClaudeMode, ModelOption, TabKind, EFFORTS};
use crate::git_accounts::{self, GitAccount, GitProvider};
use crate::{app, auth, settings, theme, updater, util};

fn combo(title: &str, options: &[&str], selected: usize, on_change: impl Fn(usize) + 'static) -> adw::ComboRow {
    let row = adw::ComboRow::new();
    row.set_title(title);
    row.set_model(Some(&gtk::StringList::new(options)));
    row.set_selected(selected as u32);
    row.connect_selected_notify(move |r| on_change(r.selected() as usize));
    row
}

fn switch(title: &str, subtitle: Option<&str>, active: bool, on_change: impl Fn(bool) + 'static) -> adw::SwitchRow {
    let row = adw::SwitchRow::new();
    row.set_title(title);
    if let Some(s) = subtitle {
        row.set_subtitle(s);
    }
    row.set_active(active);
    row.connect_active_notify(move |r| on_change(r.is_active()));
    row
}

fn group(title: &str, icon_name: &str, color: &str) -> adw::PreferencesGroup {
    let g = adw::PreferencesGroup::new();
    g.set_title(title);
    g.set_header_suffix(Some(&icon_tile(icon_name, color, 18)));
    g
}

fn account_group(dialog: &adw::PreferencesDialog) -> adw::PreferencesGroup {
    let g = group("Account", "sy-person-symbolic", "teal");
    let a = app::get();
    let (user, scopes, account) = {
        let s = a.state.borrow();
        (s.user.clone(), s.scopes.clone(), s.account.clone())
    };
    let provider = account.as_ref().map(|x| x.provider).unwrap_or(GitProvider::Github);
    match user {
        Some(u) => {
            let row = adw::ActionRow::new();
            let name = u.name.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| u.login.clone());
            row.set_title(&name);
            row.set_subtitle(&format!("{} · {}", provider.title(), account.as_ref().map(|x| x.subtitle()).unwrap_or_else(|| format!("@{}", u.login))));
            row.add_prefix(&avatar(u.avatar_url.as_deref(), 36, Some(&name)));
            g.add(&row);
            if provider.is_github() {
                let sc = adw::ActionRow::new();
                sc.set_title("Token scopes");
                sc.set_subtitle(&if scopes.is_empty() { "fine-grained / unknown".to_string() } else { scopes.join(", ") });
                sc.set_subtitle_selectable(true);
                g.add(&sc);
            }
            if let Some(acc) = account.clone() {
                g.add(&pin_row(acc));
            }
            let actions = adw::ActionRow::new();
            actions.set_title("Session");
            if provider.is_github() && auth::gh_available() {
                let refresh = button("Refresh token from gh");
                refresh.set_valign(gtk::Align::Center);
                let status_row = actions.downgrade();
                refresh.connect_clicked(move |b| {
                    b.set_sensitive(false);
                    b.set_label("Refreshing…");
                    if let Some(row) = status_row.upgrade() {
                        row.set_subtitle("");
                    }
                    let b = b.clone();
                    let status_row = status_row.clone();
                    crate::rt::spawn_local(async move {
                        let failure = app::get().refresh_token_from_gh().await;
                        b.set_label("Refresh token from gh");
                        b.set_sensitive(true);
                        if let Some(row) = status_row.upgrade() {
                            row.set_subtitle(&match failure {
                                Some(e) => format!("Couldn’t read the token from gh: {}", util::markup_esc(&e)),
                                None => "Token refreshed from gh.".to_string(),
                            });
                        }
                    });
                });
                actions.add_suffix(&refresh);
            }
            if let Some(acc) = account.clone() {
                let lock = button("Lock Now");
                lock.set_valign(gtk::Align::Center);
                lock.set_visible(false);
                let d = dialog.clone();
                lock.connect_clicked(move |_| {
                    d.close();
                    app::get().lock_now();
                });
                let shown = lock.downgrade();
                crate::rt::spawn_local(async move {
                    if crate::account_lock::is_protected(&acc.id).await {
                        if let Some(lock) = shown.upgrade() {
                            lock.set_visible(true);
                        }
                    }
                });
                actions.add_suffix(&lock);
            }
            let add = button("Add account…");
            add.set_valign(gtk::Align::Center);
            let d = dialog.clone();
            add.connect_clicked(move |_| {
                d.close();
                super::login::add_account_sheet();
            });
            actions.add_suffix(&add);
            let out = destructive("Sign out…");
            out.set_valign(gtk::Align::Center);
            let d = dialog.clone();
            out.connect_clicked(move |_| {
                d.close();
                super::accounts::confirm_sign_out();
            });
            actions.add_suffix(&out);
            g.add(&actions);
            for other in git_accounts::accounts().into_iter().filter(|x| account.as_ref().is_none_or(|c| c.id != x.id)) {
                let r = adw::ActionRow::new();
                r.set_title(&other.display_name());
                r.set_subtitle(&format!("{} · {}", other.provider.title(), other.subtitle()));
                r.add_prefix(&avatar(other.avatar_url.as_deref(), 28, Some(&other.display_name())));
                let switch = button("Switch…");
                switch.set_valign(gtk::Align::Center);
                let d = dialog.clone();
                switch.connect_clicked(move |_| {
                    d.close();
                    super::accounts::confirm_switch(other.clone());
                });
                r.add_suffix(&switch);
                g.add(&r);
            }
        }
        None => {
            let row = adw::ActionRow::new();
            row.set_title("Not signed in");
            g.add(&row);
        }
    }
    g
}

fn pin_row(account: GitAccount) -> adw::SwitchRow {
    let row = adw::SwitchRow::new();
    row.set_title("Require PIN for this account");
    row.set_subtitle("Asked when the app starts with this account and when switching to it.");
    row.set_sensitive(false);
    let guard = Rc::new(Cell::new(true));
    let r = row.clone();
    let g = guard.clone();
    let id = account.id.clone();
    crate::rt::spawn_local(async move {
        let on = crate::account_lock::is_protected(&id).await;
        r.set_active(on);
        r.set_sensitive(true);
        g.set(false);
    });
    row.connect_active_notify(move |r| {
        if guard.get() {
            return;
        }
        let want = r.is_active();
        guard.set(true);
        r.set_active(!want);
        guard.set(false);
        let (row, g) = (r.clone(), guard.clone());
        let settle: Rc<dyn Fn(bool)> = Rc::new(move |on| {
            g.set(true);
            row.set_active(on);
            g.set(false);
            app::get().refresh_lockable();
        });
        if want {
            let done = settle.clone();
            super::unlock::set_pin_sheet(&account, Rc::new(move || done(true)));
        } else {
            let done = settle.clone();
            let id = account.id.clone();
            super::unlock::unlock_sheet(
                &account,
                "Enter the PIN to turn it off",
                Rc::new(move || {
                    let (id, done) = (id.clone(), done.clone());
                    crate::rt::spawn_local(async move {
                        crate::account_lock::remove(&id).await;
                        done(false);
                    });
                }),
            );
        }
    });
    row
}

fn claude_group(dialog: &adw::PreferencesDialog) -> adw::PreferencesGroup {
    let g = group("Agents", "sy-sparkles-symbolic", "coral");
    let profiles = accounts::visible();
    let active = accounts::active_id();
    let names: Vec<String> = profiles.iter().map(|p| format!("{}{}", p.label, p.email.as_ref().map(|e| format!(" — {e}")).unwrap_or_default())).collect();
    let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
    let ids: Vec<String> = profiles.iter().map(|p| p.id.clone()).collect();
    let row = combo("Account", &refs, profiles.iter().position(|p| p.id == active).unwrap_or(0), move |i| {
        if let Some(id) = ids.get(i) {
            auth_view::switch_profile(id);
        }
    });
    let add = button("Add…");
    add.set_valign(gtk::Align::Center);
    let d = dialog.clone();
    add.connect_clicked(move |_| {
        d.close();
        auth_view::add_profile_sheet();
    });
    row.add_suffix(&add);
    g.add(&row);
    let status = accounts::store().status.borrow().clone();
    match status {
        Status::LoggedIn(info) => {
            let r = adw::ActionRow::new();
            r.set_title(info.email.as_deref().unwrap_or("Signed in"));
            r.set_subtitle(&[info.org_name.clone(), info.subscription.clone()].into_iter().flatten().collect::<Vec<_>>().join(" · "));
            let out = destructive("Sign out of Claude Code");
            out.set_valign(gtk::Align::Center);
            out.connect_clicked(|_| {
                dialogs::confirm(
                    "Sign out of Claude Code?",
                    Some("This also signs out Claude Code in the terminal. Open sessions will go to sleep. You can sign in again (including with another account) here or in the Agents section."),
                    "Sign out",
                    true,
                    || {
                        app::get().claude.sleep_all();
                        crate::rt::spawn_local(async { accounts::store().logout(None).await });
                    },
                );
            });
            r.add_suffix(&out);
            g.add(&r);
        }
        Status::NotInstalled => {
            let r = adw::ActionRow::new();
            r.set_title("claude CLI isn't installed");
            r.set_subtitle(auth_view::INSTALL_COMMAND);
            r.set_subtitle_selectable(true);
            g.add(&r);
        }
        _ => {
            let r = adw::ActionRow::new();
            r.set_title("Not signed in to Claude");
            let b = button("Sign in…");
            b.set_valign(gtk::Align::Center);
            let d = dialog.clone();
            b.connect_clicked(move |_| {
                d.close();
                app::set_section(app::Section::Claude);
                app::get().present();
            });
            r.add_suffix(&b);
            g.add(&r);
        }
    }
    let ws = app::get().claude.clone();
    let kinds = [TabKind::Chat, TabKind::Terminal];
    let w = ws.clone();
    g.add(&combo("Open new sessions as", &["Chat", "Terminal"], kinds.iter().position(|k| *k == ws.preferred_kind()).unwrap_or(0), move |i| {
        w.set_preferred_kind(kinds[i.min(kinds.len() - 1)]);
    }));
    let saved_model = ws.model_value();
    let mut model_keys: Vec<String> = ModelOption::ALL.iter().map(|m| m.key().to_string()).collect();
    let mut model_titles: Vec<String> = ModelOption::ALL.iter().map(|m| m.title().to_string()).collect();
    if !model_keys.contains(&saved_model) {
        model_keys.push(saved_model.clone());
        model_titles.push(saved_model.clone());
    }
    let model_labels: Vec<&str> = model_titles.iter().map(|t| t.as_str()).collect();
    let w = ws.clone();
    let selected_model = model_keys.iter().position(|k| *k == saved_model).unwrap_or(0);
    g.add(&combo("Model for new sessions", &model_labels, selected_model, move |i| {
        w.set_model_value(&model_keys[i.min(model_keys.len() - 1)]);
    }));
    let effort_labels: Vec<&str> = EFFORTS.iter().map(|e| if e.is_empty() { "Default" } else { *e }).collect();
    let saved_effort = ws.effort();
    let w = ws.clone();
    g.add(&combo("Effort for new sessions", &effort_labels, EFFORTS.iter().position(|e| *e == saved_effort).unwrap_or(0), move |i| {
        w.set_effort(EFFORTS[i.min(EFFORTS.len() - 1)]);
    }));
    let mode_labels: Vec<&str> = ClaudeMode::ALL.iter().map(|m| m.title()).collect();
    let saved_mode = ws.mode();
    let w = ws.clone();
    let mode_row = combo("Permission mode for new sessions", &mode_labels, ClaudeMode::ALL.iter().position(|m| *m == saved_mode).unwrap_or(0), move |i| {
        w.set_mode(ClaudeMode::ALL[i.min(ClaudeMode::ALL.len() - 1)]);
    });
    mode_row.set_subtitle(saved_mode.detail());
    mode_row.set_subtitle_lines(2);
    mode_row.connect_selected_notify(|r| {
        r.set_subtitle(ClaudeMode::ALL[(r.selected() as usize).min(ClaudeMode::ALL.len() - 1)].detail());
    });
    g.add(&mode_row);
    let w = ws.clone();
    g.add(&switch(
        "Remember changes made in the chat composer",
        Some("When on, picking a model, effort or mode in a chat also makes it the default for the next chats."),
        ws.remember_composer(),
        move |on| w.set_remember_composer(on),
    ));
    let minutes = [0i64, 5, 15, 30, 60];
    let labels = ["Never", "5 minutes", "15 minutes", "30 minutes", "1 hour"];
    let current = app::get().claude.idle_minutes();
    let idle = combo("Sleep idle sessions after", &labels, minutes.iter().position(|m| *m == current).unwrap_or(2), move |i| {
        app::get().claude.set_idle_minutes(minutes[i.min(minutes.len() - 1)]);
    });
    idle.set_subtitle("A sleeping session uses no memory: the claude process stops, the conversation stays, and the next message resumes it.");
    idle.set_subtitle_lines(3);
    g.add(&idle);
    g
}

fn saved_prompts_group() -> adw::PreferencesGroup {
    let g = group("Saved prompts", "sy-star-symbolic", "coral");
    g.set_description(Some("Save a prompt from the star menu in the chat composer, then pick it there to insert it into a message."));
    let saved = prompt_library::all();
    if saved.is_empty() {
        let row = adw::ActionRow::new();
        row.set_title("No saved prompts yet");
        g.add(&row);
    }
    for p in saved {
        let row = adw::ActionRow::new();
        row.set_use_markup(false);
        row.set_title(&p.title);
        row.set_subtitle(&p.text);
        row.set_subtitle_lines(2);
        let delete = icon_button("user-trash-symbolic", "Delete prompt");
        delete.set_valign(gtk::Align::Center);
        let (group_ref, row_ref) = (g.downgrade(), row.downgrade());
        delete.connect_clicked(move |_| {
            prompt_library::remove(&p.id);
            if let (Some(g), Some(row)) = (group_ref.upgrade(), row_ref.upgrade()) {
                g.remove(&row);
            }
        });
        row.add_suffix(&delete);
        g.add(&row);
    }
    g
}

fn usage_group() -> adw::PreferencesGroup {
    let g = group("Agent usage", "sy-gauge-symbolic", "amber");
    g.set_description(Some(&format!(
        "API-equivalent cost reported by Claude Code for chats run in {} on this computer. With a subscription this is not what you are billed.",
        crate::brand::APP_NAME
    )));
    let spans: [(&str, u64); 3] = [("Today", 1), ("Last 7 days", 7), ("Last 30 days", 30)];
    let mut values: Vec<gtk::Label> = vec![];
    for (title, days) in spans {
        let row = adw::ActionRow::new();
        row.set_title(title);
        let value = label_with(&usage_ledger::summary(usage_ledger::total(days)), &["sy-muted"]);
        row.add_suffix(&value);
        values.push(value);
        g.add(&row);
    }
    let reset = adw::ActionRow::new();
    reset.set_title("Usage history");
    reset.set_subtitle("Kept on this computer for the last 120 days with activity.");
    let clear = button("Clear");
    clear.set_valign(gtk::Align::Center);
    clear.set_sensitive(!usage_ledger::is_empty());
    clear.connect_clicked(move |b| {
        usage_ledger::clear();
        let empty = usage_ledger::summary(usage_ledger::Day::default());
        for v in &values {
            v.set_text(&empty);
        }
        b.set_sensitive(false);
    });
    reset.add_suffix(&clear);
    g.add(&reset);
    g
}

pub fn show() {
    let dialog = adw::PreferencesDialog::new();
    dialog.set_title("Preferences");
    let page = adw::PreferencesPage::new();
    page.set_title("General");
    page.set_icon_name(Some("emblem-system-symbolic"));

    let appearance = group("Appearance", "preferences-desktop-appearance-symbolic", "violet");
    let style = settings::read(|s| s.theme_style.clone());
    appearance.add(&combo(
        "Theme",
        &[crate::brand::APP_NAME, "System"],
        if style == "system" { 1 } else { 0 },
        |i| {
            settings::update(|s| s.theme_style = if i == 1 { "system".into() } else { "pullyard".into() });
            theme::apply();
        },
    ));
    let modes = ["auto", "light", "dark"];
    let mode = settings::read(|s| s.appearance.clone());
    appearance.add(&combo("Mode", &["Match system", "Light", "Dark"], modes.iter().position(|m| *m == mode).unwrap_or(0), move |i| {
        settings::update(|s| s.appearance = modes[i.min(2)].to_string());
        theme::apply();
    }));
    let levels: Vec<String> = crate::text_zoom::LEVELS.iter().map(|l| if (l - 1.0).abs() < 0.001 { "100% (default)".to_string() } else { format!("{}%", (l * 100.0).round() as i64) }).collect();
    let level_refs: Vec<&str> = levels.iter().map(|s| s.as_str()).collect();
    let scale = crate::text_zoom::scale();
    let text_size = combo("Text size", &level_refs, crate::text_zoom::LEVELS.iter().position(|l| (l - scale).abs() < 0.001).unwrap_or(2), |i| {
        crate::text_zoom::set_scale(crate::text_zoom::LEVELS[i.min(crate::text_zoom::LEVELS.len() - 1)]);
    });
    text_size.set_subtitle("Also Ctrl++ and Ctrl+− in the main window");
    appearance.add(&text_size);
    page.add(&appearance);
    page.add(&account_group(&dialog));

    let links = group("Links", "sy-external-symbolic", "indigo");
    let browsers = util::installed_browsers();
    let mut names: Vec<String> = vec!["System default".into()];
    names.extend(browsers.iter().map(|b| b.name.clone()));
    let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
    let ids: Vec<String> = std::iter::once("system".to_string()).chain(browsers.iter().map(|b| b.id.clone())).collect();
    let current = settings::read(|s| s.link_browser.clone());
    let ids2 = ids.clone();
    let browser_row = combo("Open links in", &refs, ids.iter().position(|i| *i == current).unwrap_or(0), move |i| {
        let id = ids2.get(i).cloned().unwrap_or_else(|| "system".into());
        settings::update(|s| s.link_browser = id);
    });
    if util::is_flatpak() {
        browser_row.set_subtitle("Inside Flatpak, links open through the desktop portal.");
        browser_row.set_sensitive(false);
    }
    links.add(&browser_row);
    links.add(&switch("Offer to open a copied pull request or issue link", None, settings::read(|s| s.clipboard_watch), |v| settings::update(|s| s.clipboard_watch = v)));
    page.add(&links);

    let refresh = group("Refresh", "view-refresh-symbolic", "green");
    let intervals = [15.0, 30.0, 60.0, 120.0, 300.0, 900.0];
    let ilabels = ["Every 15 seconds", "Every 30 seconds", "Every minute", "Every 2 minutes", "Every 5 minutes", "Every 15 minutes"];
    let cur = settings::read(|s| s.poll_interval);
    refresh.add(&combo("Auto-refresh lists", &ilabels, intervals.iter().position(|v| (*v - cur).abs() < 0.5).unwrap_or(1), move |i| {
        settings::update(|s| s.poll_interval = intervals[i.min(intervals.len() - 1)]);
        app::get().start_polling();
    }));
    page.add(&refresh);

    let bg = group("Notifications", "sy-bell-symbolic", "amber");
    bg.set_description(Some(&format!(
        "Pull request alerts compare each refresh with the previous one, so nothing fires for what was already waiting when {} opened or switched accounts. Agent alerts only appear when you aren't looking at that session.",
        crate::brand::APP_NAME
    )));
    for kind in crate::activity::NotifyKind::ALL {
        bg.add(&switch(kind.title(), None, crate::notify::enabled(kind), move |v| crate::notify::set_enabled(kind, v)));
    }
    bg.add(&switch(
        "Keep running after the window is closed",
        Some("Reopen the window from the app launcher. Review requests and updates still notify you."),
        settings::read(|s| s.run_in_background),
        |v| settings::update(|s| s.run_in_background = v),
    ));
    page.add(&bg);

    if app::get().state.borrow().phase == app::Phase::LoggedIn {
        page.add(&claude_group(&dialog));
        page.add(&saved_prompts_group());
        page.add(&usage_group());
    }

    let updates = group("Updates", "sy-download-symbolic", "green");
    updates.add(&switch("Check for updates automatically", None, settings::read(|s| s.update_auto_check), |v| settings::update(|s| s.update_auto_check = v)));
    let ver = adw::ActionRow::new();
    ver.set_title(&format!("Current version {}", updater::current_version()));
    ver.set_subtitle(match updater::install_kind() {
        updater::InstallKind::Flatpak => "Installed as a Flatpak",
        updater::InstallKind::Package => "Installed from a package",
        updater::InstallKind::Portable => "Portable install",
    });
    let check = button("Check Now");
    check.set_valign(gtk::Align::Center);
    check.set_sensitive(!updater::is_busy());
    let d = dialog.clone();
    check.connect_clicked(move |_| {
        d.close();
        super::update::show(true);
    });
    ver.add_suffix(&check);
    updates.add(&ver);
    page.add(&updates);

    let jira_group = group("Jira", "sy-tag-symbolic", "sky");
    let jira_form = super::jira::connect_form();
    jira_form.add_css_class("card");
    pad(&jira_form, 12);
    jira_group.add(&jira_form);
    page.add(&jira_group);

    let oauth = group(if auth::built_in_client_id().is_some() { "Use your own OAuth App" } else { "OAuth Device Flow" }, "sy-key-symbolic", "amber");
    let entry = adw::EntryRow::new();
    entry.set_title("Client ID");
    entry.set_text(&settings::read(|s| s.oauth_client_id.clone()));
    entry.connect_changed(|e| {
        let v = e.text().to_string();
        settings::update(|s| s.oauth_client_id = v);
    });
    oauth.add(&entry);
    page.add(&oauth);

    let diag = group("Diagnostics", "sy-gauge-symbolic", "indigo");
    diag.add(&switch(
        "Diagnostics",
        Some("Record network requests, live refresh timings and slow UI work in memory to measure performance. Nothing leaves this device unless you export it."),
        settings::read(|s| s.diagnostics_enabled),
        |v| {
            settings::update(|s| s.diagnostics_enabled = v);
            crate::diagnostics::set_enabled(v);
        },
    ));
    let open_diag = adw::ActionRow::new();
    open_diag.set_title("Open diagnostics");
    open_diag.set_subtitle("Requests, sizes, durations, rate limits and live refresh timings");
    open_diag.set_activatable(true);
    open_diag.add_suffix(&icon("go-next-symbolic", 16));
    let d = dialog.clone();
    open_diag.connect_activated(move |_| {
        d.close();
        super::diagnostics::show();
    });
    diag.add(&open_diag);
    page.add(&diag);

    let support = group(&format!("Support {}", crate::brand::APP_NAME), "sy-star-symbolic", "coral");
    let pizza = adw::ActionRow::new();
    pizza.set_title("Buy me a pizza 🍕");
    pizza.set_subtitle(&format!("Pay what you want, from $3. {} stays free and open source.", crate::brand::APP_NAME));
    pizza.set_activatable(true);
    pizza.add_suffix(&icon("sy-external-symbolic", 16));
    pizza.connect_activated(|_| util::open_in_default_browser(crate::brand::DONATE_URL));
    support.add(&pizza);
    page.add(&support);

    dialog.add(&page);
    crate::rt::spawn_local(async { accounts::store().refresh().await });
    let w = app::main_window();
    dialog.present(w.as_ref());
}
