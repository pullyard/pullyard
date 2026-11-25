import SwiftUI

struct SplashView: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false
    @State private var wordmark = false
    @State private var lift = false
    @State private var leave = false

    var body: some View {
        ZStack {
            Color(hex: 0x0C1220)
            ZStack {
                Circle().fill(Color(hex: 0x6B55D6).opacity(0.55)).frame(width: 240).blur(radius: 60).offset(x: -60, y: -20)
                Circle().fill(Color(hex: 0x38BDF8).opacity(0.45)).frame(width: 220).blur(radius: 60).offset(x: 70, y: 10)
            }
            .scaleEffect(glow ? 1.15 : 0.6)
            .opacity(glow ? 1 : 0)
            VStack(spacing: 18) {
                PullYardLogoMark(progress: 1, size: 200)
                    .offset(y: lift ? -6 : 0)
                    .scaleEffect(leave ? 1.25 : 1)
                Text("PullYard")
                    .mobileFont(size: 30, weight: .semibold, design: .serif)
                    .tracking(wordmark ? 1.5 : 8)
                    .foregroundStyle(.white)
                    .opacity(wordmark ? 1 : 0)
                    .blur(radius: wordmark ? 0 : 8)
                    .frame(height: 40)
            }
            .offset(y: 29)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .opacity(leave ? 0 : 1)
        .accessibilityHidden(true)
        .task {
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(350))
                done()
                return
            }
            withAnimation(.easeOut(duration: 0.9)) { glow = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { lift = true }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { wordmark = true }
            try? await Task.sleep(for: .milliseconds(950))
            withAnimation(.easeIn(duration: 0.45)) { leave = true }
            try? await Task.sleep(for: .milliseconds(420))
            done()
        }
    }
}
