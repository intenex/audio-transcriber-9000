import Foundation

/// On-disk manifest persisted as `recordings.json` inside the storage directory.
/// Audio files inside the storage directory are stored by relative filename so the
/// library survives directory moves; files elsewhere keep an absolute path.
struct RecordingManifest: Codable {
    var schemaVersion: Int
    var categories: [String]
    var recordings: [Entry]

    static let currentSchemaVersion = 1

    struct Entry: Codable {
        var id: UUID
        var fileName: String?          // relative to the storage directory
        var absolutePath: String?      // used only when the file lives outside the storage directory
        var date: Date
        var duration: TimeInterval
        var hasTranscription: Bool
        var status: TranscriptionStatus
        var name: String?
        var category: String?
        var engineUsed: String?
    }

    init(schemaVersion: Int = RecordingManifest.currentSchemaVersion,
         categories: [String] = [], recordings: [Entry] = []) {
        self.schemaVersion = schemaVersion
        self.categories = categories
        self.recordings = recordings
    }
}

extension RecordingManifest.Entry {
    init(recording: Recording, storageDirectory: URL) {
        let dirPath = storageDirectory.standardizedFileURL.path
        let filePath = recording.fileURL.standardizedFileURL.path
        let isInside = filePath.hasPrefix(dirPath + "/")

        self.init(
            id: recording.id,
            fileName: isInside ? recording.fileURL.lastPathComponent : nil,
            absolutePath: isInside ? nil : filePath,
            date: recording.date,
            duration: recording.duration,
            hasTranscription: recording.transcriptionURL != nil,
            status: recording.status,
            name: recording.name,
            category: recording.category,
            engineUsed: recording.engineUsed
        )
    }

    /// Resolve back to a runtime Recording. Returns nil when the entry has no
    /// usable file reference.
    func toRecording(storageDirectory: URL) -> Recording? {
        let url: URL
        if let fileName {
            url = storageDirectory.appendingPathComponent(fileName)
        } else if let absolutePath {
            url = URL(fileURLWithPath: absolutePath)
        } else {
            return nil
        }
        let transcriptionURL = hasTranscription
            ? url.deletingPathExtension().appendingPathExtension("md")
            : nil
        return Recording(
            id: id, fileURL: url, date: date, duration: duration,
            transcriptionURL: transcriptionURL, status: status,
            name: name, category: category, engineUsed: engineUsed
        )
    }
}
