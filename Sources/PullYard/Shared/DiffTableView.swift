import AppKit
import SwiftUI

enum DiffTableRow {
    case line(id: String, line: DiffLine, commentable: Bool, ext: String = "")
    case split(id: String, left: DiffLine?, right: DiffLine?, commentable: Bool, ext: String)
    case view(id: String, group: Bool, content: () -> AnyView)

    var id: String {
        switch self {
        case .line(let id, _, _, _): return id
        case .split(let id, _, _, _, _): return id
        case .view(let id, _, _): return id
        }
    }

    var isHunk: Bool {
        if case .line(_, let line, _, _) = self { return line.kind == .hunk }
        return false
    }

    var isGroup: Bool {
        if case .view(_, let group, _) = self { return group }
        return false
    }
}

private enum DiffStyle {
    private(set) static var scale: CGFloat = 1
    private(set) static var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private(set) static var gutterWidth: CGFloat = 112
    private(set) static var splitGutterWidth: CGFloat = 64
    static let vPad: CGFloat = 1.5
    static let addBG = NSColor.syAddBG
    static let delBG = NSColor.syDelBG
    static let hunkBG = NSColor.syHunkBG
    static let fillerBG = NSColor.syLine
    static let maxHighlightLength = 2000
    private(set) static var lineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)
    private(set) static var charWidth: CGFloat = measureCharWidth(font)
    private static var wrapStyles: [Int: NSParagraphStyle] = [:]
    static let clipStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        return p
    }()

    static func apply(scale: CGFloat) {
        guard scale != self.scale else { return }
        self.scale = scale
        font = .monospacedSystemFont(ofSize: TextZoom.size(12, at: scale), weight: .regular)
        gutterWidth = (112 * scale).rounded()
        splitGutterWidth = (64 * scale).rounded()
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        charWidth = measureCharWidth(font)
        gutterAttributes = [.font: font, .foregroundColor: NSColor.syGutter]
        wrapStyles.removeAll()
    }

    private static func measureCharWidth(_ font: NSFont) -> CGFloat {
        max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
    }

    static func color(_ kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .add: return .syAddText
        case .del: return .syDelText
        case .hunk, .meta: return .syHunkText
        default: return .syText
        }
    }

    private(set) static var gutterAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.syGutter]

    static func codeText(_ line: DiffLine) -> String {
        switch line.kind {
        case .add: return "+" + DiffText.expandTabs(line.text)
        case .del: return "-" + DiffText.expandTabs(line.text)
        case .context: return " " + DiffText.expandTabs(line.text)
        default: return line.text
        }
    }

    static func isCode(_ kind: DiffLine.Kind) -> Bool {
        kind == .add || kind == .del || kind == .context
    }

    static func unifiedCodeWidth(_ width: CGFloat) -> CGFloat {
        max(80, width - gutterWidth - 8)
    }

    static func splitCodeWidth(_ width: CGFloat) -> CGFloat {
        max(60, floor(width / 2) - splitGutterWidth - 8)
    }

    static func paragraph(_ line: DiffLine, codeWidth: CGFloat, wrap: Bool) -> NSParagraphStyle {
        guard wrap else { return clipStyle }
        let columns = isCode(line.kind) ? DiffText.hangingColumns(line.text, limit: Int(codeWidth / charWidth / 2)) : 0
        if let cached = wrapStyles[columns] { return cached }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.headIndent = CGFloat(columns) * charWidth
        wrapStyles[columns] = p
        return p
    }

    static func attributed(_ line: DiffLine, ext: String, codeWidth: CGFloat, wrap: Bool, highlight: Bool) -> NSAttributedString {
        let text = codeText(line)
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph(line, codeWidth: codeWidth, wrap: wrap), .foregroundColor: color(line.kind)])
        if highlight, isCode(line.kind), !ext.isEmpty, s.length > 1, s.length <= maxHighlightLength {
            SyntaxHighlighter.highlight(s, range: NSRange(location: 1, length: s.length - 1), ext: ext)
        }
        return s
    }

    static func height(_ line: DiffLine?, codeWidth: CGFloat, wrap: Bool) -> CGFloat {
        guard let line else { return lineHeight + vPad * 2 }
        let extra = vPad * 2 + (line.kind == .hunk ? 4 : 0)
        guard wrap else { return lineHeight + extra }
        let length = line.text.utf16.count + 1
        if length < Int(codeWidth / charWidth) - 1, !line.text.utf16.contains(9) { return lineHeight + extra }
        let rect = attributed(line, ext: "", codeWidth: codeWidth, wrap: true, highlight: false)
            .boundingRect(with: NSSize(width: codeWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return max(lineHeight, ceil(rect.height)) + extra
    }

    static func gutter(_ number: Int?) -> String {
        let s = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, 5 - s.count)) + s
    }
}

