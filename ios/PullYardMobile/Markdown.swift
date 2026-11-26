import SwiftUI
import UIKit

enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [ListItem])
    case ordered(items: [ListItem], start: Int)
    case quote(String)
    case code(language: String?, text: String)
    case suggestion(String)
    case table(rows: [[String]])
    case image(alt: String, url: URL)
    case details(summary: String, body: [MarkdownBlock])
    case rule

    struct ListItem: Hashable {
        let text: String
        let task: Bool?
        let depth: Int
    }
}

enum MarkdownParser {
    private static let cache = NSCache<NSString, BlocksBox>()
    private final class BlocksBox { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }

    static func blocks(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let cleaned = source
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let result = parse(cleaned.components(separatedBy: "\n"))
        cache.setObject(BlocksBox(result), forKey: key)
        return result
    }

    private static func parse(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1
                let text = code.joined(separator: "\n")
                blocks.append(language == "suggestion" ? .suggestion(text) : .code(language: language.isEmpty ? nil : language, text: text))
                continue
            }

            if trimmed.lowercased().hasPrefix("<details") {
                flushParagraph()
                var inner: [String] = []
                var summary = "Details"
                var depth = 0
                while index < lines.count {
                    let current = lines[index]
                    let lower = current.lowercased()
                    depth += lower.components(separatedBy: "<details").count - 1
                    depth -= lower.components(separatedBy: "</details>").count - 1
                    if let range = current.range(of: "<summary>(.*?)</summary>", options: [.regularExpression, .caseInsensitive]) {
                        summary = String(current[range]).replacingOccurrences(of: "</?summary>", with: "", options: [.regularExpression, .caseInsensitive]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    }
                    let stripped = current
                        .replacingOccurrences(of: "<summary>.*?</summary>", with: "", options: [.regularExpression, .caseInsensitive])
                        .replacingOccurrences(of: "</?details[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
                    inner.append(stripped)
                    index += 1
                    if depth <= 0 { break }
                }
                blocks.append(.details(summary: summary.trimmingCharacters(in: .whitespaces), body: parse(inner)))
                continue
            }

            if trimmed.isEmpty { flushParagraph(); index += 1; continue }

            if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushParagraph(); blocks.append(.rule); index += 1; continue
            }

            if let match = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph()
                let level = trimmed[match].filter { $0 == "#" }.count
                blocks.append(.heading(level: level, text: String(trimmed[match.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                index += 1; continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, lines[index + 1].range(of: "^\\s*\\|?\\s*:?-{2,}", options: .regularExpression) != nil {
                flushParagraph()
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[index].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !row.allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }) { rows.append(row) }
                    index += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }

            if let image = trimmed.range(of: "^!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)$", options: .regularExpression) {
                flushParagraph()
                let content = String(trimmed[image])
                let alt = content.components(separatedBy: "](").first.map { String($0.dropFirst(2)) } ?? ""
                let raw = content.components(separatedBy: "](").last.map { String($0.dropLast()).components(separatedBy: " ").first ?? "" } ?? ""
                if let url = URL(string: raw) { blocks.append(.image(alt: alt, url: url)) }
                index += 1; continue
            }
            if let src = trimmed.range(of: "(?i)^<img[^>]*src=\"([^\"]+)\"[^>]*>$", options: .regularExpression) {
                flushParagraph()
                let tag = String(trimmed[src])
                if let range = tag.range(of: "src=\"[^\"]+\"", options: .regularExpression),
                   let url = URL(string: String(tag[range]).replacingOccurrences(of: "src=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
                    blocks.append(.image(alt: "", url: url))
                }
                index += 1; continue
            }

            if listMarker(line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = []
                var ordered = false
                var start = 1
                while index < lines.count, let marker = listMarker(lines[index]) {
                    if items.isEmpty { ordered = marker.ordered; start = marker.start }
                    items.append(.init(text: marker.text, task: marker.task, depth: marker.depth))
                    index += 1
                    while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, listMarker(lines[index]) == nil, lines[index].hasPrefix("  ") {
                        if let last = items.popLast() { items.append(.init(text: last.text + " " + lines[index].trimmingCharacters(in: .whitespaces), task: last.task, depth: last.depth)) }
                        index += 1
                    }
                }
                blocks.append(ordered ? .ordered(items: items, start: start) : .bullet(items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private struct Marker: Equatable { let text: String; let ordered: Bool; let start: Int; let task: Bool?; let depth: Int }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        var ordered = false
        var start = 1
        var rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
        } else if let match = body.range(of: "^[0-9]{1,3}[.)] ", options: .regularExpression) {
            ordered = true
            start = Int(body[match].filter(\.isNumber)) ?? 1
            rest = body[match.upperBound...]
        } else {
            return nil
        }
        var task: Bool?
        if rest.hasPrefix("[ ] ") { task = false; rest = rest.dropFirst(4) }
        else if rest.lowercased().hasPrefix("[x] ") { task = true; rest = rest.dropFirst(4) }
        return Marker(text: String(rest), ordered: ordered, start: start, task: task, depth: min(3, indent / 2))
    }

    static func inline(_ text: String) -> AttributedString {
        let normalized = text
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</?(b|strong)>", with: "**", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</?(i|em)>", with: "*", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</?code>", with: "`", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        var result = (try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(normalized)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].backgroundColor = MobileTheme.sunken
        }
        return result
    }
}

struct MarkdownView: View {
    let markdown: String
    var collapsible = false
    @State private var expanded = false

    var body: some View {
        let blocks = MarkdownParser.blocks(markdown)
        let long = collapsible && markdown.count > 900 && blocks.count > 4
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((long && !expanded ? Array(blocks.prefix(4)) : blocks).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
            if long {
                Button(expanded ? "Show less" : "Show more") { withAnimation(.snappy) { expanded.toggle() } }
                    .mobileFont(size: 14, weight: .semibold)
                    .foregroundStyle(MobileTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownParser.inline(text))
                .mobileFont(size: level == 1 ? 21 : level == 2 ? 18 : 16, weight: .semibold)
                .foregroundStyle(MobileTheme.ink)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(MarkdownParser.inline(text)).mobileFont(size: 15).lineSpacing(3).foregroundStyle(MobileTheme.ink).textSelection(.enabled)
        case let .bullet(items):
            listView(items) { _, item in item.task == nil ? "•" : nil }
        case let .ordered(items, start):
            listView(items) { index, _ in "\(start + index)." }
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(MobileTheme.lineStrong).frame(width: 3)
                Text(MarkdownParser.inline(text)).mobileFont(size: 15).foregroundStyle(MobileTheme.muted).textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, text):
            CodeBlockView(language: language, code: text)
        case let .suggestion(text):
            VStack(alignment: .leading, spacing: 0) {
                Label("Suggested change", systemImage: "wand.and.stars").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.green).padding(10)
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).mobileFont(size: 13, design: .monospaced).foregroundStyle(MobileTheme.addText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 1)
                        .background(MobileTheme.addBG)
                }
            }
            .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: PYRadius.small))
            .clipShape(RoundedRectangle(cornerRadius: PYRadius.small))
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownParser.inline(cell)).mobileFont(size: 14, weight: rowIndex == 0 ? .semibold : .regular).foregroundStyle(MobileTheme.ink)
                            }
                        }
                        if rowIndex == 0 { Divider() }
                    }
                }
                .padding(12)
            }
            .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: PYRadius.small))
        case let .image(alt, url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: PYRadius.small))
                case .failure: Link(destination: url) { Label(alt.isEmpty ? "Image" : alt, systemImage: "photo") }.mobileFont(size: 14)
                default: RoundedRectangle(cornerRadius: PYRadius.small).fill(MobileTheme.sunken).frame(height: 140)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        case let .details(summary, body):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(body.enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
                }.padding(.top, 8)
            } label: {
                Text(MarkdownParser.inline(summary)).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
            }
            .tint(MobileTheme.accent)
        case .rule:
            Divider().overlay(MobileTheme.line)
        }
    }

    private func listView(_ items: [MarkdownBlock.ListItem], marker: @escaping (Int, MarkdownBlock.ListItem) -> String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let task = item.task {
                        Image(systemName: task ? "checkmark.square.fill" : "square")
                            .foregroundStyle(task ? MobileTheme.green : MobileTheme.muted)
                            .accessibilityLabel(task ? "Done" : "Not done")
                    } else if let symbol = marker(index, item) {
                        Text(symbol).foregroundStyle(MobileTheme.muted).monospacedDigit()
                    }
                    Text(MarkdownParser.inline(item.text)).foregroundStyle(item.task == true ? MobileTheme.muted : MobileTheme.ink).textSelection(.enabled)
                }
                .mobileFont(size: 15)
                .padding(.leading, CGFloat(item.depth) * 16)
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").mobileFont(size: 12, weight: .semibold, design: .monospaced).foregroundStyle(MobileTheme.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").mobileFont(size: 12, weight: .semibold)
                }
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(MobileTheme.line)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).mobileFont(size: 13, design: .monospaced).foregroundStyle(MobileTheme.ink).textSelection(.enabled).padding(12)
            }
        }
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: PYRadius.small))
        .overlay(RoundedRectangle(cornerRadius: PYRadius.small).stroke(MobileTheme.line))
    }
}

struct DiffHunkView: View {
    let hunk: String
    var maxLines = 6

    var body: some View {
        let lines = Array(hunk.components(separatedBy: "\n").filter { !$0.hasPrefix("@@") }.suffix(maxLines))
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .mobileFont(size: 12, design: .monospaced)
                        .foregroundStyle(line.hasPrefix("+") ? MobileTheme.addText : line.hasPrefix("-") ? MobileTheme.delText : MobileTheme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 1)
                        .frame(minWidth: 320, alignment: .leading)
                        .background(line.hasPrefix("+") ? MobileTheme.addBG : line.hasPrefix("-") ? MobileTheme.delBG : Color.clear)
                }
            }
            .padding(.vertical, 6)
        }
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: PYRadius.small))
        .accessibilityLabel("Code context")
    }
}
