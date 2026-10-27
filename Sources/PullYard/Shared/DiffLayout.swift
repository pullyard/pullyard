import Foundation

enum DiffPrefs {
    static let wrapKey = "diff.wrapLines"
    static let splitKey = "diff.splitView"
    static let splitMinWidth: CGFloat = 900
}

enum SplitDiffRow {
    case full(DiffLine)
    case pair(DiffLine?, DiffLine?)
}

enum DiffSplit {
    static func pair(_ lines: [DiffLine]) -> [SplitDiffRow] {
        var out: [SplitDiffRow] = []
        out.reserveCapacity(lines.count)
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append(.pair(i < removed.count ? removed[i] : nil, i < added.count ? added[i] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.kind {
            case .del:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .add:
                added.append(line)
            case .context:
                flush()
                out.append(.pair(line, line))
            case .hunk, .meta:
                flush()
                out.append(.full(line))
            }
        }
        flush()
        return out
    }
}

enum DiffText {
    static let continuationIndent = 2

    static func leadingColumns(_ text: String, tabWidth: Int = 4) -> Int {
        var columns = 0
        for c in text.utf16 {
            if c == 32 {
                columns += 1
            } else if c == 9 {
                columns += tabWidth - columns % tabWidth
            } else {
                break
            }
        }
        return columns
    }

    static func hangingColumns(_ text: String, limit: Int, tabWidth: Int = 4) -> Int {
        max(0, min(limit, 1 + leadingColumns(text, tabWidth: tabWidth) + continuationIndent))
    }

    static func expandTabs(_ text: String, tabWidth: Int = 4) -> String {
        guard text.utf16.contains(9) else { return text }
        var out = ""
        out.reserveCapacity(text.utf16.count + tabWidth * 2)
        var column = 0
        for c in text {
            if c == "\t" {
                let n = tabWidth - column % tabWidth
                out.append(String(repeating: " ", count: n))
                column += n
            } else {
                out.append(c)
                column += 1
            }
        }
        return out
    }
}
