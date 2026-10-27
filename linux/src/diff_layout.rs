use crate::diff::{DiffLine, LineKind};

pub const SPLIT_MIN_WIDTH: i32 = 900;
pub const CONTINUATION_INDENT: usize = 2;
pub const TAB_WIDTH: usize = 4;
pub const MAX_HIGHLIGHT_LENGTH: usize = 2000;
pub const MAX_HIGHLIGHT_LINES: usize = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitRow {
    Full(usize),
    Pair(Option<usize>, Option<usize>),
}

pub fn pair_kinds(kinds: &[LineKind]) -> Vec<SplitRow> {
    let mut out = Vec::with_capacity(kinds.len());
    let mut removed: Vec<usize> = vec![];
    let mut added: Vec<usize> = vec![];
    let flush = |out: &mut Vec<SplitRow>, removed: &mut Vec<usize>, added: &mut Vec<usize>| {
        for i in 0..removed.len().max(added.len()) {
            out.push(SplitRow::Pair(removed.get(i).copied(), added.get(i).copied()));
        }
        removed.clear();
        added.clear();
    };
    for (i, kind) in kinds.iter().enumerate() {
        match kind {
            LineKind::Del => {
                if !added.is_empty() {
                    flush(&mut out, &mut removed, &mut added);
                }
                removed.push(i);
            }
            LineKind::Add => added.push(i),
            LineKind::Context => {
                flush(&mut out, &mut removed, &mut added);
                out.push(SplitRow::Pair(Some(i), Some(i)));
            }
            LineKind::Hunk | LineKind::Meta => {
                flush(&mut out, &mut removed, &mut added);
                out.push(SplitRow::Full(i));
            }
        }
    }
    flush(&mut out, &mut removed, &mut added);
    out
}

#[cfg(test)]
pub fn pair(lines: &[DiffLine]) -> Vec<SplitRow> {
    let kinds: Vec<LineKind> = lines.iter().map(|l| l.kind).collect();
    pair_kinds(&kinds)
}

pub fn leading_columns(text: &str) -> usize {
    let mut columns = 0;
    for c in text.chars() {
        match c {
            ' ' => columns += 1,
            '\t' => columns += TAB_WIDTH - columns % TAB_WIDTH,
            _ => break,
        }
    }
    columns
}

pub fn hanging_columns(text: &str, limit: i64) -> usize {
    let wanted = (1 + leading_columns(text) + CONTINUATION_INDENT) as i64;
    wanted.min(limit).max(0) as usize
}

pub fn expand_tabs(text: &str) -> String {
    expand_tabs_width(text, TAB_WIDTH)
}

pub fn expand_tabs_width(text: &str, tab_width: usize) -> String {
    if !text.contains('\t') {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + tab_width * 2);
    let mut column = 0;
    for c in text.chars() {
        if c == '\t' {
            let n = tab_width - column % tab_width;
            out.extend(std::iter::repeat_n(' ', n));
            column += n;
        } else {
            out.push(c);
            column += 1;
        }
    }
    out
}

pub fn display_text(line: &DiffLine) -> String {
    match line.kind {
        LineKind::Add | LineKind::Del | LineKind::Context => format!("{}{}", line.sign(), expand_tabs(&line.text)),
        LineKind::Hunk | LineKind::Meta => line.text.clone(),
    }
}

pub fn is_code(kind: LineKind) -> bool {
    matches!(kind, LineKind::Add | LineKind::Del | LineKind::Context)
}

pub fn display_columns(line: &DiffLine) -> usize {
    if !is_code(line.kind) {
        return 0;
    }
    1 + expand_tabs(&line.text).chars().count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::parse;

    fn shape(patch: &str) -> Vec<String> {
        let lines = parse(patch);
        pair(&lines)
            .into_iter()
            .map(|row| match row {
                SplitRow::Full(i) => format!("full:{}", lines[i].id),
                SplitRow::Pair(a, b) => format!("{}|{}", a.map(|i| lines[i].id.to_string()).unwrap_or("_".into()), b.map(|i| lines[i].id.to_string()).unwrap_or("_".into())),
            })
            .collect()
    }

    #[test]
    fn pairs_removals_with_additions_in_order() {
        assert_eq!(shape("@@ -1,4 +1,3 @@\n a\n-b\n-c\n+B\n d"), ["full:0", "1|1", "2|4", "3|_", "5|5"]);
    }

    #[test]
    fn extra_additions_get_filler_on_left() {
        assert_eq!(shape("@@ -1,2 +1,4 @@\n-x\n+X\n+Y\n+Z\n k"), ["full:0", "1|2", "_|3", "_|4", "5|5"]);
    }

    #[test]
    fn additions_before_removals_do_not_pair_across_runs() {
        assert_eq!(shape("@@ -1,1 +1,1 @@\n+new\n-old"), ["full:0", "_|1", "2|_"]);
    }

    #[test]
    fn hunks_and_meta_stay_full_width() {
        assert_eq!(shape("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n@@ -9 +9 @@\n c"), ["full:0", "1|2", "full:3", "full:4", "5|5"]);
    }

    #[test]
    fn removal_runs_across_context_are_separate() {
        assert_eq!(shape("@@ -1,3 +1,3 @@\n-a\n m\n+b"), ["full:0", "1|_", "2|2", "_|3"]);
    }

    #[test]
    fn leading_columns_counts_spaces_and_tab_stops() {
        assert_eq!(leading_columns("return x"), 0);
        assert_eq!(leading_columns("    return x"), 4);
        assert_eq!(leading_columns("\t\treturn"), 8);
        assert_eq!(leading_columns("  \treturn"), 4);
        assert_eq!(leading_columns("   "), 3);
    }

    #[test]
    fn hanging_columns_include_sign_and_continuation_indent() {
        assert_eq!(hanging_columns("let a = 1", 40), 3);
        assert_eq!(hanging_columns("        let a = 1", 40), 11);
        assert_eq!(hanging_columns("\tlet a = 1", 40), 7);
    }

    #[test]
    fn hanging_columns_are_capped_by_limit() {
        assert_eq!(hanging_columns(&format!("{}x", " ".repeat(60)), 20), 20);
        assert_eq!(hanging_columns("    x", 0), 0);
        assert_eq!(hanging_columns("    x", -5), 0);
    }

    #[test]
    fn expand_tabs_aligns_to_tab_stops() {
        assert_eq!(expand_tabs("no tabs"), "no tabs");
        assert_eq!(expand_tabs("\tx"), "    x");
        assert_eq!(expand_tabs("ab\tc"), "ab  c");
        assert_eq!(expand_tabs_width("a\t\tb", 2), "a   b");
    }

    #[test]
    fn display_text_prefixes_sign_and_expands_tabs() {
        let lines = parse("@@ -1 +1 @@\n-\tx\n+y");
        assert_eq!(display_text(&lines[0]), "@@ -1 +1 @@");
        assert_eq!(display_text(&lines[1]), "-    x");
        assert_eq!(display_columns(&lines[1]), 6);
        assert_eq!(display_text(&lines[2]), "+y");
    }
}
