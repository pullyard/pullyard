import SwiftUI

enum StackMetrics {
    static let pad: CGFloat = 28
    static let cardWidth: CGFloat = 256
    static let cardHeight: CGFloat = 120
    static let gapX: CGFloat = 28
    static let gapY: CGFloat = 58
    static let pillHeight: CGFloat = 30
    static let pillWidth: CGFloat = 150
    static let noteGap: CGFloat = 8
    static let noteHeight: CGFloat = 76
}

struct StackGeometry: Equatable {
    let layout: StackLayout
    let noted: Set<Int>
    let size: CGSize
    private let tops: [Int: CGFloat]

    init(_ layout: StackLayout, noted: Set<Int>) {
        typealias M = StackMetrics
        self.layout = layout
        self.noted = noted
        let notedLevels = Set(noted.compactMap { layout.slots[$0]?.level })
        var tops: [Int: CGFloat] = [:]
        var y = M.pad + M.pillHeight + M.gapY
        for level in 1...max(layout.levels, 1) {
            tops[level] = y
            y += M.cardHeight + (notedLevels.contains(level) ? M.noteGap + M.noteHeight : 0) + M.gapY
        }
        self.tops = tops
        self.size = CGSize(width: M.pad * 2 + CGFloat(layout.columns) * (M.cardWidth + M.gapX) - M.gapX, height: y - M.gapY + M.pad)
    }

    func origin(_ number: Int) -> CGPoint? {
        guard let slot = layout.slots[number] else { return nil }
        return CGPoint(x: StackMetrics.pad + CGFloat(slot.column) * (StackMetrics.cardWidth + StackMetrics.gapX), y: tops[slot.level] ?? 0)
    }

    func bottom(_ number: Int) -> CGFloat? {
        guard let o = origin(number) else { return nil }
        return o.y + StackMetrics.cardHeight + (noted.contains(number) ? StackMetrics.noteGap + StackMetrics.noteHeight : 0)
    }
}

struct StackViewport: Equatable {
    static let range: ClosedRange<CGFloat> = 0.12...1.6
    static let margin: CGFloat = 80

    var zoom: CGFloat = 1
    var pan: CGPoint = .zero

    static func centered(on point: CGPoint, zoom: CGFloat, content: CGSize, viewport: CGSize) -> StackViewport {
        StackViewport(zoom: zoom, pan: CGPoint(x: viewport.width / 2 - point.x * zoom, y: viewport.height / 2 - point.y * zoom))
            .clamped(content: content, viewport: viewport)
    }

    static func fit(content: CGSize, viewport: CGSize) -> StackViewport {
        guard content.width > 0, content.height > 0 else { return StackViewport() }
        let z = min(max(min(1, (viewport.width - 24) / content.width, (viewport.height - 24) / content.height), range.lowerBound), range.upperBound)
        return StackViewport(zoom: z, pan: .zero).clamped(content: content, viewport: viewport)
    }

    func zoomed(to value: CGFloat, at anchor: CGPoint, content: CGSize, viewport: CGSize) -> StackViewport {
        let z = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        let k = z / zoom
        return StackViewport(zoom: z, pan: CGPoint(x: anchor.x - (anchor.x - pan.x) * k, y: anchor.y - (anchor.y - pan.y) * k))
            .clamped(content: content, viewport: viewport)
    }

    func panned(by delta: CGSize, content: CGSize, viewport: CGSize) -> StackViewport {
        StackViewport(zoom: zoom, pan: CGPoint(x: pan.x + delta.width, y: pan.y + delta.height))
            .clamped(content: content, viewport: viewport)
    }

    func clamped(content: CGSize, viewport: CGSize) -> StackViewport {
        func axis(_ p: CGFloat, _ length: CGFloat, _ visible: CGFloat) -> CGFloat {
            let scaled = length * zoom
            if scaled <= visible { return (visible - scaled) / 2 }
            return min(max(p, visible - scaled - Self.margin), Self.margin)
        }
        return StackViewport(zoom: zoom, pan: CGPoint(x: axis(pan.x, content.width, viewport.width), y: axis(pan.y, content.height, viewport.height)))
    }
}

