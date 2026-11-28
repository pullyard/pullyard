import SwiftUI
import UIKit

enum ThemeStyle: String, CaseIterable, Identifiable {
    case pullyard = "PullYard", system = "System"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .automatic: nil; case .light: .light; case .dark: .dark }
    }
}

enum ThemeStore {
    static let styleKey = "mobile.theme.style"
    static let appearanceKey = "mobile.theme.appearance"
    nonisolated(unsafe) static var style: ThemeStyle = ThemeStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .pullyard
    nonisolated(unsafe) private static var applied: ThemeStyle?

    static var isBrand: Bool { style == .pullyard }

    @MainActor
    static func update(_ next: ThemeStyle) {
        style = next
        guard applied != next else { return }
        applied = next
        applyUIKitAppearance()
    }

    @MainActor
    static func applyUIKitAppearance() {
        if #available(iOS 26.0, *) {
            applyGlassAppearance()
            return
        }
        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        if isBrand {
            let ink = MobileTheme.dynamicUIColor(0x131B2B, 0xEEF2F8)
            let serifLarge = UIFont.systemFont(ofSize: 34, weight: .semibold).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 34) } ?? .systemFont(ofSize: 34, weight: .semibold)
            let serifTitle = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 17) } ?? .systemFont(ofSize: 17, weight: .semibold)
            navigation.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: serifLarge), .foregroundColor: ink]
            navigation.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: serifTitle), .foregroundColor: ink]
            navigation.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
            navigation.backgroundColor = MobileTheme.dynamicUIColor(0xEEEAE1, 0x0A1020, lightAlpha: 0.55, darkAlpha: 0.55)
            tab.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
            tab.backgroundColor = MobileTheme.dynamicUIColor(0xEEEAE1, 0x0A1020, lightAlpha: 0.55, darkAlpha: 0.55)
        }
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = isBrand ? {
            let edge = navigation.copy()
            edge.configureWithTransparentBackground()
            edge.largeTitleTextAttributes = navigation.largeTitleTextAttributes
            edge.titleTextAttributes = navigation.titleTextAttributes
            return edge
        }() : nil
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = isBrand ? tab : nil
        UITabBarItem.appearance().badgeColor = isBrand ? MobileTheme.dynamicUIColor(0xD24A37, 0xF07563) : .systemRed
    }
}

extension ThemeStore {
    @MainActor
    static func applyGlassAppearance() {
        let bar = UINavigationBar.appearance()
        if isBrand {
            let ink = MobileTheme.dynamicUIColor(0x131B2B, 0xEEF2F8)
            let serifLarge = UIFont.systemFont(ofSize: 34, weight: .semibold).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 34) } ?? .systemFont(ofSize: 34, weight: .semibold)
            let serifTitle = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 17) } ?? .systemFont(ofSize: 17, weight: .semibold)
            bar.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: serifLarge), .foregroundColor: ink]
            bar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: serifTitle), .foregroundColor: ink]
        } else {
            bar.largeTitleTextAttributes = nil
            bar.titleTextAttributes = nil
        }
        bar.standardAppearance = UINavigationBarAppearance()
        bar.scrollEdgeAppearance = nil
        bar.compactAppearance = nil
        UITabBar.appearance().standardAppearance = UITabBarAppearance()
        UITabBar.appearance().scrollEdgeAppearance = nil
        UITabBarItem.appearance().badgeColor = isBrand ? MobileTheme.dynamicUIColor(0xD24A37, 0xF07563) : .systemRed
    }
}

