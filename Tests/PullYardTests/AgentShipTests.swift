import XCTest
@testable import PullYard

final class AgentShipTests: XCTestCase {
    func testFindsPullRequestURL() {
        let out = "Creating pull request for feature into main\n\nhttps://github.com/acme/app/pull/42\n"
        XCTAssertEqual(AgentShip.pullRequestURL(in: out), "https://github.com/acme/app/pull/42")
        XCTAssertNil(AgentShip.pullRequestURL(in: "https://github.com/acme/app/issues/3"))
    }

    func testPromptCreatesBranchOnDefault() {
        let p = AgentShip.openPRPrompt(branch: "main", defaultBranch: nil, hasChanges: true, ahead: 0)
        XCTAssertTrue(p.contains("new branch"))
        XCTAssertTrue(p.contains("gh pr create"))
        XCTAssertFalse(AgentShip.openPRPrompt(branch: "feat/x", defaultBranch: "main", hasChanges: true, ahead: 0).contains("new branch"))
    }

    func testAuthErrorDetection() {
        XCTAssertTrue(ChatSession.isAuthError("Invalid API key · Please run /login"))
        XCTAssertTrue(ChatSession.isAuthError("OAuth token has expired"))
        XCTAssertFalse(ChatSession.isAuthError("File not found"))
    }
}
