use std::sync::LazyLock;

use regex::Regex;

use crate::ui::markdown::{parse, Block};
use crate::util::esc;

pub fn render(markdown: &str, base: Option<&str>) -> String {
    let blocks = parse(markdown);
    let mut out = String::new();
    let mut i = 0;
    while i < blocks.len() {
        if let Block::Item(..) = &blocks[i] {
            let start = i;
            while i < blocks.len() && matches!(blocks[i], Block::Item(..)) {
                i += 1;
            }
            out.push_str(&list(&blocks[start..i], base));
            continue;
        }
        out.push_str(&block(&blocks[i], base));
        i += 1;
    }
    out
}

fn list(items: &[Block], base: Option<&str>) -> String {
    let ordered = matches!(items.first(), Some(Block::Item(_, marker, _)) if marker.ends_with('.'));
    let rows: String = items
        .iter()
        .filter_map(|b| match b {
            Block::Item(indent, marker, rest) => {
                let check = match marker.as_str() {
                    "☐" => "<input type=\"checkbox\" disabled> ",
                    "☑" => "<input type=\"checkbox\" checked disabled> ",
                    _ => "",
                };
                let style = if *indent > 0 { format!(" style=\"margin-left:{}px\"", indent * 8) } else { String::new() };
                Some(format!("<li{style}>{check}{}</li>", inline(rest, base)))
            }
            _ => None,
        })
        .collect();
    if ordered {
        format!("<ol>{rows}</ol>")
    } else {
        format!("<ul>{rows}</ul>")
    }
}

fn block(b: &Block, base: Option<&str>) -> String {
    match b {
        Block::Heading(level, text) => format!("<h{level}>{}</h{level}>", inline(text, base)),
        Block::Para(text) => format!("<p>{}</p>", inline(text, base)),
        Block::Code(code) => format!("<pre><code>{}</code></pre>", esc(code)),
        Block::Quote(text) => format!("<blockquote>{}</blockquote>", render(text, base)),
        Block::Rule => "<hr>".into(),
        Block::Table(rows) => table(rows, base),
        Block::Item(..) => list(std::slice::from_ref(b), base),
    }
}

fn table(rows: &[String], base: Option<&str>) -> String {
    let cells = |line: &str| -> Vec<String> { line.trim().trim_matches('|').split('|').map(|c| c.trim().to_string()).collect() };
    let Some(head) = rows.first() else { return String::new() };
    let th: String = cells(head).iter().map(|c| format!("<th>{}</th>", inline(c, base))).collect();
    let body: String = rows
        .iter()
        .enumerate()
        .skip(1)
        .filter(|(idx, line)| !(*idx == 1 && line.contains("---")))
        .map(|(_, line)| format!("<tr>{}</tr>", cells(line).iter().map(|c| format!("<td>{}</td>", inline(c, base))).collect::<String>()))
        .collect();
    format!("<table><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table>")
}

fn starts_at(chars: &[char], i: usize, pat: &str) -> bool {
    let p: Vec<char> = pat.chars().collect();
    i + p.len() <= chars.len() && chars[i..i + p.len()] == p[..]
}

fn link_at(chars: &[char], open: usize) -> Option<(String, String, usize)> {
    let close = chars[open + 1..].iter().position(|x| *x == ']')? + open + 1;
    if chars.get(close + 1) != Some(&'(') {
        return None;
    }
    let paren = chars[close + 2..].iter().position(|x| *x == ')')? + close + 2;
    let label: String = chars[open + 1..close].iter().collect();
    let url: String = chars[close + 2..paren].iter().collect();
    Some((label, url.trim().to_string(), paren + 1))
}

