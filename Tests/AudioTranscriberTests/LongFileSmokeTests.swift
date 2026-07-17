import XCTest
@testable import AudioTranscriber

// Mac-only: multi-GB library files via homeDirectoryForCurrentUser.
#if os(macOS)

/// Stress smoke test: the real 2h07m recording through the local engine.
/// Read-only on the source file; checkpoint goes to a temp path.
final class LongFileSmokeTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    private var longSampleURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber/recording_2026-03-30_17-38-10.wav")
    }

    /// 4h56m / 3.4GB — PCM payload >2GB, which crashed the old single-shot
    /// loader with com.apple.coreaudio.avfaudio error -40.
    private var hugeSampleURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber/recording_2026-03-26_10-31-39.wav")
    }

    func testFiveHourRecordingLoadsAndTranscribes() async throws {
        try XCTSkipUnless(enabled, "marker file not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: hugeSampleURL.path), "sample missing")

        let checkpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hugesmoke-\(UUID().uuidString).partial.json")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }

        let duration = RecordingStore.audioDuration(for: hugeSampleURL)
        print("[huge] duration: \(Int(duration))s (\(Int(duration/60)) min)")

        let engine = LocalFluidAudioEngine()
        let request = TranscriptionRequest(
            recordingID: UUID(), audioURL: hugeSampleURL, durationSeconds: duration,
            language: nil, checkpointURL: checkpointURL)

        nonisolated(unsafe) var lastLogged = Date.distantPast
        let began = Date()
        let output = try await engine.transcribe(request) { update in
            if Date().timeIntervalSince(lastLogged) > 30 {
                lastLogged = Date()
                print("[huge] \(Int(update.fractionComplete * 100))% — \(update.message)")
            }
        }
        let elapsed = Date().timeIntervalSince(began)

        let segments = output.result.segments
        let lastEnd = segments.map(\.end).max() ?? 0
        print("[huge] DONE in \(Int(elapsed))s (RTF \(Int(duration / elapsed))x): \(segments.count) segments, \(Set(segments.map(\.speaker)).count) speakers, coverage \(Int(lastEnd))/\(Int(duration))s")

        XCTAssertFalse(segments.isEmpty)
        XCTAssertGreaterThan(lastEnd, duration * 0.9, "coverage gap")
    }

    func testTwoHourRecordingTranscribes() async throws {
        try XCTSkipUnless(enabled, "marker file not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: longSampleURL.path), "sample missing")

        let checkpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("longsmoke-\(UUID().uuidString).partial.json")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }

        let duration = RecordingStore.audioDuration(for: longSampleURL)
        print("[smoke] duration: \(Int(duration))s (\(Int(duration/60)) min)")
        XCTAssertGreaterThan(duration, 3600)

        let engine = LocalFluidAudioEngine()
        let request = TranscriptionRequest(
            recordingID: UUID(), audioURL: longSampleURL, durationSeconds: duration,
            language: nil, checkpointURL: checkpointURL)

        nonisolated(unsafe) var lastLogged = Date.distantPast
        let began = Date()
        let output = try await engine.transcribe(request) { update in
            if Date().timeIntervalSince(lastLogged) > 15 {
                lastLogged = Date()
                print("[smoke] \(Int(update.fractionComplete * 100))% — \(update.message) — eta \(update.etaSeconds.map { Int($0) } ?? -1)s")
            }
        }
        let elapsed = Date().timeIntervalSince(began)

        let segments = output.result.segments
        let lastEnd = segments.map(\.end).max() ?? 0
        let words = segments.reduce(0) { $0 + $1.words.count }
        print("[smoke] DONE in \(Int(elapsed))s (RTF \(Int(duration / elapsed))x): \(segments.count) segments, \(words) words, \(Set(segments.map(\.speaker)).count) speakers, coverage \(Int(lastEnd))/\(Int(duration))s")

        XCTAssertFalse(segments.isEmpty)
        XCTAssertGreaterThan(lastEnd, duration * 0.9, "coverage gap")
        XCTAssertGreaterThan(words, 1000, "suspiciously few words for 2 hours")
    }
}
#endif
