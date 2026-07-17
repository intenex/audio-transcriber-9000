import Foundation

/// Transcription checkpoints are device-local resume state, rewritten after
/// every chunk of a long job. They live OUTSIDE the library directory (which
/// may be synced to iCloud) in Application Support, keyed by recording ID —
/// syncing them would be pure churn and cross-device conflicts, and the
/// fingerprint (file size + duration) makes a foreign checkpoint useless
/// anyway.
enum CheckpointLocation {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTranscriber/Checkpoints", isDirectory: true)
    }

    /// Stable per-recording checkpoint path; ensures the directory exists so
    /// callers can write to it directly.
    static func url(for recordingID: UUID) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(recordingID.uuidString).partial.json")
    }
}
