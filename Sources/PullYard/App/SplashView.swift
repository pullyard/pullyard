import SwiftUI

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(nsColor: Theme.isBrand ? .syWindow : .windowBackgroundColor)
            VStack(spacing: 20) {
                SplashLogo()
                    .scaleEffect(appeared ? 1 : 0.92)
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
        }
    }
}

struct SplashLogo: View {
    static let duration: Double = 0.9
    static var hold: Double { Motion.reduced ? 0.6 : duration + 0.15 }
    @State private var start = Date()
    @State private var done = false

    var body: some View {
        if Motion.reduced || done {
            PullYardLogoMark(progress: 1, size: 200)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                let t = context.date.timeIntervalSince(start) / Self.duration
                PullYardLogoMark(progress: min(1, t), size: 200)
            }
            .task {
                try? await Task.sleep(for: .seconds(Self.duration))
                done = true
            }
        }
    }
}
