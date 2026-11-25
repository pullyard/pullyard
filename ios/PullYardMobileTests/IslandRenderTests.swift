import SwiftUI
import XCTest
@testable import PullYardMobile

final class IslandRenderTests: XCTestCase {
    func testIslandDetectionUsesTheTopInset() {
        XCTAssertTrue(IslandGeometry(width: 402, topInset: 62).hasIsland)
        XCTAssertFalse(IslandGeometry(width: 390, topInset: 47).hasIsland)
        let geometry = IslandGeometry(width: 402, topInset: 62)
        XCTAssertEqual(geometry.card.minY, geometry.island.minY)
        XCTAssertEqual(geometry.island.midX, 201)
    }

    @MainActor
    func testRenderExpandedIsland() throws {
        let geometry = IslandGeometry(width: 402, topInset: 62)
        let view = ZStack(alignment: .topLeading) {
            Color(red: 0.93, green: 0.92, blue: 0.88)
            RoundedRectangle(cornerRadius: geometry.expandedRadius, style: .continuous).fill(.black)
                .frame(width: geometry.card.width, height: geometry.card.height)
                .offset(x: geometry.card.minX, y: geometry.card.minY)
            Capsule().stroke(.red.opacity(0.6), lineWidth: 1)
                .frame(width: geometry.island.width, height: geometry.island.height)
                .offset(x: geometry.island.minX, y: geometry.island.minY)
            HStack { ShipGlyph(size: 26); Spacer(); Circle().fill(.green.opacity(0.3)).frame(width: 28, height: 28) }
                .padding(.horizontal, 20)
                .frame(width: geometry.card.width, height: geometry.island.height)
                .offset(x: geometry.card.minX, y: geometry.card.minY)
            Text("Link copied").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .offset(x: geometry.card.minX + 20, y: geometry.island.maxY + 18)
        }
        .frame(width: 402, height: 150)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("island-card.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("ISLAND_RENDER \(url.path)")
    }
}
