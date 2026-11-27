import AppKit
import SwiftUI

extension View {
    /// A dark bubble with the full text, shown above the view after the pointer rests on it for `delay`.
    /// Unlike `.help`, it appears fast, wraps up to a few lines, and floats over scroll views and clipping.
    func hoverTip(_ text: String?, delay: TimeInterval = 2) -> some View {
        background(HoverTipAnchor(text: text, delay: delay))
    }
}

private struct HoverTipAnchor: NSViewRepresentable {
    let text: String?
    let delay: TimeInterval

    func makeNSView(context: Context) -> TipTrackingView { TipTrackingView() }

    func updateNSView(_ view: TipTrackingView, context: Context) {
        view.text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        view.delay = delay
        if view.isShowing { view.refresh() }
    }

    static func dismantleNSView(_ view: TipTrackingView, coordinator: ()) { view.hide() }
}

final class TipTrackingView: NSView {
    var text: String?
    var delay: TimeInterval = 2
    private var pending: DispatchWorkItem?
    private(set) var isShowing = false
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let text, !text.isEmpty else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func mouseExited(with event: NSEvent) { hide() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hide() }
    }

    func refresh() {
        guard let text, !text.isEmpty else { hide(); return }
        show()
    }

    private func show() {
        guard let window, let text, !text.isEmpty else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        TipPanel.shared.show(text, anchor: rect)
        isShowing = true
        if monitor == nil {
            // Any click or scroll hides it, like a system tooltip.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
                self?.hide()
                return e
            }
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isShowing { TipPanel.shared.hide() }
        isShowing = false
    }
}

@MainActor
private final class TipPanel {
    static let shared = TipPanel()
    private let panel: NSPanel
    private let host = NSHostingView(rootView: TipBubble(text: ""))

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = host
    }

    func show(_ text: String, anchor: NSRect) {
        host.rootView = TipBubble(text: text)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
        if origin.y + size.height > screen.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

private struct TipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.syCallout)
            .foregroundStyle(Color.syText.opacity(0.92))
            .lineLimit(5)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: NSColor(white: 0.17, alpha: 0.98))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            .environment(\.colorScheme, .dark)
    }
}
