import AppKit
import SwiftUI

struct EdgeReveal<Panel: View>: ViewModifier {
    let edge: HorizontalEdge
    let enabled: Bool
    let width: CGFloat
    @ViewBuilder let panel: () -> Panel
    @State private var shown = false
    @State private var hide: DispatchWorkItem?

    private var alignment: Alignment { edge == .leading ? .leading : .trailing }
    private var hiddenOffset: CGFloat { (width + 32) * (edge == .leading ? -1 : 1) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if enabled {
                    ZStack(alignment: alignment) {
                        Color.clear
                            .frame(width: 8)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onHover { $0 ? show() : scheduleHide() }
                        IsolatedPanelHost(content: panel().environment(\.inEdgePanel, true)) { inside in
                            inside ? show() : scheduleHide()
                        }
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
                hide?.cancel()
                shown = false
            }
    }

    private func show() {
        hide?.cancel()
        hide = nil
        if !shown { shown = true }
    }

    private func scheduleHide() {
        hide?.cancel()
        let item = DispatchWorkItem { shown = false }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}

private struct IsolatedPanelHost<Content: View>: NSViewRepresentable {
    let content: Content
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PanelHostView<Content> {
        PanelHostView(rootView: content, onHover: onHover)
    }

    func updateNSView(_ view: PanelHostView<Content>, context: Context) {
        view.host.rootView = content
        view.onHover = onHover
    }
}

private final class PanelHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    var onHover: (Bool) -> Void
    private var tracking: NSTrackingArea?

    init(rootView: Content, onHover: @escaping (Bool) -> Void) {
        host = NSHostingView(rootView: rootView)
        self.onHover = onHover
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

extension View {
    func edgeReveal<Panel: View>(_ edge: HorizontalEdge, enabled: Bool, width: CGFloat, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(EdgeReveal(edge: edge, enabled: enabled, width: width, panel: panel))
    }
}
