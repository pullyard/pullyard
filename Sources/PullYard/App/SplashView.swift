import SwiftUI

struct SplashView: View {
    @State private var appeared = false
    @State private var breathing = false

    var body: some View {
        ZStack {
            Color(nsColor: Theme.isBrand ? .syWindow : .windowBackgroundColor)
            VStack(spacing: 20) {
                SplashLogo()
                    .scaleEffect(appeared ? (breathing ? 1.025 : 1) : 0.92)
                VStack(spacing: 6) {
                    Text("PullYard")
                        .font(.sy(size: 32, weight: .bold))
                        .foregroundStyle(Color.syText)
                    Text("Pull requests, without the browser")
                        .foregroundStyle(Color.syMuted)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || Motion.reduced ? 0 : 10)
            }
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(Motion.reduced ? nil : .spring(response: 0.6, dampingFraction: 0.72)) { appeared = true }
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(SplashLogo.duration)) { breathing = true }
        }
    }
}

struct SplashLogo: View {
    static let duration: Double = 1.4
    static var hold: Double { Motion.reduced ? 0.75 : duration + 0.35 }
    @State private var start = Date()

    var body: some View {
        if Motion.reduced {
            PullYardLogoMark(progress: 1, size: 200)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start) / Self.duration
                PullYardLogoMark(progress: min(1, t), size: 200)
            }
        }
    }
}
