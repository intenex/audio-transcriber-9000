import Foundation

/// Resumable transcription state persisted as `<stem>.partial.json` beside the
/// audio file after every completed chunk. Resume validates version, engine,
/// and audio fingerprint; the persisted chunk plan is reused verbatim so a
/// resumed run can never misalign with already-transcribed chunks.
struct TranscriptionCheckpoint: Codable, Equatable {
    struct AudioFingerprint: Codable, Equatable {
        let fileSizeBytes: Int64
        let durationSeconds: Double
    }

    struct ChunkResult: Codable, Equatable {
        let index: Int
        let text: String
        let words: [TranscriptionWord]      // absolute times
        let processingSeconds: Double
    }

    static let currentVersion = 1

    var version: Int
    var engineID: String
    var recordingID: UUID
    var audioFingerprint: AudioFingerprint
    var createdAt: Date
    var updatedAt: Date
    var chunkPlan: [ChunkSpec]
    var chunks: [ChunkResult]
    var asrComplete: Bool

    init(engineID: String, recordingID: UUID, audioFingerprint: AudioFingerprint, chunkPlan: [ChunkSpec]) {
        self.version = Self.currentVersion
        self.engineID = engineID
        self.recordingID = recordingID
        self.audioFingerprint = audioFingerprint
        self.createdAt = .now
        self.updatedAt = .now
        self.chunkPlan = chunkPlan
        self.chunks = []
        self.asrComplete = false
    }

    var completedChunkIndices: Set<Int> { Set(chunks.map(\.index)) }

    /// Fraction of planned audio whose ASR is complete.
    var completedAudioSeconds: Double {
        let done = completedChunkIndices
        return chunkPlan.filter { done.contains($0.index) }.reduce(0) { $0 + $1.duration }
    }

    mutating func record(_ chunk: ChunkResult) {
        chunks.removeAll { $0.index == chunk.index }
        chunks.append(chunk)
        chunks.sort { $0.index < $1.index }
        updatedAt = .now
    }

    // MARK: - Persistence

    static func fingerprint(for audioURL: URL, durationSeconds: Double) -> AudioFingerprint {
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return AudioFingerprint(fileSizeBytes: size, durationSeconds: durationSeconds)
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Load and validate; returns nil (and deletes the stale file) on any mismatch.
    static func loadIfValid(from url: URL, engineID: String,
                            fingerprint: AudioFingerprint) -> TranscriptionCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(TranscriptionCheckpoint.self, from: data),
              checkpoint.version == currentVersion,
              checkpoint.engineID == engineID,
              checkpoint.audioFingerprint.fileSizeBytes == fingerprint.fileSizeBytes,
              abs(checkpoint.audioFingerprint.durationSeconds - fingerprint.durationSeconds) < 1.0
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return checkpoint
    }
}
