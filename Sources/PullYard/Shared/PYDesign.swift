import SwiftUI

struct PYBackdrop: View, Equatable {
    var tints: [Color] = [.syAccent, .syViolet]
    var base: Color = .syWindow
    var strength: Double = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func == (a: Self, b: Self) -> Bool {
        a.tints == b.tints && a.base == b.base && a.strength == b.strength
    }

    var body: some View {
        let palette = Array((tints.isEmpty ? [Color.syAccent, .syViolet] : tints).prefix(4))
        let alpha = (scheme == .dark ? 0.16 : 0.10) * strength
        ZStack {
            base
            if !reduceTransparency, Theme.isBrand {
                ForEach(Array(palette.enumerated()), id: \.offset) { i, color in
                    let x = palette.count == 1 ? 0.5 : 0.1 + 0.8 * Double(i) / Double(palette.count - 1)
                    RadialGradient(
                        colors: [color.opacity(alpha), color.opacity(0)],
                        center: UnitPoint(x: x, y: i.isMultiple(of: 2) ? 0.1 : 0.92),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct PYCardSurface: ViewModifier {
    var radius: CGFloat = 14
    var hover = false
    var accent: Color = .syAccent
    var selected = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if hover {
                    shape.fill(Color.black.opacity(scheme == .dark ? 0.35 : 0.10)).blur(radius: 8).offset(y: 5).padding(4)
                }
            }
            .background { shape.fill(selected ? accent.opacity(scheme == .dark ? 0.16 : 0.10) : Color.clear).background(shape.fill(Color.syRaised)) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.14 : 0.7), Color.syLine], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .overlay {
                if hover || selected { shape.strokeBorder(accent.opacity(selected ? 0.7 : 0.45), lineWidth: 1) }
            }
            .offset(y: hover && !Motion.reduced ? -2 : 0)
    }
}

extension View {
    func pyCardSurface(radius: CGFloat = 14, hover: Bool = false, accent: Color = .syAccent, selected: Bool = false) -> some View {
        modifier(PYCardSurface(radius: radius, hover: hover, accent: accent, selected: selected))
    }
}

struct PYGlowDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.45)
            .accessibilityHidden(true)
    }
}

struct PYCountBadge: View {
    let count: Int
    var tint: Color = .syAccent

    var body: some View {
        Text("\(count)")
            .font(.syCaption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .contentTransition(.numericText())
            .animation(Motion.snappy, value: count)
    }
}

struct PYSearchPill: View {
    @Binding var text: String
    var prompt: String
    var width: CGFloat? = 220
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(focused ? Color.syAccent : Color.syMuted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.syCaption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: width)
        .pyGlassCapsule(tint: focused ? Color.syAccent.opacity(0.12) : nil)
        .animation(Motion.fade, value: focused)
    }
}

struct PYEmptySlot: View {
    var title: String
    var icon: String = "tray"
    var active = false
    var activeTitle: String?
    var tint: Color = .syAccent

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: active ? "arrow.down.circle.fill" : icon)
                .font(.system(size: 18, weight: .medium))
            Text(active ? (activeTitle ?? title) : title)
                .font(.syCaption)
        }
        .foregroundStyle(active ? tint : Color.syDim)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? tint : Color.syLineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

struct PYPillMenuLabel: View {
    let icon: String
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(Color.syMuted)
            Text(title).foregroundStyle(value == nil ? Color.syText : Color.syMuted)
            if let value { Text(value).fontWeight(.semibold).foregroundStyle(Color.syText) }
        }
        .font(.syCaption.weight(.medium))
    }
}

extension View {
    func pyPill(interactive: Bool = true) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 7)
            .pyGlassCapsule(interactive: interactive)
    }
}
