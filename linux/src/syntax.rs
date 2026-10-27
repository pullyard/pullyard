use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Token {
    Keyword,
    Number,
    Str,
    Comment,
}

const KEYWORDS: &[&str] = &[
    "func", "let", "var", "if", "else", "for", "while", "return", "class", "struct", "enum", "protocol", "extension", "import", "guard", "switch", "case", "default", "break", "continue", "in", "is", "as", "try", "catch", "throw", "throws", "async",
    "await", "static", "private", "public", "internal", "final", "override", "init", "self", "super", "nil", "true", "false", "null", "undefined", "new", "this", "const", "function", "export", "from", "interface", "type", "implements",
    "extends", "abstract", "void", "int", "double", "bool", "String", "late", "required", "factory", "get", "set", "with", "yield", "def", "elif", "pass", "lambda", "None", "True", "False", "and", "or", "not", "package", "fun", "val", "object",
    "when", "data", "sealed", "go", "chan", "defer", "map", "range", "fn", "mut", "pub", "impl", "trait", "use", "mod", "match", "where", "some", "any", "do", "repeat", "typealias", "mixin", "dynamic", "of", "delete", "typeof", "instanceof",
    "unsafe", "fileprivate", "open", "inout", "echo", "then", "fi", "esac", "done", "local",
];

const HASH_COMMENT: &[&str] = &["py", "sh", "bash", "zsh", "rb", "yaml", "yml", "toml", "mk", "makefile", "dockerfile", "r", "pl", "conf", "cfg", "ini", "gitignore", "env"];
const SLASH_COMMENT: &[&str] = &[
    "swift", "dart", "js", "jsx", "ts", "tsx", "kt", "kts", "java", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "scala", "groovy", "gradle", "php", "css", "scss", "less", "json5", "proto",
];
const MARKUP_COMMENT: &[&str] = &["html", "xml", "vue", "svelte"];
const OTHER_CODE: &[&str] = &["lua", "sql"];

static KEYWORD_SET: LazyLock<HashSet<&'static str>> = LazyLock::new(|| KEYWORDS.iter().copied().collect());
static STRING_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#).expect("string regex"));
static NUMBER_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b").expect("number regex"));
static WORD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b[A-Za-z_][A-Za-z0-9_]*\b").expect("word regex"));
static SLASH_COMMENT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"//[^\n]*|/\*[\s\S]*?\*/").expect("slash comment regex"));
static HASH_COMMENT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)(?:^|\s)#[^\n]*").expect("hash comment regex"));
static HTML_COMMENT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<!--[\s\S]*?-->").expect("html comment regex"));

pub fn ext_for_path(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && !ext.is_empty() => ext.to_lowercase(),
        _ => name.trim_start_matches('.').to_lowercase(),
    }
}

pub fn supports(ext: &str) -> bool {
    let e = ext.to_lowercase();
    [SLASH_COMMENT, HASH_COMMENT, MARKUP_COMMENT, OTHER_CODE].iter().any(|set| set.contains(&e.as_str()))
}

fn comment_regex(ext: &str) -> Option<&'static Regex> {
    if SLASH_COMMENT.contains(&ext) {
        Some(&SLASH_COMMENT_RE)
    } else if HASH_COMMENT.contains(&ext) {
        Some(&HASH_COMMENT_RE)
    } else if MARKUP_COMMENT.contains(&ext) {
        Some(&HTML_COMMENT_RE)
    } else {
        None
    }
}

pub fn tokens(text: &str, ext: &str) -> Vec<(usize, usize, Token)> {
    let ext = ext.to_lowercase();
    if text.is_empty() || !supports(&ext) {
        return vec![];
    }
    let mut paint: Vec<Option<Token>> = vec![None; text.len()];
    let mut fill = |start: usize, end: usize, token: Token| {
        for slot in &mut paint[start..end] {
            *slot = Some(token);
        }
    };
    for m in WORD_RE.find_iter(text) {
        if KEYWORD_SET.contains(m.as_str()) {
            fill(m.start(), m.end(), Token::Keyword);
        }
    }
    for m in NUMBER_RE.find_iter(text) {
        fill(m.start(), m.end(), Token::Number);
    }
    for m in STRING_RE.find_iter(text) {
        fill(m.start(), m.end(), Token::Str);
    }
    if let Some(re) = comment_regex(&ext) {
        for m in re.find_iter(text) {
            fill(m.start(), m.end(), Token::Comment);
        }
    }
    let mut out: Vec<(usize, usize, Token)> = vec![];
    let mut i = 0;
    while i < paint.len() {
        let Some(token) = paint[i] else {
            i += 1;
            continue;
        };
        let start = i;
        while i < paint.len() && paint[i] == Some(token) {
            i += 1;
        }
        out.push((start, i, token));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spans(text: &str, ext: &str) -> Vec<(String, Token)> {
        tokens(text, ext).into_iter().map(|(s, e, t)| (text[s..e].to_string(), t)).collect()
    }

    #[test]
    fn ext_from_path() {
        assert_eq!(ext_for_path("src/main.rs"), "rs");
        assert_eq!(ext_for_path("a/Makefile"), "makefile");
        assert_eq!(ext_for_path(".gitignore"), "gitignore");
        assert_eq!(ext_for_path("dir.v2/Dockerfile"), "dockerfile");
    }

    #[test]
    fn unsupported_ext_is_plain() {
        assert!(tokens("let x = 1", "md").is_empty());
        assert!(!supports("txt"));
        assert!(supports("RS"));
    }

    #[test]
    fn keywords_numbers_strings_and_comments() {
        assert_eq!(
            spans("let x = 42 // \"note\"", "rs"),
            vec![("let".to_string(), Token::Keyword), ("42".to_string(), Token::Number), ("// \"note\"".to_string(), Token::Comment)]
        );
        assert_eq!(spans("return \"if 1\"", "ts"), vec![("return".to_string(), Token::Keyword), ("\"if 1\"".to_string(), Token::Str)]);
    }

    #[test]
    fn hash_comments_for_scripts() {
        assert_eq!(spans("x = 1 # done", "py"), vec![("1".to_string(), Token::Number), (" # done".to_string(), Token::Comment)]);
        assert_eq!(spans("color: #fff", "css"), vec![]);
    }

    #[test]
    fn spans_respect_char_boundaries() {
        for (s, e, _) in tokens("let é = \"ü\" // ß", "rs") {
            assert!("let é = \"ü\" // ß".is_char_boundary(s));
            assert!("let é = \"ü\" // ß".is_char_boundary(e));
        }
    }
}
