import AppKit
import SwiftUI

final class LineNumberRuler: NSRulerView, NSViewToolTipOwner {
    private struct VisibleLine {
        let line: Int
        let top: CGFloat
        let height: CGFloat
        let firstHeight: CGFloat
    }

    static let blameColumnWidth: CGFloat = 210

    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private var blameFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private var blameDateFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var scale: CGFloat = 1
    private var numberWidth: CGFloat = 44
    private(set) var blame: BlameMap?
    private var hoverOid: String?
    private var hoverArea: NSTrackingArea?
    private var dateLabels: [String: String] = [:]
    var onOpenCommit: ((BlameCommit) -> Void)?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    private var blameWidth: CGFloat { blame == nil ? 0 : (Self.blameColumnWidth * scale).rounded() }

    func setScale(_ value: CGFloat) {
        guard value != scale else { return }
        scale = value
        font = .monospacedDigitSystemFont(ofSize: TextZoom.size(10.5, at: value), weight: .regular)
        blameFont = .systemFont(ofSize: TextZoom.size(10.5, at: value), weight: .medium)
        blameDateFont = .monospacedDigitSystemFont(ofSize: TextZoom.size(10, at: value), weight: .regular)
        reindex()
    }

    func reindex() {
        guard let text = textView?.string else { return }
        lineStarts = Self.lineStarts(text)
        let digits = max(3, String(lineStarts.count).count)
        numberWidth = CGFloat(digits) * 7.5 * scale + 14
        updateThickness()
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    func setBlame(_ map: BlameMap?) {
        blame = map
        hoverOid = nil
        dateLabels = [:]
        updateThickness()
        window?.invalidateCursorRects(for: self)
    }

    private func updateThickness() {
        let thickness = blameWidth + numberWidth
        if ruleThickness != thickness {
            ruleThickness = thickness
            scrollView?.tile()
            scrollView?.alignContentLeading(top: false)
        }
        needsDisplay = true
        updateToolTips()
    }

    @objc private func refresh() {
        needsDisplay = true
        updateToolTips()
    }

    private func lineIndex(for location: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func visibleLines() -> [VisibleLine] {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, lm.numberOfGlyphs > 0 else { return [] }
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let total = (tv.string as NSString).length
        var result: [VisibleLine] = []
        var line = lineIndex(for: chars.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(chars) || start > total { break }
            var first: NSRect
            var last: NSRect
            if start < total {
                let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : total
                let g = lm.glyphRange(forCharacterRange: NSRange(location: start, length: max(end - start, 1)), actualCharacterRange: nil)
                first = lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
                last = g.length > 1 ? lm.lineFragmentRect(forGlyphAt: NSMaxRange(g) - 1, effectiveRange: nil) : first
            } else {
                first = lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
                if total > 0, !lm.extraLineFragmentRect.isEmpty { first = lm.extraLineFragmentRect }
                last = first
            }
            let top = convert(NSPoint(x: 0, y: first.minY + tv.textContainerInset.height), from: tv).y
            result.append(VisibleLine(line: line, top: top, height: max(last.maxY - first.minY, first.height), firstHeight: first.height))
            line += 1
        }
        return result
    }

    private func line(atY y: CGFloat) -> Int? {
        visibleLines().first { y >= $0.top && y < $0.top + $0.height }?.line
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.sySunken.setFill()
        bounds.fill()
        NSColor.syLine.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let lines = visibleLines()
        if let blame { drawBlame(blame, lines) }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.syGutter]
        for v in lines {
            let label = "\(v.line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: v.top + (v.firstHeight - size.height) / 2), withAttributes: attrs)
        }
    }

    private func drawBlame(_ blame: BlameMap, _ lines: [VisibleLine]) {
        let width = blameWidth
        NSColor.syLine.setFill()
        NSRect(x: width - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let authorAttrs: [NSAttributedString.Key: Any] = [.font: blameFont, .foregroundColor: NSColor.syMuted, .paragraphStyle: paragraph]
        let dateAttrs: [NSAttributedString.Key: Any] = [.font: blameDateFont, .foregroundColor: NSColor.syDim]
        for (i, v) in lines.enumerated() {
            guard let r = blame.range(atLine: v.line) else { continue }
            let heat = BlameMap.heat(age: r.age)
            if r.commit.oid == hoverOid {
                NSColor.syAccent.withAlphaComponent(0.12).setFill()
                NSRect(x: 0, y: v.top, width: width - 1, height: v.height).fill()
            }
            NSColor.syAccent.withAlphaComponent(0.04 + 0.08 * heat).setFill()
            NSRect(x: 0, y: v.top, width: width - 1, height: v.height).fill()
            NSColor.syAccent.withAlphaComponent(0.15 + 0.8 * heat).setFill()
            NSRect(x: 0, y: v.top, width: 3, height: v.height).fill()
            let start = blame.isBlockStart(v.line)
            if start, v.line > 0 {
                NSColor.syLine.setFill()
                NSRect(x: 0, y: v.top, width: width - 1, height: 1).fill()
            }
            guard start || i == 0 else { continue }
            let date = dateLabel(r.commit) as NSString
            let dateSize = date.size(withAttributes: dateAttrs)
            let dateX = width - 8 - dateSize.width
            date.draw(at: NSPoint(x: dateX, y: v.top + (v.firstHeight - dateSize.height) / 2), withAttributes: dateAttrs)
            let author = r.commit.authorLabel as NSString
            let authorHeight = author.size(withAttributes: authorAttrs).height
            author.draw(in: NSRect(x: 10, y: v.top + (v.firstHeight - authorHeight) / 2, width: max(dateX - 18, 0), height: authorHeight), withAttributes: authorAttrs)
        }
    }

    private func dateLabel(_ commit: BlameCommit) -> String {
        if let cached = dateLabels[commit.oid] { return cached }
        let label = Fmt.rel(commit.committedDate)
        dateLabels[commit.oid] = label
        return label
    }

    private func blocks(_ lines: [VisibleLine]) -> [(rect: NSRect, range: BlameRange)] {
        guard let blame else { return [] }
        var result: [(NSRect, BlameRange)] = []
        for v in lines {
            guard let r = blame.range(atLine: v.line) else { continue }
            if let last = result.last, last.1.commit.oid == r.commit.oid, !blame.isBlockStart(v.line) {
                result[result.count - 1].0 = last.0.union(NSRect(x: 0, y: v.top, width: blameWidth, height: v.height))
            } else {
                result.append((NSRect(x: 0, y: v.top, width: blameWidth, height: v.height), r))
            }
        }
        return result
    }

    private func updateToolTips() {
        removeAllToolTips()
        guard blame != nil else { return }
        for block in blocks(visibleLines()) {
            addToolTip(block.rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let blame, let line = line(atY: point.y), let r = blame.range(atLine: line) else { return "" }
        let c = r.commit
        var who = c.author?.name ?? c.authorLabel
        if let login = c.author?.user?.login, login != who { who += " (@\(login))" }
        return "\(c.abbreviatedOid) \(c.messageHeadline)\n\(who) · \(Fmt.full.string(from: c.committedDate))\nClick to open commit"
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if blame != nil { addCursorRect(NSRect(x: 0, y: bounds.minY, width: blameWidth, height: bounds.height), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var oid: String?
        if let blame, p.x < blameWidth, let line = line(atY: p.y) { oid = blame.range(atLine: line)?.commit.oid }
        if oid != hoverOid {
            hoverOid = oid
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverOid != nil {
            hoverOid = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let blame, p.x < blameWidth else { return super.mouseDown(with: event) }
        if let line = line(atY: p.y), let r = blame.range(atLine: line) { onOpenCommit?(r.commit) }
    }
}

struct CodeTextView: NSViewRepresentable {
    let text: String
    let ext: String
    var wrap = false
    var blame: BlameMap?
    var onOpenCommit: ((BlameCommit) -> Void)?
    var zoom = TextZoom.shared.scale

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        _ = tv.layoutManager
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = .sySunken
        tv.insertionPointColor = .syAccent
        tv.selectedTextAttributes = [.backgroundColor: NSColor.syAccent.withAlphaComponent(0.25)]
        scroll.backgroundColor = .sySunken
        scroll.drawsBackground = true
        scroll.hasHorizontalScroller = true
        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        ruler.setScale(zoom)
        apply(scroll, tv)
        context.coordinator.wrap = wrap
        context.coordinator.zoom = zoom
        ruler.onOpenCommit = onOpenCommit
        ruler.setBlame(blame)
        DispatchQueue.main.async { scroll.alignContentLeading(top: true) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text || context.coordinator.wrap != wrap {
            apply(scroll, tv)
            context.coordinator.wrap = wrap
        }
        if context.coordinator.zoom != zoom {
            context.coordinator.zoom = zoom
            (scroll.verticalRulerView as? LineNumberRuler)?.setScale(zoom)
            if let storage = tv.textStorage {
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            }
        }
        if let ruler = scroll.verticalRulerView as? LineNumberRuler {
            ruler.onOpenCommit = onOpenCommit
            if ruler.blame?.id != blame?.id { ruler.setBlame(blame) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var wrap: Bool?
        var zoom: CGFloat = 1
    }

    private var font: NSFont { .monospacedSystemFont(ofSize: TextZoom.size(12, at: zoom), weight: .regular) }

    private func apply(_ scroll: NSScrollView, _ tv: NSTextView) {
        if wrap {
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            tv.isHorizontallyResizable = true
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        tv.textStorage?.setAttributedString(SyntaxHighlighter.attributed(text, ext: ext, font: font))
        (scroll.verticalRulerView as? LineNumberRuler)?.reindex()
        scroll.alignContentLeading(top: true)
    }
}

extension NSScrollView {
    func alignContentLeading(top: Bool) {
        let insets = contentView.contentInsets
        contentView.scroll(to: NSPoint(x: -insets.left, y: top ? -insets.top : contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}
