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

    func testGroupOrderMovesAndPersists() {
        let layout = SidebarLayout(defaults: defaults)
        let keys = ["prs", "issues", "code", "jira"]
        XCTAssertEqual(layout.arrangedGroups(keys), keys)
        XCTAssertFalse(layout.canMoveGroup("prs", by: -1, in: keys))
        layout.moveGroup("jira", by: -1, in: keys)
        layout.moveGroup("jira", by: -1, in: layout.arrangedGroups(keys))
        XCTAssertEqual(layout.arrangedGroups(keys), ["prs", "jira", "issues", "code"])
        XCTAssertEqual(SidebarLayout(defaults: defaults).arrangedGroups(keys), ["prs", "jira", "issues", "code"])
        // A provider without Issues keeps the rest of the order.
        XCTAssertEqual(layout.arrangedGroups(["prs", "code", "jira"]), ["prs", "jira", "code"])
    }

    func testJiraSectionStorageKeyRoundTrips() {
        XCTAssertEqual(SidebarSection(storageKey: SidebarSection.jira.storageKey), .jira)
        XCTAssertTrue(SidebarSection.jira.isFullWidth)
    }

    func testJiraIssueParsesStatusIDAndLabels() {
        let raw: [String: Any] = [
            "key": "KRIS-740",
            "fields": [
                "summary": "Rapid redials",
                "status": ["id": "10003", "name": "Code review", "statusCategory": ["key": "indeterminate"]],
                "labels": ["android", "ios"],
            ],
        ]
        let issue = JiraClient.parseIssue(raw, base: URL(string: "https://acme.atlassian.net")!)
        XCTAssertEqual(issue.statusID, "10003")
        XCTAssertEqual(issue.labels, ["android", "ios"])
        XCTAssertEqual(JiraClient.encode("statusCategory != Done"), "statusCategory%20%21%3D%20Done")
    }

    func testDropRowAndSection() {
        let layout = SidebarLayout(defaults: defaults)
        let list = items()
        XCTAssertTrue(layout.drop(item: "repos", onto: "stacks", group: "code", visible: list))
        XCTAssertEqual(layout.arranged(list, group: "code").map(\.id), ["projects", "stacks", "repos"])
        XCTAssertTrue(layout.drop(item: "repos", onto: "projects", group: "code", visible: layout.arranged(list, group: "code")))
        XCTAssertEqual(layout.arranged(list, group: "code").map(\.id), ["repos", "projects", "stacks"])
        XCTAssertFalse(layout.drop(item: "repos", onto: "repos", group: "code", visible: list))

        let keys = ["prs", "issues", "code", "jira"]
        XCTAssertTrue(layout.drop(group: "jira", onto: "prs", visible: keys))
        XCTAssertEqual(layout.arrangedGroups(keys), ["jira", "prs", "issues", "code"])
    }

    func testDragPayloadRoundTrips() {
        XCTAssertEqual(SidebarDrag(payload: SidebarDrag.row(group: "prs", id: "prs/mine").payload), .row(group: "prs", id: "prs/mine"))
        XCTAssertEqual(SidebarDrag(payload: SidebarDrag.section("jira").payload), .section("jira"))
        XCTAssertNil(SidebarDrag(payload: "KRIS-740"))
    }

    func testJiraBoardSnapshotCodable() throws {
        var snap = JiraBoardSnapshot()
        snap.board = JiraBoard(id: 7, name: "KRISP board", type: "scrum", projectKey: "KRIS")
        snap.columns = [JiraBoardColumn(name: "To Do", statusIDs: ["1"])]
        snap.issues = [JiraIssue(key: "KRIS-1", summary: "s", status: "To Do", statusCategory: "new", type: "Bug", priority: nil, assignee: nil, assigneeAvatar: nil, reporter: nil, description: "", url: "https://x/browse/KRIS-1", updated: nil, statusID: "1", labels: ["ios"])]
        snap.fetchedAt = Date(timeIntervalSince1970: 100)
        let back = try JSONDecoder().decode(JiraBoardSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
    }

    func testImplementPromptCarriesTicket() {
        let issue = JiraIssue(key: "COM-2224", summary: "Add CarPlay", status: "To Do", statusCategory: "new", type: "Task", priority: "Medium", assignee: nil, assigneeAvatar: nil, reporter: nil, description: "Goal: CarPlay", url: "https://x/browse/COM-2224", updated: nil)
        let prompt = JiraImplementForm.defaultPrompt(issue)
        XCTAssertTrue(prompt.hasPrefix("Implement Jira ticket COM-2224: Add CarPlay"))
        XCTAssertTrue(prompt.contains("https://x/browse/COM-2224"))
        XCTAssertTrue(prompt.contains("Description:\nGoal: CarPlay"))
    }
}
