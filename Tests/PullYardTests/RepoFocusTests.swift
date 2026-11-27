import XCTest
@testable import PullYard

@MainActor
final class RepoFocusTests: XCTestCase {
    private let account = "focus-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        RepoFocus.shared.clear(account)
    }

    func testEmptyFocusIncludesEverything() {
        let focus = RepoFocus.shared
        XCTAssertFalse(focus.isActive(account))
        XCTAssertEqual(focus.query(account), "")
        XCTAssertTrue(focus.includes("any/repo", account: account))
        XCTAssertEqual(focus.summary(account), "All repositories")
    }

    func testToggleBuildsRepoQualifiersPerAccount() {
        let focus = RepoFocus.shared
        focus.toggle("octo/zeta", account: account)
        focus.toggle("octo/alpha", account: account)
        XCTAssertEqual(focus.query(account), "repo:octo/alpha repo:octo/zeta")
        XCTAssertTrue(focus.includes("OCTO/Alpha", account: account))
        XCTAssertFalse(focus.includes("octo/other", account: account))
        XCTAssertFalse(focus.isActive(account + "-other"))
        XCTAssertEqual(focus.summary(account), "2 repositories")
        focus.toggle("octo/ALPHA", account: account)
        XCTAssertEqual(focus.repos(account), ["octo/zeta"])
        XCTAssertEqual(focus.summary(account), "octo/zeta")
    }
}
