import XCTest
@testable import AudioTranscriber

/// Gated (marker-file) in-process test of the real recording flow: the live
/// file streams into the device-local spool, and only the finalized container
/// is renamed into the library. Uses the actual microphone (ambient input is
/// fine — we assert format/duration/placement, not content).
@MainActor
final class RecorderSpoolIntegrationTests: XCTestCase {

    /// Also satisfiable inside the iOS app container so these run on a real
    /// phone (see IntegrationGate).
    private var enabled: Bool { IntegrationGate.isEnabled }

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

    /// Silence guardrail, end to end on the real capture path: with thresholds
    /// that treat every possible input as silence, a live recording must stop
    /// itself after the limit AND land in the library — stop-and-SAVE, never
    /// stop-and-discard.
    func testSilenceGuardrailStopsAndSavesTheRecording() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecSilence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let restore = forceMicOnlyCapture()
        defer { restore() }

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "RecSilence-\(UUID().uuidString)")!)
        store.load()
        let recorder = AudioRecorder()
        recorder.attach(store: store)
        // Nothing can clear these bars, so whatever the room sounds like the
        // recorder sees uninterrupted silence — the wiring is what's under test.
        var config = SilenceDetector.Config.default
        config.silenceLimit = 4
        config.alwaysSoundRMSDB = 0
        config.alwaysSoundPeakDB = 0
        config.audibleFloorDB = 0
        recorder.silenceConfigOverride = config

        recorder.startRecording()
        for _ in 0..<40 where !recorder.isRecording {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(recorder.isRecording, "recording never started — mic permission?")

        for _ in 0..<40 where recorder.isRecording {
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertFalse(recorder.isRecording, "silence guardrail never fired")
        XCTAssertNotNil(recorder.errorMessage, "the auto-stop must explain itself")

        for _ in 0..<40 where store.recordings.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }
        let recording = try XCTUnwrap(store.recordings.first, "auto-stopped audio must still be saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL.path))
        XCTAssertGreaterThan(RecordingStore.audioDuration(for: recording.fileURL), 2,
                             "the captured audio survives the auto-stop")
    }

    /// Before treating silence as an empty room, the recorder reopens the
    /// input — the failure two of the user's real recordings show (47 min and
    /// 113 min of all-zero samples) is a live-but-dead input, and rotating the
    /// capture chain is the one thing that can revive it. Recovery must keep
    /// the recording running, and is capped so a quiet room can't churn.
    func testSilenceTriggersCaptureRecoveryBeforeStopping() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecRevive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let restore = forceMicOnlyCapture()
        defer { restore() }

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "RecRevive-\(UUID().uuidString)")!)
        store.load()
        let recorder = AudioRecorder()
        recorder.attach(store: store)
        var config = SilenceDetector.Config.default
        config.alwaysSoundRMSDB = 0        // nothing can register as sound
        config.alwaysSoundPeakDB = 0
        config.audibleFloorDB = 0
        config.silenceRecoveryDelay = 2
        config.maxSilenceRecoveryAttempts = 2
        config.silenceLimit = 60           // far enough out to observe recovery first
        recorder.silenceConfigOverride = config

        recorder.startRecording()
        for _ in 0..<40 where !recorder.isRecording {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(recorder.isRecording, "recording never started — mic permission?")

        for _ in 0..<40 where recorder.segmentCount < 3 {
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(recorder.segmentCount, 3, "two recovery rotations, then no more")
        XCTAssertTrue(recorder.isRecording, "recovery must not end the recording")

        // Capped: no further rotations even though silence continues.
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(recorder.segmentCount, 3, "recovery attempts must be capped")
        XCTAssertTrue(recorder.isRecording)

        recorder.stopRecording()
        for _ in 0..<60 where recorder.isFinalizingRecording || store.recordings.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }
        let recording = try XCTUnwrap(store.recordings.first, "every segment is still saved")
        XCTAssertGreaterThan(RecordingStore.audioDuration(for: recording.fileURL), 5)
    }

    /// The 2-hour check-in, driven at test speed: it fires, "Keep Recording"
    /// clears it and pushes the next one out, and the recording keeps running
    /// throughout.
    func testLongRecordingCheckInFiresAndCanBeAcknowledged() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecCheckIn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let restore = forceMicOnlyCapture()
        defer { restore() }

        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "RecCheckIn-\(UUID().uuidString)")!)
        store.load()
        let recorder = AudioRecorder()
        recorder.attach(store: store)
        recorder.checkInIntervalOverride = 3

        recorder.startRecording()
        for _ in 0..<40 where !recorder.isRecording {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(recorder.isRecording, "recording never started — mic permission?")

        for _ in 0..<20 where recorder.pendingCheckIn == nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertNotNil(recorder.pendingCheckIn, "check-in never fired")
        XCTAssertTrue(recorder.isRecording, "a check-in must not stop the recording")

        recorder.acknowledgeCheckIn()
        XCTAssertNil(recorder.pendingCheckIn)
        // Acknowledging pushes the next one a full interval out.
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertNil(recorder.pendingCheckIn, "check-in re-fired too soon")
        XCTAssertTrue(recorder.isRecording)

        for _ in 0..<20 where recorder.pendingCheckIn == nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertNotNil(recorder.pendingCheckIn, "the next check-in must arrive")
        XCTAssertTrue(recorder.isRecording, "unanswered check-ins never stop a recording")

        recorder.stopRecordingFromCheckIn()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.pendingCheckIn)
    }

    /// Mic-only for unattended runs: the system-audio tap would raise a TCC
    /// prompt. Returns the restore closure.
    private func forceMicOnlyCapture() -> () -> Void {
        let key = "recordSystemAudio"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        return {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
