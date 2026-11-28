import SwiftUI

private func hex(_ value: UInt32) -> Color { Color(nsColor: NSColor(hex: value)) }

struct OnboardingView: View {
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var progress: Double = 0
    @State private var leaving = false
    @State private var forward = true
    @State private var tilt: CGSize = .zero
    @State private var floating = false
    @State private var glow = false
    @FocusState private var focused: Bool

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let dx: CGFloat = forward ? 70 : -70
        return .asymmetric(
            insertion: .modifier(active: SlideBlur(x: dx, blur: 12, opacity: 0), identity: SlideBlur(x: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: SlideBlur(x: -dx, blur: 12, opacity: 0), identity: SlideBlur(x: 0, blur: 0, opacity: 1))
        )
    }

    private let count = 5

    var body: some View {
        ZStack {
            VoyageBackdrop(progress: progress, leaving: leaving)
                .ignoresSafeArea()
            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(eyebrow)
                        .font(.sy(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(hex(0xF07563))
                        .id("eyebrow-\(page)")
                        .transition(slide)
                    RevealText(text: title, size: 44)
                        .id("title-\(page)")
                    Text(subtitle)
                        .font(.sy(size: 17))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineSpacing(4)
                        .frame(maxWidth: 420, alignment: .leading)
                        .id("subtitle-\(page)")
                        .transition(slide)
                }
                .frame(maxWidth: 460, alignment: .leading)
                ZStack {
                    switch page {
                    case 0: HeroScene()
                    case 1: OverviewScene()
                    case 2: KeysScene()
                    case 3: MergeScene()
                    default: AgentScene()
                    }
                }
                .id("scene-\(page)")
                .transition(slide)
                .frame(width: 420, height: 340)
                .offset(y: floating && !reduceMotion ? -6 : 6)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(tilt.width) * 8), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(-tilt.height) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: floating)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: tilt)
            }
            .padding(.horizontal, 64)
            .padding(.bottom, 120)
            .opacity(leaving ? 0 : 1)
            VStack {
                HStack {
                    Spacer()
                    if page < count - 1 {
                        Button("Skip") { finishNow() }
                            .buttonStyle(.plain)
                            .font(.sy(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.white.opacity(0.12)))
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                Spacer()
                HStack(spacing: 18) {
                    if page > 0 {
                        Button { go(page - 1) } label: {
                            Image(systemName: "chevron.left").font(.syIcon(13)).frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.85))
                        .background(Circle().fill(.white.opacity(0.12)))
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .accessibilityLabel("Back")
                    }
                    PageDots(count: count, current: page) { go($0) }
                    Button(page < count - 1 ? "Next" : "Set sail") {
                        if page < count - 1 { go(page + 1) } else { depart() }
                    }
                    .buttonStyle(.plain)
                    .font(.sy(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, page < count - 1 ? 28 : 34)
                    .frame(height: 42)
                    .background(Capsule().fill(page < count - 1 ? hex(0x2A8BC8) : hex(0xC24533)))
                    .overlay {
                        if page == count - 1 {
                            Capsule()
                                .strokeBorder(hex(0xF8A59A), lineWidth: 2)
                                .scaleEffect(glow ? 1.35 : 1)
                                .opacity(glow ? 0 : 0.8)
                                .animation(reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false), value: glow)
                        }
                    }
                    .shadow(color: (page < count - 1 ? hex(0x2A8BC8) : hex(0xF07563)).opacity(glow && page == count - 1 ? 0.85 : 0.5), radius: glow && page == count - 1 ? 22 : 14, y: 4)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 36)
                .opacity(leaving ? 0 : 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            floating = true
            glow = true
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                tilt = CGSize(width: (point.x / max(1, NSScreen.main?.frame.width ?? 1440) - 0.5), height: (point.y / max(1, NSScreen.main?.frame.height ?? 900) - 0.5))
            case .ended:
                tilt = .zero
            }
        }
        .onKeyPress(.rightArrow) {
            if page < count - 1 { go(page + 1) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to PullYard")
        .accessibilityAddTraits(.isModal)
    }

    private func go(_ index: Int) {
        let target = min(count - 1, max(0, index))
        guard target != page else { return }
        forward = target > page
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.6)) {
            page = target
            progress = Double(target)
        }
    }

    private func depart() {
        withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 1.0)) { leaving = true }
        Task {
            try? await Task.sleep(nanoseconds: reduceMotion ? 220_000_000 : 1_050_000_000)
            finish()
        }
    }

    private func finishNow() {
        withAnimation(.easeOut(duration: 0.25)) { leaving = true }
        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            finish()
        }
    }

    private var eyebrow: String {
        ["Welcome aboard", "Your harbor", "Review at speed", "Merge with confidence", "Agents on deck"][page]
    }

    private var title: String {
        ["Pull requests,\nwithout the browser.", "Start every day\non Overview.", "Your keyboard\nis the fast lane.", "Know it's ready\nbefore you merge.", "Hand the fix\nto an agent."][page]
    }

    private var subtitle: String {
        [
            "PullYard is a native home for your GitHub reviews. Your token stays on this Mac, and everything refreshes on its own.",
            "See what's waiting for you, what's failing and what's ready to merge — one glance, then jump straight in.",
            "j and k walk the list. ⇧⌘R writes a review, ⇧⌘A approves, ⌥⌘↓ opens the next review request. ⌘K finds everything else.",
            "Every requirement is checked live: reviews, checks, conflicts, branch rules. Merge asks once more before it ships.",
            "Failing checks or review comments? Start an agent from the pull request and keep reviewing while it works.",
        ][page]
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Button { select(index) } label: {
                    Capsule()
                        .fill(.white.opacity(index == current ? 0.95 : 0.3))
                        .frame(width: index == current ? 22 : 7, height: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1)")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
    }
}

