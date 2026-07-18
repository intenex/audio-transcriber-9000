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
///
/// Keys are stored as SYNCHRONIZABLE items in the shared access group when
/// the app's signing allows it — they then ride iCloud Keychain to every
/// device. Without the entitlement (ad-hoc/dev builds) everything degrades to
/// the legacy device-local item; `get` dual-reads both layers and lazily
/// migrates legacy items upward.
final class KeychainStore: SecretsStore {
    static let shared = KeychainStore()

    /// $(AppIdentifierPrefix) + group from both targets' entitlements.
    static let sharedAccessGroup = "Z6FHNWFTWR.com.audiortranscriber.AudioTranscriber.shared"

    private let service: String
    /// Tests use isolated service names and must stay off the (real, global)
    /// synchronizable layer.
    private let useSynchronizable: Bool

    init(service: String = "com.audiortranscriber.AudioTranscriber") {
        self.service = service
        self.useSynchronizable = (service == "com.audiortranscriber.AudioTranscriber")
    }

    func get(_ key: SecretKey) -> String? {
        if useSynchronizable, let value = read(query: syncQuery(for: key)) {
            return value
        }
        guard let legacy = read(query: legacyQuery(for: key)) else { return nil }
        // Lazy upward migration; the legacy copy is removed only once the
        // synchronizable write actually stuck.
        if useSynchronizable, writeSynchronizable(Data(legacy.utf8), for: key) {
            SecItemDelete(legacyQuery(for: key) as CFDictionary)
        }
        return legacy
    }

    @discardableResult
    func set(_ value: String, for key: SecretKey) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let data = Data(trimmed.utf8)

        if useSynchronizable, writeSynchronizable(data, for: key) {
            // Don't leave a stale device-local copy shadowing future reads.
            SecItemDelete(legacyQuery(for: key) as CFDictionary)
            return true
        }
        return writeLegacy(data, for: key)
    }

    func delete(_ key: SecretKey) {
        SecItemDelete(syncQuery(for: key) as CFDictionary)
        SecItemDelete(legacyQuery(for: key) as CFDictionary)
    }

    /// Eagerly promote all legacy items to the synchronizable layer (no-op
    /// when signing doesn't allow it — retried automatically every launch).
    func migrateLegacyItemsIfPossible() {
        guard useSynchronizable else { return }
        for key in SecretKey.allCases {
            guard read(query: syncQuery(for: key)) == nil,
                  let legacy = read(query: legacyQuery(for: key)) else { continue }
            if writeSynchronizable(Data(legacy.utf8), for: key) {
                SecItemDelete(legacyQuery(for: key) as CFDictionary)
            }
        }
    }

    // MARK: - Plumbing

    private func read(query base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeSynchronizable(_ data: Data, for key: SecretKey) -> Bool {
        let query = syncQuery(for: key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Synchronizable forbids the ThisDeviceOnly/WhenUnlocked variants.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private func writeLegacy(_ data: Data, for key: SecretKey) -> Bool {
        let query = legacyQuery(for: key)
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

    /// iCloud-synchronizable item in the shared access group (requires the
    /// keychain-access-groups entitlement, i.e. real team signing).
    private func syncQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: Self.sharedAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The pre-sync, device-local item (what all existing installs have).
    private func legacyQuery(for key: SecretKey) -> [String: Any] {
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