final class DiffRenderState {
    var wrap = true
    var offset: CGFloat = 0
}

final class DiffLineCell: NSView {
    var line: DiffLine?
    var left: DiffLine?
    var right: DiffLine?
    var isSplit = false
    var text: NSAttributedString?
    var leftText: NSAttributedString?
    var rightText: NSAttributedString?
    var commentable = false
    var onComment: ((DiffLine) -> Void)?
    weak var state: DiffRenderState?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSplit {
            drawSplit()
        } else if let line {
            drawUnified(line)
        }
    }

    private func drawUnified(_ line: DiffLine) {
        switch line.kind {
        case .add: DiffStyle.addBG.setFill(); bounds.fill()
        case .del: DiffStyle.delBG.setFill(); bounds.fill()
        case .hunk: DiffStyle.hunkBG.setFill(); bounds.fill()
        default: break
        }
        let pad: CGFloat = line.kind == .hunk ? 3.5 : DiffStyle.vPad
        if line.kind != .hunk {
            let gutter = DiffStyle.gutter(line.oldLine) + " " + DiffStyle.gutter(line.newLine) + (commentable && line.commentable ? " +" : "  ")
            (gutter as NSString).draw(at: NSPoint(x: 4, y: pad), withAttributes: DiffStyle.gutterAttributes)
        }
        let x = DiffStyle.gutterWidth
        drawCode(text, in: NSRect(x: x, y: pad, width: bounds.width - x - 8, height: bounds.height - pad), scrolls: line.kind != .hunk)
    }

    private func drawSplit() {
        let half = floor(bounds.width / 2)
        drawSide(left, text: leftText, x: 0, width: half, old: true)
        drawSide(right, text: rightText, x: half, width: bounds.width - half, old: false)
        NSColor.syLineStrong.setFill()
        NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
    }

    private func drawSide(_ line: DiffLine?, text: NSAttributedString?, x: CGFloat, width: CGFloat, old: Bool) {
        let rect = NSRect(x: x, y: 0, width: width, height: bounds.height)
        guard let line else {
            DiffStyle.fillerBG.setFill()
            rect.fill()
            return
        }
        switch line.kind {
        case .add: DiffStyle.addBG.setFill(); rect.fill()
        case .del: DiffStyle.delBG.setFill(); rect.fill()
        default: break
        }
        let gutter = DiffStyle.gutter(old ? line.oldLine : line.newLine) + (commentable && line.commentable ? " +" : "  ")
        (gutter as NSString).draw(at: NSPoint(x: x + 4, y: DiffStyle.vPad), withAttributes: DiffStyle.gutterAttributes)
        let codeX = x + DiffStyle.splitGutterWidth
        drawCode(text, in: NSRect(x: codeX, y: DiffStyle.vPad, width: width - DiffStyle.splitGutterWidth - 8, height: bounds.height - DiffStyle.vPad), scrolls: true)
    }

    private func drawCode(_ text: NSAttributedString?, in rect: NSRect, scrolls: Bool) {
        guard let text, rect.width > 0 else { return }
        if state?.wrap ?? true {
            text.draw(with: rect, options: [.usesLineFragmentOrigin])
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX, y: 0, width: rect.width + 6, height: bounds.height).clip()
        text.draw(at: NSPoint(x: rect.minX - (scrolls ? state?.offset ?? 0 : 0), y: rect.minY))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func commentTarget(at p: NSPoint) -> DiffLine? {
        guard commentable else { return nil }
        if isSplit {
            let half = floor(bounds.width / 2)
            if p.x < DiffStyle.splitGutterWidth { return left?.commentable == true ? left : nil }
            if p.x >= half, p.x < half + DiffStyle.splitGutterWidth { return right?.commentable == true ? right : nil }
            return nil
        }
        return p.x < DiffStyle.gutterWidth && line?.commentable == true ? line : nil
    }

    private func line(at p: NSPoint) -> DiffLine? {
        guard isSplit else { return line }
        return p.x < floor(bounds.width / 2) ? (left ?? right) : (right ?? left)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let target = commentTarget(at: p) {
            onComment?(target)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        guard commentable else { return }
        if isSplit {
            let half = floor(bounds.width / 2)
            if left?.commentable == true { addCursorRect(NSRect(x: 0, y: 0, width: DiffStyle.splitGutterWidth, height: bounds.height), cursor: .pointingHand) }
            if right?.commentable == true { addCursorRect(NSRect(x: half, y: 0, width: DiffStyle.splitGutterWidth, height: bounds.height), cursor: .pointingHand) }
        } else if line?.commentable == true {
            addCursorRect(NSRect(x: 0, y: 0, width: DiffStyle.gutterWidth, height: bounds.height), cursor: .pointingHand)
        }
    }

    private var menuLine: DiffLine?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let target = line(at: p) else { return nil }
        menuLine = target
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy line", action: #selector(copyLine), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        if commentable, target.commentable {
            let c = NSMenuItem(title: "Comment on line", action: #selector(comment), keyEquivalent: "")
            c.target = self
            menu.addItem(c)
        }
        return menu
    }

    @objc private func copyLine() { if let menuLine { copyToPasteboard(menuLine.text) } }
    @objc private func comment() { if let menuLine { onComment?(menuLine) } }
}

