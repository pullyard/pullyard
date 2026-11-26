import XCTest
@testable import PullYardMobile

final class JiraKeyFinderTests: XCTestCase {
    func testFindsKeysInTitleBranchAndBody() {
        let keys = JiraKeyFinder.keys(title: "feat(become_host): banner (COM-2349)", branch: "com-2349-become-host-banner", body: "Relates to PAY-12, not UTF-8 or SHA-256")
        XCTAssertEqual(keys, ["COM-2349", "PAY-12"])
    }

    func testProjectOfKey() {
        XCTAssertEqual(JiraKeyFinder.project("COM-2349"), "COM")
    }

    func testNormalizesSites() {
        XCTAssertEqual(JiraStore.normalize("acme.atlassian.net/browse/COM-1")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraStore.normalize("https://jira.example.com/jira/browse/X-1")?.absoluteString, "https://jira.example.com/jira")
        XCTAssertNil(JiraStore.normalize("http://insecure.example.com"))
    }
}