struct StackTab: View {
    let model: PRDetailModel
    let tree: StackTree
    @Environment(AppModel.self) private var app
    @State private var view: StackViewport?
    @State private var size: CGSize = .zero
    @State private var dragStart: StackViewport?
    @State private var input = StackInput()
    @State private var sessions: [Int: ClaudeSessionInfo] = [:]
    @State private var notesFor: Int?
    private let notes = StackNotes.shared

    private var geometry: StackGeometry {
        StackGeometry(StackLayout(tree), noted: Set(tree.nodes.keys.filter { notes.hasNotes(noteKey($0)) }))
    }

    var body: some View {
        let geometry = geometry
        GeometryReader { geo in
            let vp = current(geometry, geo.size)
            ZStack(alignment: .topLeading) {
                Color.sySunken
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { g in
                                let base = dragStart ?? vp
                                if dragStart == nil { dragStart = base }
                                view = base.panned(by: g.translation, content: geometry.size, viewport: geo.size)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                StackEdgeLayer(drawing: StackEdgeDrawing(tree: tree, geometry: geometry, path: tree.pathSet), viewport: vp)
                StackCanvas(tree: tree, geometry: geometry, sessions: sessions, notes: notes, noteKey: noteKey,
                            visible: Self.visibleCards(tree: tree, geometry: geometry, viewport: vp, size: geo.size),
                            compact: vp.zoom < Self.compactBelow, onOpen: open, onSession: resume, onNote: showNotes)
                    .equatable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(vp.zoom, anchor: .topLeading)
                    .offset(x: vp.pan.x, y: vp.pan.y)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .background(StackInputProbe(input: input))
            .overlay(alignment: .bottomTrailing) { zoomControls(vp, geometry).padding(12) }
            .overlay(alignment: .topTrailing) {
                if let n = notesFor, let node = tree.nodes[n] {
                    StackNotesEditor(key: noteKey(n), number: n, title: node.title, store: notes) { showNotes(nil) }
                        .id(n)
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onAppear {
                size = geo.size
                bindInput()
            }
            .onChange(of: geo.size) { size = geo.size }
        }
        .onChange(of: tree) { bindInput() }
        .onChange(of: notesFor) { bindInput() }
        .task(id: tree.nodes.values.map { "\($0.number):\($0.headRefName)" }.sorted()) { matchSessions() }
    }

    static let cullMargin: CGFloat = 60
    static let compactBelow: CGFloat = 0.45

    static func visibleCards(tree: StackTree, geometry: StackGeometry, viewport vp: StackViewport, size: CGSize) -> Set<Int> {
        let margin = cullMargin / max(vp.zoom, 0.25)
        let rect = CGRect(x: -vp.pan.x / vp.zoom, y: -vp.pan.y / vp.zoom, width: size.width / vp.zoom, height: size.height / vp.zoom)
            .insetBy(dx: -margin, dy: -margin)
        return Set(tree.nodes.keys.filter { n in
            guard let o = geometry.origin(n), let bottom = geometry.bottom(n) else { return false }
            return rect.intersects(CGRect(x: o.x, y: o.y, width: StackMetrics.cardWidth, height: bottom - o.y))
        })
    }

    private func current(_ geometry: StackGeometry, _ viewport: CGSize) -> StackViewport {
        if let view { return view.clamped(content: geometry.size, viewport: viewport) }
        return initial(geometry, viewport)
    }

    private func initial(_ geometry: StackGeometry, _ viewport: CGSize) -> StackViewport {
        guard let o = geometry.origin(tree.current) else { return StackViewport().clamped(content: geometry.size, viewport: viewport) }
        return .centered(on: CGPoint(x: o.x + StackMetrics.cardWidth / 2, y: o.y + StackMetrics.cardHeight / 2), zoom: 1, content: geometry.size, viewport: viewport)
    }

    private func update(animated: Bool = false, _ change: (StackViewport, StackGeometry) -> StackViewport) {
        let geometry = geometry
        let next = change(current(geometry, size), geometry)
        if animated, !Motion.reduced {
            withAnimation(.easeOut(duration: 0.22)) { view = next }
        } else {
            view = next
        }
    }

    private func bindInput() {
        let panelOpen = notesFor != nil
        input.isActive = { [model] in model.tab == .stack }
        input.excluded = { p in panelOpen && p.x > size.width - 372 }
        input.onScroll = { delta in
            update { v, g in v.panned(by: delta, content: g.size, viewport: size) }
        }
        input.onMagnify = { factor, point in
            update { v, g in v.zoomed(to: v.zoom * factor, at: point, content: g.size, viewport: size) }
        }
        input.onSmartMagnify = { point in
            update(animated: true) { v, g in
                v.zoom < 0.95 ? v.zoomed(to: 1, at: point, content: g.size, viewport: size) : .fit(content: g.size, viewport: size)
            }
        }
    }

    private func focusOnCurrent() {
        update(animated: true) { v, g in
            guard let o = g.origin(tree.current) else { return v }
            return .centered(on: CGPoint(x: o.x + StackMetrics.cardWidth / 2, y: o.y + StackMetrics.cardHeight / 2), zoom: max(v.zoom, 1), content: g.size, viewport: size)
        }
    }

    private func showNotes(_ number: Int?) {
        withAnimation(Motion.quick) { notesFor = number }
    }

    private func noteKey(_ number: Int) -> String {
        StackNotes.key(account: model.cacheAccount, host: model.api.host, repo: model.ref.repo, number: number)
    }

    private func open(_ number: Int) {
        guard number != tree.current else {
            focusOnCurrent()
            return
        }
        let ref = ItemRef(repo: model.ref.repo, number: number)
        if let next = app.prModel(ref) {
            next.tab = .stack
            if let node = tree.nodes[number] {
                let nodes = StackStore.memoryNodes(api: model.api, repo: model.ref.repo, account: model.cacheAccount) ?? Array(tree.nodes.values)
                next.seedStack(node, nodes: nodes)
            }
        }
        app.open(.pr(ref))
    }

    private func resume(_ session: ClaudeSessionInfo) {
        app.section = .claude
        app.claude.resume(session)
    }

    private func matchSessions() {
        let all = app.claude.projects.flatMap(\.sessions)
        guard !all.isEmpty else {
            if !sessions.isEmpty { sessions = [:] }
            return
        }
        var byPR: [Int: ClaudeSessionInfo] = [:]
        var byBranch: [String: ClaudeSessionInfo] = [:]
        for s in all {
            if let n = s.prNumber, byPR[n] == nil { byPR[n] = s }
            if let b = s.branch, byBranch[b] == nil { byBranch[b] = s }
        }
        var out: [Int: ClaudeSessionInfo] = [:]
        for node in tree.nodes.values {
            if let s = byPR[node.number] ?? byBranch[node.headRefName] { out[node.number] = s }
        }
        if out != sessions { sessions = out }
    }

    private func zoomControls(_ vp: StackViewport, _ geometry: StackGeometry) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass", help: "Zoom out (pinch or ⌘-scroll works too)") {
                update(animated: true) { v, g in v.zoomed(to: v.zoom - 0.15, at: middle, content: g.size, viewport: size) }
            }
            Button {
                update(animated: true) { v, g in v.zoomed(to: 1, at: middle, content: g.size, viewport: size) }
            } label: {
                Text("\(Int((vp.zoom * 100).rounded()))%").font(.syCaption.monospacedDigit()).frame(width: 40)
            }
            .buttonStyle(.borderless)
            .help("Actual size")
            zoomButton("plus.magnifyingglass", help: "Zoom in") {
                update(animated: true) { v, g in v.zoomed(to: v.zoom + 0.15, at: middle, content: g.size, viewport: size) }
            }
            zoomButton("arrow.up.left.and.arrow.down.right", help: "Fit to window") {
                update(animated: true) { _, g in .fit(content: g.size, viewport: size) }
            }
            zoomButton("scope", help: "Show this pull request") { focusOnCurrent() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.syLineStrong))
    }

    private func zoomButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

@MainActor
final class StackInput {
    weak var view: NSView?
    var isActive: () -> Bool = { true }
    var excluded: (CGPoint) -> Bool = { _ in false }
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onSmartMagnify: ((CGPoint) -> Void)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var result: NSEvent? = incoming
            MainActor.assumeIsolated { result = self?.handle(incoming) ?? incoming }
            return result
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let view, let window = view.window, event.window === window, !view.isHiddenOrHasHiddenAncestor, isActive() else { return event }
        let p = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(p), !excluded(p) else { return event }
        switch event.type {
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas
            if event.modifierFlags.contains(.command) {
                onMagnify?(1 + event.scrollingDeltaY * (precise ? 0.005 : 0.05), p)
            } else {
                let k: CGFloat = precise ? 1 : 12
                onScroll?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
            }
            return nil
        case .magnify:
            onMagnify?(1 + event.magnification, p)
            return nil
        case .smartMagnify:
            onSmartMagnify?(p)
            return nil
        default:
            return event
        }
    }
}

struct StackInputProbe: NSViewRepresentable {
    let input: StackInput