pub fn inline(text: &str, base: Option<&str>) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut strong = false;
    let mut em = false;
    let mut del = false;
    let mut plain = String::new();
    let flush = |plain: &mut String, out: &mut String| {
        if !plain.is_empty() {
            out.push_str(&esc(plain));
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
        if c == '\n' {
            flush(&mut plain, &mut out);
            out.push_str("<br>");
            i += 1;
            continue;
        }
        if c == '`' {
            if let Some(end) = chars[i + 1..].iter().position(|x| *x == '`') {
                flush(&mut plain, &mut out);
                let code: String = chars[i + 1..i + 1 + end].iter().collect();
                out.push_str(&format!("<code>{}</code>", esc(&code)));
                i += end + 2;
                continue;
            }
        }
        if c == '!' && chars.get(i + 1) == Some(&'[') {
            if let Some((alt, url, next)) = link_at(&chars, i + 1) {
                flush(&mut plain, &mut out);
                out.push_str(&format!("<img src=\"{}\" alt=\"{}\">", esc(&absolute(&url, base)), esc(&alt)));
                i = next;
                continue;
            }
        }
        if c == '[' {
            if let Some((label, url, next)) = link_at(&chars, i) {
                flush(&mut plain, &mut out);
                out.push_str(&format!("<a href=\"{}\">{}</a>", esc(&absolute(&url, base)), inline(&label, base)));
                i = next;
                continue;
            }
        }
        if (c == '*' || c == '_') && chars.get(i + 1) == Some(&c) {
            flush(&mut plain, &mut out);
            out.push_str(if strong { "</strong>" } else { "<strong>" });
            strong = !strong;
            i += 2;
            continue;
        }
        if c == '~' && chars.get(i + 1) == Some(&'~') {
            flush(&mut plain, &mut out);
            out.push_str(if del { "</del>" } else { "<del>" });
            del = !del;
            i += 2;
            continue;
        }
        if c == '*' || (c == '_' && (i == 0 || !chars[i - 1].is_alphanumeric())) || (c == '_' && em) {
            let has_close = chars[i + 1..].contains(&c);
            if em || (has_close && i + 1 < chars.len() && !chars[i + 1].is_whitespace()) {
                flush(&mut plain, &mut out);
                out.push_str(if em { "</em>" } else { "<em>" });
                em = !em;
                i += 1;
                continue;
            }
        }
        if c == 'h' && (starts_at(&chars, i, "https://") || starts_at(&chars, i, "http://")) && (i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '(') {
            let end = chars[i..].iter().position(|x| x.is_whitespace() || *x == ')' || *x == '>').map(|p| i + p).unwrap_or(chars.len());
            flush(&mut plain, &mut out);
            let url: String = chars[i..end].iter().collect();
            out.push_str(&format!("<a href=\"{}\">{}</a>", esc(&url), esc(&url)));
            i = end;
            continue;
        }
        plain.push(c);
        i += 1;
    }
    flush(&mut plain, &mut out);
    if em {
        out.push_str("</em>");
    }
    if strong {
        out.push_str("</strong>");
    }
    if del {
        out.push_str("</del>");
    }
    out
}

pub fn absolute(url: &str, base: Option<&str>) -> String {
    let Some(base) = base else { return url.to_string() };
    if !url.starts_with('/') || url.starts_with("//") {
        return url.to_string();
    }
    if url.starts_with("/uploads/") {
        return format!("{}{url}", base.trim_end_matches('/'));
    }
    let Ok(root) = url::Url::parse(base) else { return url.to_string() };
    let Some(host) = root.host_str() else { return url.to_string() };
    let port = root.port().map(|p| format!(":{p}")).unwrap_or_default();
    format!("{}://{host}{port}{url}", root.scheme())
}

static PLACEHOLDER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#" src="data:image/gif;base64,[^"]*""#).expect("regex"));
static RELATIVE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(href|src)="(/[^/"][^"]*)""#).expect("regex"));

pub fn absolutize_html(html: &str, base: &str) -> String {
    let out = PLACEHOLDER.replace_all(html, "").replace(" data-src=\"", " src=\"");
    RELATIVE.replace_all(&out, |c: &regex::Captures| format!("{}=\"{}\"", &c[1], absolute(&c[2], Some(base)))).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_markdown_with_absolute_links() {
        let html = render("# Title\n\nSee [docs](/help) and `code` ![shot](/uploads/x.png)\n\n- [x] done\n- todo\n\n```swift\nlet a = 1 < 2\n```", Some("https://gitlab.example.com/g/p"));
        assert!(html.contains("<h1>Title</h1>"), "{html}");
        assert!(html.contains(r#"<a href="https://gitlab.example.com/help">docs</a>"#), "{html}");
        assert!(html.contains("<code>code</code>"), "{html}");
        assert!(html.contains(r#"<img src="https://gitlab.example.com/g/p/uploads/x.png" alt="shot">"#), "{html}");
        assert!(html.contains(r#"<li><input type="checkbox" checked disabled> done</li>"#), "{html}");
        assert!(html.contains("let a = 1 &lt; 2"), "{html}");
        assert_eq!(inline("<script>", None), "&lt;script&gt;");
        assert_eq!(render("Looks **good**", None), "<p>Looks <strong>good</strong></p>");
    }

    #[test]
    fn absolutizes_rendered_html() {
        let html = absolutize_html(r#"<p><img data-src="/g/p/uploads/a.png" src="data:image/gif;base64,R0lG"> <a href="/g/p/-/issues/3">#3</a> <a href="https://x.org/a">x</a></p>"#, "https://gitlab.example.com/g/p");
        assert!(html.contains(r#"src="https://gitlab.example.com/g/p/uploads/a.png""#), "{html}");
        assert!(html.contains(r#"href="https://gitlab.example.com/g/p/-/issues/3""#), "{html}");
        assert!(html.contains(r#"href="https://x.org/a""#), "{html}");
        assert!(!html.contains("data:image"), "{html}");
    }
}
