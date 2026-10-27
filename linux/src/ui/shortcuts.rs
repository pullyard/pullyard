use adw::prelude::*;

use crate::app;

type Group = (&'static str, &'static [(&'static str, &'static str)]);

const GROUPS: &[Group] = &[
    (
        "General",
        &[
            ("Command palette", "<Control>k"),
            ("Open by link", "<Control>l"),
            ("Refresh", "<Control>r"),
            ("Back", "<Alt>Left"),
            ("Copy short link", "<Control><Shift>c"),
            ("Preferences", "<Control>comma"),
            ("Keyboard shortcuts", "<Control>question"),
            ("Quit", "<Control>q"),
        ],
    ),
    (
        "Sections",
        &[
            ("Review requests", "<Control>1"),
            ("Created by me", "<Control>2"),
            ("Notifications", "<Control>3"),
            ("Repositories", "<Control>4"),
            ("Projects", "<Control>5"),
            ("Agents", "<Control>6"),
        ],
    ),
    (
        "Agents",
        &[
            ("Go to session", "<Control><Shift>k"),
            ("New agent session", "<Control>n"),
            ("Next session", "<Control><Shift>bracketright"),
            ("Previous session", "<Control><Shift>bracketleft"),
            ("Send message", "Return"),
            ("New line", "<Shift>Return"),
            ("Stop the agent", "Escape"),
        ],
    ),
    (
        "Pull request files",
        &[
            ("Next file", "n"),
            ("Previous file", "p"),
            ("Next hunk", "bracketright"),
            ("Previous hunk", "bracketleft"),
            ("Mark file as viewed", "v"),
            ("Wrap lines", "w"),
            ("Unified or split diff", "s"),
            ("Send comment", "<Control>Return"),
        ],
    ),
    ("Repositories", &[("Go to file", "<Control>p"), ("Toggle blame", "<Control><Alt>b")]),
    ("Text size", &[("Zoom in", "<Control>plus"), ("Zoom out", "<Control>minus"), ("Actual size", "<Control>0")]),
];

pub fn show() {
    let section = gtk::ShortcutsSection::builder().section_name("main").title("Shortcuts").build();
    for (title, items) in GROUPS {
        let group = gtk::ShortcutsGroup::builder().title(*title).build();
        for (name, accel) in items.iter() {
            group.add_shortcut(&gtk::ShortcutsShortcut::builder().title(*name).accelerator(*accel).build());
        }
        section.add_group(&group);
    }
    let mut builder = gtk::ShortcutsWindow::builder().modal(true).title("Keyboard Shortcuts");
    if let Some(win) = app::main_window() {
        builder = builder.transient_for(&win);
    }
    let window = builder.build();
    window.add_section(&section);
    window.present();
}
