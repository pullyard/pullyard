import AppKit
import SwiftUI

struct EdgeReveal<Panel: View>: ViewModifier {
    let edge: HorizontalEdge
    let enabled: Bool
    let width: CGFloat
    @ViewBuilder let panel: () -> Panel
    @State private var shown = false

    private var alignment: Alignment { edge == .leading ? .leading : .trailing }
    private var hiddenOffset: CGFloat { (width + 32) * (edge == .leading ? -1 : 1) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if enabled {
                    ZStack(alignment: alignment) {
                        EdgeProbe(edge: edge, panelWidth: width, shown: $shown)
                        IsolatedPanelHost(content: panel().environment(\.inEdgePanel, true), active: shown)
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                                Rectangle().fill(Color.syLine).frame(width: 1)
                            }
                            .shadow(color: .black.opacity(shown ? 0.28 : 0), radius: 16, x: edge == .leading ? 4 : -4)
                            .offset(x: shown ? 0 : hiddenOffset)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                    }
                    .animation(Motion.reduced ? nil : .easeOut(duration: 0.18), value: shown)
                }
            }
            .onChange(of: enabled) {
                shown = false
            }
    }
}

private struct EdgeProbe: NSViewRepresentable {
    let edge: HorizontalEdge
    let panelWidth: CGFloat
    @Binding var shown: Bool

    func makeNSView(context: Context) -> EdgeProbeView {
        let v = EdgeProbeView()
        configure(v)
        return v
    }

    func updateNSView(_ view: EdgeProbeView, context: Context) {
        configure(view)
    }

    private func configure(_ view: EdgeProbeView) {
        let binding = $shown
        view.edge = edge
        view.panelWidth = panelWidth
        view.request = { binding.wrappedValue = $0 }
        view.setShown(shown)
    }

    static func dismantleNSView(_ view: EdgeProbeView, coordinator: ()) {
        view.stop()
    }
}

private final class EdgeProbeView: NSView {
    var edge: HorizontalEdge = .leading {
        didSet { if edge != oldValue { updateTrackingAreas() } }
    }
    var panelWidth: CGFloat = 0
    var request: (Bool) -> Void = { _ in }
    private var shown = false
    private var tracking: NSTrackingArea?
    private var dwell: DispatchWorkItem?
    private var watch: Timer?
    private var outsideSince: Date?
    private var menuDepth = 0
    private var observers: [NSObjectProtocol] = []

    private var stripWidth: CGFloat { edge == .leading ? 6 : 3 }
    private var dwellDelay: TimeInterval { edge == .leading ? 0.05 : 0.25 }
    private static let hideGrace: TimeInterval = 0.3

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil else { stop(); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuDepth += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuDepth = max(0, self.menuDepth - 1)
                self.outsideSince = nil
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func stop() {
        dwell?.cancel()
        dwell = nil
        watch?.invalidate()
        watch = nil
        outsideSince = nil
    }

    func setShown(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        outsideSince = nil
        if value {
            dwell?.cancel()
            dwell = nil
            startWatching()
        } else {
            watch?.invalidate()
            watch = nil
        }
    }

    private var stripRect: NSRect {
        edge == .leading
            ? NSRect(x: 0, y: 0, width: stripWidth, height: bounds.height)
            : NSRect(x: bounds.width - stripWidth, y: 0, width: stripWidth, height: bounds.height)
    }

    private var panelRect: NSRect {
        let w = min(bounds.width, panelWidth + 1)
        return edge == .leading
            ? NSRect(x: 0, y: 0, width: w, height: bounds.height)
            : NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
    }

    private var mouseLocation: NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if let p = mouseLocation, stripRect.contains(p) { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: stripRect, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !shown else { return }
        dwell?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.shown, NSEvent.pressedMouseButtons == 0,
                  let p = self.mouseLocation, self.stripRect.insetBy(dx: -2, dy: 0).contains(p) else { return }
            self.request(true)
        }
        dwell = item
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        guard !shown else { return }
        dwell?.cancel()
        dwell = nil
    }

    private func startWatching() {
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func check() {
        guard shown else { return }
        let inside = mouseLocation.map { panelRect.contains($0) } ?? false
        if inside || menuDepth > 0 || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
            return
        }
        guard let since = outsideSince else {
            outsideSince = Date()
            return
        }
        if Date().timeIntervalSince(since) >= Self.hideGrace {
            request(false)
        }
    }
}

private struct IsolatedPanelHost<Content: View>: NSViewRepresentable {
    let content: Content
    let active: Bool

    func makeNSView(context: Context) -> PanelHostView<Content> {
        let v = PanelHostView(rootView: content)
        v.active = active
        return v
    }

    func updateNSView(_ view: PanelHostView<Content>, context: Context) {
        view.host.rootView = content
        view.active = active
    }
}

private final class PanelHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    var active = false

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        active ? super.hitTest(point) : nil
    }
}

extension View {
    func edgeReveal<Panel: View>(_ edge: HorizontalEdge, enabled: Bool, width: CGFloat, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(EdgeReveal(edge: edge, enabled: enabled, width: width, panel: panel))
    }
}
