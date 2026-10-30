use adw::prelude::*;

use super::widgets::*;
use crate::{app, util};

fn escape(s: &str) -> String {
    util::markup_esc(s)
}

fn starts_at(chars: &[char], i: usize, pat: &str) -> bool {
    let p: Vec<char> = pat.chars().collect();
    i + p.len() <= chars.len() && chars[i..i + p.len()] == p[..]
}

pub fn inline_markup(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut bold = false;
    let mut italic = false;
    let mut strike = false;
    let mut plain = String::new();
    let flush = |plain: &mut String, out: &mut String| {
        if !plain.is_empty() {
            out.push_str(&escape(plain));
            plain.clear();
        }
    };
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' && i + 1 < chars.len() && "\\`*_[]()#+-.!~".contains(chars[i + 1]) {
            plain.push(chars[i + 1]);
            i += 2;
            continue;
        }
        if c == '`' {
            if let Some(end) = chars[i + 1..].iter().position(|x| *x == '`') {
                flush(&mut plain, &mut out);
                let code: String = chars[i + 1..i + 1 + end].iter().collect();
                out.push_str(&format!("<tt>{}</tt>", escape(&code)));
                i += end + 2;
                continue;
            }
        }
        if c == '[' {
            if let Some(close) = chars[i + 1..].iter().position(|x| *x == ']') {
                let after = i + 1 + close + 1;
                if after < chars.len() && chars[after] == '(' {
                    if let Some(paren) = chars[after + 1..].iter().position(|x| *x == ')') {
                        flush(&mut plain, &mut out);
                        let label: String = chars[i + 1..i + 1 + close].iter().collect();
                        let url: String = chars[after + 1..after + 1 + paren].iter().collect();
                        out.push_str(&format!("<a href=\"{}\">{}</a>", escape(url.trim()), escape(&label)));
                        i = after + 1 + paren + 1;
                        continue;
                    }
                }
            }
        }
        if (c == '*' || c == '_') && i + 1 < chars.len() && chars[i + 1] == c {
            flush(&mut plain, &mut out);
            out.push_str(if bold { "</b>" } else { "<b>" });
            bold = !bold;
            i += 2;
            continue;
        }
        if c == '~' && i + 1 < chars.len() && chars[i + 1] == '~' {
            flush(&mut plain, &mut out);
            out.push_str(if strike { "</s>" } else { "<s>" });
            strike = !strike;
            i += 2;
            continue;
        }
        if c == '*' || (c == '_' && (i == 0 || !chars[i - 1].is_alphanumeric())) || (c == '_' && italic) {
            let has_close = chars[i + 1..].contains(&c);
            if italic || (has_close && i + 1 < chars.len() && !chars[i + 1].is_whitespace()) {
                flush(&mut plain, &mut out);
                out.push_str(if italic { "</i>" } else { "<i>" });
                italic = !italic;
                i += 1;
                continue;
            }
        }
        if c == 'h' && (starts_at(&chars, i, "https://") || starts_at(&chars, i, "http://")) && (i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '(') {
            let end = chars[i..].iter().position(|x| x.is_whitespace() || *x == ')' || *x == '>').map(|p| i + p).unwrap_or(chars.len());
            flush(&mut plain, &mut out);
            let url: String = chars[i..end].iter().collect();
            out.push_str(&format!("<a href=\"{}\">{}</a>", escape(&url), escape(&url)));
            i = end;
            continue;
        }
        plain.push(c);
        i += 1;
    }
    flush(&mut plain, &mut out);
    if italic {
        out.push_str("</i>");
    }
    if bold {
        out.push_str("</b>");
    }
    if strike {
        out.push_str("</s>");
    }
    out
}

fn connect_links(l: &gtk::Label) {
    l.connect_activate_link(|_, uri| {
        match util::parse_github_url(uri, false) {
            Some(r) => app::open(r, true),
            None => util::open_url(uri),
        }
        gtk::glib::Propagation::Stop
    });
}

pub fn inline_label(text: &str) -> gtk::Label {
    let l = gtk::Label::new(None);
    let m = inline_markup(text);
    l.set_markup(&m);
    if l.text().is_empty() && !text.is_empty() {
        l.set_text(text);
    }
    l.set_xalign(0.0);
    l.set_wrap(true);
    l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    l.set_selectable(true);
    l.add_css_class("sy-text");
    connect_links(&l);
    l
}

