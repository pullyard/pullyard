import CryptoKit
import Foundation
import IrohLib
import Network
import Security
import UIKit

struct PairedMac: Codable, Equatable {
    let id: String
    var name: String
    let key: String
    var hosts: [String]
    var port: UInt16
    var manualHost: String?
    var iroh: String?
}

struct AgentChat: Identifiable, Equatable {
    let id: String
    var title: String
    var items: [PYLinkItem] = []
    var state = PYLinkSessionState(running: false, busy: false, status: nil, error: nil, pending: [])
}

@MainActor
final class LinkClient: ObservableObject {
    enum Status: Equatable { case unpaired, offline, connecting, connected(String), failed(String) }

    static let shared = LinkClient()

    @Published private(set) var mac: PairedMac? = LinkClient.loadMac()
    @Published private(set) var status: Status = .unpaired
    @Published private(set) var sessions: [PYLinkSession] = []
    @Published private(set) var chats: [String: AgentChat] = [:]
    @Published private(set) var viaInternet = false

    private var channel: PYLinkChannel?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "pullyard.link.client")
    private var waiting: [String: CheckedContinuation<PYLinkMessage, Error>] = [:]
    private var subscriptions: Set<String> = []
    private var connectTask: Task<Void, Error>?
    private var irohEndpoint: Endpoint?
    private var irohBinding: Task<Endpoint, Error>?
    private let pathMonitor = NWPathMonitor()
    private var onLocalNetwork = true
    private lazy var identity: Curve25519.KeyAgreement.PrivateKey = LinkClient.loadIdentity()

    private init() {
        status = mac == nil ? .unpaired : .offline
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let local = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in self?.onLocalNetwork = local }
        }
        pathMonitor.start(queue: queue)
    }

    var isConnected: Bool { if case .connected = status { return true }; return false }
    var macName: String { mac?.name ?? "Mac" }

    func pair(_ pairing: PYLinkPairing) async throws {
        disconnect()
        connectTask?.cancel()
        connectTask = nil
        let candidate = PairedMac(id: pairing.id, name: pairing.name, key: pairing.key, hosts: pairing.hosts, port: pairing.port, manualHost: mac?.manualHost, iroh: pairing.iroh)
        try await connect(to: candidate, pairingCode: pairing.code)
        mac = candidate
        save()
    }

    func unpair() {
        disconnect()
        mac = nil
        sessions = []
        chats = [:]
        UserDefaults.standard.removeObject(forKey: "link.mac")
        status = .unpaired
        if let endpoint = irohEndpoint { Task { try? await endpoint.close() } }
        irohEndpoint = nil
        irohBinding = nil
    }

    func setManualHost(_ host: String) {
        guard var current = mac else { return }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        current.manualHost = trimmed.isEmpty ? nil : trimmed
        mac = current
        save()
    }

    func connectIfNeeded() {
        Task { try? await ensureConnected() }
    }

    func ensureConnected() async throws {
        if channel != nil, isConnected { return }
        if let running = connectTask { return try await running.value }
        guard let mac else { throw LinkError.notPaired }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.connect(to: mac, pairingCode: nil)
        }
        connectTask = task
        defer { if connectTask == task { connectTask = nil } }
        try await task.value
    }

    func disconnect() {
        channel?.close(nil)
        channel = nil
        browser?.cancel()
        browser = nil
        viaInternet = false
        if mac != nil { status = .offline }
        for continuation in waiting.values { continuation.resume(throwing: LinkError.disconnected) }
        waiting = [:]
    }

    func refreshSessions() async {
        if !isConnected { try? await ensureConnected() }
        guard let reply = try? await request(PYLinkMessage(type: "list")) else { return }
        sessions = reply.sessions ?? []
    }

    func startFix(repo: String, number: Int, kind: String, text: String?) async throws -> String {
        if !isConnected { try await ensureConnected() }
        var message = PYLinkMessage(type: "fix")
        message.repo = repo
        message.number = number
        message.kind = kind
        message.text = text
        let reply = try await request(message, timeout: 90)
        if let error = reply.error { throw LinkError.remote(error) }
        guard let session = reply.session else { throw LinkError.remote("The Mac didn't return a session.") }
        sessions = reply.sessions ?? sessions
        subscriptions.insert(session)
        if chats[session] == nil { chats[session] = AgentChat(id: session, title: "Agent") }
        return session
    }

    func subscribe(_ session: String) {
        subscriptions.insert(session)
        if chats[session] == nil { chats[session] = AgentChat(id: session, title: sessions.first { $0.id == session }?.title ?? "Agent") }
        var message = PYLinkMessage(type: "subscribe")
        message.session = session
        channel?.send(json: message)
    }

    func unsubscribe(_ session: String) {
        subscriptions.remove(session)
        var message = PYLinkMessage(type: "unsubscribe")
        message.session = session
        channel?.send(json: message)
    }

    func send(_ text: String, to session: String) {
        var message = PYLinkMessage(type: "send")
        message.session = session
        message.text = text
        channel?.send(json: message)
        chats[session]?.items.append(PYLinkItem(id: "local-\(UUID().uuidString)", kind: "user", text: text))
    }

    func respond(_ permission: PYLinkPermission, allow: Bool, always: Bool = false, in session: String) {
        var message = PYLinkMessage(type: "permission")
        message.session = session
        message.requestID = permission.id
        message.allow = allow
        message.always = always
        channel?.send(json: message)
        chats[session]?.state.pending.removeAll { $0.id == permission.id }
    }

    func stop(_ session: String) {
        var message = PYLinkMessage(type: "stop")
        message.session = session
        channel?.send(json: message)
    }

    private func request(_ message: PYLinkMessage, timeout: Double = 15) async throws -> PYLinkMessage {
        guard let channel else { throw LinkError.disconnected }
        var message = message
        let id = UUID().uuidString
        message.id = id
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            channel.send(json: message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let pending = self.waiting.removeValue(forKey: id) else { return }
                pending.resume(throwing: LinkError.timeout)
            }
        }
    }

    private func connect(to mac: PairedMac, pairingCode: String?) async throws {
        status = .connecting
        var lastError: Error = LinkError.unreachable
        for route in await routes(for: mac) {
            do {
                let timeout: Double = if case .internet = route { 15 } else { 5 }
                try await handshake(channel: channel(for: route), mac: mac, pairingCode: pairingCode, timeout: timeout)
                if case .internet = route { viaInternet = true } else { viaInternet = false }
                status = .connected(mac.name)
                for session in subscriptions { subscribe(session) }
                if let reply = try? await request(PYLinkMessage(type: "list")) { sessions = reply.sessions ?? sessions }
                return
            } catch let error as LinkError {
                lastError = error
                if case .rejected = error { break }
            } catch {
                lastError = error
            }
        }
        status = .failed(lastError.localizedDescription)
        throw lastError
    }

    private enum Route {
        case local(NWEndpoint)
        case internet(String)
    }

    private func routes(for mac: PairedMac) async -> [Route] {
        var result: [Route] = []
        if !onLocalNetwork, let iroh = mac.iroh { result.append(.internet(iroh)) }
        if onLocalNetwork, let found = await discover(macID: mac.id) { result.append(.local(found)) }
        if let manual = mac.manualHost {
            let parts = manual.split(separator: ":")
            let host = String(parts.first ?? "")
            let port = parts.count > 1 ? UInt16(parts[1]) ?? mac.port : mac.port
            if let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty { result.append(.local(.hostPort(host: NWEndpoint.Host(host), port: nwPort))) }
        }
        if onLocalNetwork, let iroh = mac.iroh { result.append(.internet(iroh)) }
        if onLocalNetwork, let port = NWEndpoint.Port(rawValue: mac.port) {
            result += mac.hosts.map { .local(.hostPort(host: NWEndpoint.Host($0), port: port)) }
        }
        return result
    }

    private func channel(for route: Route) async throws -> PYLinkChannel {
        switch route {
        case let .local(endpoint):
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            return PYLinkChannel(connection: NWConnection(to: endpoint, using: parameters), isServer: false, queue: queue)
        case let .internet(id):
            let endpoint = try await irohClient()
            let target = try EndpointId.fromString(s: id)
            let connection = try await Self.withTimeout(20) {
                try await endpoint.connect(addr: EndpointAddr(id: target, relayUrl: nil, addresses: []), alpn: PYLink.irohALPN)
            }
            let stream = try await connection.openBi()
            return PYLinkChannel(pipe: PYLinkIrohPipe(connection: connection, stream: stream), isServer: false)
        }
    }

    private func irohClient() async throws -> Endpoint {
        if let irohEndpoint { return irohEndpoint }
        if let irohBinding { return try await irohBinding.value }
        let binding = Task { try await Endpoint.bind(options: EndpointOptions(preset: presetN0())) }
        irohBinding = binding
        do {
            let endpoint = try await binding.value
            irohEndpoint = endpoint
            irohBinding = nil
            return endpoint
        } catch {
            irohBinding = nil
            throw error
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LinkError.unreachable
            }
            guard let first = try await group.next() else { throw LinkError.unreachable }
            group.cancelAll()
            return first
        }
    }

    private func discover(macID: String) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PYLink.serviceType, domain: nil), using: parameters)
            var finished = false
            let finish: (NWEndpoint?) -> Void = { endpoint in
                guard !finished else { return }
                finished = true
                browser.cancel()
                continuation.resume(returning: endpoint)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .bonjour(record) = result.metadata, record["id"] == macID { finish(result.endpoint); return }
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.5) { finish(nil) }
        }
    }

    private func handshake(channel: PYLinkChannel, mac: PairedMac, pairingCode: String?, timeout: Double) async throws {
        guard let macKey = PYLinkCrypto.publicKey(mac.key) else {
            channel.close(nil)
            throw LinkError.rejected("Invalid pairing key.")
        }
        let nonce = PYLinkCrypto.nonce()
        let identity = self.identity
        let hello: Result<PYLinkHelloReply, Error> = await withCheckedContinuation { continuation in
            var done = false
            let complete: (Result<PYLinkHelloReply, Error>) -> Void = { result in
                guard !done else { return }
                done = true
                continuation.resume(returning: result)
            }
            channel.onFrame = { data in
                guard let reply = try? JSONDecoder().decode(PYLinkHelloReply.self, from: data) else { complete(.failure(LinkError.unreachable)); return }
                complete(.success(reply))
            }
            channel.onClose = { _ in complete(.failure(LinkError.unreachable)) }
            channel.start()
            channel.send(json: PYLinkHello(v: PYLink.version, deviceID: Self.deviceID, deviceName: UIDevice.current.name, deviceKey: PYLinkCrypto.publicKeyString(identity), nonce: nonce, pairingCode: pairingCode))
            self.queue.asyncAfter(deadline: .now() + timeout) { complete(.failure(LinkError.timeout)) }
        }
        guard case let .success(reply) = hello else {
            channel.close(nil)
            if case let .failure(error) = hello { throw error }
            throw LinkError.unreachable
        }
        guard reply.ok, reply.desktopID == mac.id else {
            channel.close(nil)
            throw LinkError.rejected(reply.reason ?? "The Mac refused the connection.")
        }
        let key = try PYLinkCrypto.sessionKey(privateKey: identity, peer: macKey, clientNonce: nonce, serverNonce: reply.nonce)
        channel.encrypt(with: key)
        channel.onFrame = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        channel.onClose = { [weak self, weak channel] _ in
            Task { @MainActor in
                guard let self, let channel, self.channel === channel else { return }
                self.channel = nil
                if self.mac != nil { self.status = .offline }
            }
        }
        self.channel?.close(nil)
        self.channel = channel
        if var current = self.mac, current.id == mac.id, current.name != reply.desktopName {
            current.name = reply.desktopName
            self.mac = current
            save()
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(PYLinkMessage.self, from: data) else { return }
        if let id = message.id, let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(returning: message)
            if message.type != "started" { return }
        }
        switch message.type {
        case "snapshot", "update":
            guard let session = message.session else { return }
            var chat = chats[session] ?? AgentChat(id: session, title: message.text ?? "Agent")
            if let title = message.text { chat.title = title }
            var byID = Dictionary(chat.items.filter { !$0.id.hasPrefix("local-") }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for item in message.items ?? [] { byID[item.id] = item }
            if let order = message.order {
                chat.items = order.compactMap { byID[$0] }
            } else {
                let existing = chat.items.filter { !$0.id.hasPrefix("local-") }.map(\.id)
                let added = (message.items ?? []).map(\.id).filter { !existing.contains($0) }
                chat.items = (existing + added).compactMap { byID[$0] }
            }
            if let state = message.state { chat.state = state }
            chats[session] = chat
        case "sessions":
            sessions = message.sessions ?? sessions
        default:
            break
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: "link.mac") }
    }

    private static func loadMac() -> PairedMac? {
        guard let data = UserDefaults.standard.data(forKey: "link.mac") else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "link.deviceID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "link.deviceID")
        return id
    }

    private static func loadIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pullyard.mobile.link", kSecAttrAccount as String: "identity"]
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        var add = base
        add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}

enum LinkError: LocalizedError {
    case notPaired, disconnected, timeout, unreachable, rejected(String), remote(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair this iPhone with PullYard on your Mac first: Settings → Mac."
        case .disconnected: "The connection to your Mac was lost."
        case .timeout: "Your Mac didn't answer in time."
        case .unreachable: "Can't reach your Mac. Make sure PullYard is open on it with iPhone access on. Without Connect from anywhere both need the same Wi‑Fi or VPN."
        case let .rejected(reason): reason
        case let .remote(reason): reason
        }
    }
}
