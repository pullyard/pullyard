import XCTest
@testable import PullYard

final class JiraBacklogTests: XCTestCase {
    private let base = URL(string: "https://acme.atlassian.net")!

    private func issue(_ key: String, assignee: String? = nil, summary: String = "Work", labels: [String] = []) -> JiraIssue {
        JiraIssue(key: key, summary: summary, status: "To Do", statusCategory: "new", type: "Bug", priority: "Medium",
                  assignee: assignee, assigneeAvatar: nil, reporter: nil, description: "", url: "", updated: nil, labels: labels)
    }

    private func sprint(_ id: Int, _ state: String) -> JiraBacklogSprint {
        JiraBacklogSprint(id: id, name: "Sprint \(id)", state: state)
    }

    func testParsesSprintWithDates() throws {
        let s = try XCTUnwrap(JiraBacklogSprint.parse([
            "id": 24, "name": "KRISP Sprint 24", "state": "active",
            "startDate": "2026-11-19T09:00:00.000Z", "endDate": "2026-11-30T18:00:00.000Z", "goal": "  ",
        ]))
        XCTAssertTrue(s.isActive)
        XCTAssertNotNil(s.startDate)
        XCTAssertNotNil(s.endDate)
        XCTAssertNil(s.goal)
        XCTAssertNotNil(s.dates)
        XCTAssertNil(JiraBacklogSprint.parse(["name": "no id"]))
    }

    func testBuildsSectionsActiveFirstThenBacklog() {
        let snap = JiraBacklogSnapshot.build(
            sprints: [sprint(2, "future"), sprint(1, "active")],
            issues: [1: [issue("K-1")], 2: [issue("K-2"), issue("K-1")]],
            backlog: [issue("K-3"), issue("K-2")]
        )
        XCTAssertEqual(snap.sections.map(\.sprintID), [1, 2, nil])
        // An issue shows once, in the first section that has it.
        XCTAssertEqual(snap.sections.map { $0.issues.map(\.key) }, [["K-1"], ["K-2"], ["K-3"]])
        XCTAssertEqual(snap.allIssues.count, 3)
    }

    func testMovingBetweenSprintAndBacklog() {
        let snap = JiraBacklogSnapshot.build(sprints: [sprint(1, "active")], issues: [1: [issue("K-1"), issue("K-2")]], backlog: [issue("K-3")])
        let toBacklog = snap.moving("K-1", toSprint: nil)
        XCTAssertEqual(toBacklog.sections[0].issues.map(\.key), ["K-2"])
        XCTAssertEqual(toBacklog.sections[1].issues.map(\.key), ["K-3", "K-1"])
        let back = toBacklog.moving("K-1", toSprint: 1)
        XCTAssertEqual(back.sections[0].issues.map(\.key), ["K-2", "K-1"])
        // Same section, unknown key or a sprint not shown: nothing changes.
        XCTAssertEqual(snap.moving("K-1", toSprint: 1), snap)
        XCTAssertEqual(snap.moving("K-9", toSprint: nil), snap)
        XCTAssertEqual(snap.moving("K-1", toSprint: 42), snap)
    }

    func testReplaceKeepsListOnlyFields() {
        var old = issue("K-1", labels: ["ios"])
        old.created = Date(timeIntervalSince1970: 100)
        old.connectionID = "c1"
        var list = JiraListSnapshot(issues: [old])
        list.replace(issue("K-1", assignee: "Sam", summary: "Renamed"))
        XCTAssertEqual(list.issues[0].summary, "Renamed")
        XCTAssertEqual(list.issues[0].assignee, "Sam")
        XCTAssertEqual(list.issues[0].labels, ["ios"])
        XCTAssertEqual(list.issues[0].created, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(list.issues[0].connectionID, "c1")
    }

    func testListPageTokenPaging() {
        let o: [String: Any] = [
            "issues": [["key": "K-1", "fields": ["summary": "One", "created": "2026-11-20T10:00:00.000+0000",
                                                  "reporter": ["displayName": "Sevak", "avatarUrls": ["48x48": "https://a/r.png"]]]]],
            "nextPageToken": "abc", "isLast": false,
        ]
        let page = JiraListPage.parse(o, base: base, startAt: nil)
        XCTAssertEqual(page.next, .token("abc"))
        XCTAssertEqual(page.issues.first?.reporter, "Sevak")
        XCTAssertEqual(page.issues.first?.reporterAvatar, "https://a/r.png")
        XCTAssertNotNil(page.issues.first?.created)
        XCTAssertNil(JiraListPage.parse(["issues": [], "nextPageToken": "x", "isLast": true], base: base, startAt: nil).next)
    }

    func testListPageOffsetPaging() {
        let issues: [[String: Any]] = (1...2).map { ["key": "K-\($0)", "fields": [:] as [String: Any]] }
        XCTAssertEqual(JiraListPage.parse(["issues": issues, "total": 5], base: base, startAt: 0).next, .start(2))
        XCTAssertNil(JiraListPage.parse(["issues": issues, "total": 4], base: base, startAt: 2).next)
    }

    func testListAppendSkipsDuplicates() {
        var snap = JiraListSnapshot()
        snap.append(JiraListPage(issues: [issue("K-1"), issue("K-2")], next: .start(2)))
        snap.append(JiraListPage(issues: [issue("K-2"), issue("K-3")], next: nil))
        XCTAssertEqual(snap.issues.map(\.key), ["K-1", "K-2", "K-3"])
        XCTAssertNil(snap.next)
    }

    func testFilterByAssigneeAndSearch() {
        let a = issue("KRIS-721", assignee: "Rafael", summary: "View integration button", labels: ["Meetings"])
        let b = issue("KRIS-5", summary: "Typography")
        XCTAssertTrue(JiraIssueFilter.matches(a, assignees: [], query: ""))
        XCTAssertTrue(JiraIssueFilter.matches(a, assignees: ["Rafael"], query: "integration"))
        XCTAssertTrue(JiraIssueFilter.matches(a, assignees: [], query: "meet"))
        XCTAssertTrue(JiraIssueFilter.matches(a, assignees: [], query: "kris-72"))
        XCTAssertFalse(JiraIssueFilter.matches(b, assignees: ["Rafael"], query: ""))
        XCTAssertTrue(JiraIssueFilter.matches(b, assignees: [JiraPeopleFilter.unassigned], query: " typo "))
    }

    func testSnapshotsRoundTripThroughJSON() throws {
        let snap = JiraBacklogSnapshot.build(sprints: [sprint(1, "active")], issues: [1: [issue("K-1")]], backlog: [])
        XCTAssertEqual(try JSONDecoder().decode(JiraBacklogSnapshot.self, from: JSONEncoder().encode(snap)), snap)
        let list = JiraListSnapshot(issues: [issue("K-1")], next: .token("t"), fetchedAt: nil)
        XCTAssertEqual(try JSONDecoder().decode(JiraListSnapshot.self, from: JSONEncoder().encode(list)), list)
    }
}
