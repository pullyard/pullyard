import CryptoKit
import Foundation
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

    var enabled: Bool = UserDefaults.standard.bool(forKey: PYLinkServer.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    private(set) var devices: [PYLinkDevice] = PYLinkServer.loadDevices()
    private(set) var pairing: PYLinkPairing?
    private(set) var pairingExpires: Date?
    private(set) var port: UInt16?
    private(set) var connected: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [ObjectIdentifier: PYLinkClient] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "pullyard.link")
    @ObservationIgnored private var pump: Task<Void, Never>?
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
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
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
        connected = []
        pump?.cancel()
        pump = nil
    }

    func beginPairing() {
        if !enabled { enabled = true }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        pairing = PYLinkPairing(name: desktopName, id: desktopID, key: PYLinkCrypto.publicKeyString(identity), code: code, hosts: Self.localAddresses(), port: port ?? PYLink.preferredPort)
        pairingExpires = Date().addingTimeInterval(10 * 60)
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

    private func accept(_ connection: NWConnection) {
        let channel = PYLinkChannel(connection: connection, isServer: true, queue: queue)
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
                self.connected = Set(self.clients.values.compactMap(\.deviceID))
            }
        }
        channel.start()
    }

    private func handle(_ data: Data, from client: PYLinkClient) {
        guard client.authenticated else { handshake(data, client: client); return }
        guard let message = try? JSONDecoder().decode(PYLinkMessage.self, from: data) else { return }
        PYLinkBridge(server: self, app: app).handle(message, client: client)
        ensurePump()
    }

    private func handshake(_ data: Data, client: PYLinkClient) {
        guard let hello = try? JSONDecoder().decode(PYLinkHello.self, from: data), let peer = PYLinkCrypto.publicKey(hello.deviceKey) else {
            client.channel.close(nil)
            return
        }
        var known = devices.firstIndex { $0.key == hello.deviceKey }
        if known == nil, let pairing, let expires = pairingExpires, expires > .now, hello.pairingCode == pairing.code {
            devices.append(PYLinkDevice(id: hello.deviceID, name: hello.deviceName, key: hello.deviceKey, added: .now))
            known = devices.count - 1
            cancelPairing()
        }
        let serverNonce = PYLinkCrypto.nonce()
        guard let index = known, let key = try? PYLinkCrypto.sessionKey(privateKey: identity, peer: peer, clientNonce: hello.nonce, serverNonce: serverNonce) else {
            client.channel.send(json: PYLinkHelloReply(ok: false, desktopID: desktopID, desktopName: desktopName, nonce: serverNonce, reason: "This iPhone isn't paired with \(desktopName). Pair it again from PullYard Settings → iPhone."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { client.channel.close(nil) }
            return
        }
        devices[index].lastSeen = .now
        devices[index].name = hello.deviceName
        saveDevices()
        client.channel.send(json: PYLinkHelloReply(ok: true, desktopID: desktopID, desktopName: desktopName, nonce: serverNonce))
        client.channel.encrypt(with: key)
        client.authenticated = true
        client.deviceID = devices[index].id
        connected = Set(clients.values.compactMap(\.deviceID))
    }

    private func ensurePump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                let bridge = PYLinkBridge(server: self, app: self.app)
                for client in self.clients.values where client.authenticated && !client.subscriptions.isEmpty {
                    bridge.pushUpdates(to: client)
                }
            }
        }
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: Self.devicesKey) }
    }

    private static func loadDevices() -> [PYLinkDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey), let items = try? JSONDecoder().decode([PYLinkDevice].self, from: data) else { return [] }
        return items
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
    var deviceID: String?
    var subscriptions: Set<String> = []
    var sentItems: [String: [String: PYLinkItem]] = [:]
    var sentOrder: [String: [String]] = [:]
    var sentState: [String: PYLinkSessionState] = [:]

    init(channel: PYLinkChannel) { self.channel = channel }
}
