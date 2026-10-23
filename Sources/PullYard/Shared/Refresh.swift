import AppKit
import SwiftUI
import WebKit

enum RefreshText {
    static func ago(_ updated: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(updated)))
        switch s {
        case ..<10: return "just now"
        case ..<60: return "\(s / 5 * 5)s ago"
        case ..<3600: return "\(s / 60)m ago"
        default: return "\(s / 3600)h ago"
        }
    }
}

struct RefreshStatus: View {
    let updated: Date?
    let refreshing: Bool
    var error: String?
    var compact = false
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syAmber)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 12, height: 12)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(label(now: context.date))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if error != nil, !refreshing, let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
                    .font(.syCaption.weight(.medium))
            }
        }
        .font(.syCaption)
        .foregroundStyle(Color.syMuted)
        .help(error.map { "Last refresh failed: \($0)" } ?? "Pull down to refresh (⌘R)")
    }

    private func label(now: Date) -> String {
        if refreshing {
            guard !compact, let updated, now.timeIntervalSince(updated) >= 60 else { return "Updating…" }
            return "Updated \(RefreshText.ago(updated, now: now)) · updating…"
        }
        if error != nil { return compact ? "Offline" : "Couldn't refresh" }
        guard let updated else { return compact ? "" : "Not updated yet" }
        let ago = RefreshText.ago(updated, now: now)
        return compact ? ago : "Updated \(ago)"
    }
}

struct RefreshFooter: View {
    let updated: Date?
    let refreshing: Bool
    var error: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.syLine).frame(height: 1)
            RefreshStatus(updated: updated, refreshing: refreshing, error: error, retry: retry)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
    }
}

extension View {
    func liveRefresh(updated: Date?, refreshing: Bool, error: String? = nil, footer: Bool = true, web: Bool = false, button: Bool = true, revealOnTick: Bool? = nil, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(LiveRefreshModifier(updated: updated, refreshing: refreshing, error: error, footer: footer, web: web, button: button, revealOnTick: revealOnTick ?? footer, action: action))
    }
}

private let pullThreshold: CGFloat = 64
private let pullCooldown: TimeInterval = 10
private let heldMargin: CGFloat = 48

enum PullPhase: Equatable {
    case idle, loading, done
}

private struct LiveRefreshModifier: ViewModifier {
    let updated: Date?
    let refreshing: Bool
    let error: String?
    let footer: Bool
    let web: Bool
    let button: Bool
    let revealOnTick: Bool
    let action: @MainActor () async -> Void
    @Environment(AppModel.self) private var app: AppModel?
    @State private var pull: CGFloat = 0
    @State private var phase: PullPhase = .idle
    @State private var lastPull: Date?
    @State private var scrollTopToken = 0
    @State private var revealing = false
    @State private var sawRefreshing = false
    @State private var manual = false

    private var held: Bool { phase != .idle }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            scrollArea(content)
                .background(ScrollPullProbe(pull: $pull, scrollTopToken: scrollTopToken, onTrigger: pulled))
                .overlay(alignment: .top) {
                    PullIndicator(pull: pull, phase: phase)
                        .allowsHitTesting(false)
                }
                .clipped()
                .onChange(of: pull >= pullThreshold) { _, armed in
                    if armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                }
            if footer {
                RefreshFooter(updated: updated, refreshing: refreshing && phase == .idle, error: error) {
                    manualRefresh()
                }
            }
        }
        .toolbar {
            if button {
                ToolbarItem {
                    Button(action: manualRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh")
                    .disabled(phase != .idle)
                }
            }
        }
        .onChange(of: app?.refreshTick) { if revealOnTick { reveal() } }
        .onChange(of: refreshing) { _, now in
            guard revealing else { return }
            if now { sawRefreshing = true } else if sawRefreshing { finish() }
        }
    }

    @ViewBuilder
    private func scrollArea(_ content: Content) -> some View {
        if web {
            content.padding(.top, held ? heldMargin : 0)
        } else {
            content
                .scrollBounceBehavior(.always, axes: .vertical)
                .contentMargins(.top, held && !manual ? heldMargin : nil, for: .scrollContent)
                .padding(.top, held && manual ? heldMargin : 0)
        }
    }

    private func pulled() {
        guard phase == .idle else { return }
        if let lastPull, Date().timeIntervalSince(lastPull) < pullCooldown { return }
        lastPull = Date()
        run()
    }

    private func manualRefresh() {
        guard phase == .idle else { return }
        lastPull = Date()
        scrollTopToken += 1
        manual = true
        run()
    }

    private func run() {
        withAnimation(Motion.insert) { phase = .loading }
        Task { @MainActor in
            await action()
            try? await Task.sleep(nanoseconds: 600_000_000)
            finish()
        }
    }

    private func reveal() {
        guard phase == .idle else { return }
        scrollTopToken += 1
        manual = true
        revealing = true
        sawRefreshing = refreshing
        withAnimation(Motion.insert) { phase = .loading }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if revealing && !sawRefreshing { finish() }
        }
    }

    private func finish() {
        revealing = false
        guard phase == .loading else { return }
        withAnimation(Motion.fade) { phase = .done }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard phase == .done else { return }
            withAnimation(Motion.insert) {
                phase = .idle
                manual = false
            }
        }
    }
}