final class HostingCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private struct HeightReporter: ViewModifier {
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { report(g.size.height) }
                    .onChange(of: g.size.height) { _, h in report(h) }
            })
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

final class DiffTable: NSTableView {
    var onHorizontalScroll: ((NSEvent) -> Bool)?

    override func drawGrid(inClipRect clipRect: NSRect) {}

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), onHorizontalScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

final class DiffHorizontalBar: NSView {
    var proportion: CGFloat = 1 { didSet { needsDisplay = true } }
    var position: CGFloat = 0 { didSet { needsDisplay = true } }
    var onScroll: ((CGFloat) -> Void)?
    private var dragOrigin: (x: CGFloat, position: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityOrientation(.horizontal)
        setAccessibilityLabel("Horizontal scroll")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var knobWidth: CGFloat { max(36, (bounds.width - 8) * min(1, proportion)) }

    private var knobRect: NSRect {
        let travel = max(0, bounds.width - 8 - knobWidth)
        return NSRect(x: 4 + travel * position, y: (bounds.height - 6) / 2, width: knobWidth, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.syDim.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: 3, yRadius: 3).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !knobRect.insetBy(dx: 0, dy: -4).contains(p) {
            let travel = max(1, bounds.width - 8 - knobWidth)
            onScroll?(min(1, max(0, (p.x - 4 - knobWidth / 2) / travel)))
        }
        dragOrigin = (p.x, position)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        let travel = max(1, bounds.width - 8 - knobWidth)
        onScroll?(min(1, max(0, dragOrigin.position + (p.x - dragOrigin.x) / travel)))
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func accessibilityValue() -> Any? { NSNumber(value: Double(position)) }
}

final class DiffContainerView: NSView {
    let scroll = NSScrollView()
    let bar = DiffHorizontalBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(scroll)
        addSubview(bar)
        bar.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeSubviews()
    }

    override func layout() {
        super.layout()
        placeSubviews()
    }

    private func placeSubviews() {
        scroll.frame = bounds
        bar.frame = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
    }
}

final class DiffNavigator {
    fileprivate weak var coordinator: DiffTableView.Coordinator?

