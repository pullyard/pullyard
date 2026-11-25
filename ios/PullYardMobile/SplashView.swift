import SwiftUI

struct SplashView: View {
    let done: () -> Void

    var body: some View {
        ZStack {
            Color(hex: 0x0C1220)
            PullYardLogoMark(progress: 1, size: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            done()
        }
    }
}
