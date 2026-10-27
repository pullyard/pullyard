import AppKit

enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "class", "struct", "enum", "protocol", "extension", "import", "guard", "switch", "case", "default", "break", "continue", "in", "is", "as", "try", "catch", "throw", "throws", "async", "await", "static", "private", "public", "internal", "final", "override", "init", "self", "super", "nil", "true", "false", "null", "undefined", "new", "this", "const", "function", "export", "from", "interface", "type", "implements", "extends", "abstract", "void", "int", "double", "bool", "String", "late", "required", "factory", "get", "set", "with", "yield", "def", "elif", "pass", "lambda", "None", "True", "False", "and", "or", "not", "package", "fun", "val", "object", "when", "data", "sealed", "go", "chan", "defer", "map", "range", "fn", "mut", "pub", "impl", "trait", "use", "mod", "match", "where", "some", "any", "do", "repeat", "typealias", "mixin", "dynamic", "final", "of", "delete", "typeof", "instanceof", "static", "unsafe", "fileprivate", "open", "inout", "where", "echo", "then", "fi", "esac", "done", "local"
    ]

    private static let hashComment: Set<String> = ["py", "sh", "bash", "zsh", "rb", "yaml", "yml", "toml", "mk", "makefile", "dockerfile", "r", "pl", "conf", "cfg", "ini", "gitignore", "env"]
    private static let slashComment: Set<String> = ["swift", "dart", "js", "jsx", "ts", "tsx", "kt", "kts", "java", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "scala", "groovy", "gradle", "php", "css", "scss", "less", "json5", "proto"]
    private static let markupComment: Set<String> = ["html", "xml", "vue", "svelte"]
    private static let otherCode: Set<String> = ["lua", "sql"]

    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
    private static let slashCommentRegex = try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#)
    private static let hashCommentRegex = try! NSRegularExpression(pattern: #"(?m)(?:^|\s)#[^\n]*"#)
    private static let htmlCommentRegex = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

    static func ext(forPath path: String) -> String {
        let ns = path as NSString
        return ns.pathExtension.isEmpty ? ns.lastPathComponent : ns.pathExtension
    }

    static func supports(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return slashComment.contains(e) || hashComment.contains(e) || markupComment.contains(e) || otherCode.contains(e)
    }

    static func attributed(_ text: String, ext: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.syText])
        guard text.utf16.count < 400_000 else { return result }
        highlight(result, range: NSRange(location: 0, length: result.length), ext: ext)
        return result
    }

    static func highlight(_ result: NSMutableAttributedString, range: NSRange, ext: String) {
        let e = ext.lowercased()
        guard supports(e), range.length > 0 else { return }
        let text = result.string
        let ns = text as NSString

        wordRegex.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let r = m?.range, keywords.contains(ns.substring(with: r)) else { return }
            result.addAttribute(.foregroundColor, value: NSColor.syCoral, range: r)
        }
        numberRegex.enumerateMatches(in: text, range: range) { m, _, _ in
            if let r = m?.range { result.addAttribute(.foregroundColor, value: NSColor.syViolet, range: r) }
        }
        stringRegex.enumerateMatches(in: text, range: range) { m, _, _ in
            if let r = m?.range { result.addAttribute(.foregroundColor, value: NSColor.syGreen, range: r) }
        }
        let commentRegex: NSRegularExpression? = slashComment.contains(e) ? slashCommentRegex : hashComment.contains(e) ? hashCommentRegex : markupComment.contains(e) ? htmlCommentRegex : nil
        commentRegex?.enumerateMatches(in: text, range: range) { m, _, _ in
            if let r = m?.range { result.addAttribute(.foregroundColor, value: NSColor.syDim, range: r) }
        }
    }
}
