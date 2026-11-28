import SwiftUI
import XCTest
@testable import PullYard

final class AppCommandTests: XCTestCase {
    func testShortcutsAreUnique() {
        var seen: [String: AppCommand] = [:]
        for command in AppCommand.allCases {
            guard let s = command.shortcut else { continue }
            let glyph = AppCommand.glyph(s)
            XCTAssertNil(seen[glyph], "\(glyph) is used by \(seen[glyph]?.rawValue ?? "") and \(command.rawValue)")
            seen[glyph] = command
        }
    }

    func testGlyphs() {
        XCTAssertEqual(AppCommand.approve.glyph, "⇧⌘A")
        XCTAssertEqual(AppCommand.nextInQueue.glyph, "⌥⌘↓")
        XCTAssertEqual(AppCommand.zoomOut.glyph, "⌘−")
        XCTAssertEqual(AppCommand.toggleSidebar.glyph, "⌃⌘S")
        XCTAssertEqual(AppCommand.sendComment.glyph, "⌘↩")
    }

    func testEveryGroupIsListed() {
        for group in CommandGroupKind.allCases {
            XCTAssertFalse(AppCommand.listed(in: group).isEmpty, group.rawValue)
        }
    }
}
