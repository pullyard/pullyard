use std::rc::Rc;

use serde_json::Value;

use super::chat::{ChatItem, ChatText, ToolCall, ToolStatus};
use crate::util;

#[derive(Clone)]
pub enum ToolStep {
    Call(Rc<ToolCall>),
    Thinking(Rc<ChatText>),
}

impl ToolStep {
    pub fn id(&self) -> String {
        match self {
            ToolStep::Call(c) => format!("c{}", c.id),
            ToolStep::Thinking(t) => format!("k{}", t.id),
        }
    }

    pub fn call(&self) -> Option<&Rc<ToolCall>> {
        match self {
            ToolStep::Call(c) => Some(c),
            ToolStep::Thinking(_) => None,
        }
    }
}

#[derive(Clone)]
pub enum DisplayItem {
    Item(ChatItem),
    Tools { id: String, steps: Vec<ToolStep> },
}

impl DisplayItem {
    pub fn id(&self) -> String {
        match self {
            DisplayItem::Item(item) => item.id(),
            DisplayItem::Tools { id, .. } => format!("g{id}"),
        }
    }

    pub fn item_ids(&self) -> Vec<String> {
        match self {
            DisplayItem::Item(item) => vec![item.id()],
            DisplayItem::Tools { steps, .. } => steps.iter().map(|s| s.id()).collect(),
        }
    }

    pub fn signature(&self) -> String {
        match self {
            DisplayItem::Item(item) => item.id(),
            DisplayItem::Tools { id, steps } => format!("g{id}|{}", steps.iter().map(|s| s.id()).collect::<Vec<_>>().join(",")),
        }
    }
}

pub fn groupable(call: &ToolCall) -> bool {
    if call.permission.borrow().as_ref().map(|p| !p.resolved.get()).unwrap_or(false) {
        return false;
    }
    !matches!(call.name.as_str(), "TodoWrite" | "ExitPlanMode" | "AskUserQuestion")
}

pub fn build(items: &[ChatItem]) -> Vec<DisplayItem> {
    let mut out: Vec<DisplayItem> = vec![];
    let mut run: Vec<ToolStep> = vec![];
    fn flush(out: &mut Vec<DisplayItem>, run: &mut Vec<ToolStep>) {
        let steps = std::mem::take(run);
        match steps.iter().find_map(|s| s.call().cloned()) {
            Some(first) => out.push(DisplayItem::Tools { id: first.id.clone(), steps }),
            None => {
                for s in steps {
                    if let ToolStep::Thinking(t) = s {
                        out.push(DisplayItem::Item(ChatItem::Thinking(t)));
                    }
                }
            }
        }
    }
    for item in items {
        match item {
            ChatItem::Tool(call) if groupable(call) => run.push(ToolStep::Call(call.clone())),
            ChatItem::Thinking(t) if !run.is_empty() => run.push(ToolStep::Thinking(t.clone())),
            _ => {
                flush(&mut out, &mut run);
                out.push(DisplayItem::Item(item.clone()));
            }
        }
    }
    flush(&mut out, &mut run);
    out
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Kind {
    Command,
    Read,
    Edit,
    Search,
    Web,
    Agent,
    Other,
}

impl Kind {
    pub const ALL: [Kind; 7] = [Kind::Command, Kind::Read, Kind::Edit, Kind::Search, Kind::Web, Kind::Agent, Kind::Other];

    pub fn of(name: &str) -> Kind {
        match name {
            "Bash" | "BashOutput" | "KillShell" => Kind::Command,
            "Read" => Kind::Read,
            "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => Kind::Edit,
            "Grep" | "Glob" => Kind::Search,
            "WebFetch" | "WebSearch" => Kind::Web,
            "Task" | "Agent" => Kind::Agent,
            _ => Kind::Other,
        }
    }

    fn verb(&self) -> &'static str {
        match self {
            Kind::Command | Kind::Agent => "ran",
            Kind::Read => "read",
            Kind::Edit => "edited",
            Kind::Search => "searched",
            Kind::Web => "fetched",
            Kind::Other => "used",
        }
    }

    fn noun(&self, n: usize) -> String {
        let (one, many) = match self {
            Kind::Command => ("command", "commands"),
            Kind::Read | Kind::Edit => ("file", "files"),
            Kind::Search => ("pattern", "patterns"),
            Kind::Web => ("page", "pages"),
            Kind::Agent => ("agent", "agents"),
            Kind::Other => ("tool", "tools"),
        };
        plural(n, one, many)
    }

    pub fn tint(&self) -> &'static str {
        match self {
            Kind::Command => "sky",
            Kind::Read => "violet",
            Kind::Edit => "coral",
            Kind::Search => "teal",
            Kind::Web => "indigo",
            Kind::Agent => "amber",
            Kind::Other => "muted",
        }
    }
}

