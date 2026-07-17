import CoreMedia
import XCTest
@testable import AudioTranscriber

// Mac-only: real library files + Keychain live checks.
#if os(macOS)

/// Gated verifications against real user data / live APIs — the exact
/// reproductions of reported bugs. Enabled by the integration marker file.
final class LiveFixVerificationTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    /// "Family Planning Discussion" — the 2h07m WAV whose compression died at
    /// 1.8 MB under the old AVAssetReader path (quirky header stops the reader
    /// after ~2.5 min; AVAudioFile reads it fully).
    private var quirkyWavURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber/recording_2026-03-30_17-38-10.wav")
    }

    func testQuirkyWavCompressesFully() async throws {
        try XCTSkipUnless(enabled, "marker file not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: quirkyWavURL.path), "sample missing")

        let sourceDuration = RecordingStore.audioDuration(for: quirkyWavURL)
        print("[compress] source duration: \(Int(sourceDuration))s")
        XCTAssertGreaterThan(sourceDuration, 3600)

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("quirky-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: dest) }

        nonisolated(unsafe) var lastLogged = Date.distantPast
        let began = Date()
        _ = try await AudioCompressor.compress(source: quirkyWavURL, to: dest, spec: .storage) { fraction in
            if Date().timeIntervalSince(lastLogged) > 10 {
                lastLogged = Date()
                print("[compress] \(Int(fraction * 100))%")
            }
        }
        let elapsed = Date().timeIntervalSince(began)

        let outDuration = RecordingStore.audioDuration(for: dest)
        let outBytes = RecordingStore.fileSize(of: dest)
        print("[compress] DONE in \(Int(elapsed))s: \(Int(outDuration))s of audio, \(outBytes / 1_000_000) MB")

        XCTAssertEqual(outDuration, sourceDuration, accuracy: max(1, sourceDuration * 0.01),
                       "compressed duration must match the source — the old bug truncated at ~150s")
        // 2h07m @ 96 kbps ≈ 92 MB
        XCTAssertGreaterThan(outBytes, 50_000_000)
        XCTAssertLessThan(outBytes, 150_000_000)
    }

    /// Live MiniMax summary: real Keychain key, real endpoint, real transcript.
    /// Verifies the reasoning-model handling end to end (think blocks, JSON parse).
    func testLiveMiniMaxSummary() async throws {
        try XCTSkipUnless(enabled, "marker file not present")
        let secrets = KeychainStore.shared
        try XCTSkipUnless(secrets.has(.miniMax), "no MiniMax key in Keychain")

        let transcriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber/recording_2026-03-10_14-14-43.md")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript missing")
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)

        let provider = OpenAICompatibleChatProvider(
            id: .miniMax, displayName: "MiniMax",
            baseURL: { URL(string: "https://api.minimax.io/v1") },
            model: { "MiniMax-M3" },
            secretKey: .miniMax, secrets: secrets)

        let began = Date()
        let summary = try await SummarizationService.summarize(transcript: transcript, provider: provider)
        print("[minimax] summary in \(Int(Date().timeIntervalSince(began)))s")
        print("[minimax] name: \(summary.generatedName)")
        print("[minimax] topics: \(summary.topics ?? [])")
        print("[minimax] keyPoints: \(summary.keyPoints?.count ?? 0), actions: \(summary.actionItems.count)")
        print("[minimax] summary head: \(summary.summary.prefix(140))")

        XCTAssertFalse(summary.summary.isEmpty)
        XCTAssertFalse(summary.generatedName.isEmpty)
        XCTAssertFalse(summary.summary.contains("<think>"), "think block leaked into summary")
        XCTAssertEqual(summary.modelUsed, "MiniMax-M3")
    }
}
#endif
