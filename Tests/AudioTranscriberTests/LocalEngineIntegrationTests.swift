import XCTest
@testable import AudioTranscriber

/// Real-model integration tests. Skipped unless FLUIDAUDIO_INTEGRATION=1 —
/// the first run downloads ~1.5GB of models.
/// Run: TEST_RUNNER_FLUIDAUDIO_INTEGRATION=1 xcodebuild test ... -only-testing:AudioTranscriberTests/LocalEngineIntegrationTests
final class LocalEngineIntegrationTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["FLUIDAUDIO_INTEGRATION"] == "1"
            // Env vars don't reliably forward to hosted test bundles; a marker
            // file works everywhere: touch /tmp/audiotranscriber-integration-tests
            || FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    private var sampleURL: URL {
        // Repo root test fixture: 63s, two speakers.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AudioTranscriberTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("test_recording.wav")
    }

    func testFullLocalPipeline() async throws {
        try XCTSkipUnless(enabled, "Set FLUIDAUDIO_INTEGRATION=1 to run")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sampleURL.path), "fixture missing")

        let checkpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-\(UUID().uuidString).partial.json")
        defer { try? FileManager.default.removeItem(at: checkpointURL) }

        let engine = LocalFluidAudioEngine()
        let duration = RecordingStore.audioDuration(for: sampleURL)
        XCTAssertGreaterThan(duration, 30)

        let request = TranscriptionRequest(
            recordingID: UUID(), audioURL: sampleURL, durationSeconds: duration,
            language: nil, checkpointURL: checkpointURL)

        let began = Date()
        let output = try await engine.transcribe(request) { update in
            print("[integration] \(Int(update.fractionComplete * 100))% — \(update.message)")
        }
        let elapsed = Date().timeIntervalSince(began)
        print("[integration] finished in \(String(format: "%.1f", elapsed))s (RTF \(String(format: "%.0f", duration / elapsed))x)")

        let segments = output.result.segments
        XCTAssertFalse(segments.isEmpty, "no segments produced")

        // Two speakers expected in the fixture
        let speakers = Set(segments.map(\.speaker))
        XCTAssertGreaterThanOrEqual(speakers.count, 2, "expected >=2 speakers, got \(speakers)")

        // Non-trivial text
        let fullText = segments.map(\.text).joined(separator: " ")
        XCTAssertGreaterThan(fullText.split(separator: " ").count, 50, "suspiciously short transcript: \(fullText)")

        // Word timing sanity: monotonic non-negative within segments
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.start, segment.end)
            for word in segment.words {
                if let s = word.start, let e = word.end {
                    XCTAssertLessThanOrEqual(s, e + 0.001)
                    XCTAssertGreaterThanOrEqual(s, -0.001)
                    XCTAssertLessThanOrEqual(e, duration + 5)
                }
            }
        }

        // Cluster embeddings exposed for enrollment
        XCTAssertFalse(output.speakerEmbeddings.isEmpty, "no speaker embeddings returned")

        // RTF calibration recorded
        XCTAssertTrue(RTFStore.hasCalibration(engineID: engine.id))

        // Checkpoint cleaned up by the service normally; engine leaves it — verify it exists and is valid
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))

        print("[integration] \(segments.count) segments, speakers: \(speakers)")
        print("[integration] first segment: \(segments.first?.speaker ?? "") — \(segments.first?.text.prefix(80) ?? "")")
    }
}
