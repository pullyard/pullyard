import SwiftUI
import UIKit

struct LogoDrawOn: View {
    var size: CGFloat
    var duration: Double = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var done = false

    var body: some View {
        if reduceMotion || done {
            PullYardLogoMark(progress: 1, size: size)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                let t = min(1, context.date.timeIntervalSince(start) / duration)
                PullYardLogoMark(progress: (1 - cos(t * .pi)) / 2, size: size)
            }
            .task {
                start = Date()
                try? await Task.sleep(for: .seconds(duration))
                done = true
            }
        }
    }
}

struct PullYardLoader: View {
    var title: String? = nil
    var size: CGFloat = 40
    var style: LogoStyle = .brand
    private static let draw: Double = 1.5
    private static let hold: Double = 0.45
    private static let fade: Double = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var pulse = false

    var body: some View {
        let layout = title == nil || size < 30 ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            mark
            if let title {
                Text(title).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var mark: some View {
        if reduceMotion {
            PullYardLogoMark(progress: 1, size: size, style: style)
                .opacity(pulse ? 0.45 : 0.9)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let cycle = Self.draw + Self.hold + Self.fade
                let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                let progress = min(1, t / Self.draw)
                let erase = t > Self.draw + Self.hold ? (t - Self.draw - Self.hold) / Self.fade : 0
                PullYardLogoMark(progress: progress, erase: easeInOut(erase), size: size, style: style)
            }
        }
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

struct PullToRefreshLogo: ViewModifier {
    let isRefreshing: Bool
    @State private var pull: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    -(geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, value in
                    pull = max(0, value)
                }
                .overlay(alignment: .top) { indicator }
        } else {
            content.overlay(alignment: .top) { indicator }
        }
    }

    @ViewBuilder private var indicator: some View {
        let progress = min(1, Double(pull / 110))
        if isRefreshing {
            PullYardLoader(size: 46)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .pyGlassCapsule()
                .padding(.top, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
        } else if progress > 0.04 {
            PullYardLogoMark(progress: progress, size: 46)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .pyGlassCapsule()
                .scaleEffect(0.75 + 0.25 * progress)
                .opacity(min(1, progress * 1.6))
                .padding(.top, max(4, pull * 0.35 - 30))
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func pullToRefreshLogo(isRefreshing: Bool) -> some View {
        modifier(PullToRefreshLogo(isRefreshing: isRefreshing))
    }
}

struct PYBranchLoader: View {
    var size: CGFloat = 16
    var label = "Loading"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BranchLoaderLayer(side: size, animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }
}

private struct BranchLoaderLayer: UIViewRepresentable {
    let side: CGFloat
    let animated: Bool

    func makeUIView(context: Context) -> BranchLoaderView { BranchLoaderView() }

    func updateUIView(_ view: BranchLoaderView, context: Context) {
        view.configure(side: side, animated: animated)
    }
}

final class BranchLoaderView: UIView {
    private static let box = CGRect(x: 160, y: 454, width: 372, height: 364)
    private var shapes: [(layer: CAShapeLayer, violet: Bool, curve: Bool)] = []
    private var state: (side: CGFloat, animated: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for (violet, curve) in [(true, false), (false, false), (true, true), (false, true)] {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            layer.addSublayer(shape)
            shapes.append((shape, violet, curve))
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, let state { restart(state.animated) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    func configure(side: CGFloat, animated: Bool) {
        guard state?.side != side || state?.animated != animated else { return }
        state = (side, animated)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let box = Self.box
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.midX - box.midX * scale, ty: rect.midY - box.midY * scale)
        let paths = [LogoGeometry.nodeAPath, LogoGeometry.nodeBPath, LogoGeometry.curveAPath, LogoGeometry.curveBPath]
        for (i, item) in shapes.enumerated() {
            item.layer.frame = rect
            item.layer.path = paths[i].applying(transform).cgPath
            item.layer.lineWidth = max(1.4, side / 9)
        }
        applyColors()
        restart(animated)
    }

    private func applyColors() {
        let violet = UIColor(MobileTheme.violet).resolvedColor(with: traitCollection)
        let sky = UIColor(MobileTheme.sky).resolvedColor(with: traitCollection)
        for item in shapes { item.layer.strokeColor = (item.violet ? violet : sky).cgColor }
    }

    private func restart(_ animated: Bool) {
        for item in shapes {
            item.layer.removeAllAnimations()
            item.layer.strokeStart = 0
            item.layer.strokeEnd = 1
            guard animated else { continue }
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            let end = CAKeyframeAnimation(keyPath: "strokeEnd")
            end.values = item.curve ? [0, 0, 1, 1] : [0, 1, 1]
            end.keyTimes = item.curve ? [0, 0.12, 0.5, 1] : [0, 0.25, 1]
            end.timingFunctions = item.curve ? [ease, ease, ease] : [ease, ease]
            let start = CAKeyframeAnimation(keyPath: "strokeStart")
            start.values = [0, 0, 1]
            start.keyTimes = [0, 0.5, 1]
            start.timingFunctions = [ease, ease]
            let group = CAAnimationGroup()
            group.animations = [end, start]
            group.duration = 1.8
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            item.layer.add(group, forKey: "draw")
        }
    }
}

struct WakeLoader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WakeLayer(animated: !reduceMotion)
            .frame(width: 20, height: 12)
            .accessibilityLabel(Text("Running"))
    }
}

private struct WakeLayer: UIViewRepresentable {
    let animated: Bool

    func makeUIView(context: Context) -> WakeLayerView { WakeLayerView() }

    func updateUIView(_ view: WakeLayerView, context: Context) {
        view.animated = animated
    }
}

final class WakeLayerView: UIView {
    private var arcs: [CAShapeLayer] = []
    var animated = true {
        didSet { if animated != oldValue { restart() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let colors = [UIColor(red: 0.22, green: 0.741, blue: 0.973, alpha: 1), UIColor(red: 0.43, green: 0.65, blue: 0.98, alpha: 1), UIColor(red: 0.655, green: 0.545, blue: 0.98, alpha: 1)]
        for color in colors {
            let arc = CAShapeLayer()
            arc.fillColor = nil
            arc.lineWidth = 2
            arc.lineCap = .round
            arc.strokeColor = color.cgColor
            layer.addSublayer(arc)
            arcs.append(arc)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restart() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, arc) in arcs.enumerated() {
            let x = bounds.width * (0.12 + 0.3 * CGFloat(i))
            let y = bounds.height * 0.62
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x - 3, y: y))
            path.addQuadCurve(to: CGPoint(x: x + 3, y: y), controlPoint: CGPoint(x: x, y: y - 3))
            arc.frame = bounds
            arc.path = path.cgPath
        }
    }

    private func restart() {
        for (i, arc) in arcs.enumerated() {
            arc.removeAllAnimations()
            arc.opacity = animated ? 0.45 : 0.8
            guard animated, window != nil else { continue }
            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = [0, -3.4, 0]
            lift.keyTimes = [0, 0.5, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.45, 1, 0.45]
            fade.keyTimes = [0, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [lift, fade]
            group.duration = 0.625
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.1375
            group.isRemovedOnCompletion = false
            arc.add(group, forKey: "wake")
        }
    }
}

struct AgentWorkingCapsule: View {
    let status: String?
    let since: Date?

    var body: some View {
        HStack(spacing: 8) {
            PYBranchLoader(size: 16, label: "Working")
            Text(status ?? L("Working…"))
                .mobileFont(size: 13, weight: .medium)
                .foregroundStyle(MobileTheme.ink)
                .lineLimit(1)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(since)))
                        .mobileFont(size: 12)
                        .monospacedDigit()
                        .foregroundStyle(MobileTheme.muted)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 34)
        .background(MobileTheme.coral.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(MobileTheme.coral.opacity(0.22)))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct ThinkingLabel: View {
    var text = "Thinking…"

    var body: some View {
        Label {
            Text(LocalizedStringKey(text))
                .foregroundStyle(LinearGradient(colors: [MobileTheme.violet, MobileTheme.sky], startPoint: .leading, endPoint: .trailing))
        } icon: {
            Image(systemName: "brain").foregroundStyle(MobileTheme.violet)
        }
    }
}

struct AgentStateDot: View {
    let state: String

    var body: some View {
        Group {
            switch state {
            case "working": PYBranchLoader(size: 14, label: "Working")
            case "waiting":
                Circle().fill(MobileTheme.coral).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(MobileTheme.coral.opacity(0.35), lineWidth: 3).scaleEffect(1.7))
            case "active": Circle().fill(MobileTheme.green).frame(width: 8, height: 8)
            default: Circle().stroke(MobileTheme.slate, lineWidth: 1.2).frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
    }
}