private struct RevealText: View {
    let text: String
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                let words = line.split(separator: " ").map(String.init)
                let before = lines.prefix(lineIndex).reduce(0) { $0 + $1.split(separator: " ").count }
                HStack(spacing: size * 0.24) {
                    ForEach(Array(words.enumerated()), id: \.offset) { wordIndex, word in
                        Text(word)
                            .font(.system(size: TextZoom.shared.size(size), weight: .semibold, design: .serif))
                            .tracking(-0.6)
                            .foregroundStyle(.white)
                            .opacity(shown ? 1 : 0)
                            .blur(radius: shown || reduceMotion ? 0 : 10)
                            .offset(y: shown || reduceMotion ? 0 : 18)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1 + Double(before + wordIndex) * 0.06), value: shown)
                    }
                }
            }
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct VoyageBackdrop: View {
    let progress: Double
    let leaving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Sky(progress: progress, time: time)
                    Starfield(time: time, streak: leaving)
                        .opacity(max(0, 1 - progress * 0.3))
                    ShootingStars(time: time)
                        .opacity(max(0, 1 - progress * 0.2))
                    Waves(time: time, progress: progress)
                        .frame(height: geo.size.height * 0.3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Glints(time: time)
                        .frame(height: geo.size.height * 0.3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    WakeTrail(ship: shipPosition(in: geo.size, time: time), height: geo.size.height, leaving: leaving)
                    Ship(time: time)
                        .frame(width: 110, height: 84)
                        .position(shipPosition(in: geo.size, time: time))
                        .rotationEffect(.degrees(reduceMotion ? 0 : sin(time * 1.4) * 2))
                }
            }
        }
    }

    private func shipPosition(in size: CGSize, time: Double) -> CGPoint {
        let travel = min(1, progress / 4)
        let x = leaving ? Double(size.width) * 1.3 : Double(size.width) * (0.12 + 0.7 * travel)
        let bob = reduceMotion ? 0 : sin(time * 1.6) * 4
        return CGPoint(x: x, y: Double(size.height) * 0.73 + bob)
    }
}

private struct Sky: View {
    let progress: Double
    let time: Double

    private static let palettes: [[UInt32]] = [
        [0x0B1226, 0x1A2540, 0x2A2160],
        [0x101A38, 0x3A2E7A, 0x1F5C8F],
        [0x15274F, 0x6B4CC2, 0x2A8BC8],
        [0x182A52, 0x8A4FB0, 0x3C9AD0],
        [0x1C2A55, 0xC2557A, 0xF07563],
    ]

    var body: some View {
        let colors = blended
        if #available(macOS 15.0, *) {
            let drift = Float(sin(time * 0.3) * 0.08)
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
        return (0..<3).map { mix(Self.palettes[lower][$0], Self.palettes[upper][$0], t) }
    }

    private func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func channel(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xff) / 255 }
        let r = channel(a, 16) + (channel(b, 16) - channel(a, 16)) * t
        let g = channel(a, 8) + (channel(b, 8) - channel(a, 8)) * t
        let bl = channel(a, 0) + (channel(b, 0) - channel(a, 0)) * t
        return Color(red: r, green: g, blue: bl)
    }
}

private struct Starfield: View {
    let time: Double
    var streak = false

