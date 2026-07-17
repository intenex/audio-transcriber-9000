import Foundation

enum TranscriptionStatus: String, Codable {
    case pending
    case processing
    case done
    case failed
    case paused    // user paused; checkpoint on disk
    case partial   // interrupted (crash/quit) with checkpoint found at launch

    // Tolerate unknown raw values from future/older versions.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TranscriptionStatus(rawValue: raw) ?? .pending
    }

    /// Statuses from which a (re-)transcription may be started.
    var canStartTranscription: Bool {
        switch self {
        case .pending, .failed, .paused, .partial: return true
        case .processing, .done: return false
        }
    }

    /// Has a resumable checkpoint semantic.
    var isResumable: Bool { self == .paused || self == .partial }
}

struct Recording: Identifiable, Codable {
    let id: UUID
    /// Mutable: compress-in-place swaps a .wav for its .m4a (same stem, so all
    /// sidecars keep matching).
    var fileURL: URL
    let date: Date
    var duration: TimeInterval
    var transcriptionURL: URL?
    var status: TranscriptionStatus
    var name: String?
    var category: String?
    /// Human-readable engine/model that produced the transcript, e.g.
    /// "On-Device · Parakeet v3". Optional for pre-existing data.
    var engineUsed: String?

    init(id: UUID = UUID(), fileURL: URL, date: Date = .now, duration: TimeInterval = 0,
         transcriptionURL: URL? = nil, status: TranscriptionStatus = .pending,
         name: String? = nil, category: String? = nil, engineUsed: String? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.date = date
        self.duration = duration
        self.transcriptionURL = transcriptionURL
        self.status = status
        self.name = name
        self.category = category
        self.engineUsed = engineUsed
    }

    var displayName: String {
        name ?? formattedDate
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Sidecar URLs

    private func sidecar(_ ext: String) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension(ext)
    }

    var segmentsURL: URL { sidecar("segments.json") }
    var summaryURL: URL { sidecar("summary.json") }
    var chatURL: URL { sidecar("chat.json") }
    var speakersURL: URL { sidecar("speakers.json") }
    var checkpointURL: URL { sidecar("partial.json") }
    var markdownURL: URL { sidecar("md") }

    /// All sidecar files that belong to this recording.
    var allSidecarURLs: [URL] {
        [markdownURL, segmentsURL, summaryURL, chatURL, speakersURL, checkpointURL]
    }
}
