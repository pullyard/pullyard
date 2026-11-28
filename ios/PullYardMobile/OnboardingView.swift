import SwiftUI

struct OnboardingView: View {
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int? = 0
    @State private var progress: Double = 0
    @State private var leaving = false
    @State private var finishPulse = 0

    private let count = 4
    private var current: Int { page ?? 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VoyageBackdrop(progress: progress, leaving: leaving)
                    .ignoresSafeArea()

                ScrollView(.horizontal, showsIndicators: false) { Group {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { index in
                            OnboardingPage(index: index, active: current == index && !leaving)
                                .frame(width: geo.size.width)
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .opacity(1 - abs(phase.value) * 0.7)
                                        .scaleEffect(1 - abs(phase.value) * 0.14)
                                        .rotation3DEffect(.degrees(reduceMotion ? 0 : phase.value * -28), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                        .blur(radius: abs(phase.value) * 7)
                                }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }.background(HorizontalOnly()) }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $page)
                .modifier(ScrollProgress(progress: $progress, width: geo.size.width, page: current))
                .opacity(leaving ? 0 : 1)

                VStack {
                    HStack {
                        Spacer()
                        if current < count - 1 {
                            Button("Skip") { withAnimation(.snappy) { page = count - 1 } }
                                .mobileFont(size: 15, weight: .semibold)
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Capsule())
                                .pyGlassCapsule(interactive: true, fallback: Color.white.opacity(0.12))
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8)
                    Spacer()
                    PageDots(count: count, current: current)
                        .padding(.bottom, 18)
                    CTAButton(title: L(current < count - 1 ? "Next" : "Set sail"), isFinal: current == count - 1) {
                        if current < count - 1 {
                            withAnimation(.smooth(duration: 0.6)) { page = current + 1 }
                        } else {
                            depart()
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
                .opacity(leaving ? 0 : 1)
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: current)
        .sensoryFeedback(.success, trigger: finishPulse)
        .statusBarHidden()
    }

    private func depart() {
        finishPulse += 1
        withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 1.1)) { leaving = true }
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.25 : 1.15))
            finish()
        }
    }
}

private struct ScrollProgress: ViewModifier {
    @Binding var progress: Double
    let width: CGFloat
    let page: Int

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.x / max(1, width))
            } action: { _, value in
                progress = max(0, value)
            }
        } else {
            content.onChange(of: page) { _, value in
                withAnimation(.smooth(duration: 0.6)) { progress = Double(value) }
            }
        }
    }
}

private struct VoyageBackdrop: View {
    let progress: Double
    let leaving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Sky(progress: progress, time: time)
                    Starfield(time: time)
                        .opacity(max(0, 1 - progress * 0.45))
                    Waves(time: time, progress: progress)
                        .frame(height: geo.size.height * 0.34)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Wake(progress: progress, leaving: leaving)
                        .frame(height: geo.size.height * 0.34)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Ship(time: time)
                        .frame(width: 120, height: 92)
                        .position(shipPosition(in: geo.size, time: time))
                        .rotationEffect(.degrees(reduceMotion ? 0 : sin(time * 1.4) * 2.5))
                }
            }
        }
    }

    private func shipPosition(in size: CGSize, time: Double) -> CGPoint {
        let span = Double(size.width) * 0.62
        let start = Double(size.width) * 0.19
        let travel = min(1, progress / 3)
        let x = leaving ? Double(size.width) * 1.35 : start + span * travel
        let bob = reduceMotion ? 0 : sin(time * 1.6) * 4
        return CGPoint(x: x, y: Double(size.height) * 0.72 + bob)
    }
}

private struct Sky: View {
    let progress: Double
    let time: Double

    private static let palettes: [[Color]] = [
        [Color(hex: 0x0B1226), Color(hex: 0x1A2540), Color(hex: 0x2A2160)],
        [Color(hex: 0x101A38), Color(hex: 0x3A2E7A), Color(hex: 0x1F5C8F)],
        [Color(hex: 0x15274F), Color(hex: 0x6B4CC2), Color(hex: 0x2A8BC8)],
        [Color(hex: 0x1C2A55), Color(hex: 0xC2557A), Color(hex: 0xF07563)],
    ]

