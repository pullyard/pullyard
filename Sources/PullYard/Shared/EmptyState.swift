import SwiftUI

struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.sy(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.syText)
            .padding(.horizontal, 6)
            .frame(minWidth: TextZoom.shared.size(22), minHeight: TextZoom.shared.size(20))
            .background(RoundedRectangle(cornerRadius: Radius.xs).fill(Color.syRaised))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Color.syLineStrong, lineWidth: 1))
    }
}

struct HarborWaves: View {
    var body: some View {
        Canvas { ctx, size in
            for (i, y) in [size.height * 0.35, size.height * 0.8].enumerated() {
                var p = Path()
                let inset = size.width * (i == 0 ? 0 : 0.12)
                let w = size.width - inset * 2
                p.move(to: CGPoint(x: inset, y: y))
                let steps = 4
                for s in 0..<steps {
                    let x0 = inset + w * CGFloat(s) / CGFloat(steps)
                    let x1 = inset + w * CGFloat(s + 1) / CGFloat(steps)
                    let dip: CGFloat = s.isMultiple(of: 2) ? -4 : 4
                    p.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: (x0 + x1) / 2, y: y + dip))
                }
                ctx.stroke(p, with: .color(Color.syHarborLine.opacity(i == 0 ? 1 : 0.6)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

struct BrandAurora: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.syViolet.opacity(0.08)).frame(width: 320).offset(x: -160, y: -90)
            Circle().fill(Color.syAccent.opacity(0.08)).frame(width: 300).offset(x: 170, y: -40)
            Circle().fill(Color.syCoral.opacity(0.06)).frame(width: 260).offset(x: 20, y: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: 70)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PYEmptyState: View {
    var key = "detail-empty"
    var title: String
    var message: String
    var shortcuts: [(key: String, label: String)] = []
    var aurora = true
    var nextUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        ZStack {
            if aurora && Theme.isBrand { BrandAurora() }
            VStack(spacing: 14) {
                ZStack(alignment: .bottom) {
                    HarborWaves()
                        .frame(width: 200, height: 22)
                        .offset(y: 16)
                    DrawnLogoMark(key: key, size: 96)
                        .offset(y: lifted ? -4 : 0)
                }
                .padding(.bottom, 14)
                Text(title)
                    .font(.system(size: TextZoom.shared.size(28), weight: .semibold, design: .serif))
                    .foregroundStyle(Color.syText)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if !shortcuts.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(shortcuts, id: \.key) { item in
                            HStack(spacing: 6) {
                                Keycap(key: item.key)
                                Text(item.label).font(.syCaption).foregroundStyle(Color.syMuted)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                if nextUp {
                    VStack(spacing: 14) {
                        NextUpPanel()
                        FirstRunChecklist()
                    }
                    .padding(.top, 18)
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .task { await bob() }
    }

    private func bob() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        for _ in 0..<2 {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 2.3)) { lifted = true }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            withAnimation(.easeInOut(duration: 2.3)) { lifted = false }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
        }
    }
}