    func currentGroupID() -> String? { coordinator?.currentGroupID() }
    func jumpHunk(_ step: Int) { coordinator?.jump(step, where: \.isHunk) }
    func scroll(to id: String) { coordinator?.scroll(to: id, remember: true) }
}

struct DiffTableView: NSViewRepresentable {
    let rows: [DiffTableRow]
    var version: Int = 0
    var scrollTarget: String?
    var scrollToken = 0
    var active = true
    var wrap = true
    var navigator: DiffNavigator?
    var onTopGroup: ((String?) -> Void)?
    var onKey: ((String) -> Bool)?
    var onComment: ((String, DiffLine) -> Void)?
    var zoom = TextZoom.shared.scale

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffContainerView {
        let table = DiffTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let container = DiffContainerView()
        let scroll = container.scroll
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.table = table
        context.coordinator.bar = container.bar
        table.onHorizontalScroll = { [weak coordinator = context.coordinator] event in coordinator?.scrollHorizontally(event) ?? false }
        container.bar.onScroll = { [weak coordinator = context.coordinator] fraction in coordinator?.setOffset(fraction: fraction) }
        context.coordinator.observeWidth(scroll)
        context.coordinator.observeScroll(scroll)
        navigator?.coordinator = context.coordinator
        context.coordinator.active = active
        context.coordinator.onTopGroup = onTopGroup
        context.coordinator.lastScrollToken = scrollToken
        context.coordinator.update(rows: rows, version: version, zoom: zoom, wrap: wrap, onComment: onComment)
        context.coordinator.setKeyHandler(onKey)
        return container
    }

    func updateNSView(_ container: DiffContainerView, context: Context) {
        navigator?.coordinator = context.coordinator
        context.coordinator.setKeyHandler(onKey)
        context.coordinator.active = active
        context.coordinator.onTopGroup = onTopGroup
        context.coordinator.update(rows: rows, version: version, zoom: zoom, wrap: wrap, onComment: onComment)
        if let target = scrollTarget, target != context.coordinator.lastScrollTarget || scrollToken != context.coordinator.lastScrollToken {
            context.coordinator.lastScrollTarget = target
            context.coordinator.lastScrollToken = scrollToken
            context.coordinator.scroll(to: target)
        }
    }