    var body: some View {
        let colors = blended
        if #available(iOS 18.0, *) {
            let drift = Float(sin(time * 0.35) * 0.08)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + drift, 0.45 - drift], [1, 0.55],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                colors[0], colors[0], colors[1],
                colors[1], colors[2], colors[1],
                colors[0], colors[0], colors[0],
            ])
        } else {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        }
    }

    private var blended: [Color] {
        let clamped = min(Double(Self.palettes.count - 1), max(0, progress))
        let lower = Int(clamped.rounded(.down))
        let upper = min(Self.palettes.count - 1, lower + 1)
        let t = clamped - Double(lower)
        return (0..<3).map { Self.palettes[lower][$0].mix(Self.palettes[upper][$0], t) }
    }
}

private struct Starfield: View {
    let time: Double

    var body: some View {
        Canvas { context, size in
            for index in 0..<90 {
                let seed = Double(index) * 12.9898
                let x = fract(sin(seed) * 43758.5453) * size.width
                let y = fract(sin(seed * 1.7) * 23421.631) * size.height * 0.62
                let radius = 0.6 + fract(sin(seed * 3.1) * 9813.13) * 1.6
                let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * (0.8 + fract(seed) * 2.2) + seed))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)), with: .color(.white.opacity(twinkle * 0.85)))
            }
        }
        .allowsHitTesting(false)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct Waves: View {
    let time: Double
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let layers: [(Color, Double, Double, Double)] = [
                (Color(hex: 0x1F7FB8).opacity(0.35), 0.18, 0.9, 0.2),
                (Color(hex: 0x0E3A5F).opacity(0.75), 0.36, 1.25, 0.45),
                (Color(hex: 0x081A2E).opacity(0.95), 0.56, 1.7, 0.75),
            ]
            for (color, top, speed, parallax) in layers {
                var path = Path()
                let baseline = size.height * top
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: baseline))
                var x: CGFloat = 0
                while x <= size.width + 8 {
                    let phase = Double(x) / 70 + time * speed - progress * 3 * parallax
                    let y = baseline + CGFloat(sin(phase) * 7 + sin(phase * 0.43 + 1.3) * 4)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 6
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Wake: View {
    let progress: Double
    let leaving: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let travel = leaving ? 1 : min(1, progress / 3)
            let tip = CGPoint(x: w * (0.19 + 0.62 * travel) - 40, y: h * 0.38)
            ZStack {
                curve(from: CGPoint(x: -20, y: h * 0.22), to: tip, bend: -40)
                    .trim(from: 0, to: 0.25 + 0.75 * travel)
                    .stroke(Color(hex: 0xA78BFA).opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                curve(from: CGPoint(x: -20, y: h * 0.58), to: tip, bend: 40)
                    .trim(from: 0, to: 0.25 + 0.75 * travel)
                    .stroke(Color(hex: 0x38BDF8).opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .shadow(color: Color(hex: 0x38BDF8).opacity(0.6), radius: 8)
        }
        .allowsHitTesting(false)
    }

    private func curve(from: CGPoint, to: CGPoint, bend: CGFloat) -> Path {
        var path = Path()
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: from.x + (to.x - from.x) * 0.55, y: from.y), control2: CGPoint(x: from.x + (to.x - from.x) * 0.45, y: to.y + bend * 0.1))
        return path
    }
}

