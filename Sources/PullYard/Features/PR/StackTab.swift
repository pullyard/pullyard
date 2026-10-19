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

enum StackViewMode: String {
    case list, graph
}

struct StackTab: View {
    static let modeKey = "stack.view"
    static let supportAskedKey = "stack.graphSupportShown"

    let model: PRDetailModel
    let tree: StackTree
    @Environment(AppModel.self) private var app
    @AppStorage(StackTab.modeKey) private var mode = StackViewMode.list.rawValue
    @AppStorage(StackTab.supportAskedKey) private var supportAsked = false
    @State private var loading: Int?
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

    private var isGraph: Bool { mode == StackViewMode.graph.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: Binding(get: { isGraph ? StackViewMode.graph : .list }, set: switchMode)) {
                    Label("List", systemImage: "list.bullet.indent").tag(StackViewMode.list)
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(StackViewMode.graph)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(plural(tree.count, "pull request", "pull requests") + " on " + tree.base)
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                if isGraph {
                    graph
                } else {
                    StackListView(tree: tree, sessions: sessions, notes: notes, noteKey: noteKey, busy: loading, onOpen: { open($0, inPlace: true) }, onNote: showNotes)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let n = notesFor, let node = tree.nodes[n] {
                    StackNotesEditor(key: noteKey(n), number: n, title: node.title, store: notes) { showNotes(nil) }
                        .id(n)
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onChange(of: tree) { bindInput() }
        .onChange(of: notesFor) { bindInput() }
        .task(id: tree.nodes.values.map { "\($0.number):\($0.headRefName)" }.sorted()) { matchSessions() }
    }

    private func switchMode(_ next: StackViewMode) {
        mode = next.rawValue
        guard next == .graph, !supportAsked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { askForSupport() }
    }

    private func askForSupport() {
        guard !supportAsked, isGraph else { return }
        supportAsked = true
        let alert = NSAlert()
        alert.messageText = "Like the stack graph?"
        alert.informativeText = "PullYard is free and built by one developer. If it saves you time, you can be part of it by buying a pizza that keeps it going. We only ask once."
        alert.addButton(withTitle: "Buy a Pizza 🍕")
        alert.addButton(withTitle: "OK")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { openInBrowser(Support.pizzaURL) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private var graph: some View {
        let geometry = geometry
        return GeometryReader { geo in
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
            .onAppear {
                size = geo.size
                bindInput()
            }
            .onChange(of: geo.size) { size = geo.size }
        }
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
        input.isActive = { [model] in model.tab == .stack && UserDefaults.standard.string(forKey: StackTab.modeKey) == StackViewMode.graph.rawValue }
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
        open(number, inPlace: false)
    }

    private func open(_ number: Int, inPlace: Bool) {
        guard loading == nil else { return }
        guard number != tree.current else {
            if !inPlace { focusOnCurrent() }
            return
        }
        let ref = ItemRef(repo: model.ref.repo, number: number)
        guard let next = app.prModel(ref) else {
            switchTo(ref)
            return
        }
        next.tab = .stack
        if let node = tree.nodes[number] {
            let nodes = StackStore.memoryNodes(api: model.api, repo: model.ref.repo, account: model.cacheAccount) ?? Array(tree.nodes.values)
            next.seedStack(node, nodes: nodes)
        }
        guard inPlace, next.pr == nil else {
            switchTo(ref)
            return
        }
        let here = Route.pr(model.ref)
        loading = number
        Task {
            await next.load()
            loading = nil
            guard app.detailRoot == here, app.detailPath.isEmpty else { return }
            switchTo(ref)
        }
    }

    private func switchTo(_ ref: ItemRef) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { app.open(.pr(ref)) }
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

struct StackListView: View {
    let tree: StackTree
    let sessions: [Int: ClaudeSessionInfo]
    let notes: StackNotes
    let noteKey: (Int) -> String
    var busy: Int?
    let onOpen: (Int) -> Void
    let onNote: (Int) -> Void
    @State private var position: Int?

    nonisolated(unsafe) private static var anchors: [String: Int] = [:]

    init(tree: StackTree, sessions: [Int: ClaudeSessionInfo], notes: StackNotes, noteKey: @escaping (Int) -> String,
         busy: Int? = nil, onOpen: @escaping (Int) -> Void, onNote: @escaping (Int) -> Void) {
        self.tree = tree
        self.sessions = sessions
        self.notes = notes
        self.noteKey = noteKey
        self.busy = busy
        self.onOpen = onOpen
        self.onNote = onNote
        let saved = Self.anchors[Self.anchorKey(tree)]
        _position = State(initialValue: saved.flatMap { tree.nodes[$0] == nil ? nil : $0 } ?? tree.current)
    }

    private static func anchorKey(_ tree: StackTree) -> String { "\(tree.root)|\(tree.base)" }

    struct Row: Identifiable {
        let node: StackNode
        let depth: Int
        var id: Int { node.number }
    }

    static func rows(_ tree: StackTree) -> [Row] {
        var out: [Row] = []
        var stack: [(Int, Int)] = [(tree.root, 0)]
        while let (n, depth) = stack.popLast() {
            if let node = tree.nodes[n] { out.append(Row(node: node, depth: depth)) }
            for c in (tree.children[n] ?? []).reversed() { stack.append((c, depth + 1)) }
        }
        return out
    }

    var body: some View {
        let path = tree.pathSet
        let rows = Self.rows(tree)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Label(tree.base, systemImage: "arrow.triangle.branch")
                    .font(.syCallout.monospaced())
                    .foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        StackListRow(node: row.node, depth: row.depth, current: row.node.number == tree.current, onPath: path.contains(row.node.number),
                                     noteCount: notes.notes(noteKey(row.node.number)).count, hasSession: sessions[row.node.number] != nil,
                                     opening: busy == row.node.number,
                                     onOpen: { onOpen(row.node.number) },
                                     onNote: { onNote(row.node.number) })
                            .opacity(busy == nil || busy == row.node.number ? 1 : 0.55)
                            .id(row.node.number)
                    }
                }
                .scrollTargetLayout()
            }
            .padding(12)
            .allowsHitTesting(busy == nil)
            .animation(Motion.fade, value: busy)
        }
        .scrollPosition(id: $position)
        .onChange(of: position) {
            if let position { Self.anchors[Self.anchorKey(tree)] = position }
        }
    }
}

private struct StackListRow: View {
    let node: StackNode
    let depth: Int
    let current: Bool
    let onPath: Bool
    let noteCount: Int
    let hasSession: Bool
    let opening: Bool
    let onOpen: () -> Void
    let onNote: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * 22, height: 1)
            Image(systemName: depth == 0 ? "circle.fill" : "arrow.turn.down.right")
                .font(.syCaption2)
                .foregroundStyle(onPath ? Color.syIndigo : Color.syDim)
                .frame(width: 14)
            StateBadge(state: node.visualState, compact: true)
            Text("#\(node.number)").font(.syCallout.weight(.semibold)).foregroundStyle(Color.syMuted)
            Text(node.title)
                .font(.syCallout.weight(current ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let key = node.jiraKey, !node.headRefName.contains(key) {
                Text(key).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
            }
            if hasSession {
                Image(systemName: "sparkles").font(.syCaption).foregroundStyle(Color.syCoral).help("Has a Claude Code session")
            }
            BranchChip(name: node.headRefName, color: current ? .syViolet : .sySlate)
            Button(action: onNote) {
                if noteCount > 0 {
                    Label("\(noteCount)", systemImage: "note.text").labelStyle(.titleAndIcon).foregroundStyle(Color.syAmber)
                } else {
                    Image(systemName: "note.text.badge.plus").foregroundStyle(hovered ? Color.syMuted : Color.syDim)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(current ? Color.syIndigo.opacity(0.12) : (hovered ? Color.syLine : Color.clear))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(current || opening ? Color.syIndigo.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open #\(node.number)", action: onOpen).disabled(current)
            Button(noteCount > 0 ? "Notes…" : "Add note…", action: onNote)
            Divider()
            Button("Copy branch name") { copyToPasteboard(node.headRefName) }
        }
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
