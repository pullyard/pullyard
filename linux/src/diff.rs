use crate::api::models::PrFile;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    Hunk,
    Context,
    Add,
    Del,
    Meta,
}

#[derive(Debug, Clone)]
pub struct DiffLine {
    pub id: usize,
    pub kind: LineKind,
    pub text: String,
    pub old_line: Option<i64>,
    pub new_line: Option<i64>,
    pub word: Option<(usize, usize)>,
    pub outside: bool,
}

impl DiffLine {
    pub fn anchor_side(&self) -> &'static str {
        if self.kind == LineKind::Del {
            "LEFT"
        } else {
            "RIGHT"
        }
    }

    pub fn anchor_line(&self) -> Option<i64> {
        if self.kind == LineKind::Del {
            self.old_line
        } else {
            self.new_line
        }
    }

    pub fn commentable(&self) -> bool {
        !self.outside && matches!(self.kind, LineKind::Add | LineKind::Del | LineKind::Context)
    }

    pub fn sign(&self) -> &'static str {
        match self.kind {
            LineKind::Add => "+",
            LineKind::Del => "-",
            LineKind::Context => " ",
            _ => "",
        }
    }

    pub fn gutter(&self, commentable: bool) -> String {
        let pad = |n: Option<i64>| format!("{:>5}", n.map(|n| n.to_string()).unwrap_or_default());
        format!("{} {}{}", pad(self.old_line), pad(self.new_line), if commentable && self.commentable() { " +" } else { "  " })
    }
}

#[derive(Debug, Clone)]
pub struct DiffFile {
    pub id: String,
    pub previous_filename: Option<String>,
    pub status: String,
    pub additions: i64,
    pub deletions: i64,
    pub lines: Vec<DiffLine>,
    pub has_patch: bool,
}

impl DiffFile {
    pub fn new(f: &PrFile) -> Self {
        DiffFile {
            id: f.filename.clone(),
            previous_filename: f.previous_filename.clone(),
            status: f.status.clone(),
            additions: f.additions,
            deletions: f.deletions,
            has_patch: f.patch.is_some(),
            lines: f.patch.as_deref().map(parse).unwrap_or_default(),
        }
    }