    static func dismantleNSView(_ container: DiffContainerView, coordinator: Coordinator) {
        coordinator.setKeyHandler(nil)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var bar: DiffHorizontalBar?
        var rows: [DiffTableRow] = []
        var ids: [String] = []
        var signature: [Int] = []
        var version = -1
        var zoom: CGFloat = 0
        var onComment: ((String, DiffLine) -> Void)?
        var lastScrollTarget: String?
        var lastScrollToken = 0
        var active = true
        var onTopGroup: ((String?) -> Void)?
        private var topGroup: String?
        private var scrollObserver: NSObjectProtocol?
        private var topGroupCheck: DispatchWorkItem?
        let state = DiffRenderState()
        private var wrap: Bool?
        private var hasSplit = false
        private var maxCodeWidth: CGFloat?
        private var lineHeights: [String: CGFloat] = [:]
        private var viewHeights: [String: CGFloat] = [:]
        private var texts: [String: NSAttributedString] = [:]
        private var width: CGFloat = 0
        private var widthObserver: NSObjectProtocol?
        private var widthSettle: DispatchWorkItem?
        private var onKey: ((String) -> Bool)?
        private var keyMonitor: Any?
        private static let reviewKeys: Set<String> = ["n", "p", "[", "]", "v", "w", "s"]

        deinit {
            if let widthObserver { NotificationCenter.default.removeObserver(widthObserver) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }

        func observeWidth(_ scroll: NSScrollView) {
            widthObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, let table = self.table, abs(table.bounds.width - self.width) > 1 else { return }
                self.widthSettle?.cancel()
                let settle = DispatchWorkItem { [weak self] in
                    guard let self, let table = self.table else { return }
                    let w = table.bounds.width
                    guard abs(w - self.width) > 1 else { return }
                    self.width = w
                    self.lineHeights.removeAll()
                    self.texts.removeAll()
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.rows.count))
                    self.refreshLineCells()
                    self.updateBar()
                }
                self.widthSettle = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.width == 0 ? 0 : 0.15), execute: settle)
            }
            scroll.contentView.postsFrameChangedNotifications = true
        }

        func observeScroll(_ scroll: NSScrollView) {
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, self.onTopGroup != nil, self.topGroupCheck == nil else { return }
                let check = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.topGroupCheck = nil
                    let id = self.currentGroupID()
                    guard id != self.topGroup else { return }
                    self.topGroup = id
                    self.onTopGroup?(id)
                }
                self.topGroupCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: check)
            }
        }

        func setKeyHandler(_ handler: ((String) -> Bool)?) {
            onKey = handler
            if handler == nil {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
                return
            }
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, let handler = self.onKey, let table = self.table, let window = table.window,
                      event.window === window, window.isKeyWindow, !table.isHiddenOrHasHiddenAncestor, !table.visibleRect.isEmpty,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = event.characters, Self.reviewKeys.contains(key),
                      self.ownsKeys(window.firstResponder) else { return event }
                return handler(key) ? nil : event
            }
        }

        private func ownsKeys(_ responder: NSResponder?) -> Bool {
            guard let responder, responder !== table?.window else { return true }
            guard !(responder is NSTextInputClient), let view = responder as? NSView, let table, let container = table.enclosingScrollView?.superview else { return false }
            if view.isDescendant(of: container) { return true }
            let frame = view.convert(view.bounds, to: nil)
            let area = container.convert(container.bounds, to: nil)
            return frame.minX >= area.minX - 300 && frame.maxX <= area.minX + 1 && frame.intersects(area.insetBy(dx: -301, dy: 0))
        }

        func update(rows newRows: [DiffTableRow], version newVersion: Int, zoom newZoom: CGFloat, wrap newWrap: Bool, onComment: ((String, DiffLine) -> Void)?) {
            self.onComment = onComment
            DiffStyle.apply(scale: newZoom)
            let newIds = newRows.map(\.id)
            if newVersion > 0, newVersion == version, newZoom == zoom, newWrap == wrap, newIds == ids {
                rows = newRows
                refreshVisibleHosts()
                return
            }
            let newSignature = newRows.map { row -> Int in
                var h = Hasher()
                switch row {
                case .line(let id, let line, let commentable, let ext):
                    h.combine(id)
                    h.combine(line.text)
                    h.combine(line.oldLine)
                    h.combine(line.newLine)
                    h.combine(commentable)
                    h.combine(ext)
                case .split(let id, let left, let right, let commentable, let ext):
                    h.combine(id)
                    h.combine(left?.text)
                    h.combine(left?.oldLine)
                    h.combine(right?.text)
                    h.combine(right?.newLine)
                    h.combine(commentable)
                    h.combine(ext)
                case .view(let id, _, _):
                    h.combine(id)
                }
                return h.finalize()
            }
            guard newIds != ids || newVersion != version || newSignature != signature || newZoom != zoom || newWrap != wrap else {
                rows = newRows
                refreshVisibleHosts()
                return
            }
            rows = newRows
            ids = newIds
            signature = newSignature
            version = newVersion
            zoom = newZoom
            wrap = newWrap
            state.wrap = newWrap
            hasSplit = newRows.contains { if case .split = $0 { return true } else { return false } }
            maxCodeWidth = nil
            lineHeights.removeAll()
            texts.removeAll()
            table?.reloadData()
            updateBar()
            DispatchQueue.main.async { [weak self] in self?.updateBar() }
        }

        private func refreshVisibleHosts() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for i in visible.location..<min(rows.count, visible.location + visible.length) {
                if case .view(let id, _, let content) = rows[i], let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? HostingCell {
                    cell.host.rootView = wrapped(id: id, content: content)
                }
            }
        }

        private func refreshLineCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for i in visible.location..<min(rows.count, visible.location + visible.length) {
                guard let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? DiffLineCell else { continue }
                configure(cell, row: rows[i])
            }
        }

        private var codeWidth: CGFloat {
            hasSplit ? DiffStyle.splitCodeWidth(width) : DiffStyle.unifiedCodeWidth(width)
        }

        private var maxOffset: CGFloat {
            guard wrap == false, width > 0 else { return 0 }
            if maxCodeWidth == nil {
                var longest = 0
                for row in rows {
                    switch row {
                    case .line(_, let line, _, _) where line.kind != .hunk:
                        longest = max(longest, DiffStyle.codeText(line).utf16.count)
                    case .split(_, let left, let right, _, _):
                        longest = max(longest, left.map { DiffStyle.codeText($0).utf16.count } ?? 0, right.map { DiffStyle.codeText($0).utf16.count } ?? 0)
                    default:
                        break
                    }
                }
                maxCodeWidth = CGFloat(longest) * DiffStyle.charWidth + 12
            }
            return max(0, (maxCodeWidth ?? 0) - codeWidth)
        }

        private func updateBar() {
            let limit = maxOffset
            if state.offset > limit { state.offset = limit }
            guard let bar else { return }
            bar.isHidden = limit <= 0
            guard limit > 0 else { return }
            bar.proportion = codeWidth / (codeWidth + limit)
            bar.position = state.offset / limit
        }

        func scrollHorizontally(_ event: NSEvent) -> Bool {
            let limit = maxOffset
            guard limit > 0 else { return false }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * DiffStyle.charWidth * 3
            setOffset(state.offset - delta)
            return true
        }

        func setOffset(fraction: CGFloat) {
            setOffset(fraction * maxOffset)
        }

        private func setOffset(_ value: CGFloat) {
            let clamped = min(max(0, value), maxOffset)
            guard abs(clamped - state.offset) > 0.1 else { return }
            state.offset = clamped
            updateBar()
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for i in visible.location..<min(rows.count, visible.location + visible.length) {
                table.view(atColumn: 0, row: i, makeIfNecessary: false)?.needsDisplay = true
            }
        }

        func scroll(to id: String, remember: Bool = false) {
            if remember { lastScrollTarget = id }
            guard let table, let i = ids.firstIndex(of: id) else { return }
            scroll(toY: table.rect(ofRow: i).minY)
        }

        private func scroll(toY y: CGFloat) {
            guard let clip = table?.enclosingScrollView?.contentView, let scroll = table?.enclosingScrollView else { return }
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(clip)
        }

        private func groupIndex(atOrBefore index: Int) -> Int? {
            var i = min(index, rows.count - 1)
            while i >= 0 {
                if rows[i].isGroup { return i }
                i -= 1
            }
            return nil
        }

        private func floatingInset(for index: Int) -> CGFloat {
            guard let table, let g = groupIndex(atOrBefore: index), g != index else { return 0 }
            return table.rect(ofRow: g).height
        }

        private func currentIndex() -> Int? {
            guard let table, !rows.isEmpty else { return nil }
            let top = table.visibleRect.minY
            var first = table.row(at: NSPoint(x: 1, y: top + 1))
            if first < 0 { first = top <= 0 ? 0 : rows.count - 1 }
            let r = table.row(at: NSPoint(x: 1, y: top + floatingInset(for: first) + 1))
            return r >= 0 ? r : first
        }

        func currentGroupID() -> String? {
            guard let i = currentIndex(), let g = groupIndex(atOrBefore: i) else { return nil }
            return rows[g].id
        }

        func jump(_ step: Int, where match: (DiffTableRow) -> Bool) {
            guard let table, let current = currentIndex() else { return }
            let candidates: [Int] = step > 0 ? Array(stride(from: current + 1, to: rows.count, by: 1)) : Array(stride(from: current - 1, through: 0, by: -1))
            guard let target = candidates.first(where: { match(rows[$0]) }) else { return }
            scroll(toY: table.rect(ofRow: target).minY - floatingInset(for: target))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            rows[row].isGroup
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if width == 0 { width = tableView.bounds.width }
            let wrap = state.wrap
            switch rows[row] {
            case .line(let id, let line, _, _):
                if let h = lineHeights[id] { return h }
                let h = DiffStyle.height(line, codeWidth: DiffStyle.unifiedCodeWidth(width), wrap: wrap)
                lineHeights[id] = h
                return h
            case .split(let id, let left, let right, _, _):
                if let h = lineHeights[id] { return h }
                let w = DiffStyle.splitCodeWidth(width)
                let h = max(DiffStyle.height(left, codeWidth: w, wrap: wrap), DiffStyle.height(right, codeWidth: w, wrap: wrap))
                lineHeights[id] = h
                return h
            case .view(let id, _, _):
                return viewHeights[id] ?? 34
            }
        }

        private func text(_ key: String, _ line: DiffLine?, ext: String, codeWidth: CGFloat) -> NSAttributedString? {
            guard let line else { return nil }
            if let cached = texts[key] { return cached }
            if texts.count > 4000 { texts.removeAll() }
            let s = DiffStyle.attributed(line, ext: ext, codeWidth: codeWidth, wrap: state.wrap, highlight: true)
            texts[key] = s
            return s
        }

        private func configure(_ cell: DiffLineCell, row: DiffTableRow) {
            cell.state = state
            switch row {
            case .line(let id, let line, let commentable, let ext):
                cell.isSplit = false
                cell.line = line
                cell.left = nil
                cell.right = nil
                cell.text = text(id, line, ext: ext, codeWidth: DiffStyle.unifiedCodeWidth(width))
                cell.commentable = commentable
                cell.onComment = { [weak self] l in self?.onComment?(id, l) }
            case .split(let id, let left, let right, let commentable, let ext):
                let w = DiffStyle.splitCodeWidth(width)
                cell.isSplit = true
                cell.line = nil
                cell.left = left
                cell.right = right
                cell.leftText = text(id + "|L", left, ext: ext, codeWidth: w)
                cell.rightText = text(id + "|R", right, ext: ext, codeWidth: w)
                cell.commentable = commentable
                cell.onComment = { [weak self] l in self?.onComment?(id, l) }
            case .view:
                return
            }
            cell.needsDisplay = true
            cell.window?.invalidateCursorRects(for: cell)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if width == 0 { width = tableView.bounds.width }
            switch rows[row] {
            case .line, .split:
                let cell = (tableView.makeView(withIdentifier: .init("line"), owner: nil) as? DiffLineCell) ?? {
                    let c = DiffLineCell()
                    c.identifier = .init("line")
                    return c
                }()
                configure(cell, row: rows[row])
                return cell
            case .view(let id, _, let content):
                let cell = (tableView.makeView(withIdentifier: .init("host"), owner: nil) as? HostingCell) ?? {
                    let c = HostingCell()
                    c.identifier = .init("host")
                    return c
                }()
                cell.host.rootView = wrapped(id: id, content: content)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = NSTableRowView()
            v.isGroupRowStyle = false
            return v
        }

        private func wrapped(id: String, content: () -> AnyView) -> AnyView {
            AnyView(content().id(id).modifier(HeightReporter { [weak self] h in self?.report(id: id, height: h) }))
        }

        private func report(id: String, height: CGFloat) {
            let h = max(1, ceil(height))
            guard abs((viewHeights[id] ?? 0) - h) > 0.5 else { return }
            viewHeights[id] = h
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table, let i = self.ids.firstIndex(of: id) else { return }
                let old = table.rect(ofRow: i)
                let top = table.visibleRect.minY
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: i))
                }
                let delta = table.rect(ofRow: i).height - old.height
                guard old.minY < top - 0.5, abs(delta) > 0.5, let scroll = table.enclosingScrollView else { return }
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.origin.y + delta)))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }
}