private struct PullIndicator: View {
    let pull: CGFloat
    let phase: PullPhase

    private var progress: CGFloat { min(1, pull / pullThreshold) }

    var body: some View {
        let visible = phase != .idle || pull > 2
        Group {
            switch phase {
            case .done:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.syCaption2.weight(.bold)).foregroundStyle(Color.syMuted)
                    Text("Updated just now").font(.syCaption.weight(.medium)).foregroundStyle(Color.syMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
            case .loading:
                PullYardLoader(size: 30)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
            case .idle:
                PullYardLogoMark(progress: Double(progress), size: 30)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .scaleEffect(0.75 + 0.25 * progress)
            }
        }
        .frame(height: 26)
        .padding(.top, phase == .idle ? max(4, min(pull, pullThreshold) / 2 - 13) : (heldMargin - 26) / 2)
        .opacity(visible ? (phase == .idle ? Double(min(1, pull / 16)) : 1) : 0)
        .animation(Motion.fade, value: phase)
    }

}

struct PullGesture {
    private(set) var value: CGFloat = 0
    private var active = false

    mutating func handle(_ event: NSEvent, atTop: Bool) -> (pull: CGFloat?, fire: Bool) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return (nil, false) }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            active = atTop
            value = 0
        }
        if event.phase.contains(.changed) {
            guard active else { return (nil, false) }
            if !atTop && value <= 0 {
                active = false
                return (0, false)
            }
            value = max(0, value + event.scrollingDeltaY)
            return (value, false)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let fire = active && event.phase.contains(.ended) && value >= pullThreshold
            active = false
            value = 0
            return (0, fire)
        }
        return (nil, false)
    }
}

final class PullWebView: WKWebView {
    var atTop = true
    var onPull: ((CGFloat) -> Void)?
    var onTrigger: (() -> Void)?
    private var gesture = PullGesture()

    override func reload(_ sender: Any?) { onTrigger?() }

    override func reloadFromOrigin(_ sender: Any?) { onTrigger?() }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard onPull != nil else { return }
        let r = gesture.handle(event, atTop: atTop)
        if let p = r.pull { onPull?(p) }
        if r.fire { onTrigger?() }
    }
}