pub fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

pub fn label(names: &[&str]) -> String {
    let mut counts = [0usize; 7];
    for n in names {
        counts[Kind::of(n) as usize] += 1;
    }
    let parts: Vec<String> = Kind::ALL.iter().filter(|k| counts[**k as usize] > 0).map(|k| format!("{} {}", k.verb(), k.noun(counts[*k as usize]))).collect();
    let text = parts.join(", ");
    let mut chars = text.chars();
    match chars.next() {
        Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
        None => text,
    }
}

pub fn icon(name: &str) -> &'static str {
    match name {
        "Read" => "sy-file-symbolic",
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "document-edit-symbolic",
        "Bash" | "BashOutput" | "KillShell" => "sy-terminal-symbolic",
        "Grep" | "WebSearch" => "system-search-symbolic",
        "Glob" => "sy-folder-symbolic",
        "WebFetch" => "sy-globe-symbolic",
        "Task" | "Agent" => "sy-person-symbolic",
        "TodoWrite" => "sy-checklist-symbolic",
        "AskUserQuestion" => "sy-comment-symbolic",
        "ExitPlanMode" => "sy-checklist-symbolic",
        "Skill" => "sy-sparkles-symbolic",
        n if n.starts_with("mcp__") => "sy-project-symbolic",
        _ => "emblem-system-symbolic",
    }
}

pub fn kind_icons(names: &[&str]) -> Vec<(&'static str, &'static str)> {
    let mut seen: Vec<(&'static str, &'static str)> = vec![];
    for n in names {
        let i = icon(n);
        if !seen.iter().any(|(x, _)| *x == i) {
            seen.push((i, Kind::of(n).tint()));
        }
    }
    seen.truncate(4);
    seen
}

pub fn relative(path: &str, folder: &str) -> String {
    match path.strip_prefix(&format!("{folder}/")) {
        Some(r) => r.to_string(),
        None => util::tilde(path),
    }
}

pub fn tool_title(c: &ToolCall) -> String {
    if c.name.starts_with("mcp__") {
        return c.name.split('_').filter(|s| !s.is_empty()).next_back().unwrap_or(&c.name).to_string();
    }
    c.name.clone()
}

pub fn tool_summary(c: &ToolCall, folder: &str) -> String {
    let i = c.input.borrow();
    let g = |k: &str| i.get(k).and_then(|v| v.as_str()).map(|s| s.to_string());
    match c.name.as_str() {
        "Read" | "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => relative(&g("file_path").or_else(|| g("notebook_path")).unwrap_or_default(), folder),
        "Bash" => g("description").or_else(|| g("command")).unwrap_or_default(),
        "Grep" => format!("\"{}\"{}", g("pattern").unwrap_or_default(), g("path").map(|p| format!(" · {}", relative(&p, folder))).unwrap_or_default()),
        "Glob" => g("pattern").unwrap_or_default(),
        "WebFetch" => g("url").unwrap_or_default(),
        "WebSearch" => g("query").unwrap_or_default(),
        "Task" | "Agent" => g("description").unwrap_or_default(),
        "Skill" => g("skill").unwrap_or_default(),
        _ => match i.values().find_map(|v| v.as_str()) {
            Some(s) => s.chars().take(120).collect(),
            None => {
                if c.partial_input.borrow().is_empty() {
                    String::new()
                } else {
                    "…".into()
                }
            }
        },
    }
}

