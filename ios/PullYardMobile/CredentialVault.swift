import Foundation
import Security

enum CredentialReadResult: Equatable {
    case found(String)
    case notFound
    case locked
    case failure(OSStatus)
}

protocol CredentialStore {
    func read() -> CredentialReadResult
    func write(_ token: String) throws
    func clear()
}

struct CredentialVault: CredentialStore {
    private let service = "com.pullyard.mobile.github"
    private let account = "primary"
    private let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> CredentialReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let data = attributes[kSecValueData as String] as? Data,
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else { return .notFound }
            if (attributes[kSecAttrAccessible as String] as? String) != (accessibility as String) {
                SecItemUpdate(baseQuery as CFDictionary, [kSecAttrAccessible as String: accessibility] as CFDictionary)
            }
            return .found(token)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .failure(status)
        }
    }

    func write(_ token: String) throws {
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: accessibility]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            update.forEach { insert[$0.key] = $0.value }
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw VaultError.status(result) }
        } else if status != errSecSuccess {
            throw VaultError.status(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    enum VaultError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            if case let .status(code) = self { return "Couldn't save the token in Keychain (\(code))." }
            return nil
        }
    }
}
