import SwiftUI
import XCTest
@testable import PullYardMobile

final class IslandRenderTests: XCTestCase {
    @MainActor
    func testRenderDropletFrames() throws {
        let size = CGSize(width: 402, height: 150)
        let geometry = IslandGeometry(size: size, topInset: 62)
        let start = Date(timeIntervalSince1970: 0)
        let frames = [0.2, 0.4, 0.55, 0.65, 0.8, 1.0].map { progress in
            IslandHost.frame(phase: .showing, start: start, now: start.addingTimeInterval(progress * IslandPresenter.showDuration), geometry: geometry, reduceMotion: false)
        }
        let view = VStack(spacing: 4) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                ZStack(alignment: .topLeading) {
                    Color(red: 0.93, green: 0.92, blue: 0.88)
                    Canvas { canvas, _ in
                        canvas.addFilter(.alphaThreshold(min: 0.5, color: .black))
                        canvas.addFilter(.blur(radius: 7))
                        canvas.drawLayer { layer in
                            layer.fill(Path(roundedRect: geometry.island.insetBy(dx: 3, dy: 2), cornerRadius: geometry.island.height / 2), with: .color(.black))
                            layer.fill(Path(roundedRect: frame.blob, cornerRadius: min(frame.blob.height, frame.blob.width) / 2), with: .color(.black))
                        }
                    }
                    RoundedRectangle(cornerRadius: frame.blob.height / 2, style: .continuous).fill(.black)
                        .frame(width: frame.blob.width, height: frame.blob.height)
                        .offset(x: frame.blob.minX, y: frame.blob.minY)
                        .opacity(frame.solid)
                    Text("Merged pullyard#42").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .offset(x: geometry.pill.minX + 58, y: geometry.pill.minY + 20)
                        .opacity(frame.content)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("island-frames.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("ISLAND_RENDER \(url.path)")
    }
}
