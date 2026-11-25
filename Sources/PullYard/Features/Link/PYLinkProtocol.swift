import CryptoKit
import Foundation
import Network

enum PYLink {
    static let serviceType = "_pullyard._tcp"
    static let version = 2
    static let preferredPort: UInt16 = 47811
    static let maxFrame = 32 * 1024 * 1024
    static let maxHandshakeFrame = 16 * 1024
    static let irohALPN = Data("pullyard/link/1".utf8)
}

struct PYLinkPairing: Codable, Equatable {
    var v = PYLink.version
    let name: String
    let id: String
    let key: String
    let code: String
    let hosts: [String]
    let port: UInt16
    var iroh: String? = nil

    var url: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "pullyard://pair?d=\(encoded)"
    }

    static func parse(_ string: String) -> PYLinkPairing? {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme == "pullyard", components.host == "pair",
              var value = components.queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(PYLinkPairing.self, from: data)
    }
}

struct PYLinkHello: Codable {
    let v: Int
    let deviceID: String
    let deviceName: String
    let deviceKey: String
    let nonce: String
    var ephemeral: String?
    var pairing: Bool?
    var proof: String?

    func proofParts(code: String) -> [String] {
        ["hello", String(v), deviceID, deviceName, deviceKey, nonce, ephemeral ?? "", pairing == true ? code : ""]
    }
}

struct PYLinkHelloReply: Codable {
    let ok: Bool
    let desktopID: String
    let desktopName: String
    let nonce: String
    var reason: String?
    var ephemeral: String?
    var proof: String?

    func proofParts(hello: PYLinkHello) -> [String] {
        ["reply", ok ? "1" : "0", desktopID, desktopName, hello.nonce, hello.ephemeral ?? "", nonce, ephemeral ?? "", reason ?? ""]
    }
}

struct PYLinkPermission: Codable, Equatable, Identifiable {
    let id: String
    let tool: String
    let summary: String
    var detail: String?
}

struct PYLinkItem: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    var text: String
    var tool: String?
    var status: String?
    var permission: PYLinkPermission?
    var files: [String]?
}

struct PYLinkAttachment: Codable, Equatable {
    var name: String
    var mediaType: String
    var data: Data
}

struct PYLinkSessionState: Codable, Equatable {
    var running: Bool
    var busy: Bool
    var status: String?
    var error: String?
    var pending: [PYLinkPermission]
}

struct PYLinkSession: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var folder: String
    var state: String
    var repo: String?
    var number: Int?
    var updated: Date?
}

struct PYLinkMessage: Codable {
    var type: String
    var id: String?
    var session: String?
    var repo: String?
    var number: Int?
    var kind: String?
    var text: String?
    var requestID: String?
    var allow: Bool?
    var always: Bool?
    var sessions: [PYLinkSession]?
    var items: [PYLinkItem]?
    var removed: [String]?
    var order: [String]?
    var state: PYLinkSessionState?
    var error: String?
    var url: String?
    var attachments: [PYLinkAttachment]?
    var prompt: String?
    var replacesItem: String?

    init(type: String) { self.type = type }
}

