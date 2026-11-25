import CryptoKit
import Network
import XCTest
@testable import PullYard

final class PYLinkTests: XCTestCase {
    func testPairingURLRoundTrip() {
        let pairing = PYLinkPairing(name: "Studio Mac", id: "abc", key: "key==", code: "123456", hosts: ["192.168.1.5", "100.64.0.2"], port: 47811)
        XCTAssertEqual(PYLinkPairing.parse(pairing.url), pairing)
        XCTAssertNil(PYLinkPairing.parse("pullyard://pull/a/b/1"))
    }

    func testBothSidesDeriveTheSameKey() throws {
        let desktop = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let a = try PYLinkCrypto.sessionKey(privateKey: desktop, peer: phone.publicKey, clientNonce: "c", serverNonce: "s")
        let b = try PYLinkCrypto.sessionKey(privateKey: phone, peer: desktop.publicKey, clientNonce: "c", serverNonce: "s")
        let sealed = try PYLinkCrypto.seal(Data("hello".utf8), key: a, direction: "c2s")
        XCTAssertEqual(try PYLinkCrypto.open(sealed, key: b, direction: "c2s"), Data("hello".utf8))
        XCTAssertThrowsError(try PYLinkCrypto.open(sealed, key: b, direction: "s2c"))
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let c = try PYLinkCrypto.sessionKey(privateKey: stranger, peer: desktop.publicKey, clientNonce: "c", serverNonce: "s")
        XCTAssertThrowsError(try PYLinkCrypto.open(sealed, key: c, direction: "c2s"))
    }

    func testEncryptedFramesOverLocalhost() throws {
        let key = SymmetricKey(size: .bits256)
        let queue = DispatchQueue(label: "test.link")
        let listener = try NWListener(using: .tcp, on: .any)
        let received = expectation(description: "server got frames")
        var serverChannel: PYLinkChannel?
        var frames: [String] = []
        listener.newConnectionHandler = { connection in
            let channel = PYLinkChannel(connection: connection, isServer: true, queue: queue)
            channel.encrypt(with: key)
            channel.onFrame = { data in
                frames.append(String(decoding: data, as: UTF8.self))
                if frames.count == 2 { received.fulfill() }
            }
            serverChannel = channel
            channel.start()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let client = PYLinkChannel(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp), isServer: false, queue: queue)
        client.encrypt(with: key)
        client.start()
        client.send(Data("first".utf8))
        client.send(Data(String(repeating: "x", count: 200_000).utf8))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(frames.first, "first")
        XCTAssertEqual(frames.last?.count, 200_000)
        client.close(nil)
        serverChannel?.close(nil)
        listener.cancel()
    }
}