pub fn step_title(c: &ToolCall, folder: &str) -> String {
    let i = c.input.borrow();
    let g = |k: &str| i.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    match c.name.as_str() {
        "Bash" => {
            let d = g("description");
            if !d.is_empty() {
                return d;
            }
            let cmd = g("command");
            match cmd.lines().next() {
                Some(l) if !l.trim().is_empty() => l.to_string(),
                _ => "Command".into(),
            }
        }
        "Read" => format!("Read {}", relative(&g("file_path"), folder)),
        "Edit" | "MultiEdit" => format!("Edited {}", relative(&g("file_path"), folder)),
        "Write" => format!("Wrote {}", relative(&g("file_path"), folder)),
        "NotebookEdit" => format!("Edited {}", relative(&g("notebook_path"), folder)),
        "Grep" => format!("Searched for \"{}\"", g("pattern")),
        "Glob" => format!("Found files matching {}", g("pattern")),
        "WebFetch" => format!("Fetched {}", url::Url::parse(&g("url")).ok().and_then(|u| u.host_str().map(|h| h.to_string())).unwrap_or_else(|| "page".into())),
        "WebSearch" => format!("Searched the web for \"{}\"", g("query")),
        "Task" | "Agent" => {
            let d = g("description");
            format!("Agent: {}", if d.is_empty() { "task".to_string() } else { d })
        }
        _ => {
            let summary = tool_summary(c, folder);
            if summary.is_empty() {
                tool_title(c)
            } else {
                format!("{} {summary}", tool_title(c))
            }
        }
    }
}

