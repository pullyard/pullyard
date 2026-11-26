import CryptoKit
#if canImport(IrohLib)
import IrohLib
#endif
import Network
import XCTest
@testable import PullYard

final class PYLinkTests: XCTestCase {
    func testPairingURLRoundTrip() {
        let pairing = PYLinkPairing(name: "Studio Mac", id: "abc", key: "key==", code: "123456", hosts: ["192.168.1.5", "100.64.0.2"], port: 47811, iroh: "abcdef")
        XCTAssertEqual(PYLinkPairing.parse(pairing.url), pairing)
        XCTAssertNil(PYLinkPairing.parse("pullyard://pull/a/b/1"))
    }

    func testBothSidesDeriveTheSameKey() throws {
        let desktop = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let desktopEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let a = try PYLinkCrypto.sessionKey(identity: desktop, peer: phone.publicKey, ephemeral: desktopEphemeral, peerEphemeral: phoneEphemeral.publicKey, clientNonce: "c", serverNonce: "s")
        let b = try PYLinkCrypto.sessionKey(identity: phone, peer: desktop.publicKey, ephemeral: phoneEphemeral, peerEphemeral: desktopEphemeral.publicKey, clientNonce: "c", serverNonce: "s")
        let sealed = try PYLinkCrypto.seal(Data("hello".utf8), key: a, direction: "c2s", counter: 0)
        XCTAssertEqual(try PYLinkCrypto.open(sealed, key: b, direction: "c2s", counter: 0), Data("hello".utf8))
        XCTAssertThrowsError(try PYLinkCrypto.open(sealed, key: b, direction: "s2c", counter: 0))
        XCTAssertThrowsError(try PYLinkCrypto.open(sealed, key: b, direction: "c2s", counter: 1))
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let c = try PYLinkCrypto.sessionKey(identity: stranger, peer: desktop.publicKey, ephemeral: phoneEphemeral, peerEphemeral: desktopEphemeral.publicKey, clientNonce: "c", serverNonce: "s")
        XCTAssertThrowsError(try PYLinkCrypto.open(sealed, key: c, direction: "c2s", counter: 0))
    }

    func testDirectionsNeverShareANonce() {
        XCTAssertNotEqual(Data(PYLinkCrypto.frameNonce(direction: "c2s", counter: 7)), Data(PYLinkCrypto.frameNonce(direction: "s2c", counter: 7)))
    }

    func testHelloProofNeedsTheRightKeysAndCode() throws {
        let desktop = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let attacker = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = try PYLinkCrypto.authKey(privateKey: phone, peer: desktop.publicKey)
        let desktopKey = try PYLinkCrypto.authKey(privateKey: desktop, peer: phone.publicKey)
        var hello = PYLinkHello(v: PYLink.version, deviceID: "d", deviceName: "iPhone", deviceKey: PYLinkCrypto.publicKeyString(phone), nonce: "n", ephemeral: "e", pairing: true)
        hello.proof = PYLinkCrypto.proof(hello.proofParts(code: "123456"), key: phoneKey)
        XCTAssertTrue(PYLinkCrypto.verify(hello.proof, parts: hello.proofParts(code: "123456"), key: desktopKey))
        XCTAssertFalse(PYLinkCrypto.verify(hello.proof, parts: hello.proofParts(code: "654321"), key: desktopKey))
        let attackerKey = try PYLinkCrypto.authKey(privateKey: attacker, peer: desktop.publicKey)
        var forged = hello
        forged.proof = PYLinkCrypto.proof(hello.proofParts(code: "123456"), key: attackerKey)
        XCTAssertFalse(PYLinkCrypto.verify(forged.proof, parts: forged.proofParts(code: "123456"), key: desktopKey))
    }

