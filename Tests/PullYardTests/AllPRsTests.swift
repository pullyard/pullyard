import XCTest
@testable import PullYard

final class AllPRsTests: XCTestCase {
    func testParseRepo() {
        XCTAssertEqual(AllPRsView.parseRepo("guestpass-llc/client_app")?.full, "guestpass-llc/client_app")
        XCTAssertEqual(AllPRsView.parseRepo("https://github.com/guestpass-llc/client_app/pulls")?.full, "guestpass-llc/client_app")
        XCTAssertEqual(AllPRsView.parseRepo("git@github.com:x/y.git")?.full, "x/y")
        XCTAssertEqual(AllPRsView.parseRepo("github.com/x/y.git")?.full, "x/y")
        XCTAssertNil(AllPRsView.parseRepo("client_app"))
    }
}
