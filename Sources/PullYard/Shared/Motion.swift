import AppKit
import SwiftUI

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var quick: Animation? { reduced ? nil : .snappy(duration: 0.22) }
    static var smooth: Animation? { reduced ? nil : .smooth(duration: 0.3) }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82) }
    static var fade: Animation? { reduced ? nil : .easeOut(duration: 0.2) }
    static var swap: Animation? { reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22) }
    static var insert: Animation { reduced ? .easeOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.45) }

    static func rowIn(_ index: Int) -> Animation { rowIn(delay: Double(index) * 0.03) }

    static func rowIn(delay: Double) -> Animation {
        reduced ? .easeOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.45).delay(delay)
    }

    static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    enum Dur {
        static let micro = 0.12
        static let fast = 0.18
        static let base = 0.24
        static let slow = 0.36
        static let story = 0.7
    }

    static var snappy: Animation? { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86) }
    static var bouncy: Animation? { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.72) }
    static var gentle: Animation? { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.9) }
    static var brand: Animation { reduced ? .easeOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: Dur.base) }
}

extension AnyTransition {
    static var rise: AnyTransition {
        Motion.reduced ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    static var slideIn: AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity)
    }

    static var reveal: AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity.combined(with: .offset(y: -4)))
    }

    private static var swapIn: Animation { .easeOut(duration: 0.16) }

    static var routeSwap: AnyTransition {
        Motion.reduced ? .identity : .asymmetric(insertion: .opacity.animation(swapIn), removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    static var pop: AnyTransition {
        Motion.reduced ? .opacity : .opacity.combined(with: .offset(y: 4))
    }
}

struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 8
    var color: Color = .syText
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(color.opacity(hovering ? 0.06 : 0)))
            .onHover { h in withAnimation(Motion.fade) { hovering = h } }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.96 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct AppearFade: ViewModifier {
    var delay: Double = 0
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.smooth?.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 8, color: Color = .syText) -> some View { modifier(HoverHighlight(radius: radius, color: color)) }
    func appearFade(delay: Double = 0) -> some View { modifier(AppearFade(delay: delay)) }
}