    func testPlaintextAfterHelloIsNeverDelivered() throws {
        let queue = DispatchQueue(label: "test.link.plain")
        let listener = try NWListener(using: .tcp, on: .any)
        let first = expectation(description: "hello delivered")
        let closed = expectation(description: "injected frame rejected")
        var serverChannel: PYLinkChannel?
        var frames: [String] = []
        listener.newConnectionHandler = { connection in
            let channel = PYLinkChannel(connection: connection, isServer: true, queue: queue)
            channel.onFrame = { data in
                frames.append(String(decoding: data, as: UTF8.self))
                if frames.count == 1 {
                    first.fulfill()
                    channel.encrypt(with: SymmetricKey(size: .bits256))
                }
            }
            channel.onClose = { _ in closed.fulfill() }
            serverChannel = channel
            channel.start()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let client = PYLinkChannel(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp), isServer: false, queue: queue)
        client.start()
        client.send(Data("hello".utf8))
        client.send(Data("{\"type\":\"fix\"}".utf8))
        wait(for: [first, closed], timeout: 5)
        XCTAssertEqual(frames, ["hello"])
        client.close(nil)
        serverChannel?.close(nil)
        listener.cancel()
    }

    func testOversizedHandshakeFrameIsRejected() throws {
        let queue = DispatchQueue(label: "test.link.big")
        let listener = try NWListener(using: .tcp, on: .any)
        let closed = expectation(description: "closed")
        var serverChannel: PYLinkChannel?
        listener.newConnectionHandler = { connection in
            let channel = PYLinkChannel(connection: connection, isServer: true, queue: queue)
            channel.onFrame = { _ in XCTFail("oversized frame delivered") }
            channel.onClose = { _ in closed.fulfill() }
            serverChannel = channel
            channel.start()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let client = PYLinkChannel(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp), isServer: false, queue: queue)
        client.start()
        client.send(Data(repeating: 65, count: PYLink.maxHandshakeFrame + 1))
        wait(for: [closed], timeout: 5)
        client.close(nil)
        serverChannel?.close(nil)
        listener.cancel()
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

#if canImport(IrohLib)
    func testEncryptedFramesOverIroh() async throws {
        let key = SymmetricKey(size: .bits256)
        let server = try await Endpoint.bind(options: EndpointOptions(preset: presetN0(), alpns: [PYLink.irohALPN], relayMode: RelayMode.disabled()))
        let client = try await Endpoint.bind(options: EndpointOptions(preset: presetN0(), relayMode: RelayMode.disabled()))
        let received = expectation(description: "server got frames")
        let replied = expectation(description: "client got reply")
        let box = FrameBox()
        let serverTask = Task {
            let incoming = await server.acceptNext()!
            let connection = try await incoming.accept().connect()
            let stream = try await connection.acceptBi()
            let channel = PYLinkChannel(pipe: PYLinkIrohPipe(connection: connection, stream: stream), isServer: true)
            channel.encrypt(with: key)
            channel.onFrame = { data in
                if box.append(String(decoding: data, as: UTF8.self)) == 2 {
                    received.fulfill()
                    channel.send(Data("pong".utf8))
                }
            }
            channel.start()
            return channel
        }
        let connection = try await client.connect(addr: server.addr(), alpn: PYLink.irohALPN)
        let stream = try await connection.openBi()
        let channel = PYLinkChannel(pipe: PYLinkIrohPipe(connection: connection, stream: stream), isServer: false)
        channel.encrypt(with: key)
        channel.onFrame = { data in if String(decoding: data, as: UTF8.self) == "pong" { replied.fulfill() } }
        channel.start()
        channel.send(Data("first".utf8))
        channel.send(Data(String(repeating: "x", count: 200_000).utf8))
        await fulfillment(of: [received, replied], timeout: 15)
        XCTAssertEqual(box.frames.first, "first")
        XCTAssertEqual(box.frames.last?.count, 200_000)
        channel.close(nil)
        try await serverTask.value.close(nil)
        try? await client.close()
        try? await server.close()
    }
    #endif
}

private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var frames: [String] = []

    func append(_ frame: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        return frames.count
    }
}
