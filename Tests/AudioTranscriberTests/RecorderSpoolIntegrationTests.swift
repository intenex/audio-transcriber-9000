import XCTest
@testable import AudioTranscriber

/// Gated (marker-file) in-process test of the real recording flow: the live
/// file streams into the device-local spool, and only the finalized container
/// is renamed into the library. Uses the actual microphone (ambient input is
/// fine — we assert format/duration/placement, not content).
@MainActor
final class RecorderSpoolIntegrationTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    func testRecordingSpoolsThenLandsInLibrary() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecSpool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "RecSpool-\(UUID().uuidString)")!)
        store.load()
        let recorder = AudioRecorder()
        recorder.attach(store: store)

        recorder.startRecording()
        // Engine init is async (detached, TCC off-main); wait for it.
        for _ in 0..<40 where !recorder.isRecording {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(recorder.isRecording, "recording never started — mic permission?")

        // The growing file must be in the spool, never the library.
        let active = try XCTUnwrap(store.activeRecordingURL)
        XCTAssertTrue(active.path.contains("InProgress"), "live file streams into the spool")
        XCTAssertFalse(active.path.hasPrefix(tempDir.path))

        try await Task.sleep(for: .seconds(3))
        let recording = try XCTUnwrap(recorder.stopRecording())

        XCTAssertTrue(recording.fileURL.path.hasPrefix(tempDir.path),
                      "finalized file was renamed into the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path), "spool copy gone")
        XCTAssertNil(store.activeRecordingURL)
        XCTAssertGreaterThan(recording.duration, 1.5)
        // Header-verified duration proves the container was finalized before
        // the move (an unfinalized m4a reads as 0).
        XCTAssertEqual(RecordingStore.audioDuration(for: recording.fileURL),
                       recording.duration, accuracy: 1.0)
        XCTAssertEqual(store.recordings.first?.id, recording.id)
    }

    /// The bug that lost an hour-long recording: a mid-recording input change
    /// (AirPods connecting) silently stopped the engine while the UI kept
    /// showing "recording". Drives the REAL restart path: record → force a
    /// capture rotation → keep recording → stop → the segments stitch into one
    /// file covering both halves.
    func testCaptureInterruptionRotatesSegmentsAndStitches() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecRotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Keep this run mic-only: the system-audio tap would trigger a TCC
        // prompt in an unattended test run. Restore whatever the user had.
        let systemAudioKey = "recordSystemAudio"
        let previous = UserDefaults.standard.object(forKey: systemAudioKey)
        UserDefaults.standard.set(false, forKey: systemAudioKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: systemAudioKey)
            } else {
                UserDefaults.standard.removeObject(forKey: systemAudioKey)
            }
        }

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "RecRotate-\(UUID().uuidString)")!)
        store.load()
        let recorder = AudioRecorder()
        recorder.attach(store: store)

        recorder.startRecording()
        for _ in 0..<40 where !recorder.isRecording {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(recorder.isRecording, "recording never started — mic permission?")

        try await Task.sleep(for: .seconds(2))

        // Simulate the device change (same code path the config-change
        // notification and the device store use).
        recorder.captureInputChanged()

        // The recorder must still be recording after the rotation…
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(recorder.isRecording, "capture rotation must not end the recording")

        // …and stop must stitch the segments into one library file.
        let immediate = recorder.stopRecording()
        XCTAssertNil(immediate, "multi-segment stop finalizes asynchronously")
        for _ in 0..<60 where recorder.isFinalizingRecording || store.recordings.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }

        let recording = try XCTUnwrap(store.recordings.first, "stitched recording inserted")
        XCTAssertTrue(recording.fileURL.path.hasPrefix(tempDir.path))
        let duration = RecordingStore.audioDuration(for: recording.fileURL)
        // ~5s wall time minus a small rotation gap; anything ≥3.5s proves both
        // halves are present (a dead post-rotation capture would leave ~2s).
        XCTAssertGreaterThan(duration, 3.5, "audio from BOTH sides of the interruption must survive")
        // No stray segment files left in the spool.
        let spoolLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: SpoolLocation.directory.path)) ?? []
        XCTAssertTrue(spoolLeftovers.filter { $0.contains(".seg") }.isEmpty,
                      "segments cleaned up after stitch: \(spoolLeftovers)")
    }
}