private struct Ship: View {
    let time: Double

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            for index in 0..<4 {
                let age = fract(time * 0.35 + Double(index) * 0.25)
                let radius = 5 + age * 10
                let x = w * 0.66 + age * 14
                let y = h * 0.04 - age * 26
                context.fill(Path(ellipseIn: CGRect(x: x - radius / 2, y: y - radius / 2 + 18, width: radius, height: radius)), with: .color(.white.opacity((1 - age) * 0.35)))
            }
            var hull = Path()
            hull.move(to: CGPoint(x: 0, y: h * 0.52))
            hull.addLine(to: CGPoint(x: w, y: h * 0.52))
            hull.addLine(to: CGPoint(x: w * 0.83, y: h * 0.95))
            hull.addLine(to: CGPoint(x: w * 0.18, y: h * 0.95))
            hull.closeSubpath()
            context.fill(hull, with: .linearGradient(Gradient(colors: [Color(hex: 0xFB7185), Color(hex: 0xD61F4E)]), startPoint: CGPoint(x: 0, y: h * 0.52), endPoint: CGPoint(x: 0, y: h * 0.95)))
            context.fill(Path(CGRect(x: 0, y: h * 0.52, width: w, height: h * 0.06)), with: .color(Color(hex: 0xFECDD3)))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.72, y: h * 0.66, width: w * 0.08, height: w * 0.08)), with: .color(Color(hex: 0xFECDD3)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.6, y: h * 0.05, width: w * 0.1, height: h * 0.3), cornerRadius: 3), with: .color(Color(hex: 0xE2E8F0)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.6, y: h * 0.05, width: w * 0.1, height: h * 0.07), cornerRadius: 2), with: .color(Color(hex: 0xFB7185)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.29, y: h * 0.24, width: w * 0.46, height: h * 0.3), cornerRadius: 5), with: .color(Color(hex: 0xF8FAFC)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.36, y: h * 0.31, width: w * 0.1, height: h * 0.1), cornerRadius: 2), with: .color(Color(hex: 0x1E293B)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.5, y: h * 0.31, width: w * 0.1, height: h * 0.1), cornerRadius: 2), with: .color(Color(hex: 0x1E293B)))
        }
        .shadow(color: Color(hex: 0xF07563).opacity(0.45), radius: 14, y: 6)
        .accessibilityHidden(true)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct OnboardingPage: View {
    let index: Int
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 40)
            ZStack {
                switch index {
                case 0: HeroScene(active: active)
                case 1: QueueScene(active: active)
                case 2: ProjectsScene(active: active)
                default: MergeScene(active: active)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            RevealText(text: L(title), active: active, size: 36)
            Text(L(subtitle))
                .mobileFont(size: 17)
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(4)
                .opacity(active ? 1 : 0)
                .offset(y: active ? 0 : 12)
                .animation(.easeOut(duration: 0.6).delay(0.45), value: active)
            Spacer(minLength: 230)
        }
        .padding(.horizontal, 28)
    }

    private var title: String {
        ["Your reviews,\nwithin reach.", "Your queue,\neverywhere.", "Every project\nat a glance.", "Review. Approve.\nMerge."][index]
    }

    private var subtitle: String {
        [
            "PullYard brings your GitHub pull requests to iPhone — no server, your token stays on this device.",
            "Review requests, your own pull requests and notifications — with CI and review status on every row.",
            "Pin the repositories you care about and see what's waiting for you in each of them.",
            "Read diffs, resolve threads, approve and merge — with checks and readiness right there.",
        ][index]
    }
}

private struct RevealText: View {
    let text: String
    let active: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                let words = line.split(separator: " ").map(String.init)
                let before = lines.prefix(lineIndex).reduce(0) { $0 + $1.split(separator: " ").count }
                HStack(spacing: size * 0.26) {
                    ForEach(Array(words.enumerated()), id: \.offset) { wordIndex, word in
                        Text(word)
                            .mobileFont(size: size, design: .serif)
                            .tracking(-0.6)
                            .foregroundStyle(.white)
                            .opacity(active ? 1 : 0)
                            .blur(radius: active || reduceMotion ? 0 : 10)
                            .offset(y: active || reduceMotion ? 0 : 18)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.12 + Double(before + wordIndex) * 0.07), value: active)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct HeroScene: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x6B55D6).opacity(0.35)).frame(width: 240).blur(radius: 50)
            if shown {
                LogoDrawOn(size: 230, duration: 2.0)
                    .shadow(color: Color(hex: 0x38BDF8).opacity(0.5), radius: 24)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onChange(of: active, initial: true) { _, value in
            if value && !shown { withAnimation(.spring(response: 0.8, dampingFraction: 0.75)) { shown = true } }
        }
    }
}

private struct QueueScene: View {
    let active: Bool
    @State private var count = 0