pub fn group_header(calls: &[Rc<ToolCall>], folder: &str) -> (String, bool) {
    match calls.iter().rev().find(|c| c.status.get() == ToolStatus::Running) {
        Some(running) => (format!("Running: {}", step_title(running, folder)), true),
        None => {
            let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
            (label(&names), false)
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Todo {
    pub title: String,
    pub content: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TodoProgress {
    pub todos: Vec<Todo>,
    pub done: usize,
    pub current: Option<String>,
}

impl TodoProgress {
    pub fn key(&self) -> String {
        self.todos.iter().map(|t| format!("{}:{}", t.status, t.content)).collect::<Vec<_>>().join("|")
    }
}

pub fn latest_todos(items: &[ChatItem]) -> Vec<Value> {
    for item in items.iter().rev() {
        if let ChatItem::Tool(c) = item {
            if c.name == "TodoWrite" {
                if let Some(t) = c.input.borrow().get("todos").and_then(|t| t.as_array()) {
                    return t.clone();
                }
            }
        }
    }
    vec![]
}

pub fn todo_progress(todos: &[Value]) -> Option<TodoProgress> {
    let list: Vec<Todo> = todos
        .iter()
        .map(|t| {
            let s = |k: &str| t.get(k).and_then(|v| v.as_str()).map(|s| s.to_string());
            let content = s("content").or_else(|| s("subject")).unwrap_or_default();
            Todo { title: s("activeForm").unwrap_or_else(|| content.clone()), content, status: s("status").unwrap_or_else(|| "pending".into()) }
        })
        .collect();
    let done = list.iter().filter(|t| t.status == "completed").count();
    if list.is_empty() || done >= list.len() {
        return None;
    }
    let current = list.iter().find(|t| t.status == "in_progress").or_else(|| list.iter().find(|t| t.status != "completed")).map(|t| t.title.clone());
    Some(TodoProgress { todos: list, done, current })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claude::chat::PermissionRequest;
    use serde_json::json;
    use std::cell::{Cell, RefCell};

    fn tool(id: &str, name: &str, input: Value) -> Rc<ToolCall> {
        let c = ToolCall::new(id, name);
        *c.input.borrow_mut() = input.as_object().cloned().unwrap_or_default();
        c
    }

    fn text(id: &str, s: &str) -> Rc<ChatText> {
        Rc::new(ChatText { id: id.into(), text: RefCell::new(s.into()), finalized: Cell::new(true) })
    }

    fn user(id: &str) -> ChatItem {
        ChatItem::User { id: id.into(), text: "hi".into(), images: vec![] }
    }

    fn ids(out: &[DisplayItem]) -> Vec<String> {
        out.iter().map(|d| d.signature()).collect()
    }

    #[test]
    fn groups_consecutive_tools_and_thinking() {
        let items = vec![
            user("1"),
            ChatItem::Thinking(text("a", "plan")),
            ChatItem::Tool(tool("t1", "Bash", json!({"command": "ls"}))),
            ChatItem::Thinking(text("b", "hmm")),
            ChatItem::Tool(tool("t2", "Read", json!({"file_path": "/p/a.rs"}))),
            ChatItem::Text(text("x", "done")),
            ChatItem::Tool(tool("t3", "Grep", json!({"pattern": "foo"}))),
        ];
        let out = build(&items);
        assert_eq!(ids(&out), vec!["u1", "ka", "gt1|ct1,kb,ct2", "tx", "gt3|ct3"]);
        assert_eq!(out[2].id(), "gt1");
        assert_eq!(out[2].item_ids(), vec!["ct1", "kb", "ct2"]);
    }

    #[test]
    fn trailing_thinking_without_tools_stays_alone() {
        let items = vec![ChatItem::Thinking(text("a", "x")), ChatItem::Text(text("b", "y")), ChatItem::Thinking(text("c", "z"))];
        assert_eq!(ids(&build(&items)), vec!["ka", "tb", "kc"]);
    }

    #[test]
    fn special_tools_and_pending_permissions_break_runs() {
        let pending = tool("t2", "Edit", json!({"file_path": "/p/a"}));
        let req = Rc::new(PermissionRequest {
            id: "r".into(),
            tool_name: "Edit".into(),
            input: Default::default(),
            description: None,
            blocked_path: None,
            suggestions: vec![],
            tool_use_id: Some("t2".into()),
            resolved: Cell::new(false),
        });
        *pending.permission.borrow_mut() = Some(req.clone());
        let items = vec![
            ChatItem::Tool(tool("t1", "Bash", json!({}))),
            ChatItem::Tool(pending.clone()),
            ChatItem::Tool(tool("t3", "Read", json!({}))),
            ChatItem::Tool(tool("t4", "TodoWrite", json!({}))),
            ChatItem::Tool(tool("t5", "Read", json!({}))),
        ];
        assert_eq!(ids(&build(&items)), vec!["gt1|ct1", "ct2", "gt3|ct3", "ct4", "gt5|ct5"]);
        req.resolved.set(true);
        assert_eq!(ids(&build(&items)), vec!["gt1|ct1,ct2,ct3", "ct4", "gt5|ct5"]);
    }

    #[test]
    fn labels_count_by_kind() {
        assert_eq!(label(&["Bash", "Bash", "Bash", "Read", "Read"]), "Ran 3 commands, read 2 files");
        assert_eq!(label(&["Edit", "Grep", "WebFetch", "Task", "mcp__x__y"]), "Edited 1 file, searched 1 pattern, fetched 1 page, ran 1 agent, used 1 tool");
        assert_eq!(label(&[]), "");
        assert_eq!(kind_icons(&["Bash", "Bash", "Read", "Grep", "Glob", "WebFetch"]).len(), 4);
        assert_eq!(kind_icons(&["Bash", "Read"]), vec![("sy-terminal-symbolic", "sky"), ("sy-file-symbolic", "violet")]);
    }

    #[test]
    fn step_titles_and_running_header() {
        let folder = "/p";
        let bash = tool("t1", "Bash", json!({"command": "cargo test\n--all"}));
        assert_eq!(step_title(&bash, folder), "cargo test");
        let described = tool("t2", "Bash", json!({"command": "x", "description": "Run tests"}));
        assert_eq!(step_title(&described, folder), "Run tests");
        assert_eq!(step_title(&tool("t3", "Read", json!({"file_path": "/p/src/a.rs"})), folder), "Read src/a.rs");
        assert_eq!(step_title(&tool("t4", "WebFetch", json!({"url": "https://docs.rs/gtk4"})), folder), "Fetched docs.rs");
        assert_eq!(step_title(&tool("t5", "Grep", json!({"pattern": "fn main"})), folder), "Searched for \"fn main\"");
        assert_eq!(step_title(&tool("t6", "Task", json!({})), folder), "Agent: task");
        let calls = vec![bash.clone(), described.clone()];
        bash.status.set(ToolStatus::Done);
        assert_eq!(group_header(&calls, folder), ("Running: Run tests".to_string(), true));
        described.status.set(ToolStatus::Error);
        assert_eq!(group_header(&calls, folder), ("Ran 2 commands".to_string(), false));
    }

    #[test]
    fn fixture_stream_groups_tools_and_records_pr() {
        let chat = crate::claude::chat::ChatSession::new("/tmp", None);
        for line in crate::fixtures::CHAT_STREAM {
            chat.feed(line);
        }
        let items = chat.items.borrow().clone();
        let display = build(&items);
        let group = display.iter().find(|d| d.id() == "gtool-5").expect("group");
        assert_eq!(group.item_ids(), vec!["ctool-5", "km4:0", "ctool-6", "ctool-7"]);
        assert_eq!(chat.created_pr.borrow().as_deref(), Some("https://github.com/octocat/Hello-World/pull/42"));
        let read = items.iter().find_map(|i| match i {
            ChatItem::Tool(c) if c.id == "tool-5" => Some(c.clone()),
            _ => None,
        });
        assert!(!read.unwrap().structured.borrow().as_ref().unwrap().contains_key("originalFile"));
        let p = todo_progress(&latest_todos(&items)).unwrap();
        assert_eq!((p.done, p.todos.len(), p.current.as_deref()), (1, 2, Some("Test")));
    }

    #[test]
    fn prompts_queue_until_the_process_runs() {
        let chat = crate::claude::chat::ChatSession::new("/tmp", None);
        let image = crate::claude::chat::ChatImage { data: vec![1, 2, 3], media_type: "image/png".into() };
        chat.send("  first  ", vec![image]);
        chat.send("second", vec![]);
        chat.send("   ", vec![]);
        assert_eq!(chat.queued_count(), 2);
        let users: Vec<(String, usize)> = chat
            .items
            .borrow()
            .iter()
            .filter_map(|i| match i {
                ChatItem::User { text, images, .. } => Some((text.clone(), images.len())),
                _ => None,
            })
            .collect();
        assert_eq!(users, vec![("first".to_string(), 1), ("second".to_string(), 0)]);
    }

    #[test]
    fn todo_progress_from_latest_write() {
        let items = vec![
            ChatItem::Tool(tool("a", "TodoWrite", json!({"todos": [{"content": "Old", "status": "pending"}]}))),
            ChatItem::Tool(tool(
                "b",
                "TodoWrite",
                json!({"todos": [
                    {"content": "Fix", "status": "completed"},
                    {"content": "Test", "activeForm": "Testing", "status": "in_progress"},
                    {"content": "Ship", "status": "pending"}
                ]}),
            )),
        ];
        let p = todo_progress(&latest_todos(&items)).unwrap();
        assert_eq!(p.done, 1);
        assert_eq!(p.todos.len(), 3);
        assert_eq!(p.current.as_deref(), Some("Testing"));
        let finished = json!([{"content": "Fix", "status": "completed"}]);
        assert!(todo_progress(finished.as_array().unwrap()).is_none());
        assert!(todo_progress(&[]).is_none());
        let waiting = json!([{"content": "A", "status": "completed"}, {"content": "B"}]);
        assert_eq!(todo_progress(waiting.as_array().unwrap()).unwrap().current.as_deref(), Some("B"));
    }
}
