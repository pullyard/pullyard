import CryptoKit
import XCTest
@testable import PullYard

final class UpdateSignatureTests: XCTestCase {
    func testValidSignaturePasses() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("PullYard.dmg".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()
        XCTAssertTrue(UpdateSignature.isValid(signature: signature, payload: payload, publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testTamperedPayloadFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data("original".utf8)).base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, payload: Data("tampered".utf8), publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testOtherKeyFails() throws {
        let payload = Data("PullYard.dmg".utf8)
        let signature = try Curve25519.Signing.PrivateKey().signature(for: payload).base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, payload: payload, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
    }

    func testGarbageFails() {
        XCTAssertFalse(UpdateSignature.isValid(signature: "not base64", payload: Data(), publicKey: "also not"))
    }
}