    final class Probe: NSView {
        weak var input: StackInput?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                input?.uninstall()
            } else {
                input?.view = self
                input?.install()
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.input = input
        input.view = v
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {
        v.input = input
        input.view = v
    }

    static func dismantleNSView(_ v: Probe, coordinator: ()) {
        v.input?.uninstall()
    }
}

struct StackCanvas: View, Equatable {
    let tree: StackTree
    let geometry: StackGeometry
    let sessions: [Int: ClaudeSessionInfo]
    let notes: StackNotes
    let noteKey: (Int) -> String
    var visible: Set<Int>?
    var compact = false
    let onOpen: (Int) -> Void
    let onSession: (ClaudeSessionInfo) -> Void
    var onNote: (Int) -> Void = { _ in }
    @State private var opening: Int?

    static func == (a: StackCanvas, b: StackCanvas) -> Bool {
        a.tree == b.tree && a.geometry == b.geometry && a.sessions == b.sessions && a.visible == b.visible && a.compact == b.compact
    }

    var body: some View {
        let path = tree.pathSet
        ZStack(alignment: .topLeading) {
            Color.clear
            if let o = geometry.origin(tree.root) {
                BasePill(name: tree.base)
                    .frame(width: StackMetrics.pillWidth, height: StackMetrics.pillHeight)
                    .offset(x: o.x + (StackMetrics.cardWidth - StackMetrics.pillWidth) / 2, y: StackMetrics.pad)
            }
            ForEach(tree.nodes.values.filter { visible?.contains($0.number) ?? true }.sorted { $0.number < $1.number }) { node in
                if let o = geometry.origin(node.number), compact {
                    CompactStackCard(node: node, current: node.number == tree.current, onPath: path.contains(node.number),
                                     hasNotes: geometry.noted.contains(node.number)) {
                        if node.number != tree.current { opening = node.number }
                        onOpen(node.number)
                    }
                    .equatable()
                    .frame(width: StackMetrics.cardWidth, height: StackMetrics.cardHeight)
                    .id(node.number)
                    .offset(x: o.x, y: o.y)
                } else if let o = geometry.origin(node.number) {
                    let onPath = path.contains(node.number)
                    VStack(spacing: StackMetrics.noteGap) {
                        StackCard(node: node, current: node.number == tree.current, onPath: onPath, session: sessions[node.number],
                                  noteCount: notes.notes(noteKey(node.number)).count, opening: opening == node.number,
                                  onOpen: {
                                      if node.number != tree.current { opening = node.number }
                                      onOpen(node.number)
                                  }, onSession: onSession, onNote: { onNote(node.number) })
                            .equatable()
                            .frame(height: StackMetrics.cardHeight)
                        if geometry.noted.contains(node.number) {
                            StickyNote(notes: notes.notes(noteKey(node.number)))
                                .frame(height: StackMetrics.noteHeight)
                                .opacity(onPath ? 1 : 0.75)
                                .contentShape(Rectangle())
                                .onTapGesture { onNote(node.number) }
                        }
                    }
                    .frame(width: StackMetrics.cardWidth, alignment: .top)
                    .id(node.number)
                    .offset(x: o.x, y: o.y)
                }
            }
        }
        .animation(Motion.smooth, value: tree)
        .onChange(of: tree.current) { opening = nil }
    }
}

struct StackEdgeDrawing: Equatable {
    var lit = Path()
    var dim = Path()
    var litLabels: [CGPoint] = []
    var litFromRight: [Bool] = []
    var dimLabels: [CGPoint] = []
    var dimFromRight: [Bool] = []

