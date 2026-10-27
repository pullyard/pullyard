use adw::prelude::*;

use super::menu::Menu;
use super::widgets::*;
use crate::api::models::{Route, SearchItem};
use crate::{app, util};

fn prefix(item: &SearchItem) -> &'static str {
    if item.forge && item.is_pr() {
        app::number_prefix()
    } else {
        "#"
    }
}

pub fn spoken_label(item: &SearchItem) -> String {
    let mut parts = vec![item.title.clone(), format!("{}{}{}", item.repository.name_with_owner, prefix(item), item.number)];
    if let Some(login) = item.author.as_ref().map(|a| a.login.as_str()).filter(|l| !l.is_empty()) {
        parts.push(format!("by {login}"));
    }
    parts.push(item.visual_state().title().to_string());
    if item.is_pr() {
        match item.ci_state().as_deref() {
            Some("SUCCESS") => parts.push("checks passed".into()),
            Some("FAILURE") | Some("ERROR") => parts.push("checks failed".into()),
            Some("PENDING") | Some("EXPECTED") => parts.push("checks running".into()),
            _ => {}
        }
        match item.review_decision.as_deref() {
            Some("APPROVED") => parts.push("approved".into()),
            Some("CHANGES_REQUESTED") => parts.push("changes requested".into()),
            Some("REVIEW_REQUIRED") => parts.push("review required".into()),
            _ => {}
        }
    }
    let comments = item.comments.total_count;
    if comments > 0 {
        parts.push(format!("{comments} {}", if comments == 1 { "comment" } else { "comments" }));
    }
    parts.push(format!("updated {}", util::rel(Some(item.updated_at))));
    parts.join(", ")
}

pub fn describe_row(row: &gtk::ListBoxRow, item: &SearchItem) {
    row.set_tooltip_text(Some(&item.title));
    row.update_property(&[gtk::accessible::Property::Label(&spoken_label(item))]);
}

pub fn item_row(item: &SearchItem, show_repo: bool) -> gtk::Box {
    let row = hbox(10);
    margins(&row, 4, 0, 4, 0);
    row.append(&state_badge(item.visual_state(), true));
    let col = vbox(4);
    col.set_hexpand(true);
    let title = wrap_label(&item.title, &["sy-row-title"]);
    title.set_lines(2);
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    col.append(&title);
    let meta = hbox(5);
    meta.add_css_class("sy-row-meta");
    let where_ = if show_repo { format!("{}{}{}", item.repository.name_with_owner, prefix(item), item.number) } else { format!("{}{}", prefix(item), item.number) };
    let reference = label(&where_);
    reference.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    meta.append(&reference);
    meta.append(&label_with("·", &["sy-dim"]));
    meta.append(&label(&util::rel(Some(item.updated_at))));
    meta.append(&spacer());
    if item.is_pr() {
        if let (Some(a), Some(d)) = (item.additions, item.deletions) {
            meta.append(&diff_stat(a, d));
        }
    }
    col.append(&meta);
    let info = hbox(6);
    info.add_css_class("sy-row-meta");
    info.append(&ringed_avatar(item.author.as_ref().and_then(|a| a.avatar_url.as_deref()), 18, None));
    let author = label(item.author.as_ref().map(|a| a.login.as_str()).unwrap_or(""));
    author.set_ellipsize(gtk::pango::EllipsizeMode::End);
    info.append(&author);
    info.append(&spacer());
    let status = hbox(8);
    if item.is_pr() {
        if let Some(ci) = ci_icon(item.ci_state().as_deref()) {
            status.append(&ci);
        }
        match item.review_decision.as_deref() {
            Some("APPROVED") => status.append(&status_icon("sy-check-symbolic", 12, "green", "Approved")),
            Some("CHANGES_REQUESTED") => status.append(&status_icon("sy-plusminus-symbolic", 12, "red", "Changes requested")),
            Some("REVIEW_REQUIRED") => status.append(&status_icon("sy-eye-symbolic", 12, "muted", "Review required")),
            _ => {}
        }
    }
    if item.comments.total_count > 0 {
        let c = hbox(3);
        c.append(&colored_icon("sy-comment-symbolic", 11, "muted"));
        c.append(&label(&item.comments.total_count.to_string()));
        let n = item.comments.total_count;
        c.set_tooltip_text(Some(&format!("{n} {}", if n == 1 { "comment" } else { "comments" })));
        status.append(&c);
    }
    info.append(&status);
    col.append(&info);
    if let Some(base) = item.stacked_on() {
        let s = hbox(4);
        s.append(&colored_icon("sy-stack-symbolic", 12, "indigo"));
        let l = label_with(&format!("stacked on {base}"), &["fg-indigo", "sy-small"]);
        l.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        s.append(&l);
        s.set_tooltip_text(Some(&base));
        col.append(&s);
    }
    let labels = item.labels();
    if !labels.is_empty() {
        let lb = hbox(4);
        for l in labels.iter().take(4) {
            lb.append(&label_chip(l));
        }
        col.append(&lb);
    }
    row.append(&col);
    row
}

pub fn copy_short_link(route: &Route) {
    if let Some(link) = route.short_link() {
        util::copy(&link);
        app::toast(&format!("Copied {link}"));
    }
}

pub fn short_link_button(route: &Route) -> gtk::Button {
    let b = gtk::Button::with_label("#");
    b.add_css_class("flat");
    b.add_css_class("sy-mono");
    b.add_css_class("sy-bold");
    let link = route.short_link().unwrap_or_default();
    b.set_tooltip_text(Some(&format!("Copy short link {link} (Ctrl+Shift+C)")));
    set_label(&b, "Copy short link");
    let r = route.clone();
    b.connect_clicked(move |_| copy_short_link(&r));
    b
}

pub fn item_menu(item: &SearchItem) -> Menu {
    let menu = Menu::ctx();
    let url = item.url.clone();
    menu.item("Open in Browser", move || util::open_url(&url));
    let url = item.url.clone();
    menu.item("Copy Link", move || util::copy(&url));
    let route = item.route();
    if route.short_link().is_some() {
        menu.item("Copy Short Link", move || copy_short_link(&route));
    }
    if item.is_pr() && !item.forge {
        let cmd = format!("gh pr checkout {} -R {}", item.number, item.repository.name_with_owner);
        menu.item("Copy “gh pr checkout”", move || util::copy(&cmd));
    }
    menu
}
