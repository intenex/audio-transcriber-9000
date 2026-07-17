import Foundation

/// One-time cleanups of settings left behind by earlier versions.
enum LegacySettingsMigrator {
    static func runOnce(defaults: UserDefaults = .standard) {
        let v1 = "didCleanupLegacyKeys.v1"
        if !defaults.bool(forKey: v1) {
            // Plaintext secret from the old whisperX pipeline — purge it.
            defaults.removeObject(forKey: "huggingFaceToken")
            defaults.removeObject(forKey: "whisperModel")
            defaults.set(true, forKey: v1)
        }

        let v2 = "didCleanupLegacyKeys.v2"
        if !defaults.bool(forKey: v2) {
            // Old default chat model — clear so the new MiniMax-M3 default applies.
            // (Only removes the exact old default; a deliberate custom choice survives.)
            if defaults.string(forKey: "miniMaxModel") == "MiniMax-M2" {
                defaults.removeObject(forKey: "miniMaxModel")
            }
            defaults.set(true, forKey: v2)
        }
    }
}
