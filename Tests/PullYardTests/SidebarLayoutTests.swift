import SwiftUI
import XCTest
@testable import PullYard

@MainActor
final class SidebarLayoutTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "SidebarLayoutTests-\(UUID().uuidString)")
    }

    private func items() -> [SidebarItem] {
        [
            SidebarItem(section: .repos, title: "Repositories", icon: "a", color: .red),
            SidebarItem(section: .projects, title: "Projects", icon: "b", color: .red),
            SidebarItem(section: .stacks, title: "Stacks", icon: "c", color: .red),
        ]
    }

    func testDefaultOrderWithoutSavedLayout() {
        let layout = SidebarLayout(defaults: defaults)
        XCTAssertEqual(layout.arranged(items(), group: "code").map(\.id), ["repos", "projects", "stacks"])
    }

    func testMovePersistsAndReloads() {
        let layout = SidebarLayout(defaults: defaults)
        layout.move(in: "code", visible: items(), from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(layout.arranged(items(), group: "code").map(\.id), ["stacks", "repos", "projects"])
        let reloaded = SidebarLayout(defaults: defaults)
        XCTAssertEqual(reloaded.arranged(items(), group: "code").map(\.id), ["stacks", "repos", "projects"])
    }

    func testMoveByOneAndBounds() {
        let layout = SidebarLayout(defaults: defaults)
        let list = items()
        XCTAssertFalse(layout.canMove(list[0], by: -1, in: list))
        layout.move(list[0], by: 1, in: "code", visible: list)
        XCTAssertEqual(layout.arranged(list, group: "code").map(\.id), ["projects", "repos", "stacks"])
    }

    func testNewItemsKeepDefaultPositionAfterSavedOnes() {
        let layout = SidebarLayout(defaults: defaults)
        let two = Array(items().prefix(2))
        layout.move(in: "code", visible: two, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(layout.arranged(items(), group: "code").map(\.id), ["projects", "repos", "stacks"])
    }

    func testRenameAndRestore() {
        let layout = SidebarLayout(defaults: defaults)
        layout.rename(.repos, to: "  Code  ", default: "Repositories")
        XCTAssertEqual(layout.title(for: .repos, default: "Repositories"), "Code")
        XCTAssertEqual(SidebarLayout(defaults: defaults).title(for: .repos, default: "Repositories"), "Code")
        layout.rename(.repos, to: "", default: "Repositories")
        XCTAssertFalse(layout.hasCustomName(.repos))
        layout.rename(.repos, to: "X", default: "Repositories")
        layout.resetAll()
        XCTAssertFalse(layout.isCustomised)
    }
}