    init(tree: StackTree, geometry: StackGeometry, path: Set<Int>) {
        let half = StackMetrics.cardWidth / 2
        if let o = geometry.origin(tree.root) {
            lit.move(to: CGPoint(x: o.x + half, y: StackMetrics.pad + StackMetrics.pillHeight))
            lit.addLine(to: CGPoint(x: o.x + half, y: o.y))
            litLabels.append(CGPoint(x: o.x + half, y: o.y))
            litFromRight.append(false)
        }
        for (parent, kids) in tree.children {
            guard let p = geometry.origin(parent), let pb = geometry.bottom(parent) else { continue }
            let from = CGPoint(x: p.x + half, y: pb)
            let tops = kids.compactMap { k in geometry.origin(k).map { (k, CGPoint(x: $0.x + half, y: $0.y)) } }
            guard let firstTop = tops.map(\.1.y).min() else { continue }
            let midY = pb + (firstTop - pb) / 2
            let fan = tops.count > 4
            for (k, top) in tops {
                let edge = fan ? Self.elbow(from: from, to: top, busY: midY) : Self.curve(from: from, to: top)
                let fromRight = from.x > top.x + 1
                if path.contains(k) && path.contains(parent) {
                    lit.addPath(edge)
                    litLabels.append(top)
                    litFromRight.append(fromRight)
                } else {
                    dim.addPath(edge)
                    if !fan {
                        dimLabels.append(top)
                        dimFromRight.append(fromRight)
                    }
                }
            }
        }
    }