fn code_block(code: &str) -> gtk::Widget {
    let l = gtk::Label::new(Some(code));
    l.set_xalign(0.0);
    l.set_selectable(true);
    l.add_css_class("sy-mono");
    let s = gtk::ScrolledWindow::new();
    s.set_vscrollbar_policy(gtk::PolicyType::Never);
    s.set_propagate_natural_height(true);
    s.set_child(Some(&l));
    let b = vbox(0);
    b.add_css_class("chat-code");
    b.append(&s);
    b.upcast()
}

#[derive(Clone, PartialEq, Debug)]
enum Block {
    Para(String),
    Code(String),
    Heading(usize, String),
    Rule,
    Quote(String),
    Table(Vec<String>),
    Item(i32, String, String),
}

fn parse(text: &str) -> Vec<Block> {
    let mut blocks = vec![];
    let lines: Vec<&str> = text.split('\n').collect();
    let mut i = 0;
    let mut para: Vec<&str> = vec![];
    let flush_para = |para: &mut Vec<&str>, blocks: &mut Vec<Block>| {
        if !para.is_empty() {
            blocks.push(Block::Para(para.join("\n")));
            para.clear();
        }
    };
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            flush_para(&mut para, &mut blocks);
            let mut code = vec![];
            i += 1;
            while i < lines.len() && !lines[i].trim_start().starts_with("```") {
                code.push(lines[i]);
                i += 1;
            }
            i += 1;
            blocks.push(Block::Code(code.join("\n")));
            continue;
        }
        if trimmed.is_empty() {
            flush_para(&mut para, &mut blocks);
            i += 1;
            continue;
        }
        if trimmed.starts_with('#') {
            let level = trimmed.chars().take_while(|c| *c == '#').count();
            if level <= 6 && trimmed.chars().nth(level) == Some(' ') {
                flush_para(&mut para, &mut blocks);
                blocks.push(Block::Heading(level, trimmed[level..].trim().to_string()));
                i += 1;
                continue;
            }
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flush_para(&mut para, &mut blocks);
            blocks.push(Block::Rule);
            i += 1;
            continue;
        }
        if trimmed.starts_with("> ") || trimmed == ">" {
            flush_para(&mut para, &mut blocks);
            let mut quote = vec![];
            while i < lines.len() && lines[i].trim_start().starts_with('>') {
                quote.push(lines[i].trim_start().trim_start_matches('>').trim_start());
                i += 1;
            }
            blocks.push(Block::Quote(quote.join("\n")));
            continue;
        }
        if trimmed.starts_with('|') && i + 1 < lines.len() && lines[i + 1].trim_start().starts_with('|') && lines[i + 1].contains("---") {
            flush_para(&mut para, &mut blocks);
            let mut table = vec![];
            while i < lines.len() && lines[i].trim_start().starts_with('|') {
                table.push(lines[i].to_string());
                i += 1;
            }
            blocks.push(Block::Table(table));
            continue;
        }
        if let Some((marker, rest)) = list_marker(trimmed) {
            flush_para(&mut para, &mut blocks);
            blocks.push(Block::Item((line.len() - trimmed.len()) as i32, marker, rest));
            i += 1;
            continue;
        }
        para.push(line);
        i += 1;
    }
    flush_para(&mut para, &mut blocks);
    blocks
}