    var body: some View {
        Canvas { context, size in
            for index in 0..<110 {
                let seed = Double(index) * 12.9898
                let x = fract(sin(seed) * 43758.5453) * size.width
                let y = fract(sin(seed * 1.7) * 23421.631) * size.height * 0.6
                let radius = 0.6 + fract(sin(seed * 3.1) * 9813.13) * 1.6
                let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * (0.8 + fract(seed) * 2.2) + seed))
                let length = streak ? radius * 26 : radius
                context.fill(Path(roundedRect: CGRect(x: x - length + radius, y: y, width: length, height: radius), cornerRadius: radius / 2), with: .color(.white.opacity(twinkle * 0.85)))
            }
        }
        .animation(.easeIn(duration: 0.8), value: streak)
        .allowsHitTesting(false)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct Waves: View {
    let time: Double
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let layers: [(UInt32, Double, Double, Double, Double)] = [
                (0x1F7FB8, 0.35, 0.18, 0.9, 0.2),
                (0x0E3A5F, 0.75, 0.36, 1.25, 0.45),
                (0x081A2E, 0.95, 0.56, 1.7, 0.75),
            ]
            for (color, alpha, top, speed, parallax) in layers {
                var path = Path()
                let baseline = size.height * top
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: baseline))
                var x: CGFloat = 0
                while x <= size.width + 8 {
                    let phase = Double(x) / 80 + time * speed - progress * 2.4 * parallax
                    let y = baseline + CGFloat(sin(phase) * 7 + sin(phase * 0.43 + 1.3) * 4)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 8
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(hex(color).opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
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
            context.fill(hull, with: .linearGradient(Gradient(colors: [hex(0xFB7185), hex(0xD61F4E)]), startPoint: CGPoint(x: 0, y: h * 0.52), endPoint: CGPoint(x: 0, y: h * 0.95)))
            context.fill(Path(CGRect(x: 0, y: h * 0.52, width: w, height: h * 0.06)), with: .color(hex(0xFECDD3)))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.72, y: h * 0.66, width: w * 0.08, height: w * 0.08)), with: .color(hex(0xFECDD3)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.6, y: h * 0.05, width: w * 0.1, height: h * 0.3), cornerRadius: 3), with: .color(hex(0xE2E8F0)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.6, y: h * 0.05, width: w * 0.1, height: h * 0.07), cornerRadius: 2), with: .color(hex(0xFB7185)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.29, y: h * 0.24, width: w * 0.46, height: h * 0.3), cornerRadius: 5), with: .color(hex(0xF8FAFC)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.36, y: h * 0.31, width: w * 0.1, height: h * 0.1), cornerRadius: 2), with: .color(hex(0x1E293B)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.5, y: h * 0.31, width: w * 0.1, height: h * 0.1), cornerRadius: 2), with: .color(hex(0x1E293B)))
        }
        .shadow(color: hex(0xF07563).opacity(0.45), radius: 14, y: 6)
        .accessibilityHidden(true)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct SceneCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16)))
    }
}

private struct HeroScene: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(hex(0x6B55D6).opacity(0.35)).frame(width: 260).blur(radius: 60)
            if shown {
                LogoDrawOn(size: 300, duration: 2.0)
                    .shadow(color: hex(0x38BDF8).opacity(0.5), radius: 24)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.75)) { shown = true } }
    }
}

private struct OverviewScene: View {
    @State private var counts = [0, 0, 0, 0]
    private let tiles: [(String, String, UInt32, Int)] = [
        ("Reviews waiting", "eye.fill", 0xF07563, 4),
        ("Ready to merge", "arrow.triangle.merge", 0x5DBE8A, 2),
        ("Failing checks", "xmark.octagon.fill", 0xE8746A, 1),
        ("Mentioned", "at", 0x8C97E8, 3),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                SceneCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: tile.1)
                            .font(.syIcon(14))
                            .foregroundStyle(hex(tile.2))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(hex(tile.2).opacity(0.2)))
                        Text("\(counts[index])")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text(tile.0).font(.sy(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            for step in 1...4 {
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.snappy) { counts = tiles.map { min($0.3, step) } }
            }
        }
    }
}

private struct KeysScene: View {
    @State private var shown = 0
    private let keys: [(String, String)] = [("j  k", "Next / previous"), ("⇧⌘R", "Write review"), ("⇧⌘A", "Approve"), ("⌥⌘↓", "Next in queue"), ("⌘K", "Command palette")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                HStack(spacing: 14) {
                    Text(key.0)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(minWidth: 74)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.25)))
                        .shadow(color: .black.opacity(0.3), radius: 0, y: 2)
                    Text(key.1).font(.sy(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
                .opacity(index < shown ? 1 : 0)
                .offset(x: index < shown ? 0 : 30)
            }
        }
        .task {
            for step in 1...keys.count {
                try? await Task.sleep(nanoseconds: 160_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { shown = step }
            }
        }
    }
}

