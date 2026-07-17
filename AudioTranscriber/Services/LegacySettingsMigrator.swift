import Foundation

/// One-time cleanup of settings from the retired whisperX/Python pipeline.
enum LegacySettingsMigrator {
    static func runOnce(defaults: UserDefaults = .standard) {
        let marker = "didCleanupLegacyKeys.v1"
        guard !defaults.bool(forKey: marker) else { return }
        // Plaintext secret from the old pipeline — purge it.
        defaults.removeObject(forKey: "huggingFaceToken")
        defaults.removeObject(forKey: "whisperModel")
        defaults.set(true, forKey: marker)
    }
}
