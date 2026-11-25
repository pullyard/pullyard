import SwiftUI
import XCTest
@testable import PullYardMobile

final class VoyageTests: XCTestCase {
    private func state(passed: Int = 0, failed: Int = 0, running: Int = 0, merged: Bool? = nil) -> CIActivityAttributes.ContentState {
        CIActivityAttributes.ContentState(passed: passed, failed: failed, running: running, skipped: 0, updated: .now, merged: merged)
    }

    func testVoyageStates() {
        XCTAssertEqual(state(passed: 2, running: 3).voyage, "Sailing · 2 of 5 checks")
        XCTAssertEqual(state(passed: 4, failed: 1).voyage, "Storm · 1 check failing")
        XCTAssertEqual(state(passed: 5).voyage, "Ready to dock · all checks passed")
        XCTAssertEqual(state(passed: 5, merged: true).voyage, "Docked · merged")
        XCTAssertEqual(state(passed: 5, merged: true).progress, 1)
        XCTAssertLessThan(state(passed: 5).progress, 1)
    }

    @MainActor
    func testRenderShipGlyph() throws {
        let renderer = ImageRenderer(content: HStack(spacing: 20) {
            ShipGlyph(size: 120)
            ShipGlyph(size: 24)
            PullYardLogoMark(progress: 1, size: 120, flatten: false)
        }.padding(20).background(Color(red: 0.05, green: 0.07, blue: 0.13)))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ship-glyph.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("SHIP_RENDER \(url.path)")
    }
}
