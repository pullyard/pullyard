import XCTest
@testable import PullYard

final class StackViewportTests: XCTestCase {
    private let content = CGSize(width: 6000, height: 2000)
    private let viewport = CGSize(width: 1000, height: 700)

    func testZoomKeepsPointUnderCursor() {
        let start = StackViewport(zoom: 1, pan: CGPoint(x: -2000, y: -500))
        let anchor = CGPoint(x: 300, y: 200)
        let before = CGPoint(x: (anchor.x - start.pan.x) / start.zoom, y: (anchor.y - start.pan.y) / start.zoom)
        let next = start.zoomed(to: 1.4, at: anchor, content: content, viewport: viewport)
        let after = CGPoint(x: (anchor.x - next.pan.x) / next.zoom, y: (anchor.y - next.pan.y) / next.zoom)
        XCTAssertEqual(before.x, after.x, accuracy: 0.001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.001)
    }

    func testZoomIsClampedToRange() {
        let v = StackViewport().zoomed(to: 50, at: .zero, content: content, viewport: viewport)
        XCTAssertEqual(v.zoom, StackViewport.range.upperBound)
        XCTAssertEqual(StackViewport().zoomed(to: 0.001, at: .zero, content: content, viewport: viewport).zoom, StackViewport.range.lowerBound)
    }

    func testSmallContentIsCentered() {
        let v = StackViewport(zoom: 1, pan: CGPoint(x: 400, y: -300)).clamped(content: CGSize(width: 500, height: 300), viewport: viewport)
        XCTAssertEqual(v.pan.x, 250)
        XCTAssertEqual(v.pan.y, 200)
    }

    func testPanStopsAtMargin() {
        let far = StackViewport().panned(by: CGSize(width: 10_000, height: -10_000), content: content, viewport: viewport)
        XCTAssertEqual(far.pan.x, StackViewport.margin)
        XCTAssertEqual(far.pan.y, viewport.height - content.height - StackViewport.margin)
    }

    func testCenteredPutsPointInMiddle() {
        let v = StackViewport.centered(on: CGPoint(x: 3000, y: 1000), zoom: 1, content: content, viewport: viewport)
        XCTAssertEqual(v.pan.x + 3000, viewport.width / 2)
        XCTAssertEqual(v.pan.y + 1000, viewport.height / 2)
    }

    func testFitShowsEverything() {
        let v = StackViewport.fit(content: CGSize(width: 3000, height: 800), viewport: viewport)
        XCTAssertLessThanOrEqual(3000 * v.zoom, viewport.width)
        XCTAssertLessThanOrEqual(800 * v.zoom, viewport.height)
        XCTAssertEqual(v.pan.x, (viewport.width - 3000 * v.zoom) / 2, accuracy: 0.001)
    }
}
