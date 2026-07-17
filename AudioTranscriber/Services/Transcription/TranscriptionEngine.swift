import Foundation

enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable {
    case local
    case openAI
    case assemblyAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "On-Device (Local)"
        case .openAI: return "OpenAI"
        case .assemblyAI: return "AssemblyAI"
        }
    }

    var isCloud: Bool { self != .local }
}

struct KnownSpeakerReference: Sendable, Equatable {
    let name: String
    let clipURL: URL
}

struct TranscriptionRequest: Sendable {
    let recordingID: UUID
    let audioURL: URL
    let durationSeconds: TimeInterval
    let language: String?
    let checkpointURL: URL
    var knownSpeakers: [KnownSpeakerReference] = []
}

enum TranscriptionPhase: Sendable, Equatable {
    case preparingModels
    case downloadingModels
    case loadingAudio
    case transcribing(chunk: Int, of: Int)
    case diarizing
    case compressing
    case uploading(part: Int, of: Int)
    case waitingForProvider
    case finalizing
}

struct TranscriptionProgress: Sendable {
    var phase: TranscriptionPhase
    var fractionComplete: Double     // 0...1 overall, monotonic
    var message: String
    var etaSeconds: TimeInterval? = nil
}

struct TranscriptionOutput {
    var result: TranscriptionResult
    /// Auto-identified speaker names, e.g. "SPEAKER_00" -> "Ben". Never overwrites user edits.
    var speakerNames: [String: String] = [:]
    /// Per-cluster speaker embeddings (local engine only).
    var speakerEmbeddings: [String: [Float]] = [:]
}

enum TranscriptionEngineError: LocalizedError {
    case modelsNotAvailable(String)
    case audioLoadFailed(String)
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .modelsNotAvailable(let msg): return msg
        case .audioLoadFailed(let msg): return "Couldn't load audio: \(msg)"
        case .engineFailure(let msg): return msg
        }
    }
}

protocol TranscriptionEngine: Sendable {
    /// Stable identifier used as the realtime-factor calibration key.
    var id: String { get }
    var kind: TranscriptionEngineKind { get }
    /// Human-readable engine + model for attribution, e.g. "On-Device · Parakeet v3".
    var modelDescription: String { get }

    /// Ensure models/credentials are ready. Idempotent; reports .downloadingModels progress.
    func prepare(progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws

    /// Full pipeline: returns segments with words and normalized SPEAKER_00-style labels.
    /// Must honor Task cancellation (throw CancellationError) and resume from a
    /// valid checkpoint at request.checkpointURL when one exists.
    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void)
        async throws -> TranscriptionOutput
}