    private let rows: [(String, String, Color, String)] = [
        ("Add ETag support to sync", "harbor/api #482", Color(hex: 0x62C48F), "checkmark.circle.fill"),
        ("Fix cold start when offline", "harbor/mobile #1290", Color(hex: 0xEE7A6E), "xmark.circle.fill"),
        ("New status colours", "harbor/design #77", Color(hex: 0xEDB955), "clock.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                Text("Needs review")
                Text("\(count)")
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.white.opacity(0.22), in: Capsule())
            }
            .mobileFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .pyGlassCapsule(tint: Color(hex: 0xD24A37), fallback: Color(hex: 0xD24A37))
            .scaleEffect(active ? 1 : 0.8)
            .opacity(active ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: active)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 10) {
                    Circle().fill(Color.white.opacity(0.2)).frame(width: 26, height: 26)
                        .overlay(Text(String(row.1.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).mobileFont(size: 15, weight: .semibold).foregroundStyle(.white).lineLimit(1)
                        Text(row.1).mobileFont(size: 12).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Image(systemName: row.3).foregroundStyle(row.2).symbolEffect(.pulse, isActive: active && index == 2)
                }
                .padding(12)
                .pyGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fallback: Color.white.opacity(0.1))
                .rotation3DEffect(.degrees(active ? 0 : 35), axis: (x: 1, y: 0, z: 0), anchor: .bottom)
                .offset(x: active ? 0 : 60, y: active ? 0 : 40)
                .opacity(active ? 1 : 0)
                .animation(.spring(response: 0.65, dampingFraction: 0.72).delay(0.15 + Double(index) * 0.12), value: active)
            }
        }
        .padding(.horizontal, 4)
        .task(id: active) {
            guard active else { count = 0; return }
            for value in 1...3 {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.snappy) { count = value }
            }
        }
    }
}

private struct ProjectsScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let projects: [(String, Color, Bool)] = [
        ("api", Color(hex: 0x6B55D6), true), ("mobile", Color(hex: 0x2A8BC8), true), ("design", Color(hex: 0xD24A37), false),
        ("docs", Color(hex: 0x23824D), false), ("infra", Color(hex: 0xB06F12), false), ("web", Color(hex: 0x5BB8EC), false),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 6])).frame(width: 220, height: 220)
                    Circle().stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 7])).frame(width: 140, height: 140)
                    PullYardLogoMark(progress: active ? 1 : 0, size: 70)
                        .animation(.easeInOut(duration: 1.2), value: active)
                    ForEach(Array(projects.enumerated()), id: \.offset) { index, project in
                        let radius: CGFloat = index % 2 == 0 ? 110 : 70
                        let angle = Double(index) / Double(projects.count) * .pi * 2 + time * (index % 2 == 0 ? 0.25 : -0.35)
                        let point = CGPoint(x: center.x + cos(angle) * radius * (active ? 1 : 0.2), y: center.y + sin(angle) * radius * 0.72 * (active ? 1 : 0.2))
                        VStack(spacing: 3) {
                            Text(project.0.prefix(2).uppercased())
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .pyGlass(in: Circle(), tint: project.1.opacity(0.8), fallback: project.1)
                                .overlay(alignment: .topTrailing) {
                                    if project.2 { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xF07563)).offset(x: 4, y: -4) }
                                }
                            Text(project.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                        }
                        .position(point)
                        .opacity(active ? 1 : 0)
                        .animation(.spring(response: 0.9, dampingFraction: 0.7).delay(Double(index) * 0.06), value: active)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MergeScene: View {
    let active: Bool
    @State private var passed = 0
    @State private var approved = false
    @State private var merged = false
    @State private var burst: Date?

    private let checks = ["build", "unit-tests", "lint", "deploy-preview"]

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 10) {
                        Image(systemName: index < passed ? "checkmark.circle.fill" : "clock.fill")
                            .foregroundStyle(index < passed ? Color(hex: 0x62C48F) : Color(hex: 0xEDB955))
                            .contentTransition(.symbolEffect(.replace))
                        Text(name).mobileFont(size: 14, weight: .semibold, design: .monospaced).foregroundStyle(.white)
                        Spacer()
                        Text(index < passed ? "passed" : "running").mobileFont(size: 12).foregroundStyle(.white.opacity(0.55))
                            .contentTransition(.opacity)
                    }
                    .opacity(active ? 1 : 0)
                    .offset(x: active ? 0 : -30)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.08), value: active)
                }
                HStack(spacing: 10) {
                    Label(approved ? "Approved" : "Approve", systemImage: approved ? "checkmark.seal.fill" : "checkmark")
                        .mobileFont(size: 15, weight: .semibold).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .pyGlass(in: Capsule(), tint: Color(hex: 0x23784A).opacity(approved ? 1 : 0.6), fallback: Color(hex: 0x23784A))
                        .scaleEffect(approved ? 1.04 : 1)
                        .symbolEffect(.bounce, value: approved)
                    Label(merged ? "Merged" : "Merge", systemImage: "arrow.triangle.merge")
                        .mobileFont(size: 15, weight: .semibold).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .pyGlass(in: Capsule(), tint: Color(hex: 0x5E48C8).opacity(merged ? 1 : 0.5), fallback: Color(hex: 0x5E48C8))
                        .scaleEffect(merged ? 1.06 : 1)
                }
                .padding(.top, 6)
                .opacity(active ? 1 : 0)
                .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.35), value: active)
            }
            .padding(16)
            .pyGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), fallback: Color.white.opacity(0.08))
            if let burst {
                ConfettiBurst(start: burst).allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.success, trigger: merged)
        .sensoryFeedback(.impact(weight: .medium), trigger: approved)
        .task(id: active) {
            guard active else { passed = 0; approved = false; merged = false; burst = nil; return }
            try? await Task.sleep(for: .milliseconds(500))
            for value in 1...checks.count {
                try? await Task.sleep(for: .milliseconds(380))
                withAnimation(.snappy) { passed = value }
            }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { approved = true }
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { merged = true }
            burst = .now
        }
    }
}

