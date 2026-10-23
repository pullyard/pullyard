import SwiftUI

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
}

private struct LogoPart: Shape {
    let build: (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var p = Path()
        build(&p)
        let box = LogoGeometry.box
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * scale
        let dy = rect.midY - box.midY * scale
        return p.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

struct PullYardLogoMark: View {
    var progress: Double
    var erase: Double = 0
    var size: CGFloat = 40

    private func stage(_ from: Double, _ to: Double) -> Double {
        let t = min(1, max(0, (progress - from) / (to - from)))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    var body: some View {
        let lineScale = size / LogoGeometry.box.width
        let nodes = stage(0.00, 0.22)
        let curves = stage(0.14, 0.48)
        let hullLine = stage(0.40, 0.68)
        let hullFill = stage(0.58, 0.78)
        let cabin = stage(0.66, 0.86)
        let waves = stage(0.74, 1.00)
        let tail = min(1, max(0, erase))
        ZStack {
            Group {
                LogoPart(build: LogoGeometry.nodeA).trim(from: tail, to: nodes)
                    .stroke(LogoGeometry.violet, style: StrokeStyle(lineWidth: 18 * lineScale, lineCap: .round))
                LogoPart(build: LogoGeometry.nodeB).trim(from: tail, to: nodes)
                    .stroke(LogoGeometry.sky, style: StrokeStyle(lineWidth: 18 * lineScale, lineCap: .round))
                LogoPart(build: LogoGeometry.curveA).trim(from: tail, to: curves)
                    .stroke(LogoGeometry.violet, style: StrokeStyle(lineWidth: 24 * lineScale, lineCap: .round))
                LogoPart(build: LogoGeometry.curveB).trim(from: tail, to: curves)
                    .stroke(LogoGeometry.sky, style: StrokeStyle(lineWidth: 24 * lineScale, lineCap: .round))
            }
            Group {
                LogoPart(build: LogoGeometry.hull)
                    .fill(LinearGradient(colors: [LogoGeometry.hullTop, LogoGeometry.hullBottom], startPoint: .top, endPoint: .bottom))
                    .opacity(hullFill * (1 - tail))
                LogoPart(build: LogoGeometry.deckStrip).fill(LogoGeometry.deck).opacity(hullFill * (1 - tail))
                LogoPart(build: LogoGeometry.porthole).fill(LogoGeometry.deck).opacity(hullFill * (1 - tail))
                LogoPart(build: LogoGeometry.hull).trim(from: tail, to: hullLine)
                    .stroke(LogoGeometry.hullTop, style: StrokeStyle(lineWidth: 14 * lineScale, lineCap: .round, lineJoin: .round))
                    .opacity(1 - hullFill * 0.85)
            }
            Group {
                LogoPart(build: LogoGeometry.chimney).fill(LogoGeometry.cabinShade)
                LogoPart(build: LogoGeometry.chimneyTop).fill(LogoGeometry.hullTop)
                LogoPart(build: LogoGeometry.cabin).fill(LogoGeometry.cabin)
                LogoPart(build: LogoGeometry.cabinShade).fill(LogoGeometry.cabinShade)
                LogoPart(build: LogoGeometry.windows).fill(LogoGeometry.window)
            }
            .scaleEffect(x: 1, y: 0.6 + 0.4 * cabin, anchor: UnitPoint(x: 0.5, y: (566 - LogoGeometry.box.minY) / LogoGeometry.box.height))
            .opacity(cabin * (1 - tail))
            Group {
                LogoPart(build: LogoGeometry.wave1).trim(from: tail, to: waves)
                    .stroke(LogoGeometry.wave.opacity(0.55), style: StrokeStyle(lineWidth: 12 * lineScale, lineCap: .round))
                LogoPart(build: LogoGeometry.wave2).trim(from: tail, to: max(0, waves - 0.15) / 0.85)
                    .stroke(LogoGeometry.wave.opacity(0.32), style: StrokeStyle(lineWidth: 10 * lineScale, lineCap: .round))
            }
        }
        .frame(width: size, height: size * LogoGeometry.box.height / LogoGeometry.box.width)
        .accessibilityHidden(true)
    }
}

struct PullYardLoader: View {
    var size: CGFloat = 40
    private static let draw: Double = 1.7
    private static let hold: Double = 0.5
    private static let fade: Double = 0.55
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if reduceMotion {
            PullYardLogoMark(progress: 1, size: size)
                .opacity(0.8)
                .accessibilityLabel("Loading")
        } else {
            TimelineView(.animation) { context in
                let cycle = Self.draw + Self.hold + Self.fade
                let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                let progress = min(1, t / Self.draw)
                let erase = t > Self.draw + Self.hold ? (t - Self.draw - Self.hold) / Self.fade : 0
                PullYardLogoMark(progress: progress, erase: easeInOut(erase), size: size)
            }
            .accessibilityLabel("Loading")
        }
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
