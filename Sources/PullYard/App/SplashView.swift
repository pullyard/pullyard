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

    var body: some View {
        LogoDrawOn(size: 200, duration: Self.duration)
    }
}
