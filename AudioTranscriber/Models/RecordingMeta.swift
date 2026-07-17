import Foundation

/// Per-recording metadata sidecar (`<stem>.meta.json`). The manifest
/// (`recordings.json`) is a rebuildable cache; this sidecar is the durable
/// source of identity and user-edited metadata, so a library rebuilt from the
/// directory alone (orphan adoption, another synced device) keeps stable IDs,
/// names, categories, and engine attribution.
///
/// Deliberately carries NO transcription status: status is derivable
/// (`.md` present → done, checkpoint present → partial, else pending) and the
/// runtime states (.processing/.paused) are device-local.
struct RecordingMeta: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var id: UUID
    var date: Date
    var duration: TimeInterval
    var name: String?
    var category: String?
    var engineUsed: String?
    var fileSizeBytes: Int64?
    /// Last-writer-wins key for cross-device conflict resolution.
    var updatedAt: Date

    init(recording: Recording, updatedAt: Date = .now) {
        self.version = Self.currentVersion
        self.id = recording.id
        self.date = recording.date
        self.duration = recording.duration
        self.name = recording.name
        self.category = recording.category
        self.engineUsed = recording.engineUsed
        self.fileSizeBytes = recording.fileSizeBytes
        self.updatedAt = updatedAt
    }

    /// True when everything except `updatedAt` matches — used to skip
    /// rewrites (and updatedAt bumps) for no-op saves.
    func sameContent(as other: RecordingMeta) -> Bool {
        var normalized = other
        normalized.updatedAt = updatedAt
        return normalized == self
    }
}

/// `<storageDir>/library.json` — the synced master list of categories.
/// The manifest's copy is the local cache; on load the two are unioned.
struct LibraryFile: Codable {
    static let currentVersion = 1

    var version: Int
    var categories: [String]
    var updatedAt: Date

    init(categories: [String], updatedAt: Date = .now) {
        self.version = Self.currentVersion
        self.categories = categories
        self.updatedAt = updatedAt
    }
}