enum PYLinkCrypto {
    static func publicKeyString(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    static func publicKey(_ string: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    static func fingerprint(_ keyString: String) -> String {
        let digest = SHA256.hash(data: Data(base64Encoded: keyString) ?? Data(keyString.utf8))
        let hex = digest.prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    static func authKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("pullyard-link-v2-auth".utf8), sharedInfo: Data("handshake".utf8), outputByteCount: 32)
    }

    static func proof(_ parts: [String], key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "\n").utf8), using: key)).base64EncodedString()
    }

    static func verify(_ proof: String?, parts: [String], key: SymmetricKey) -> Bool {
        guard let proof, let code = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(parts.joined(separator: "\n").utf8), using: key)
    }

    static func sessionKey(identity: Curve25519.KeyAgreement.PrivateKey, peer: Curve25519.KeyAgreement.PublicKey, ephemeral: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Curve25519.KeyAgreement.PublicKey, clientNonce: String, serverNonce: String) throws -> SymmetricKey {
        let longTerm = try identity.sharedSecretFromKeyAgreement(with: peer)
        let fresh = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        var material = longTerm.withUnsafeBytes { Data($0) }
        material.append(fresh.withUnsafeBytes { Data($0) })
        let salt = Data((clientNonce + "|" + serverNonce).utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: Data("pullyard-link-v2".utf8), outputByteCount: 32)
    }

    static func frameNonce(direction: String, counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data([0, 0, 0, direction == "s2c" ? 1 : 2])
        var value = counter.bigEndian
        bytes.append(Data(bytes: &value, count: 8))
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ data: Data, key: SymmetricKey, direction: String, counter: UInt64) throws -> Data {
        try ChaChaPoly.seal(data, using: key, nonce: frameNonce(direction: direction, counter: counter), authenticating: Data(direction.utf8)).combined
    }

    static func open(_ data: Data, key: SymmetricKey, direction: String, counter: UInt64) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: data)
        guard Data(box.nonce) == Data(frameNonce(direction: direction, counter: counter)) else { throw CryptoKitError.authenticationFailure }
        return try ChaChaPoly.open(box, using: key, authenticating: Data(direction.utf8))
    }
}

protocol PYLinkPipe: AnyObject {
    func start(onData: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void)
    func write(_ data: Data)
    func close()
}

final class PYLinkNWPipe: PYLinkPipe, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var onClose: ((Error?) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(onData)
    }

    func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in if let error { self?.finish(error) } })
    }

    func close() { connection.cancel() }

    private func finish(_ error: Error?) {
        let handler = onClose
        onClose = nil
        handler?(error)
    }

    private func receive(_ onData: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { onData(data) }
            if let error { self.finish(error); return }
            if complete { self.finish(nil); return }
            self.receive(onData)
        }
    }
}

final class PYLinkChannel: @unchecked Sendable {
    let pipe: PYLinkPipe
    private var buffer = Data()
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var plaintextFrames = 1
    private let sendDirection: String
    private let receiveDirection: String
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var closed = false

    init(pipe: PYLinkPipe, isServer: Bool) {
        self.pipe = pipe
        sendDirection = isServer ? "s2c" : "c2s"
        receiveDirection = isServer ? "c2s" : "s2c"
    }

    convenience init(connection: NWConnection, isServer: Bool, queue: DispatchQueue) {
        self.init(pipe: PYLinkNWPipe(connection: connection, queue: queue), isServer: isServer)
    }

    var isEncrypted: Bool {
        lock.lock(); defer { lock.unlock() }
        return key != nil
    }

    func start() {
        pipe.start(onData: { [weak self] data in self?.received(data) }, onClose: { [weak self] error in self?.close(error) })
    }

    func encrypt(with key: SymmetricKey) {
        lock.lock()
        self.key = key
        lock.unlock()
        drain()
    }

    func send(_ payload: Data) {
        lock.lock()
        let body: Data
        if let key {
            guard let sealed = try? PYLinkCrypto.seal(payload, key: key, direction: sendDirection, counter: sendCounter) else { lock.unlock(); return }
            sendCounter += 1
            body = sealed
        } else {
            body = payload
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        pipe.write(frame)
        lock.unlock()
    }

    func send<T: Encodable>(json value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(data)
    }

    func close(_ error: Error?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        pipe.close()
        onClose?(error)
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let overflow = key == nil && buffer.count > PYLink.maxHandshakeFrame * 4
        lock.unlock()
        if overflow { close(nil); return }
        drain()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !closed, buffer.count >= 4 else { lock.unlock(); return }
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let limit = key == nil ? PYLink.maxHandshakeFrame : PYLink.maxFrame
            guard length <= limit else { lock.unlock(); close(nil); return }
            guard buffer.count >= 4 + length else { lock.unlock(); return }
            guard key != nil || plaintextFrames > 0 else { lock.unlock(); return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            let frame: Data
            if let key {
                guard let opened = try? PYLinkCrypto.open(body, key: key, direction: receiveDirection, counter: receiveCounter) else { lock.unlock(); close(nil); return }
                receiveCounter += 1
                frame = opened
            } else {
                plaintextFrames -= 1
                frame = body
            }
            lock.unlock()
            onFrame?(frame)
        }
    }
}
