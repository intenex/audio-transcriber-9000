import XCTest
@testable import AudioTranscriber

/// Full-stack resume test: RecordingStore + TranscriptionService + real
/// LocalFluidAudioEngine on a real multi-chunk recording. Pauses mid-ASR,
/// simulates an app relaunch with a fresh service, and verifies the job
/// resumes from the checkpoint instead of starting over.
/// Gated by the integration marker file; needs a long local sample.
@MainActor
final class ResumeIntegrationTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    /// A real ~18-minute recording from the local library (multi-chunk).
    private var longSampleURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber/recording_2026-03-26_17-31-40.wav")
    }

    func testPauseAndResumeAcrossServiceRestart() async throws {
        try XCTSkipUnless(enabled, "marker file not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: longSampleURL.path), "long sample missing")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Copy the sample so all sidecars/checkpoints land in the temp dir.
        let audioURL = tempDir.appendingPathComponent("long.wav")
        try FileManager.default.copyItem(at: longSampleURL, to: audioURL)

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "ResumeTest-\(UUID().uuidString)")!)
        store.load()
        guard let recording = store.recordings.first else {
            return XCTFail("orphan adoption should have picked up long.wav")
        }
        let duration = recording.duration
        XCTAssertGreaterThan(duration, 600, "need a multi-chunk file")

        // ---- Run 1: start, then pause once a few chunks are checkpointed ----
        let service1 = TranscriptionService()
        service1.attach(store: store, chatService: nil)
        service1.enqueue(recording.id)

        let deadline1 = Date().addingTimeInterval(300)
        while Date() < deadline1 {
            try await Task.sleep(for: .milliseconds(250))
            if let checkpoint = loadCheckpoint(recording),
               checkpoint.chunks.count >= 2, !checkpoint.asrComplete {
                break
            }
        }
        guard var midCheckpoint = loadCheckpoint(recording), midCheckpoint.chunks.count >= 2 else {
            return XCTFail("no mid-run checkpoint appeared within 5 minutes")
        }
        let completedBeforePause = midCheckpoint.completedChunkIndices
        print("[resume] pausing with \(completedBeforePause.count) of \(midCheckpoint.chunkPlan.count) chunks done")

        service1.pause(recording.id)
        let pauseDeadline = Date().addingTimeInterval(30)
        while store.recording(with: recording.id)?.status != .paused && Date() < pauseDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.checkpointURL.path))
        midCheckpoint = loadCheckpoint(recording)!

        // ---- Run 2: fresh service + engine ("app relaunch"), resume ----
        let service2 = TranscriptionService()
        service2.attach(store: store, chatService: nil)

        nonisolated(unsafe) var firstChunkMessages: [String] = []
        // Observe resume behavior via the engine's chunk numbering in progress text.
        service2.enqueue(recording.id)

        let deadline2 = Date().addingTimeInterval(600)
        while store.recording(with: recording.id)?.status != .done && Date() < deadline2 {
            try await Task.sleep(for: .milliseconds(500))
            let message = service2.progress
            if message.hasPrefix("Transcribing part"), firstChunkMessages.last != message {
                firstChunkMessages.append(message)
            }
        }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .done, "resume run didn't complete")

        // Resumed run must not re-transcribe already-completed chunks.
        if let firstMessage = firstChunkMessages.first {
            print("[resume] first ASR message after resume: \(firstMessage)")
            let resumedFromChunk = Int(firstMessage
                .replacingOccurrences(of: "Transcribing part ", with: "")
                .components(separatedBy: " ").first ?? "") ?? 1
            XCTAssertGreaterThan(resumedFromChunk, completedBeforePause.count,
                                 "resume restarted from the beginning")
        }

        // Transcript sanity: sidecars exist, segments span the whole file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.markdownURL.path))
        let segmentData = try Data(contentsOf: recording.segmentsURL)
        let segments = try JSONDecoder().decode([TranscriptionSegment].self, from: segmentData)
        XCTAssertFalse(segments.isEmpty)
        let lastEnd = segments.map(\.end).max() ?? 0
        XCTAssertGreaterThan(lastEnd, duration * 0.9, "transcript doesn't cover the full recording (last=\(lastEnd) of \(duration))")
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start + 0.5, "segments out of order at \(a.start)")
        }
        // Checkpoint cleaned up after success.
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.checkpointURL.path))

        let speakers = Set(segments.map(\.speaker))
        print("[resume] DONE: \(segments.count) segments, \(speakers.count) speakers, coverage to \(Int(lastEnd))s of \(Int(duration))s")
    }

    private func loadCheckpoint(_ recording: Recording) -> TranscriptionCheckpoint? {
        guard let data = try? Data(contentsOf: recording.checkpointURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptionCheckpoint.self, from: data)
    }
}
