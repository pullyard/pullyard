import SwiftUI

struct ShimmerBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = 6
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color.syLine)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.syLineStrong, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
            }
            .frame(width: width, height: height)
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityHidden(true)
    }
}
