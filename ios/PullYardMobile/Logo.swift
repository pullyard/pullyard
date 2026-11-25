import SwiftUI
import UIKit

private enum LogoGeometry {
    static let box = CGRect(x: 150, y: 370, width: 750, height: 500)

    static let violet = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let sky = Color(red: 0.220, green: 0.741, blue: 0.973)
    static let hullTop = Color(red: 0.984, green: 0.443, blue: 0.522)
    static let hullBottom = Color(red: 0.839, green: 0.122, blue: 0.306)
    static let deck = Color(red: 0.996, green: 0.804, blue: 0.827)
    static let cabin = Color(red: 0.973, green: 0.980, blue: 0.988)
    static let cabinShade = Color(red: 0.886, green: 0.910, blue: 0.941)
    static let window = Color(red: 0.118, green: 0.161, blue: 0.231)
    static let wave = Color(red: 0.490, green: 0.827, blue: 0.988)

    static func nodeA(_ p: inout Path) { p.addEllipse(in: CGRect(x: 172, y: 466, width: 68, height: 68)) }
    static func nodeB(_ p: inout Path) { p.addEllipse(in: CGRect(x: 172, y: 738, width: 68, height: 68)) }

    static func curveA(_ p: inout Path) {
        p.move(to: CGPoint(x: 240, y: 500))
        p.addCurve(to: CGPoint(x: 520, y: 636), control1: CGPoint(x: 392, y: 500), control2: CGPoint(x: 420, y: 636))
    }

    static func curveB(_ p: inout Path) {
        p.move(to: CGPoint(x: 240, y: 772))
        p.addCurve(to: CGPoint(x: 520, y: 636), control1: CGPoint(x: 392, y: 772), control2: CGPoint(x: 420, y: 636))
    }

    static func hull(_ p: inout Path) {
        p.move(to: CGPoint(x: 470, y: 566))
        p.addLine(to: CGPoint(x: 866, y: 566))
        p.addLine(to: CGPoint(x: 800, y: 728))
        p.addLine(to: CGPoint(x: 540, y: 728))
        p.closeSubpath()
    }

    static func deckStrip(_ p: inout Path) {
        p.move(to: CGPoint(x: 470, y: 566))
        p.addLine(to: CGPoint(x: 866, y: 566))
        p.addLine(to: CGPoint(x: 857, y: 590))
        p.addLine(to: CGPoint(x: 480, y: 590))
        p.closeSubpath()
    }

    static func cabin(_ p: inout Path) { p.addRoundedRect(in: CGRect(x: 584, y: 462, width: 176, height: 104), cornerSize: CGSize(width: 16, height: 16)) }
    static func cabinShade(_ p: inout Path) { p.addRect(CGRect(x: 584, y: 540, width: 176, height: 26)) }
    static func chimney(_ p: inout Path) { p.addRoundedRect(in: CGRect(x: 702, y: 392, width: 40, height: 86), cornerSize: CGSize(width: 8, height: 8)) }
    static func chimneyTop(_ p: inout Path) { p.addRoundedRect(in: CGRect(x: 702, y: 392, width: 40, height: 20), cornerSize: CGSize(width: 6, height: 6)) }

    static func windows(_ p: inout Path) {
        p.addRoundedRect(in: CGRect(x: 610, y: 488, width: 38, height: 34), cornerSize: CGSize(width: 8, height: 8))
        p.addRoundedRect(in: CGRect(x: 664, y: 488, width: 38, height: 34), cornerSize: CGSize(width: 8, height: 8))
    }

    static func porthole(_ p: inout Path) { p.addEllipse(in: CGRect(x: 755, y: 627, width: 30, height: 30)) }

    static func wave1(_ p: inout Path) {
        p.move(to: CGPoint(x: 560, y: 786))
        p.addCurve(to: CGPoint(x: 720, y: 786), control1: CGPoint(x: 620, y: 770), control2: CGPoint(x: 660, y: 802))
        p.addCurve(to: CGPoint(x: 870, y: 786), control1: CGPoint(x: 780, y: 770), control2: CGPoint(x: 820, y: 770))
    }

    static func wave2(_ p: inout Path) {
        p.move(to: CGPoint(x: 600, y: 836))
        p.addCurve(to: CGPoint(x: 740, y: 836), control1: CGPoint(x: 650, y: 822), control2: CGPoint(x: 690, y: 848))
        p.addCurve(to: CGPoint(x: 850, y: 836), control1: CGPoint(x: 790, y: 824), control2: CGPoint(x: 820, y: 822))
    }

    static func make(_ build: (inout Path) -> Void) -> Path {
        var p = Path()
        build(&p)
        return p
    }