enum MobileTheme {
    static let canvas = token(0xEEEAE1, 0x0A1020, system: .systemGroupedBackground)
    static let card = token(0xFFFFFF, 0x152038, system: .secondarySystemGroupedBackground)
    static let panel = token(0xFAF8F4, 0x101A2E, system: .secondarySystemGroupedBackground)
    static let sunken = token(0xF2EEE6, 0x070D19, system: .tertiarySystemFill)
    static let line = token(0x1A2333, 0xA0AEC4, lightAlpha: 0.12, darkAlpha: 0.14, system: .separator)
    static let lineStrong = token(0x1A2333, 0xA0AEC4, lightAlpha: 0.2, darkAlpha: 0.22, system: .opaqueSeparator)
    static let ink = token(0x131B2B, 0xEEF2F8, system: .label)
    static let muted = token(0x556174, 0x98A4B8, system: .secondaryLabel)
    static let dim = token(0x7C8494, 0x6B778C, system: .tertiaryLabel)
    static let accent = token(0x1F7FC0, 0x5BB8EC, system: .systemBlue)
    static let sky = token(0x1F7FB8, 0x5BB8EC, system: .systemCyan)
    static let violet = token(0x5B45D1, 0xA193F5, system: .systemPurple)
    static let coral = token(0xD24A37, 0xF07563, system: .systemOrange)
    static let green = token(0x23824D, 0x62C48F, system: .systemGreen)
    static let red = token(0xBE3A28, 0xEE7A6E, system: .systemRed)
    static let amber = token(0xB06F12, 0xEDB955, system: .systemOrange)
    static let slate = token(0x5E6779, 0x98A2B6, system: .systemGray)
    static let accentFill = token(0x1D70A6, 0x2580C0, system: .systemBlue)
    static let greenFill = token(0x23784A, 0x2B8A55, system: .systemGreen)
    static let violetFill = token(0x5E48C8, 0x6A55D8, system: .systemPurple)
    static let redFill = token(0xB23A2A, 0xC4483A, system: .systemRed)
    static let amberInk = token(0x7F4F0A, 0xF0C674, system: .systemBrown)
    static let addBG = token(0x23824D, 0x62C48F, lightAlpha: 0.13, darkAlpha: 0.14, system: UIColor.systemGreen.withAlphaComponent(0.15))
    static let delBG = token(0xBE3A28, 0xEE7A6E, lightAlpha: 0.12, darkAlpha: 0.14, system: UIColor.systemRed.withAlphaComponent(0.15))
    static let addText = token(0x1E5A3A, 0xC2E9D2, system: .label)
    static let delText = token(0x7A2A20, 0xF3C4BE, system: .label)
    static let hunkText = token(0x1F6E9E, 0x8CCBEE, system: .secondaryLabel)
    static let navy = Color(uiColor: UIColor(hex: 0x0C1220))

    static func color(for state: PRDisplayState) -> Color {
        switch state {
        case .open: green
        case .draft: slate
        case .merged: violet
        case .closed: red
        }
    }

    static func dynamicUIColor(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        }
    }

    private static func token(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1, system: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            guard ThemeStore.isBrand else { return system.resolvedColor(with: traits) }
            return traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

struct BrandBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            MobileTheme.canvas
            if ThemeStore.isBrand {
                ZStack {
                    RadialGradient(colors: [MobileTheme.violet.opacity(0.14), .clear], center: UnitPoint(x: 0.15, y: 0), startRadius: 0, endRadius: 340)
                    RadialGradient(colors: [MobileTheme.sky.opacity(0.14), .clear], center: UnitPoint(x: 0.9, y: 0.05), startRadius: 0, endRadius: 320)
                    RadialGradient(colors: [MobileTheme.coral.opacity(0.06), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 280)
                }
                .frame(height: 420)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

enum PYRadius {
    static let small: CGFloat = 10
    static let card: CGFloat = 16
    static let large: CGFloat = 24
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    convenience init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        self.init(hex: value)
    }

    var relativeLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

private struct PullYardScaledFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scaledSize = 16.0
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

extension View {
    func mobileFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        let style: Font.TextStyle = size >= 24 ? .title : size >= 17 ? .headline : size >= 14 ? .body : size >= 12 ? .subheadline : .caption
        return modifier(PullYardScaledFont(size: size, weight: weight, design: design, relativeTo: style))
    }

    func pyCard(padding: CGFloat = 16, radius: CGFloat = PYRadius.card) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(MobileTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(ThemeStore.isBrand ? 0.05 : 0), radius: 10, y: 3)
    }

    func pyListStyle() -> some View {
        self.listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BrandBackdrop())
    }

    func pyRow() -> some View {
        listRowBackground(MobileTheme.card)
    }
}

