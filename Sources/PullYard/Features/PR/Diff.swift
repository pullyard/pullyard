import Foundation

struct DiffLine: Identifiable {
    enum Kind { case hunk, context, add, del, meta }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    var outsideHunk = false

    var anchorSide: String { kind == .del ? "LEFT" : "RIGHT" }
    var anchorLine: Int? { kind == .del ? oldLine : newLine }
    var commentable: Bool { !outsideHunk && (kind == .add || kind == .del || kind == .context) }
}

enum DiffExpand {
    struct Hunk {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    static func header(_ text: String) -> Hunk? {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int, _ fallback: Int) -> Int {
            guard let r = Range(m.range(at: i), in: text) else { return fallback }
            return Int(text[r]) ?? fallback
        }
        return Hunk(oldStart: group(1, 0), oldCount: group(2, 1), newStart: group(3, 0), newCount: group(4, 1))
    }

    static func fullFile(_ lines: [DiffLine], newText: [String]) -> [DiffLine] {
        var out: [DiffLine] = []
        var cursor = 1
        var lastOld = 0
        var lastNew = 0
        var nextID = 1_000_000
        func fill(upTo end: Int) {
            guard cursor <= end else { return }
            let delta = lastOld - lastNew
            for n in cursor...end where n - 1 < newText.count {
                out.append(DiffLine(id: nextID, kind: .context, text: newText[n - 1], oldLine: n + delta, newLine: n, outsideHunk: true))
                nextID += 1
            }
            cursor = max(cursor, end + 1)
        }
        for line in lines {
            if line.kind == .hunk, let h = header(line.text) {
                fill(upTo: h.newStart - 1)
                lastOld = h.oldStart - 1
                lastNew = h.newStart - 1
                cursor = max(cursor, h.newStart)
                continue
            }
            if line.kind == .meta { continue }
            out.append(line)
            if let o = line.oldLine { lastOld = o }
            if let n = line.newLine {
                lastNew = n
                cursor = max(cursor, n + 1)
            }
        }
        fill(upTo: newText.count)
        return out
    }
}

struct DiffFile: Identifiable {
    let id: String
    let previousFilename: String?
    let status: String
    let additions: Int
    let deletions: Int
    let lines: [DiffLine]
    let hasPatch: Bool

    init(_ f: PRFile) {
        id = f.filename
        previousFilename = f.previousFilename
        status = f.status
        additions = f.additions
        deletions = f.deletions
        hasPatch = f.patch != nil
        lines = f.patch.map(DiffParser.parse) ?? []
    }

    var syntaxExt: String {
        lines.count > 20_000 ? "" : SyntaxHighlighter.ext(forPath: id)
    }

    var statusLetter: String {
        switch status {
        case "added": return "A"
        case "removed": return "D"
        case "renamed": return "R"
        case "copied": return "C"
        default: return "M"
        }
    }
}

struct DiffAnchor: Hashable {
    let path: String
    let line: Int
    let side: String
}

enum DiffParser {
    static func parse(_ patch: String) -> [DiffLine] {
        var result: [DiffLine] = []
        result.reserveCapacity(patch.count / 40)
        var old = 0, new = 0, idx = 0
        patch.enumerateLines { raw, _ in
            defer { idx += 1 }
            if raw.hasPrefix("@@") {
                let (o, n) = hunkStart(raw)
                old = o
                new = n
                result.append(DiffLine(id: idx, kind: .hunk, text: raw, oldLine: nil, newLine: nil))
                return
            }
            let first = raw.first
            let body = raw.isEmpty ? "" : String(raw.dropFirst())
            switch first {
            case "+":
                result.append(DiffLine(id: idx, kind: .add, text: body, oldLine: nil, newLine: new))
                new += 1
            case "-":
                result.append(DiffLine(id: idx, kind: .del, text: body, oldLine: old, newLine: nil))
                old += 1
            case "\\":
                result.append(DiffLine(id: idx, kind: .meta, text: raw, oldLine: nil, newLine: nil))
            default:
                result.append(DiffLine(id: idx, kind: .context, text: body, oldLine: old, newLine: new))
                old += 1
                new += 1
            }
        }
        return result
    }

    private static func hunkStart(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            let digits = token.dropFirst().split(separator: ",").first ?? "1"
            return Int(digits) ?? 1
        }
        return (start(parts.first { $0.hasPrefix("-") }), start(parts.first { $0.hasPrefix("+") }))
    }
}
