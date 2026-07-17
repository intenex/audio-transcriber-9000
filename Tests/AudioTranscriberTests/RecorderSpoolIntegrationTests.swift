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
}
