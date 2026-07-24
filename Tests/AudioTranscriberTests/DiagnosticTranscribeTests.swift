import XCTest
@testable import AudioTranscriber

/// On-demand harness: run the full local pipeline against ANY audio file to
/// reproduce user-reported transcription failures with the real models.
///
/// Enable by writing the audio file's absolute path into
/// /tmp/audiotranscriber-diagnose-file (single line), then:
///   xcodebuild test ... -only-testing:AudioTranscriberTests/DiagnosticTranscribeTests
/// Skipped when the marker file is absent. Uses a scratch checkpoint — never
/// touches the file's real sidecars.
final class DiagnosticTranscribeTests: XCTestCase {

    private static let markerPath = "/tmp/audiotranscriber-diagnose-file"

    func testTranscribeArbitraryFile() async throws {
        guard let raw = try? String(contentsOfFile: Self.markerPath, encoding: .utf8) else {
            throw XCTSkip("write an audio path into \(Self.markerPath) to run")
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioURL = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: audioURL.path), "no file at \(path)")

        let checkpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnose-\(UUID().uuidString).partial.json")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }

        let duration = RecordingStore.audioDuration(for: audioURL)
        NSLog("[diagnose] file: %@ duration: %.1fs", audioURL.lastPathComponent, duration)

        let engine = LocalFluidAudioEngine()
        let request = TranscriptionRequest(
            recordingID: UUID(), audioURL: audioURL, durationSeconds: duration,
            language: nil, checkpointURL: checkpointURL)

        let began = Date()
        do {
            let output = try await engine.transcribe(request) { update in
                NSLog("[diagnose] %3d%% — %@", Int(update.fractionComplete * 100), update.message)
            }
            let elapsed = Date().timeIntervalSince(began)
            let segments = output.result.segments
            NSLog("[diagnose] SUCCESS in %.1fs — %d segments, %d speakers, coverage to %.1f min",
                  elapsed, segments.count, Set(segments.map(\.speaker)).count,
                  (segments.last?.end ?? 0) / 60)
            XCTAssertFalse(segments.isEmpty)
        } catch {
            let elapsed = Date().timeIntervalSince(began)
            NSLog("[diagnose] FAILED after %.1fs: %@", elapsed, String(describing: error))
            XCTFail("transcription failed after \(Int(elapsed))s: \(error)")
        }
    }
}