private struct ConfettiBurst: View {
    let start: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let colors: [Color] = [Color(hex: 0xA78BFA), Color(hex: 0x38BDF8), Color(hex: 0xF07563), Color(hex: 0x62C48F), Color(hex: 0xEDB955), .white]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard t < 2.4 else { return }
                let origin = CGPoint(x: size.width * 0.72, y: size.height * 0.82)
                for index in 0..<70 {
                    let seed = Double(index) * 7.31
                    let angle = -Double.pi / 2 + (sin(seed) * 0.5) * Double.pi * 0.9
                    let speed = 260 + abs(sin(seed * 1.9)) * 260
                    let x = origin.x + CGFloat(cos(angle) * speed * t)
                    let y = origin.y + CGFloat(sin(angle) * speed * t + 520 * t * t)
                    let alpha = max(0, 1 - t / 2.4)
                    let rect = CGRect(x: x, y: y, width: 6, height: index % 3 == 0 ? 6 : 10)
                    var piece = canvas
                    piece.translateBy(x: rect.midX, y: rect.midY)
                    piece.rotate(by: .radians(t * 8 + seed))
                    piece.fill(Path(roundedRect: CGRect(x: -3, y: -4, width: rect.width, height: rect.height), cornerRadius: 1.5), with: .color(colors[index % colors.count].opacity(alpha)))
                }
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.35))
                    .frame(width: index == current ? 26 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

private struct CTAButton: View {
    let title: String
    let isFinal: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer: CGFloat = -1

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).contentTransition(.interpolate)
                Image(systemName: isFinal ? "sailboat.fill" : "arrow.right").contentTransition(.symbolEffect(.replace))
            }
            .mobileFont(size: 17, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay {
                if isFinal {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: shimmer * geo.size.width)
                            .blendMode(.plusLighter)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .pyGlass(in: Capsule(), tint: isFinal ? Color(hex: 0xD24A37) : MobileTheme.accentFill, interactive: true, fallback: isFinal ? Color(hex: 0xD24A37) : MobileTheme.accentFill)
            .shadow(color: (isFinal ? Color(hex: 0xF07563) : Color(hex: 0x38BDF8)).opacity(0.45), radius: 18, y: 6)
        }
        .buttonStyle(.pyPlain)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isFinal)
        .onChange(of: isFinal, initial: true) { _, value in
            guard value, !reduceMotion else { return }
            shimmer = -1
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false).delay(0.4)) { shimmer = 1.4 }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    func mix(_ other: Color, _ amount: Double) -> Color {
        Color(uiColor: UIColor(self).blended(with: UIColor(other), CGFloat(amount)))
    }
}
