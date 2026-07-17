import Foundation
import Security

enum SecretKey: String, CaseIterable {
    case openAI = "openai.apiKey"
    case miniMax = "minimax.apiKey"
    case assemblyAI = "assemblyai.apiKey"
    case custom = "custom.apiKey"
}

protocol SecretsStore: AnyObject {
    func get(_ key: SecretKey) -> String?
    /// Persists a non-empty secret; empty/whitespace input is a no-op.
    /// Removal is only ever explicit via `delete(_:)` — a transiently empty
    /// text field must never be able to destroy a stored key.
    @discardableResult
    func set(_ value: String, for key: SecretKey) -> Bool
    func delete(_ key: SecretKey)
}

extension SecretsStore {
    /// True when a non-empty secret exists for the key.
    func has(_ key: SecretKey) -> Bool {
        guard let value = get(key) else { return false }
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Keychain-backed secrets storage (kSecClassGenericPassword).
/// The service string is a fixed constant, NOT Bundle.main.bundleIdentifier:
/// the iOS app has a different bundle id, and synced keys are only findable
/// when both platforms query the same service. (Identical to the Mac bundle
/// id, so existing items keep resolving.)
final class KeychainStore: SecretsStore {
    static let shared = KeychainStore()

    private let service: String

    init(service: String = "com.audiortranscriber.AudioTranscriber") {
        self.service = service
    }

    func get(_ key: SecretKey) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for key: SecretKey) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let data = Data(trimmed.utf8)

        let query = baseQuery(for: key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete(_ key: SecretKey) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

/// Test double: keeps secrets in memory.
final class InMemorySecretsStore: SecretsStore {
    private var storage: [SecretKey: String] = [:]

    init(_ initial: [SecretKey: String] = [:]) {
        storage = initial
    }

    func get(_ key: SecretKey) -> String? { storage[key] }
    @discardableResult
    func set(_ value: String, for key: SecretKey) -> Bool {
        if !value.isEmpty { storage[key] = value }
        return true
    }
    func delete(_ key: SecretKey) { storage[key] = nil }
}
