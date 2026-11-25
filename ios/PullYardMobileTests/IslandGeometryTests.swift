import XCTest
@testable import PullYardMobile

final class IslandGeometryTests: XCTestCase {
    func testToastStartsAtTheIslandAndLandsBelowIt() {
        let geometry = IslandGeometry(width: 402, topInset: 62)
        XCTAssertTrue(geometry.hasIsland)
        XCTAssertEqual(geometry.collapsed, geometry.island)
        XCTAssertEqual(geometry.island.midX, geometry.toast.midX)
        XCTAssertGreaterThan(geometry.toast.minY, geometry.island.maxY)
    }

    func testPhonesWithoutAnIslandSlideFromAboveTheScreen() {
        let geometry = IslandGeometry(width: 390, topInset: 47)
        XCTAssertFalse(geometry.hasIsland)
        XCTAssertLessThan(geometry.collapsed.maxY, 0)
    }
}