    pub fn status_letter(&self) -> &'static str {
        match self.status.as_str() {
            "added" => "A",
            "removed" => "D",
            "renamed" => "R",
            "copied" => "C",
            _ => "M",
        }
    }

    pub fn status_css(&self) -> &'static str {
        match self.status.as_str() {
            "added" => "green",
            "removed" => "red",
            "renamed" => "violet",
            _ => "amber",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DiffAnchor {
    pub path: String,
    pub line: i64,
    pub side: String,
}

fn hunk_start(header: &str) -> (i64, i64) {
    let parts: Vec<&str> = header.split(' ').collect();
    let start = |token: Option<&&str>| -> i64 {
        token.and_then(|t| t[1..].split(',').next().and_then(|d| d.parse::<i64>().ok())).unwrap_or(1)
    };
    (start(parts.iter().find(|p| p.starts_with('-'))), start(parts.iter().find(|p| p.starts_with('+'))))
}

pub fn parse(patch: &str) -> Vec<DiffLine> {
    let mut result = Vec::with_capacity(patch.len() / 40);
    let (mut old, mut new) = (0i64, 0i64);
    for (idx, raw) in patch.split('\n').enumerate() {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        if idx > 0 && raw.is_empty() && patch.ends_with('\n') && idx == patch.matches('\n').count() {
            break;
        }
        if raw.starts_with("@@") {
            let (o, n) = hunk_start(raw);
            old = o;
            new = n;
            result.push(DiffLine { id: idx, kind: LineKind::Hunk, text: raw.to_string(), old_line: None, new_line: None, word: None, outside: false });
            continue;
        }
        let first = raw.chars().next();
        let body = if raw.is_empty() { String::new() } else { raw[first.map(|c| c.len_utf8()).unwrap_or(0)..].to_string() };
        match first {
            Some('+') => {
                result.push(DiffLine { id: idx, kind: LineKind::Add, text: body, old_line: None, new_line: Some(new), word: None, outside: false });
                new += 1;
            }
            Some('-') => {
                result.push(DiffLine { id: idx, kind: LineKind::Del, text: body, old_line: Some(old), new_line: None, word: None, outside: false });
                old += 1;
            }
            Some('\\') => {
                result.push(DiffLine { id: idx, kind: LineKind::Meta, text: raw.to_string(), old_line: None, new_line: None, word: None, outside: false });
            }
            _ => {
                result.push(DiffLine { id: idx, kind: LineKind::Context, text: body, old_line: Some(old), new_line: Some(new), word: None, outside: false });
                old += 1;
                new += 1;
            }
        }
    }
    mark_intraline(&mut result);
    result
}

const INTRALINE_MAX: usize = 400;
const INTRALINE_MIN_COMMON: f64 = 0.4;

pub fn changed_span(a: &str, b: &str) -> Option<((usize, usize), (usize, usize))> {
    if a == b || a.len() > INTRALINE_MAX || b.len() > INTRALINE_MAX {
        return None;
    }
    let mut prefix = 0;
    for ((i, ca), (_, cb)) in a.char_indices().zip(b.char_indices()) {
        if ca != cb {
            break;
        }
        prefix = i + ca.len_utf8();
    }
    let mut suffix = 0;
    for (ca, cb) in a[prefix..].chars().rev().zip(b[prefix..].chars().rev()) {
        if ca != cb {
            break;
        }
        suffix += ca.len_utf8();
    }
    if prefix + suffix == 0 || a[prefix..].trim().is_empty() && b[prefix..].trim().is_empty() {
        return None;
    }
    if ((prefix + suffix) as f64) < INTRALINE_MIN_COMMON * a.len().max(b.len()) as f64 {
        return None;
    }
    let (ae, be) = (a.len() - suffix, b.len() - suffix);
    if ae <= prefix && be <= prefix {
        return None;
    }
    Some(((prefix, ae.max(prefix)), (prefix, be.max(prefix))))
}

pub fn mark_intraline(lines: &mut [DiffLine]) {
    let mut i = 0;
    while i < lines.len() {
        if lines[i].kind != LineKind::Del {
            i += 1;
            continue;
        }
        let del_start = i;
        while i < lines.len() && lines[i].kind == LineKind::Del {
            i += 1;
        }
        let add_start = i;
        while i < lines.len() && lines[i].kind == LineKind::Add {
            i += 1;
        }
        let pairs = (add_start - del_start).min(i - add_start);
        for k in 0..pairs {
            let (d, a) = (del_start + k, add_start + k);
            if let Some((ds, as_)) = changed_span(&lines[d].text, &lines[a].text) {
                lines[d].word = Some(ds).filter(|(s, e)| e > s);
                lines[a].word = Some(as_).filter(|(s, e)| e > s);
            }
        }
    }
}

pub fn expand_full(lines: &[DiffLine], full: &str) -> Vec<DiffLine> {
    let file: Vec<&str> = full.strip_suffix('\n').unwrap_or(full).split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect();
    let mut out = Vec::with_capacity(file.len() + lines.len());
    let mut next_new: i64 = 1;
    let mut delta: i64 = 0;
    let mut id = 1_000_000usize;
    let mut push_outside = |out: &mut Vec<DiffLine>, upto: i64, next_new: &mut i64, delta: i64| {
        while *next_new < upto && (*next_new as usize) <= file.len() {
            let text = file[*next_new as usize - 1].to_string();
            out.push(DiffLine { id, kind: LineKind::Context, text, old_line: Some(*next_new + delta), new_line: Some(*next_new), word: None, outside: true });
            id += 1;
            *next_new += 1;
        }
    };
    for line in lines {
        match line.kind {
            LineKind::Hunk => {
                let (old, new) = hunk_start(&line.text);
                push_outside(&mut out, new, &mut next_new, delta);
                delta = old - new;
            }
            LineKind::Add | LineKind::Context => {
                if let Some(n) = line.new_line {
                    next_new = n + 1;
                    if let Some(o) = line.old_line {
                        delta = o - n;
                    }
                }
                out.push(line.clone());
            }
            LineKind::Del => {
                if let Some(o) = line.old_line {
                    delta = o + 1 - next_new;
                }
                out.push(line.clone());
            }
            LineKind::Meta => out.push(line.clone()),
        }
    }
    push_outside(&mut out, file.len() as i64 + 1, &mut next_new, delta);
    out
}

pub fn parse_unified(text: &str) -> Vec<PrFile> {
    let mut files = vec![];
    let mut path: Option<String> = None;
    let mut old_path: Option<String> = None;
    let mut status = "modified".to_string();
    let mut patch: Vec<&str> = vec![];
    let (mut adds, mut dels) = (0i64, 0i64);
    let mut binary = false;

    let flush = |files: &mut Vec<PrFile>, path: &Option<String>, old_path: &Option<String>, status: &str, patch: &Vec<&str>, adds: i64, dels: i64, binary: bool| {
        if let Some(p) = path {
            let body = patch.join("\n");
            files.push(PrFile {
                filename: p.clone(),
                status: status.to_string(),
                additions: adds,
                deletions: dels,
                patch: if binary || body.is_empty() { None } else { Some(body) },
                previous_filename: if old_path.as_deref() != Some(p.as_str()) { old_path.clone() } else { None },
            });
        }
    };

    for line in text.split('\n') {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            flush(&mut files, &path, &old_path, &status, &patch, adds, dels, binary);
            path = None;
            old_path = None;
            status = "modified".into();
            patch = vec![];
            adds = 0;
            dels = 0;
            binary = false;
            let parts: Vec<&str> = rest.split(" b/").collect();
            if parts.len() >= 2 {
                old_path = Some(parts[0].get(2..).unwrap_or("").to_string());
                path = Some(parts[1..].join(" b/"));
            }
            continue;
        }
        if patch.is_empty() {
            if line.starts_with("new file") {
                status = "added".into();
                continue;
            }
            if line.starts_with("deleted file") {
                status = "removed".into();
                continue;
            }
            if let Some(from) = line.strip_prefix("rename from ") {
                status = "renamed".into();
                old_path = Some(from.to_string());
                continue;
            }
            if let Some(to) = line.strip_prefix("rename to ") {
                path = Some(to.to_string());
                continue;
            }
            if line.starts_with("Binary files") {
                binary = true;
                continue;
            }
            if line.starts_with("index ") || line.starts_with("--- ") || line.starts_with("+++ ") || line.starts_with("similarity") || line.starts_with("old mode") || line.starts_with("new mode") {
                continue;
            }
        }
        if path.is_none() {
            continue;
        }
        if line.starts_with("@@") || !patch.is_empty() {
            patch.push(line);
            if line.starts_with('+') {
                adds += 1;
            } else if line.starts_with('-') {
                dels += 1;
            }
        }
    }
    flush(&mut files, &path, &old_path, &status, &patch, adds, dels, binary);
    files
}

