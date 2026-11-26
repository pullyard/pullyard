#if canImport(IrohLib)
import Foundation
import IrohLib
import Security

final class PYLinkIrohPipe: PYLinkPipe, @unchecked Sendable {
    let connection: Connection
    private let sendStream: SendStream
    private let recvStream: RecvStream
    private var readTask: Task<Void, Never>?
    private var lastWrite: Task<Void, Never>?
    private let lock = NSLock()

    init(connection: Connection, stream: BiStream) {
        self.connection = connection
        sendStream = stream.send()
        recvStream = stream.recv()
    }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        let recv = recvStream
        readTask = Task.detached {
            do {
                while !Task.isCancelled {
                    let chunk = try await recv.read(sizeLimit: 64 * 1024)
                    if chunk.isEmpty { onClose(nil); return }
                    onData(Data(chunk))
                }
            } catch {
                onClose(error)
            }
        }
    }

    func write(_ data: Data) {
        lock.lock()
        let previous = lastWrite
        let stream = sendStream
        lastWrite = Task.detached {
            await previous?.value
            try? await stream.writeAll(buf: data)
        }
        lock.unlock()
    }

    func close() {
        readTask?.cancel()
        try? connection.close(errorCode: 0, reason: Data())
    }
}

enum PYLinkIrohKeys {
    static func secret(service: String) -> Data {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "iroh"]
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        let data = Data(SecretKey.generate().toBytes())
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return data
    }
}
#endif
