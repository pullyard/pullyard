import XCTest
@testable import PullYard

final class JiraFollowUpTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: JiraFollowUp.dismissedKey)
    }

    private func issue(_ key: String, _ status: String, _ category: String) -> JiraIssue {
        JiraIssue(key: key, summary: "s", status: status, statusCategory: category, type: nil, priority: nil, assignee: nil, assigneeAvatar: nil,
                  reporter: nil, description: "", url: "https://x.atlassian.net/browse/\(key)", updated: nil)
    }

    func testOpenIssuesAndDoneTransition() {
        let issues = [issue("A-1", "In Review", "indeterminate"), issue("A-2", "Done", "done"), issue("A-3", "To Do", "new")]
        XCTAssertEqual(JiraFollowUp.open(issues).map(\.key), ["A-1", "A-3"])
        let transitions = [
            JiraTransition(id: "1", name: "Back to progress", to: "In Progress", toCategory: "indeterminate"),
            JiraTransition(id: "2", name: "Ship it", to: "Released", toCategory: "done"),
            JiraTransition(id: "3", name: "Finish", to: "Done", toCategory: "done")
        ]
        XCTAssertEqual(JiraFollowUp.doneTransition(transitions)?.id, "3")
        XCTAssertEqual(JiraFollowUp.doneTransition(Array(transitions.prefix(2)))?.id, "2")
        XCTAssertNil(JiraFollowUp.doneTransition([transitions[0]]))
    }

    func testDismissIsRememberedPerPR() {
        XCTAssertFalse(JiraFollowUp.isDismissed("https://github.com/o/r/pull/1"))
        JiraFollowUp.dismiss("https://github.com/o/r/pull/1")
        JiraFollowUp.dismiss("https://github.com/o/r/pull/1")
        XCTAssertTrue(JiraFollowUp.isDismissed("https://github.com/o/r/pull/1"))
        XCTAssertFalse(JiraFollowUp.isDismissed("https://github.com/o/r/pull/2"))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: JiraFollowUp.dismissedKey)?.count, 1)
    }

    func testShipPromptMentionsJiraKey() {
        XCTAssertEqual(JiraFollowUp.shipStep(branch: "fix/soc-1235-public-search"), "The branch refers to Jira issue SOC-1235. Start the title with SOC-1235 and mention SOC-1235 in the description.")
        XCTAssertNil(JiraFollowUp.shipStep(branch: "feature/login"))
        let prompt = AgentShip.openPRPrompt(branch: "fix/SOC-1235-search", defaultBranch: "main", hasChanges: true, ahead: 0)
        XCTAssertTrue(prompt.contains("Start the title with SOC-1235"))
        XCTAssertFalse(AgentShip.openPRPrompt(branch: "main", defaultBranch: "main", hasChanges: true, ahead: 0).contains("Jira"))
    }
}
