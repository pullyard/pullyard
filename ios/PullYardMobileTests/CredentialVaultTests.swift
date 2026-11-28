import XCTest
@testable import PullYardMobile

final class CredentialVaultTests: XCTestCase {
    func testResolvesPrefixedGroup() {
        XCTAssertEqual(CredentialVault.resolveGroup("T5S7X9CM2J.com.pullyard.mobile"), "T5S7X9CM2J.com.pullyard.mobile")
    }

    func testRejectsUnprefixedOrUnexpandedGroup() {
        XCTAssertNil(CredentialVault.resolveGroup("group.com.pullyard.mobile"))
        XCTAssertNil(CredentialVault.resolveGroup("com.pullyard.mobile"))
        XCTAssertNil(CredentialVault.resolveGroup("$(AppIdentifierPrefix)com.pullyard.mobile"))
        XCTAssertNil(CredentialVault.resolveGroup(""))
        XCTAssertNil(CredentialVault.resolveGroup(nil))
    }
}
