import XCTest
@testable import PullYard

final class GitWatchTests: XCTestCase {
    func testRelevantPaths() {
        XCTAssertTrue(GitWorkingCopy.isRelevant("/r/Sources/App.swift"))
        XCTAssertTrue(GitWorkingCopy.isRelevant("/r/.git/HEAD"))
        XCTAssertTrue(GitWorkingCopy.isRelevant("/r/.git/index"))
        XCTAssertTrue(GitWorkingCopy.isRelevant("/r/.git/refs/heads/main"))
        XCTAssertFalse(GitWorkingCopy.isRelevant("/r/.git/objects/ab/cd"))
        XCTAssertFalse(GitWorkingCopy.isRelevant("/r/.build/debug/App.o"))
        XCTAssertFalse(GitWorkingCopy.isRelevant("/r/node_modules/x/index.js"))
    }
}