#[cfg(test)]
mod tests {

    #[test]
    fn full_file_puts_changes_in_place() {
        let full = "a\nb\nc2\nd\ne\nf\n";
        let lines = parse("@@ -2,3 +2,3 @@\n b\n-c\n+c2\n d");
        let out = expand_full(&lines, full);
        let shown: Vec<(LineKind, &str, Option<i64>, Option<i64>, bool)> = out.iter().map(|l| (l.kind, l.text.as_str(), l.old_line, l.new_line, l.outside)).collect();
        assert_eq!(
            shown,
            vec![
                (LineKind::Context, "a", Some(1), Some(1), true),
                (LineKind::Context, "b", Some(2), Some(2), false),
                (LineKind::Del, "c", Some(3), None, false),
                (LineKind::Add, "c2", None, Some(3), false),
                (LineKind::Context, "d", Some(4), Some(4), false),
                (LineKind::Context, "e", Some(5), Some(5), true),
                (LineKind::Context, "f", Some(6), Some(6), true),
            ]
        );
        assert!(!out[0].commentable());
        assert!(out[3].commentable());
    }

    #[test]
    fn full_file_tracks_line_offsets_after_additions() {
        let full = "x\nnew1\nnew2\ny\nz\n";
        let lines = parse("@@ -1,2 +1,4 @@\n x\n+new1\n+new2\n y");
        let out = expand_full(&lines, full);
        let last = out.last().unwrap();
        assert_eq!((last.text.as_str(), last.old_line, last.new_line, last.outside), ("z", Some(3), Some(5), true));
    }


    #[test]
    fn intraline_marks_only_the_changed_span() {
        let lines = parse("@@ -1,2 +1,2 @@\n-let total = price * 2;\n+let total = price * 3;\n same");
        assert_eq!(lines[1].word, Some((20, 21)));
        assert_eq!(lines[2].word, Some((20, 21)));
        assert_eq!(lines[3].word, None);
    }

    #[test]
    fn intraline_skips_lines_with_nothing_in_common() {
        assert_eq!(changed_span("alpha", "omega"), None);
        assert_eq!(changed_span("same", "same"), None);
        let lines = parse("@@ -1 +1 @@\n-abc\n+xyz");
        assert_eq!(lines[1].word, None);
    }

    #[test]
    fn intraline_pairs_runs_in_order_and_handles_unicode() {
        let lines = parse("@@ -1,2 +1,3 @@\n-naïve = 1\n-b = 2\n+naïve = 5\n+b = 7\n+c = 9");
        assert_eq!(lines[1].word.map(|(s, e)| &lines[1].text[s..e]), Some("1"));
        assert_eq!(lines[3].word.map(|(s, e)| &lines[3].text[s..e]), Some("5"));
        assert_eq!(lines[4].word.map(|(s, e)| &lines[4].text[s..e]), Some("7"));
        assert_eq!(lines[5].word, None);
    }

    #[test]
    fn intraline_insertion_marks_added_text() {
        assert_eq!(changed_span("foo(a)", "foo(a, b)"), Some(((5, 5), (5, 8))));
    }

    use super::*;

    #[test]
    fn parses_patch() {
        let lines = parse("@@ -10,3 +10,4 @@ fn x\n a\n-b\n+c\n+d\n e");
        assert_eq!(lines[0].kind, LineKind::Hunk);
        assert_eq!(lines[1].old_line, Some(10));
        assert_eq!(lines[2].kind, LineKind::Del);
        assert_eq!(lines[2].old_line, Some(11));
        assert_eq!(lines[3].new_line, Some(11));
        assert_eq!(lines[5].new_line, Some(13));
    }

    #[test]
    fn parses_unified() {
        let text = "diff --git a/x.txt b/x.txt\nindex 1..2 100644\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+hi\n";
        let files = parse_unified(text);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].additions, 1);
        assert_eq!(files[1].status, "added");
    }
}