    static func curve(from: CGPoint, to: CGPoint) -> Path {
        let midY = (from.y + to.y) / 2
        var p = Path()
        p.move(to: from)
        p.addCurve(to: to, control1: CGPoint(x: from.x, y: midY), control2: CGPoint(x: to.x, y: midY))
        return p
    }

    static func elbow(from: CGPoint, to: CGPoint, busY: CGFloat) -> Path {
        var p = Path()
        p.move(to: from)
        let dx = to.x - from.x
        guard abs(dx) > 1 else {
            p.addLine(to: to)
            return p
        }
        let r = min(18, abs(dx) / 2, (busY - from.y), (to.y - busY))
        let sign: CGFloat = dx > 0 ? 1 : -1
        p.addLine(to: CGPoint(x: from.x, y: busY - r))
        p.addQuadCurve(to: CGPoint(x: from.x + sign * r, y: busY), control: CGPoint(x: from.x, y: busY))
        p.addLine(to: CGPoint(x: to.x - sign * r, y: busY))
        p.addQuadCurve(to: CGPoint(x: to.x, y: busY + r), control: CGPoint(x: to.x, y: busY))
        p.addLine(to: to)
        return p
    }
}

struct StackEdgeLayer: View {
    let drawing: StackEdgeDrawing
    let viewport: StackViewport

    private struct Label: Identifiable {
        let id: Int
        let point: CGPoint
        let fromRight: Bool
        let lit: Bool
    }

    var body: some View {
        let z = viewport.zoom
        let toScreen = CGAffineTransform(translationX: viewport.pan.x, y: viewport.pan.y).scaledBy(x: z, y: z)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                drawing.dim.applying(toScreen)
                    .stroke(z < 0.5 ? Color.syMuted : Color.syDim, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                drawing.lit.applying(toScreen)
                    .stroke(Color.syIndigo, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if z >= 0.5 {
                    ForEach(labels(toScreen, in: CGRect(origin: .zero, size: geo.size))) { l in
                        Text("stacked on")
                            .font(.system(size: 10 * z))
                            .foregroundStyle(l.lit ? Color.syIndigo : Color.syDim)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in l.fromRight ? d.width : 0 }
                            .alignmentGuide(.top) { d in d.height / 2 }
                            .offset(x: l.point.x + (l.fromRight ? -6 : 6) * z, y: l.point.y - 12 * z)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func labels(_ t: CGAffineTransform, in bounds: CGRect) -> [Label] {
        var out: [Label] = []
        let area = bounds.insetBy(dx: -120, dy: -40)
        for (i, p) in drawing.dimLabels.enumerated() {
            let s = p.applying(t)
            if area.contains(s) { out.append(Label(id: i, point: s, fromRight: drawing.dimFromRight[i], lit: false)) }
        }
        for (i, p) in drawing.litLabels.enumerated() {
            let s = p.applying(t)
            if area.contains(s) { out.append(Label(id: 100_000 + i, point: s, fromRight: drawing.litFromRight[i], lit: true)) }
        }
        return out
    }
}

private struct BasePill: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "arrow.triangle.branch")
            .font(.syCallout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color.syRaised))
            .overlay(Capsule().stroke(Color.syLineStrong))
            .help(name)
    }
}

private struct StackCard: View, Equatable {
    let node: StackNode
    let current: Bool
    let onPath: Bool
    let session: ClaudeSessionInfo?
    let noteCount: Int
    let opening: Bool
    let onOpen: () -> Void
    let onSession: (ClaudeSessionInfo) -> Void
    let onNote: () -> Void

