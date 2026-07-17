import XCTest
import FluidAudio
@testable import AudioTranscriber

/// Temporary tuning harness: sweep diarizer clustering thresholds against the
/// known-2-speaker fixture. Enabled by the same marker file as integration tests.
final class DiarizerThresholdSweepTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    private var sampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test_recording.wav")
    }

    func testThresholdSweep() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let samples = try AudioConverter().resampleAudioFile(sampleURL)
        let models = try await DiarizerModels.downloadIfNeeded()
        var results: [String] = []

        for threshold in [Float(0.5), 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9] {
            var config = DiarizerConfig()
            config.clusteringThreshold = threshold
            let manager = DiarizerManager(config: config)
            let freshModels = try await DiarizerModels.downloadIfNeeded()
            manager.initialize(models: freshModels)
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
            let speakers = Set(result.segments.map(\.speakerId))
            let line = "threshold \(threshold): \(speakers.count) speakers, \(result.segments.count) turns"
            print("[sweep] \(line)")
            results.append(line)
        }
        _ = models
        print("[sweep] DONE:\n" + results.joined(separator: "\n"))
    }
}
