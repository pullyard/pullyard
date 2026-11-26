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
    static let accessGroupKey = "PYKeychainAccessGroup"
    static let accessGroup = resolveGroup(Bundle.main.object(forInfoDictionaryKey: accessGroupKey) as? String)

    static func resolveGroup(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              value.range(of: "^[A-Z0-9]{10}\\.[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

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
            let group = attributes[kSecAttrAccessGroup as String] as? String ?? ""
            if let target = Self.accessGroup, !group.isEmpty, group != target {
                migrate(token: token, from: group, to: target)
            } else if (attributes[kSecAttrAccessible as String] as? String) != (accessibility as String) {
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
            var result = errSecMissingEntitlement
            if let group = Self.accessGroup {
                var grouped = insert
                grouped[kSecAttrAccessGroup as String] = group
                result = SecItemAdd(grouped as CFDictionary, nil)
            }
            if result == errSecMissingEntitlement { result = SecItemAdd(insert as CFDictionary, nil) }
            guard result == errSecSuccess else { throw VaultError.status(result) }
        } else if status != errSecSuccess {
            throw VaultError.status(status)
        }
    }

    private func migrate(token: String, from oldGroup: String, to newGroup: String) {
        var insert = baseQuery
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = accessibility
        insert[kSecAttrAccessGroup as String] = newGroup
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return }
        var old = baseQuery
        old[kSecAttrAccessGroup as String] = oldGroup
        SecItemDelete(old as CFDictionary)
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
