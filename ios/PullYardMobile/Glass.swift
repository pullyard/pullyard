import SwiftUI

extension View {
    @ViewBuilder
    func pyGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else if let fallback {
            self.background(fallback, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    func pyGlassCapsule(tint: Color? = nil, interactive: Bool = false, fallback: Color? = nil) -> some View {
        pyGlass(in: Capsule(), tint: tint, interactive: interactive, fallback: fallback)
    }

    @ViewBuilder
    func pyGlassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint ?? MobileTheme.accentFill)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent).tint(tint ?? MobileTheme.accentFill)
        } else {
            self.buttonStyle(.bordered).tint(tint)
        }
    }

    @ViewBuilder
    func pyTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var value = Glass.regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }
}

struct PYGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum GlassSupport {
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

struct PYPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PYPressStyle {
    static var pyPlain: PYPressStyle { PYPressStyle() }
}

extension View {
    func pyHitArea(minSize: CGFloat = 44) -> some View {
        frame(minWidth: minSize, minHeight: minSize).contentShape(Rectangle())
    }
}

extension View {
    func pySheetStyle() -> some View {
        self
            .presentationBackground(MobileTheme.canvas)
            .presentationCornerRadius(28)
            .presentationDragIndicator(.visible)
    }
}

struct HStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .fixedSize(horizontal: false, vertical: true)
    }
}