fn block_widget(block: &Block) -> gtk::Widget {
    match block {
        Block::Para(text) => inline_label(text).upcast(),
        Block::Code(code) => code_block(code),
        Block::Heading(level, text) => {
            let l = inline_label(text);
            l.add_css_class("sy-bold");
            l.add_css_class(if *level <= 2 { "title-4" } else { "heading" });
            l.upcast()
        }
        Block::Rule => line_sep().upcast(),
        Block::Quote(text) => {
            let q = view(text);
            q.add_css_class("sy-muted");
            let b = hbox(8);
            let bar = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            bar.add_css_class("edge-slate");
            b.append(&bar);
            b.append(&q);
            b.upcast()
        }
        Block::Table(rows) => {
            let rows: Vec<&str> = rows.iter().map(|r| r.as_str()).collect();
            table_widget(&rows)
        }
        Block::Item(indent, marker, rest) => {
            let row = hbox(6);
            row.set_margin_start(indent * 4);
            let m = label_with(marker, &["sy-muted"]);
            m.set_valign(gtk::Align::Start);
            row.append(&m);
            let content = inline_label(rest);
            content.set_hexpand(true);
            row.append(&content);
            row.upcast()
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
enum Segment {
    Prose(Vec<Block>),
    Single(Block),
}

fn is_prose(b: &Block) -> bool {
    matches!(b, Block::Para(_) | Block::Heading(..) | Block::Item(..))
}

fn segments(blocks: Vec<Block>) -> Vec<Segment> {
    let mut out: Vec<Segment> = vec![];
    for b in blocks {
        let prose = is_prose(&b);
        let extend = prose && matches!(out.last(), Some(Segment::Prose(_)));
        if extend {
            if let Some(Segment::Prose(run)) = out.last_mut() {
                run.push(b);
            }
        } else if prose {
            out.push(Segment::Prose(vec![b]));
        } else {
            out.push(Segment::Single(b));
        }
    }
    out
}

const PARA_GAP: &str = "\n<span size=\"4096\"> </span>\n";

fn item_indent(indent: i32) -> String {
    "\u{2003}".repeat((indent / 2).max(0) as usize)
}

fn prose_markup(blocks: &[Block]) -> String {
    let mut out = String::new();
    let mut prev: Option<&Block> = None;
    for b in blocks {
        if let Some(p) = prev {
            out.push_str(if matches!((p, b), (Block::Item(..), Block::Item(..))) { "\n" } else { PARA_GAP });
        }
        match b {
            Block::Para(t) => out.push_str(&inline_markup(t)),
            Block::Heading(level, t) => out.push_str(&format!("<span weight=\"bold\" size=\"{}\">{}</span>", if *level <= 2 { "large" } else { "medium" }, inline_markup(t))),
            Block::Item(indent, marker, rest) => out.push_str(&format!("{}<span alpha=\"60%\">{}</span> {}", item_indent(*indent), escape(marker), inline_markup(rest))),
            _ => {}
        }
        prev = Some(b);
    }
    out
}

fn prose_plain(blocks: &[Block]) -> String {
    blocks
        .iter()
        .map(|b| match b {
            Block::Para(t) | Block::Heading(_, t) => t.clone(),
            Block::Item(indent, marker, rest) => format!("{}{marker} {rest}", item_indent(*indent)),
            _ => String::new(),
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn set_prose(l: &gtk::Label, blocks: &[Block]) {
    l.set_text("");
    l.set_markup(&prose_markup(blocks));
    if l.text().is_empty() {
        l.set_text(&prose_plain(blocks));
    }
}

fn prose_label(blocks: &[Block]) -> gtk::Label {
    let l = gtk::Label::new(None);
    set_prose(&l, blocks);
    l.set_xalign(0.0);
    l.set_wrap(true);
    l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    l.set_selectable(true);
    l.add_css_class("sy-text");
    connect_links(&l);
    l
}

fn segment_widget(seg: &Segment) -> gtk::Widget {
    match seg {
        Segment::Prose(blocks) => prose_label(blocks).upcast(),
        Segment::Single(block) => block_widget(block),
    }
}

pub fn view(text: &str) -> gtk::Box {
    let root = vbox(8);
    for seg in segments(parse(text)) {
        root.append(&segment_widget(&seg));
    }
    root
}

pub struct MarkdownView {
    pub widget: gtk::Box,
    segments: std::cell::RefCell<Vec<(Segment, gtk::Widget)>>,
}

impl MarkdownView {
    pub fn new(text: &str) -> std::rc::Rc<Self> {
        let me = std::rc::Rc::new(MarkdownView { widget: vbox(8), segments: std::cell::RefCell::new(vec![]) });
        me.set_text(text);
        me
    }

    pub fn set_text(&self, text: &str) {
        let new = segments(parse(text));
        let mut segs = self.segments.borrow_mut();
        let mut keep = segs.iter().zip(&new).take_while(|((old, _), seg)| old == *seg).count();
        if keep < segs.len() && keep < new.len() {
            let reuse = matches!((&segs[keep].0, &new[keep]), (Segment::Prose(_), Segment::Prose(_)));
            if reuse {
                if let (Some(l), Segment::Prose(blocks)) = (segs[keep].1.downcast_ref::<gtk::Label>(), &new[keep]) {
                    set_prose(l, blocks);
                }
                segs[keep].0 = new[keep].clone();
                keep += 1;
            }
        }
        for (_, w) in segs.drain(keep..) {
            self.widget.remove(&w);
        }
        for seg in new.into_iter().skip(keep) {
            let w = segment_widget(&seg);
            self.widget.append(&w);
            segs.push((seg, w));
        }
    }
}

fn line_sep() -> gtk::Separator {
    super::widgets::line()
}

fn list_marker(trimmed: &str) -> Option<(String, String)> {
    for p in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] {
        if let Some(rest) = trimmed.strip_prefix(p) {
            return Some((if p.contains("[ ]") { "☐".into() } else { "☑".into() }, rest.to_string()));
        }
    }
    for p in ["- ", "* ", "+ "] {
        if let Some(rest) = trimmed.strip_prefix(p) {
            return Some(("•".into(), rest.to_string()));
        }
    }
    let digits: String = trimmed.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() && digits.len() < 4 {
        let rest = &trimmed[digits.len()..];
        if let Some(r) = rest.strip_prefix(". ").or_else(|| rest.strip_prefix(") ")) {
            return Some((format!("{digits}."), r.to_string()));
        }
    }
    None
}

fn table_widget(rows: &[&str]) -> gtk::Widget {
    let grid = gtk::Grid::new();
    grid.set_column_spacing(14);
    grid.set_row_spacing(4);
    let mut r = 0;
    for (idx, line) in rows.iter().enumerate() {
        if idx == 1 && line.contains("---") {
            continue;
        }
        let cells: Vec<&str> = line.trim().trim_matches('|').split('|').collect();
        for (c, cell) in cells.iter().enumerate() {
            let l = inline_label(cell.trim());
            if idx == 0 {
                l.add_css_class("sy-bold");
            }
            grid.attach(&l, c as i32, r, 1, 1);
        }
        r += 1;
    }
    let s = gtk::ScrolledWindow::new();
    s.set_vscrollbar_policy(gtk::PolicyType::Never);
    s.set_propagate_natural_height(true);
    s.set_child(Some(&grid));
    s.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline() {
        assert_eq!(inline_markup("a **b** `c`"), "a <b>b</b> <tt>c</tt>");
        assert_eq!(inline_markup("see [x](https://e.com)"), "see <a href=\"https://e.com\">x</a>");
        assert_eq!(inline_markup("1 < 2"), "1 &lt; 2");
    }

    #[test]
    fn blocks() {
        let b = parse("# Title\n\nsome text\nmore\n\n- a\n```\ncode\n```\n> q\n---");
        assert_eq!(
            b,
            vec![
                Block::Heading(1, "Title".into()),
                Block::Para("some text\nmore".into()),
                Block::Item(0, "•".into(), "a".into()),
                Block::Code("code".into()),
                Block::Quote("q".into()),
                Block::Rule,
            ]
        );
        let streaming = parse("# Title\n\nsome te");
        assert_eq!(streaming[0], b[0]);
    }

    #[test]
    fn prose_blocks_merge_into_one_run() {
        let segs = segments(parse("# Title\n\nsome text\n\n- a\n- b\n```\ncode\n```\nafter"));
        assert_eq!(segs.len(), 3);
        match &segs[0] {
            Segment::Prose(blocks) => {
                assert_eq!(blocks.len(), 4);
                let m = prose_markup(blocks);
                assert!(m.starts_with("<span weight=\"bold\" size=\"large\">Title</span>"));
                assert!(m.contains("<span alpha=\"60%\">•</span> a\n<span alpha=\"60%\">•</span> b"));
            }
            _ => panic!("expected prose"),
        }
        assert_eq!(segs[1], Segment::Single(Block::Code("code".into())));
        assert_eq!(segs[2], Segment::Prose(vec![Block::Para("after".into())]));
    }
}