    static func == (a: StackCard, b: StackCard) -> Bool {
        a.node == b.node && a.current == b.current && a.onPath == b.onPath && a.session == b.session && a.noteCount == b.noteCount && a.opening == b.opening
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(node.number)").fontWeight(.semibold)
                if let key = node.jiraKey {
                    Text(key).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
                }
                Spacer(minLength: 4)
                Button(action: onNote) {
                    if noteCount > 0 {
                        Label("\(noteCount)", systemImage: "note.text").labelStyle(.titleAndIcon).foregroundStyle(Color.syAmber)
                    } else {
                        Image(systemName: "note.text.badge.plus").foregroundStyle(Color.syDim)
                    }
                }
                .buttonStyle(.plain)
                .font(.syCaption.weight(.semibold))
                .help(noteCount > 0 ? plural(noteCount, "note", "notes") + " — click to open" : "Add a note")
                if opening {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                }
                StatusPill(status: node.status)
            }
            .font(.syCallout)
            Text(node.title)
                .font(.syCallout.weight(.semibold))
                .lineLimit(1)
                .padding(.bottom, 2)
            field("branch", node.headRefName)
            field("base", node.baseRefName)
            if let session {
                HStack(spacing: 6) {
                    Text("session").foregroundStyle(Color.syDim).frame(width: 48, alignment: .leading)
                    Button {
                        onSession(session)
                    } label: {
                        Text(session.title).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.syAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Resume Claude Code session")
                }
                .font(.syCaption)
            }
            if let oid = node.commitOid {
                Text("› \(oid) \(node.commitHeadline ?? "")")
                    .font(.syCaption.monospaced())
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.sySunken))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(current || opening ? Color.syIndigo : Color.syLineStrong, lineWidth: current || opening ? 2 : 1)
        )
        .opacity(onPath || opening ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open #\(node.number)", action: onOpen).disabled(current)
            Button(noteCount > 0 ? "Notes…" : "Add note…", action: onNote)
            Divider()
            Button("Copy branch name") { copyToPasteboard(node.headRefName) }
        }
        .help(current ? "#\(node.number) \(node.title) · \(node.author.map { "@\($0)" } ?? "") — click to center" : "#\(node.number) \(node.title) · \(node.author.map { "@\($0)" } ?? "") — click to open")
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Color.syDim).frame(width: 48, alignment: .leading)
            Text(value).font(.syCaption.monospaced()).lineLimit(1).truncationMode(.middle)
        }
        .font(.syCaption)
    }
}

private struct CompactStackCard: View, Equatable {
    let node: StackNode
    let current: Bool
    let onPath: Bool
    let hasNotes: Bool
    let onOpen: () -> Void

    static func == (a: CompactStackCard, b: CompactStackCard) -> Bool {
        a.node == b.node && a.current == b.current && a.onPath == b.onPath && a.hasNotes == b.hasNotes
    }

    var body: some View {
        let status = node.status
        HStack(spacing: 0) {
            Rectangle().fill(status.color).frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("#\(node.number)").font(.system(size: 40, weight: .bold))
                    if hasNotes {
                        Image(systemName: "note.text").font(.system(size: 30)).foregroundStyle(Color.syAmber)
                    }
                }
                Text(status.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(status.color)
            }
            .lineLimit(1)
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.syRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Color.syIndigo : Color.syLineStrong, lineWidth: current ? 8 : 3))
        .opacity(onPath ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

struct StatusPill: View {
    let status: StackStatus

    var body: some View {
        Text(status.title)
            .font(.syCaption2.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.color.opacity(0.14)))
            .lineLimit(1)
    }
}