    static let nodeAPath = make(nodeA)
    static let nodeBPath = make(nodeB)
    static let curveAPath = make(curveA)
    static let curveBPath = make(curveB)
    static let hullPath = make(hull)
    static let deckPath = make(deckStrip)
    static let portholePath = make(porthole)
    static let chimneyPath = make(chimney)
    static let chimneyTopPath = make(chimneyTop)
    static let cabinPath = make(cabin)
    static let cabinShadePath = make(cabinShade)
    static let windowsPath = make(windows)
    static let wave1Path = make(wave1)
    static let wave2Path = make(wave2)
}

private struct LogoPart: Shape {
    let base: Path

    init(_ base: Path) { self.base = base }

    func path(in rect: CGRect) -> Path {
        let box = LogoGeometry.box
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * scale
        let dy = rect.midY - box.midY * scale
        return base.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

enum LogoStyle: Equatable {
    case brand
    case monochrome(Color)
}

struct PullYardLogoMark: View {
    var progress: Double
    var erase: Double = 0
    var size: CGFloat = 40
    var style: LogoStyle = .brand

    private func stage(_ from: Double, _ to: Double) -> Double {
        let t = min(1, max(0, (progress - from) / (to - from)))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func tint(_ brand: Color) -> Color {
        if case let .monochrome(color) = style { return color }
        return brand
    }

    var body: some View {
        let lineScale = size / LogoGeometry.box.width
        let line: (CGFloat) -> CGFloat = { max(1.5, $0 * lineScale) }
        let nodes = stage(0.00, 0.22)
        let curves = stage(0.14, 0.48)
        let hullLine = stage(0.40, 0.68)
        let hullFill = stage(0.58, 0.78)
        let cabin = stage(0.66, 0.86)
        let waves = stage(0.74, 1.00)
        let tail = min(1, max(0, erase))
        let mono = style != .brand
        ZStack {
            Group {
                LogoPart(LogoGeometry.nodeAPath).trim(from: tail, to: nodes)
                    .stroke(tint(LogoGeometry.violet), style: StrokeStyle(lineWidth: line(18), lineCap: .round))
                LogoPart(LogoGeometry.nodeBPath).trim(from: tail, to: nodes)
                    .stroke(tint(LogoGeometry.sky), style: StrokeStyle(lineWidth: line(18), lineCap: .round))
                LogoPart(LogoGeometry.curveAPath).trim(from: tail, to: curves)
                    .stroke(tint(LogoGeometry.violet), style: StrokeStyle(lineWidth: line(24), lineCap: .round))
                LogoPart(LogoGeometry.curveBPath).trim(from: tail, to: curves)
                    .stroke(tint(LogoGeometry.sky), style: StrokeStyle(lineWidth: line(24), lineCap: .round))
            }
            Group {
                LogoPart(LogoGeometry.hullPath)
                    .fill(mono ? AnyShapeStyle(tint(.clear)) : AnyShapeStyle(LinearGradient(colors: [LogoGeometry.hullTop, LogoGeometry.hullBottom], startPoint: .top, endPoint: .bottom)))
                    .opacity(hullFill * (1 - tail))
                if !mono {
                    LogoPart(LogoGeometry.deckPath).fill(LogoGeometry.deck).opacity(hullFill * (1 - tail))
                    LogoPart(LogoGeometry.portholePath).fill(LogoGeometry.deck).opacity(hullFill * (1 - tail))
                }
                LogoPart(LogoGeometry.hullPath).trim(from: tail, to: hullLine)
                    .stroke(tint(LogoGeometry.hullTop), style: StrokeStyle(lineWidth: line(14), lineCap: .round, lineJoin: .round))
                    .opacity(1 - hullFill * 0.85)
            }
            Group {
                LogoPart(LogoGeometry.chimneyPath).fill(mono ? tint(.clear) : LogoGeometry.cabinShade)
                if !mono {
                    LogoPart(LogoGeometry.chimneyTopPath).fill(LogoGeometry.hullTop)
                    LogoPart(LogoGeometry.cabinPath).fill(LogoGeometry.cabin)
                    LogoPart(LogoGeometry.cabinShadePath).fill(LogoGeometry.cabinShade)
                    LogoPart(LogoGeometry.windowsPath).fill(LogoGeometry.window)
                } else {
                    LogoPart(LogoGeometry.cabinPath).fill(tint(.clear))
                }
            }
            .scaleEffect(x: 1, y: 0.6 + 0.4 * cabin, anchor: UnitPoint(x: 0.5, y: (566 - LogoGeometry.box.minY) / LogoGeometry.box.height))
            .opacity(cabin * (1 - tail))
            Group {
                LogoPart(LogoGeometry.wave1Path).trim(from: tail, to: waves)
                    .stroke(tint(LogoGeometry.wave).opacity(0.55), style: StrokeStyle(lineWidth: line(12), lineCap: .round))
                if size >= 28 {
                    LogoPart(LogoGeometry.wave2Path).trim(from: tail, to: max(0, waves - 0.15) / 0.85)
                        .stroke(tint(LogoGeometry.wave).opacity(0.32), style: StrokeStyle(lineWidth: line(10), lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size * LogoGeometry.box.height / LogoGeometry.box.width)
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

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
