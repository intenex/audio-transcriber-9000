import Foundation

/// Minimal facade over NSUbiquitousKeyValueStore so tests can fake it.
protocol UbiquitousStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousStore {}

/// Mirrors the syncable preference keys between UserDefaults and the iCloud
/// key-value store. Pull-into-UserDefaults design: every call site keeps
/// reading `.standard`, so nothing else changes. Device-local keys
/// (storageDirectory, iCloudSyncEnabled, rtf.*, playback/UI state, migration
/// markers) are deliberately NOT listed.
final class SyncedDefaults {
    static let syncedKeys: [String] = [
        "recordingFormat", "importCompression", "diarizationClusteringThreshold",
        "defaultTranscriptionEngine", "confirmCloudTranscription", "autoSummarize",
        "autoTranscribeNewRecordings", "liveTranscriptionPreview", "chatProviderID",
        "miniMaxModel", "openAIChatModel", "customChatBaseURL", "customChatModel",
    ]

    private let defaults: UserDefaults
    private let cloud: UbiquitousStore
    private var lastPushed: [String: Any] = [:]
    private var isApplyingRemote = false
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard,
         cloud: UbiquitousStore = NSUbiquitousKeyValueStore.default) {
        self.defaults = defaults
        self.cloud = cloud
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func activate() {
        // Initial reconcile: local values win (push); remote fills only keys
        // the local device has never set.
        for key in Self.syncedKeys {
            if let local = defaults.object(forKey: key) {
                cloud.set(local, forKey: key)
                lastPushed[key] = local
            } else if let remote = cloud.object(forKey: key) {
                isApplyingRemote = true
                defaults.set(remote, forKey: key)
                isApplyingRemote = false
            }
        }
        cloud.synchronize()

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pushLocalChanges()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.pullRemoteChanges(note)
        })
    }

    private func pushLocalChanges() {
        guard !isApplyingRemote else { return }
        var changed = false
        for key in Self.syncedKeys {
            let local = defaults.object(forKey: key)
            guard let local else { continue }
            if !valuesEqual(lastPushed[key], local) {
                cloud.set(local, forKey: key)
                lastPushed[key] = local
                changed = true
            }
        }
        if changed { cloud.synchronize() }
    }

    /// Visible for tests (the external-change notification carries the store
    /// as `object`, which a fake can't be for NSUbiquitousKeyValueStore).
    func pullRemoteChanges(_ note: Notification) {
        let changedKeys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
            ?? Self.syncedKeys
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in changedKeys where Self.syncedKeys.contains(key) {
            guard let remote = cloud.object(forKey: key) else { continue }
            defaults.set(remote, forKey: key)
            lastPushed[key] = remote
        }
    }

    private func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a as NSObject, b as NSObject): return a.isEqual(b)
        default: return false
        }
    }
}