struct RelativeTime: View {
    let date: Date
    var prefix: String? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(now: context.date))
                .monospacedDigit()
                .accessibilityLabel(Text(prefix.map { "\($0) " } ?? "") + Text(date, format: .dateTime.day().month().hour().minute()))
        }
    }

    private func label(now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let text: String
        if abs(seconds) < 45 { text = L("just now") }
        else if seconds < 3_600 { text = "\(Int(seconds / 60))\(L("m"))" }
        else if seconds < 86_400 { text = "\(Int(seconds / 3_600))\(L("h"))" }
        else if seconds < 7 * 86_400 { text = "\(Int(seconds / 86_400))\(L("d"))" }
        else { text = date.formatted(.dateTime.day().month(.abbreviated)) }
        guard let prefix else { return text }
        let suffix = abs(seconds) >= 45 && seconds < 7 * 86_400 ? L(" ago") : ""
        return "\(L(prefix)) \(text)\(suffix)"
    }
}

struct PRStatePill: View {
    let state: PRDisplayState

    var body: some View {
        let color = MobileTheme.color(for: state)
        Label(L(state.title), systemImage: state.symbol)
            .labelStyle(.titleAndIcon)
            .mobileFont(size: 11, weight: .semibold, design: .rounded)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
            .accessibilityLabel("State: \(state.title)")
    }
}

struct Chip: View {
    let title: String
    var count: Int? = nil
    var symbol: String? = nil
    var isSelected: Bool
    var tint: Color = MobileTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).mobileFont(size: 12, weight: .semibold) }
                Text(L(title)).mobileFont(size: 14, weight: .semibold)
                if let count {
                    Text("\(count)")
                        .mobileFont(size: 12, weight: .bold, design: .rounded)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.22) : tint.opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? Color.white : MobileTheme.ink)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .contentShape(Capsule())
            .pyGlassCapsule(tint: isSelected ? tint : nil, interactive: true, fallback: isSelected ? tint : MobileTheme.card)
            .overlay(Capsule().stroke(isSelected || GlassSupport.isAvailable ? Color.clear : MobileTheme.line, lineWidth: 1))
        }
        .buttonStyle(.pyPlain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

struct LabelChip: View {
    let label: PRLabel

    var body: some View {
        let base = label.color.flatMap(UIColor.init(hexString:)) ?? UIColor(hex: 0x6B7486)
        let dark = base.relativeLuminance < 0.35
        Text(label.name)
            .mobileFont(size: 11, weight: .semibold)
            .lineLimit(1)
            .foregroundStyle(Color(uiColor: dark ? base.blended(with: .white, 0.55) : base.blended(with: .black, 0.55)))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(uiColor: base).opacity(0.18), in: Capsule())
    }
}

extension UIColor {
    func blended(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(MobileTheme.amber.opacity(0.14)).frame(width: 74, height: 74)
                Image(systemName: "exclamationmark.triangle.fill").mobileFont(size: 28, weight: .semibold).foregroundStyle(MobileTheme.amber)
            }
            Text(L(title)).mobileFont(size: 19, weight: .semibold).foregroundStyle(MobileTheme.ink).multilineTextAlignment(.center)
            Text(L(message)).mobileFont(size: 15).foregroundStyle(MobileTheme.muted).multilineTextAlignment(.center)
            if let retry {
                Button(action: retry) { Text("Try again").mobileFont(size: 15, weight: .semibold).padding(.horizontal, 22).padding(.vertical, 11) }
                    .buttonStyle(.borderedProminent).tint(MobileTheme.accentFill)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
    }
}

struct PYEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            HarborMark().padding(.bottom, 4)
            Text(L(title)).mobileFont(size: 19, weight: .semibold).foregroundStyle(MobileTheme.ink).multilineTextAlignment(.center)
            Text(L(message)).mobileFont(size: 15).foregroundStyle(MobileTheme.muted).multilineTextAlignment(.center)
            actions.padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
    }
}

extension PYEmptyState where Actions == EmptyView {
    init(title: String, message: String) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

struct HarborMark: View {
    var body: some View {
        ZStack {
            Circle().fill(MobileTheme.accent.opacity(0.08)).frame(width: 112, height: 112)
            Circle().stroke(MobileTheme.line, lineWidth: 1).frame(width: 112, height: 112)
            PullYardLogoMark(progress: 1, size: 84).offset(y: 4)
        }
        .accessibilityHidden(true)
    }
}