private struct MergeScene: View {
    @State private var done = 0
    @State private var merged = false
    private let items = ["Approved by 2 reviewers", "All 12 checks passing", "No conflicts with main", "Branch rules satisfied"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SceneCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: index < done ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(index < done ? hex(0x5DBE8A) : .white.opacity(0.4))
                                .contentTransition(.symbolEffect(.replace))
                            Text(item).font(.sy(size: 15)).foregroundStyle(.white.opacity(index < done ? 0.95 : 0.55))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Image(systemName: merged ? "checkmark.seal.fill" : "arrow.triangle.merge")
                    .contentTransition(.symbolEffect(.replace))
                Text(merged ? "Merged into main" : "Merge…")
            }
            .font(.sy(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(merged ? hex(0x6B55D6) : hex(0x2B7F50)))
            .scaleEffect(merged ? 1.04 : 1)
        }
        .task {
            for step in 1...items.count {
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.snappy) { done = step }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { merged = true }
        }
    }
}

private struct AgentScene: View {
    @State private var running = false
    @State private var lines = 0
    private let log = ["Reading 3 review comments…", "Updating SyncEngine.swift", "Running tests · 48 passed", "Pushed fix to the branch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                Text("Fix with agent")
            }
            .font(.sy(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(hex(0xC24533)))
            .shadow(color: hex(0xF07563).opacity(0.5), radius: 12, y: 4)
            SceneCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(hex(0xF07563)).frame(width: 7, height: 7)
                            .opacity(running ? 1 : 0.3)
                        Text("Agent running · 1m").font(.sy(size: 13, weight: .semibold)).foregroundStyle(hex(0xF8A59A))
                    }
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text("› " + line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .opacity(index < lines ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { running = true }
            for step in 1...log.count {
                try? await Task.sleep(nanoseconds: 420_000_000)
                withAnimation(.easeOut(duration: 0.25)) { lines = step }
            }
        }
    }
}

private struct SlideBlur: ViewModifier {
    let x: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

private struct ShootingStars: View {
    let time: Double

    var body: some View {
        Canvas { context, size in
            for lane in 0..<3 {
                let period = 5.5 + Double(lane) * 2.3
                let local = (time + Double(lane) * 1.9).truncatingRemainder(dividingBy: period)
                let flight = 0.9
                guard local < flight else { continue }
                let t = local / flight
                let cycle = Int((time + Double(lane) * 1.9) / period)
                let seed = Double(cycle * 7 + lane * 13) * 1.618
                let startX = (0.15 + fract(sin(seed) * 43758.5453) * 0.7) * size.width
                let startY = (0.04 + fract(sin(seed * 2.3) * 9731.17) * 0.28) * size.height
                let travel = size.width * 0.22
                let head = CGPoint(x: startX + travel * t, y: startY + travel * 0.42 * t)
                let tail = CGPoint(x: head.x - 90 * (1 - t * 0.4), y: head.y - 38 * (1 - t * 0.4))
                var path = Path()
                path.move(to: tail)
                path.addLine(to: head)
                let fade = sin(t * .pi)
                context.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.9 * fade)]), startPoint: tail, endPoint: head), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white.opacity(fade)))
            }
        }
        .allowsHitTesting(false)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct Glints: View {
    let time: Double

    var body: some View {
        Canvas { context, size in
            for index in 0..<26 {
                let seed = Double(index) * 7.31
                let x = fract(sin(seed) * 43758.5453) * size.width
                let y = size.height * (0.24 + fract(sin(seed * 1.9) * 2731.3) * 0.5)
                let pulse = max(0, sin(time * (1.1 + fract(seed) * 1.6) + seed * 3))
                let w = 4 + pulse * 10
                context.fill(Path(roundedRect: CGRect(x: x - w / 2, y: y, width: w, height: 1.4), cornerRadius: 0.7), with: .color(Color(red: 0.75, green: 0.88, blue: 1).opacity(pulse * 0.55)))
            }
        }
        .allowsHitTesting(false)
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct WakeTrail: View {
    let ship: CGPoint
    let height: CGFloat
    let leaving: Bool

    var body: some View {
        Canvas { context, _ in
            let tip = CGPoint(x: ship.x - 48, y: ship.y + 22)
            let tails = [(CGPoint(x: -20, y: tip.y - height * 0.08), hex(0xA78BFA)), (CGPoint(x: -20, y: tip.y + height * 0.06), hex(0x38BDF8))]
            for (start, color) in tails {
                var path = Path()
                path.move(to: start)
                path.addCurve(to: tip, control1: CGPoint(x: start.x + (tip.x - start.x) * 0.55, y: start.y), control2: CGPoint(x: start.x + (tip.x - start.x) * 0.45, y: tip.y))
                context.stroke(path, with: .color(color.opacity(0.18)), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                context.stroke(path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)), with: .color(.white.opacity(0.7)))
        }
        .shadow(color: hex(0x38BDF8).opacity(0.5), radius: 8)
        .opacity(ship.x > 60 ? 1 : 0)
        .allowsHitTesting(false)
    }
}
