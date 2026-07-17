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
    func set(_ value: String, for key: SecretKey)
    func delete(_ key: SecretKey)
}

extension SecretsStore {
    /// True when a non-empty secret exists for the key.
    func has(_ key: SecretKey) -> Bool {
        guard let value = get(key) else { return false }
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Keychain-backed secrets storage (kSecClassGenericPassword, service = bundle id).
final class KeychainStore: SecretsStore {
    static let shared = KeychainStore()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.audiortranscriber.AudioTranscriber") {
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

    func set(_ value: String, for key: SecretKey) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return
        }
        let data = Data(trimmed.utf8)

        let query = baseQuery(for: key)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
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
    func set(_ value: String, for key: SecretKey) {
        if value.isEmpty { storage[key] = nil } else { storage[key] = value }
    }
    func delete(_ key: SecretKey) { storage[key] = nil }
}