private struct ScrollPullProbe: NSViewRepresentable {
    @Binding var pull: CGFloat
    var scrollTopToken = 0
    let onTrigger: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        context.coordinator.onPull = { value in
            if abs(value - pull) >= 1 || (value == 0) != (pull == 0) { pull = value }
        }
        context.coordinator.onTrigger = onTrigger
        view.coordinator = context.coordinator
        if context.coordinator.scrollTopToken != scrollTopToken {
            context.coordinator.scrollTopToken = scrollTopToken
            context.coordinator.scrollToTop()
        }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?
        private var attempts = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                coordinator?.detach()
                return
            }
            attempts = 0
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func layout() {
            super.layout()
            if coordinator?.attached == false, window != nil, attempts < 20 { attach() }
        }

        private func attach() {
            attempts += 1
            guard let coordinator, window != nil else { return }
            switch findTarget() {
            case let scroll as NSScrollView: coordinator.attach(scroll)
            case let web as PullWebView: coordinator.attach(web)
            default: break
            }
        }

        private func findTarget() -> NSView? {
            let target = convert(bounds, to: nil)
            guard target.width > 0, target.height > 0 else { return nil }
            var ancestor = superview
            while let a = ancestor {
                var best: (NSView, CGFloat)?
                var queue: [NSView] = [a]
                while !queue.isEmpty {
                    let v = queue.removeFirst()
                    let candidate = (v as? NSScrollView).flatMap { $0.hasVerticalScroller || $0.documentView != nil ? $0 : nil } ?? (v as? PullWebView)
                    if let c = candidate {
                        let r = c.convert(c.bounds, to: nil)
                        let overlap = r.intersection(target)
                        if !overlap.isNull, overlap.width * overlap.height > target.width * target.height * 0.5 {
                            let diff = abs(r.minX - target.minX) + abs(r.minY - target.minY) + abs(r.width - target.width) + abs(r.height - target.height)
                            if best == nil || diff < best!.1 { best = (c, diff) }
                        }
                        continue
                    }
                    queue.append(contentsOf: v.subviews)
                }
                if let best { return best.0 }
                ancestor = a.superview
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var webView: PullWebView?
        var onPull: (CGFloat) -> Void = { _ in }
        var onTrigger: () -> Void = {}
        var scrollTopToken = 0
        private var monitor: Any?
        private var gesture = PullGesture()
        private var settle: DispatchWorkItem?

        var attached: Bool { scrollView != nil || webView != nil }

        func attach(_ web: PullWebView) {
            guard web !== webView else { return }
            detach()
            webView = web
            web.onPull = { [weak self] in self?.report($0) }
            web.onTrigger = { [weak self] in self?.onTrigger() }
        }

        func attach(_ scroll: NSScrollView) {
            guard scroll !== scrollView else { return }
            detach()
            scrollView = scroll
            scroll.verticalScrollElasticity = .allowed
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            scrollView = nil
            webView?.onPull = nil
            webView?.onTrigger = nil
            webView = nil
        }

        func scrollToTop() {
            if let web = webView {
                web.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'})")
                return
            }
            guard let scroll = scrollView else { return }
            let clip = scroll.contentView
            let top = NSPoint(x: clip.bounds.minX, y: clip.isFlipped ? -clip.contentInsets.top : max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height))
            guard abs(clip.bounds.origin.y - top.y) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0 : 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(top)
            } completionHandler: {
                MainActor.assumeIsolated { scroll.reflectScrolledClipView(clip) }
            }
        }

        private var atTop: Bool {
            guard let scroll = scrollView else { return false }
            let clip = scroll.contentView
            guard clip.isFlipped else { return false }
            return clip.bounds.minY + clip.contentInsets.top <= 1
        }

        private func handle(_ event: NSEvent) {
            guard let scroll = scrollView, let window = scroll.window else { return }
            if let w = event.window, w !== window { return }
            let inWindow = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            let point = scroll.convert(inWindow, from: nil)
            guard scroll.bounds.contains(point) else { return }
            let r = gesture.handle(event, atTop: atTop)
            if let p = r.pull { report(p) }
            if r.fire { onTrigger() }
        }

        private func report(_ value: CGFloat) {
            onPull(value)
            settle?.cancel()
            guard value > 0 else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.gesture = PullGesture()
                self?.onPull(0)
            }
            settle = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }
}

private struct LiveFrontKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var liveFront: Bool {
        get { self[LiveFrontKey.self] }
        set { self[LiveFrontKey.self] = newValue }
    }
}

struct LiveTickModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.liveFront) private var front
    @State private var shown = false
    @State private var stale = false
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                shown = true
                stale = false
            }
            .onDisappear { shown = false }
            .onChange(of: front) { catchUp() }
            .onChange(of: app.liveTick) {
                if shown && front {
                    Diagnostics.liveTask { await action() }
                } else {
                    stale = true
                }
            }
    }

    private func catchUp() {
        guard stale, shown, front else { return }
        stale = false
        Diagnostics.liveTask { await action() }
    }
}

extension View {
    func onLiveTick(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(LiveTickModifier(action: action))
    }
}
