import AVFoundation
import Foundation

/// Joins several recordings into one, in an order the user chooses.
///
/// A recording gets split for reasons the user never asked for: the capture
/// rotated to a new segment when the audio device changed, an interruption
/// ended the file early, one conversation arrived as two takes. This puts them
/// back together as a single recording.
///
/// The concatenation itself is `AudioCompressor.concatenateSync` — the same
/// code the recorder uses to stitch its own segments, which already handles
/// parts recorded at different sample rates (AirPods at 24 kHz, built-in mic
/// at 48 kHz). What lives here is the part-list arithmetic and the verification
/// that makes the result safe to keep.
enum RecordingMerger {
    struct Part: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let displayName: String
        /// From the audio file itself — manifest durations can be stale.
        let duration: TimeInterval
        let bytes: Int64
    }

    struct Plan: Equatable {
        var parts: [Part]
        var format: RecordingFormat

        var totalDuration: TimeInterval { parts.reduce(0) { $0 + $1.duration } }
        var totalBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
        var isValid: Bool { parts.count >= 2 && parts.allSatisfy { $0.duration > 0 } }
    }

    enum MergeError: LocalizedError {
        case tooFewParts
        case unreadable(String)
        case durationMismatch(expected: TimeInterval, actual: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .tooFewParts:
                return "Pick at least two recordings to combine."
            case .unreadable(let name):
                return "\(name) can't be read — combine it once it has finished downloading or converting."
            case .durationMismatch(let expected, let actual):
                return "The combined file holds \(Int(actual))s of audio instead of \(Int(expected))s, so it was discarded and the originals kept."
            }
        }
    }

    /// Builds a plan from recordings in the caller's chosen order. Reads each
    /// file's header (cheap) — the ordering, not the manifest, decides what
    /// ends up where.
    static func plan(for recordings: [Recording],
                     format: RecordingFormat = .selected) throws -> Plan {
        guard recordings.count >= 2 else { throw MergeError.tooFewParts }
        let parts: [Part] = try recordings.map { recording in
            let duration = RecordingStore.audioDuration(for: recording.fileURL)
            guard duration > 0 else { throw MergeError.unreadable(recording.displayName) }
            return Part(id: recording.id,
                        url: recording.fileURL,
                        displayName: recording.displayName,
                        duration: duration,
                        bytes: RecordingStore.fileSize(of: recording.fileURL))
        }
        return Plan(parts: parts, format: format)
    }

    /// Writes the combined audio and verifies it holds what the parts held.
    /// Heavy and synchronous inside — kept off the main thread by the caller.
    static func merge(_ plan: Plan, to destination: URL) async throws {
        guard plan.isValid else { throw MergeError.tooFewParts }
        let urls = plan.parts.map(\.url)
        let format = plan.format
        try? FileManager.default.removeItem(at: destination)
        try await Task.detached(priority: .userInitiated) {
            try AudioCompressor.concatenateSync(segments: urls, to: destination, as: format)
        }.value

        let expected = plan.totalDuration
        let actual = RecordingStore.audioDuration(for: destination)
        // AAC frame padding at each join costs a fraction of a second per part.
        let tolerance = max(2.0, expected * 0.02)
        guard actual > 0, abs(actual - expected) <= tolerance else {
            try? FileManager.default.removeItem(at: destination)
            throw MergeError.durationMismatch(expected: expected, actual: actual)
        }
    }

    /// "21:27 + 0:02 = 21:29" style summary for the confirmation UI.
    static func summary(for plan: Plan) -> String {
        let parts = plan.parts.map { timeLabel($0.duration) }.joined(separator: " + ")
        return "\(parts) = \(timeLabel(plan.totalDuration))"
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
