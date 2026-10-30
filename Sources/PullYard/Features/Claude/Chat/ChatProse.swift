import AppKit
import SwiftUI

enum MDSegment {
    case prose([MDBlock])
    case block(MDBlock)

    static func group(_ blocks: [MDBlock]) -> [MDSegment] {
        var out: [MDSegment] = []
        var run: [MDBlock] = []
        for block in blocks {
            switch block {
            case .heading, .paragraph, .bullet, .quote:
                run.append(block)
            default:
                if !run.isEmpty { out.append(.prose(run)) }
                run = []
                out.append(.block(block))
            }
        }
        if !run.isEmpty { out.append(.prose(run)) }
        return out
    }
}

struct ProseText: View {
    let blocks: [MDBlock]
    var muted = false
    var baseStyle: NSFont.TextStyle = .body

    var body: some View {
        let text = ProseRenderer.render(blocks, muted: muted, base: baseStyle, zoom: TextZoom.shared.scale)
        ProseLayout(text: text) {
            ProseTextHost(text: text)
        }
    }
}

private struct ProseLayout: Layout {
    let text: NSAttributedString

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 600
        return CGSize(width: width, height: MainActor.assumeIsolated { ProseRenderer.height(of: text, width: width) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ProseTextHost: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> ProseTextView {
        let view = ProseTextView()
        view.apply(text)
        return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
        view.apply(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class ProseTextView: NSTextView {
    private weak var current: NSAttributedString?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.syAccent, .cursor: NSCursor.pointingHand]
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        delegate = self
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if selectedRange().length > 0, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    func apply(_ text: NSAttributedString) {
        guard text !== current else { return }
        current = text
        textStorage?.setAttributedString(text)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.size.width - newSize.width) > 0.5 {
            container.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
    }
}

extension ProseTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        LinkBrowser.open(url)
        return true
    }
}

@MainActor
enum ProseRenderer {
    private static let measureStorage = NSTextStorage()
    private static let measureLayout: NSLayoutManager = {
        let layout = NSLayoutManager()
        measureStorage.addLayoutManager(layout)
        layout.addTextContainer(measureContainer)
        return layout
    }()
    private static let measureContainer: NSTextContainer = {
        let c = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        return c
    }()
    private static var heights: [ObjectIdentifier: (width: CGFloat, height: CGFloat)] = [:]

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let id = ObjectIdentifier(text)
        if let hit = heights[id], abs(hit.width - width) < 0.5 { return hit.height }
        let layout = measureLayout
        measureStorage.setAttributedString(text)
        measureContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: measureContainer)
        let height = ceil(layout.usedRect(for: measureContainer).height)
        if heights.count > 2000 { heights.removeAll() }
        heights[id] = (width, height)
        return height
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 600
        c.totalCostLimit = 16 << 20
        return c
    }()

    static func render(_ blocks: [MDBlock], muted: Bool, base: NSFont.TextStyle, zoom: CGFloat) -> NSAttributedString {
        let id = "\(muted)\u{0}\(base.rawValue)\u{0}\(zoom)\u{0}\(blocks.hashValue)\u{0}\(blocks.count)" as NSString
        if let hit = cache.object(forKey: id) { return hit }
        let out = build(blocks, muted: muted, base: base, zoom: zoom)
        cache.setObject(out, forKey: id, cost: out.length * 2)
        return out
    }

    private static func font(_ style: NSFont.TextStyle, zoom: CGFloat, weight: NSFont.Weight? = nil) -> NSFont {
        let d = NSFontDescriptor.preferredFontDescriptor(forTextStyle: style)
        let size = TextZoom.size(d.pointSize, at: zoom)
        guard let weight else { return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size) }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static func build(_ blocks: [MDBlock], muted: Bool, base: NSFont.TextStyle, zoom: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = font(base, zoom: zoom)
        let color: NSColor = muted ? .syMuted : .syText
        let gap = round(body.pointSize * 0.62)
        let lineSpacing = round(body.pointSize * 0.18)

        func paragraphStyle(head: CGFloat = 0, first: CGFloat = 0, tab: CGFloat? = nil, after: CGFloat, before: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineSpacing
            p.headIndent = head
            p.firstLineHeadIndent = first
            p.paragraphSpacing = after
            p.paragraphSpacingBefore = before
            if let tab { p.tabStops = [NSTextTab(textAlignment: .left, location: tab)] }
            return p
        }

        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block {
            case .heading(let level, let s):
                let style: NSFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                let f = font(style, zoom: zoom, weight: level <= 2 ? (level == 1 ? .bold : .semibold) : .semibold)
                let line = inline(s, font: f, color: color)
                line.addAttribute(.paragraphStyle, value: paragraphStyle(after: round(gap * 0.6), before: index == 0 ? 0 : round(gap * 0.6)), range: NSRange(location: 0, length: line.length))
                out.append(line)
            case .paragraph(let s):
                let line = inline(s, font: body, color: color)
                line.addAttribute(.paragraphStyle, value: paragraphStyle(after: gap), range: NSRange(location: 0, length: line.length))
                out.append(line)
            case .bullet(let items):
                let markerFont = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
                for (i, item) in items.enumerated() {
                    let indent = CGFloat(item.indent) * round(body.pointSize * 1.3)
                    let markerWidth = max(round(body.pointSize * 1.4), (item.marker as NSString).size(withAttributes: [.font: markerFont]).width + 6)
                    let line = NSMutableAttributedString(string: item.marker + "\t", attributes: [.font: markerFont, .foregroundColor: NSColor.syDim])
                    line.append(inline(item.text, font: body, color: color))
                    let after = i == items.count - 1 ? gap : round(gap * 0.4)
                    line.addAttribute(.paragraphStyle, value: paragraphStyle(head: indent + markerWidth, first: indent, tab: indent + markerWidth, after: after), range: NSRange(location: 0, length: line.length))
                    out.append(line)
                    if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
                }
            case .quote(let s):
                let line = inline(s, font: body, color: .syMuted)
                let block = NSTextBlock()
                block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(.syLineStrong, for: .minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                let p = NSMutableParagraphStyle()
                p.setParagraphStyle(paragraphStyle(after: gap))
                p.textBlocks = [block]
                line.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: line.length))
                out.append(line)
            default:
                break
            }
            if !last { out.append(NSAttributedString(string: "\n")) }
        }
        if out.length > 0, let last = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.setParagraphStyle(last)
            p.paragraphSpacing = 0
            var range = NSRange()
            _ = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: &range)
            out.addAttribute(.paragraphStyle, value: p, range: range)
        }
        return out
    }

    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        var opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        let parsed = (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: round(font.pointSize * 0.92 * 2) / 2, weight: .regular)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var f = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                f = mono
                attrs[.backgroundColor] = NSColor.syLineStrong
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    f = NSFont(descriptor: d, size: font.pointSize) ?? font
                }
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
