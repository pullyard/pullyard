import CryptoKit
import Foundation
import IrohLib
import Network
import Observation
import Security

struct PYLinkDevice: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let key: String
    let added: Date
    var lastSeen: Date?
}

@Observable
@MainActor
final class PYLinkServer {
    static let shared = PYLinkServer()

    private static let enabledKey = "link.enabled"
    private static let devicesKey = "link.devices"
    private static let desktopIDKey = "link.desktopID"
    private static let internetKey = "link.internet"

    var enabled: Bool = UserDefaults.standard.bool(forKey: PYLinkServer.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    var internet: Bool = UserDefaults.standard.object(forKey: PYLinkServer.internetKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(internet, forKey: Self.internetKey)
            guard listener != nil else { return }
            internet ? startIroh() : stopIroh()
        }
    }
    private(set) var devices: [PYLinkDevice] = PYLinkServer.loadDevices()
    private(set) var pairing: PYLinkPairing?
    private(set) var pairingExpires: Date?
    private(set) var port: UInt16?
    private(set) var connected: Set<String> = []
    private(set) var lastError: String?
    @ObservationIgnored private var pairingFailures = 0
    private(set) var irohID: String?
    private(set) var irohOnline = false
    private(set) var irohError: String?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [ObjectIdentifier: PYLinkClient] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "pullyard.link")
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var irohEndpoint: Endpoint?
    @ObservationIgnored private var irohTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored lazy var identity: Curve25519.KeyAgreement.PrivateKey = PYLinkServer.loadIdentity()

    let desktopID: String = {
        if let id = UserDefaults.standard.string(forKey: PYLinkServer.desktopIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: PYLinkServer.desktopIDKey)
        return id
    }()

    var desktopName: String { Host.current().localizedName ?? "Mac" }
    var isRunning: Bool { listener != nil && port != nil }

    func attach(_ app: AppModel) {
        self.app = app
        if enabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener: NWListener
            if let preferred = NWEndpoint.Port(rawValue: PYLink.preferredPort), let candidate = try? NWListener(using: parameters, on: preferred) {
                listener = candidate
            } else {
                listener = try NWListener(using: parameters)
            }
            listener.service = NWListener.Service(name: desktopName, type: PYLink.serviceType, txtRecord: NWTXTRecord(["id": desktopID, "v": String(PYLink.version)]))
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = listener.port?.rawValue
                    case .failed(let error):
                        self.lastError = error.localizedDescription
                        self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { return }
                    self.accept(PYLinkChannel(connection: connection, isServer: true, queue: self.queue))
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            if internet { startIroh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for client in clients.values { client.channel.close(nil) }
        clients = [:]
        refreshConnected()
        pump?.cancel()
        pump = nil
        stopIroh()
    }

    private func startIroh() {
        guard irohTask == nil else { return }
        irohError = nil
        let secret = PYLinkIrohKeys.secret(service: "dev.pullyard.link")
        irohTask = Task { @MainActor [weak self] in
            do {
                let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetN0(), secretKey: secret, alpns: [PYLink.irohALPN]))
                guard let self, !Task.isCancelled else {
                    try? await endpoint.close()
                    return
                }
                self.irohEndpoint = endpoint
                self.irohID = endpoint.id().description
                if self.pairing != nil { self.pairing?.iroh = self.irohID }
                Task { @MainActor [weak self] in
                    await endpoint.online()
                    if self?.irohEndpoint === endpoint { self?.irohOnline = true }
                }
                while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
                    Task { @MainActor [weak self] in
                        guard let connection = try? await incoming.accept().connect(), let stream = try? await connection.acceptBi() else { return }
                        guard let self, self.irohEndpoint === endpoint else {
                            try? connection.close(errorCode: 0, reason: Data())
                            return
                        }
                        self.accept(PYLinkChannel(pipe: PYLinkIrohPipe(connection: connection, stream: stream), isServer: true))
                    }
                }
            } catch {
                self?.irohError = error.localizedDescription
                self?.irohTask = nil
            }
        }
    }

    private func stopIroh() {
        irohTask?.cancel()
        irohTask = nil
        if let endpoint = irohEndpoint { Task { try? await endpoint.close() } }
        irohEndpoint = nil
        irohID = nil
        irohOnline = false
    }

    func beginPairing() {
        if !enabled { enabled = true }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        pairing = PYLinkPairing(name: desktopName, id: desktopID, key: PYLinkCrypto.publicKeyString(identity), code: code, hosts: Self.localAddresses(), port: port ?? PYLink.preferredPort, iroh: irohID)
        pairingExpires = Date().addingTimeInterval(10 * 60)
        pairingFailures = 0
        lastError = nil
    }

    func cancelPairing() {
        pairing = nil
        pairingExpires = nil
    }

    func remove(_ device: PYLinkDevice) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        for client in clients.values where client.deviceID == device.id { client.channel.close(nil) }
    }

    private func accept(_ channel: PYLinkChannel) {
        guard clients.values.filter({ !$0.authenticated }).count < 8 else {
            channel.close(nil)
            return
        }
        let client = PYLinkClient(channel: channel)
        let id = ObjectIdentifier(client)
        clients[id] = client
        channel.onFrame = { [weak self] data in
            Task { @MainActor in self?.handle(data, from: client) }
        }
        channel.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clients[id] = nil
                self.refreshConnected()
            }
        }
        channel.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak client] in
            guard let client, !client.authenticated else { return }
            client.channel.close(nil)
        }
    }

    private func handle(_ data: Data, from client: PYLinkClient) {
        guard client.authenticated else {
            guard !client.greeted else { client.channel.close(nil); return }
            client.greeted = true
            handshake(data, client: client)
            return
        }
        guard client.channel.isEncrypted, let message = try? JSONDecoder().decode(PYLinkMessage.self, from: data) else { return }
        PYLinkBridge(server: self, app: app).handle(message, client: client)
        ensurePump()
    }

    private func reject(_ client: PYLinkClient, hello: PYLinkHello?, authKey: SymmetricKey?, reason: String) {
        var reply = PYLinkHelloReply(ok: false, desktopID: desktopID, desktopName: desktopName, nonce: PYLinkCrypto.nonce(), reason: reason)
        if let hello, let authKey { reply.proof = PYLinkCrypto.proof(reply.proofParts(hello: hello), key: authKey) }
        client.channel.send(json: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { client.channel.close(nil) }
    }

    private func handshake(_ data: Data, client: PYLinkClient) {
        guard let hello = try? JSONDecoder().decode(PYLinkHello.self, from: data), let peer = PYLinkCrypto.publicKey(hello.deviceKey) else {
            client.channel.close(nil)
            return
        }
        guard hello.v >= PYLink.version, let ephemeralString = hello.ephemeral, let peerEphemeral = PYLinkCrypto.publicKey(ephemeralString),
              let authKey = try? PYLinkCrypto.authKey(privateKey: identity, peer: peer) else {
            return reject(client, hello: nil, authKey: nil, reason: "Update PullYard on this iPhone to connect to \(desktopName).")
        }
        let wantsPairing = hello.pairing == true
        let activeCode = (pairingExpires ?? .distantPast) > .now ? pairing?.code : nil
        let code = wantsPairing ? (activeCode ?? "") : ""
        guard PYLinkCrypto.verify(hello.proof, parts: hello.proofParts(code: code), key: authKey) else {
            if wantsPairing, activeCode != nil {
                pairingFailures += 1
                if pairingFailures >= 5 {
                    cancelPairing()
                    lastError = "Pairing stopped after too many wrong attempts. Show a new code to try again."
                }
            }
            return reject(client, hello: hello, authKey: authKey, reason: wantsPairing ? "The pairing code didn't match. Scan the code on \(desktopName) again." : "This iPhone isn't paired with \(desktopName). Pair it again from PullYard Settings → iPhone.")
        }
        var index = devices.firstIndex { $0.key == hello.deviceKey }
        if wantsPairing {
            if index == nil {
                devices.append(PYLinkDevice(id: hello.deviceID, name: hello.deviceName, key: hello.deviceKey, added: .now))
                index = devices.count - 1
            }
            cancelPairing()
        }
        guard let index else {
            return reject(client, hello: hello, authKey: authKey, reason: "This iPhone isn't paired with \(desktopName). Pair it again from PullYard Settings → iPhone.")
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var reply = PYLinkHelloReply(ok: true, desktopID: desktopID, desktopName: desktopName, nonce: PYLinkCrypto.nonce(), ephemeral: PYLinkCrypto.publicKeyString(ephemeral))
        guard let key = try? PYLinkCrypto.sessionKey(identity: identity, peer: peer, ephemeral: ephemeral, peerEphemeral: peerEphemeral, clientNonce: hello.nonce, serverNonce: reply.nonce) else {
            return reject(client, hello: hello, authKey: authKey, reason: "Couldn't set up an encrypted connection.")
        }
        reply.proof = PYLinkCrypto.proof(reply.proofParts(hello: hello), key: authKey)
        devices[index].lastSeen = .now
        devices[index].name = String(hello.deviceName.prefix(80))
        saveDevices()
        client.channel.send(json: reply)
        client.channel.encrypt(with: key)
        client.authenticated = true
        client.deviceID = devices[index].id
        refreshConnected()
    }

    private func refreshConnected() {
        connected = Set(clients.values.compactMap(\.deviceID))
        if connected.isEmpty {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "PullYard for iPhone is connected")
        }
    }

    private func ensurePump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                let bridge = PYLinkBridge(server: self, app: self.app)
                for client in self.clients.values where client.authenticated {
                    bridge.pushSessions(to: client)
                    if !client.subscriptions.isEmpty { bridge.pushUpdates(to: client) }
                }
            }
        }
    }

    private func saveDevices() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        Self.storeSecret(data, account: "devices")
        UserDefaults.standard.removeObject(forKey: Self.devicesKey)
    }

    private static func loadDevices() -> [PYLinkDevice] {
        if let data = loadSecret(account: "devices"), let items = try? JSONDecoder().decode([PYLinkDevice].self, from: data) { return items }
        guard let data = UserDefaults.standard.data(forKey: devicesKey), let items = try? JSONDecoder().decode([PYLinkDevice].self, from: data) else { return [] }
        storeSecret(data, account: "devices")
        UserDefaults.standard.removeObject(forKey: devicesKey)
        return items
    }

    private static func loadSecret(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pullyard.link", kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func storeSecret(_ data: Data, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pullyard.link", kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func loadIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pullyard.link", kSecAttrAccount as String: "identity", kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pullyard.link", kSecAttrAccount as String: "identity", kSecValueData as String: key.rawRepresentation, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }

    static func localAddresses() -> [String] {
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !result.contains(ip) { result.append(ip) }
            }
        }
        return result
    }
}

final class PYLinkClient {
    let channel: PYLinkChannel
    var authenticated = false
    var greeted = false
    var deviceID: String?
    var subscriptions: Set<String> = []
    var sentItems: [String: [String: PYLinkItem]] = [:]
    var sentOrder: [String: [String]] = [:]
    var sentState: [String: PYLinkSessionState] = [:]
    var sentSessions: [PYLinkSession]?

    init(channel: PYLinkChannel) { self.channel = channel }
}
