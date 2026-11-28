import SwiftUI

private struct PYGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: Color?
    let outline: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(fallback ?? .syRaised, in: shape)
                .overlay(shape.stroke(Color.syLineStrong))
        } else {
            styled(content)
        }
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            plain(content)
        }
        #else
        plain(content)
        #endif
    }

    @ViewBuilder
    private func plain(_ content: Content) -> some View {
        if let fallback {
            content
                .background(fallback, in: shape)
                .overlay { if outline { shape.stroke(Color.syLineStrong) } }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { if outline { shape.stroke(Color.syLineStrong) } }
        }
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var glass: Glass {
        var value = Glass.regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }
    #endif
}

extension View {
    func pyGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Color? = nil, outline: Bool = true) -> some View {
        modifier(PYGlassModifier(shape: shape, tint: tint, interactive: interactive, fallback: fallback, outline: outline))
    }

    func pyGlassCapsule(tint: Color? = nil, interactive: Bool = false, fallback: Color? = nil, outline: Bool = true) -> some View {
        pyGlass(in: Capsule(), tint: tint, interactive: interactive, fallback: fallback, outline: outline)
    }

    @ViewBuilder
    func pyGlassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint ?? .syAccentFill)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            borderedButton(prominent: prominent, tint: tint)
        }
        #else
        borderedButton(prominent: prominent, tint: tint)
        #endif
    }

    @ViewBuilder
    private func borderedButton(prominent: Bool, tint: Color?) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent).tint(tint ?? .syAccentFill)
        } else {
            self.buttonStyle(.bordered).tint(tint)
        }
    }
}

struct PYGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

enum GlassSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}
