// iOS-only: AVAudioSession + idle-timer behavior (macOS has neither).
#if os(iOS)
import AVFoundation
import UIKit
import XCTest
@testable import AudioTranscriber

final class AudioSessionControllerTests: XCTestCase {
    override func tearDown() {
        AudioSessionController.shared.endRecordingSession()
        super.tearDown()
    }

    func testActivateRecordingSetsPlayAndRecord() throws {
        try AudioSessionController.shared.activateRecording()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        XCTAssertTrue(AudioSessionController.shared.isRecordingSessionActive)
        // Idempotent — a second activation must not throw.
        try AudioSessionController.shared.activateRecording()
    }

    func testActivatePlaybackIsNoOpWhileRecordingSessionActive() throws {
        try AudioSessionController.shared.activateRecording()
        try AudioSessionController.shared.activatePlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord,
                       "playback activation must not downgrade an active record session")

        AudioSessionController.shared.endRecordingSession()
        try AudioSessionController.shared.activatePlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }
}

@MainActor
final class BackgroundPauseResumeTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!
    private var service: TranscriptionService!
    private var coordinator: TranscriptionBackgroundCoordinator!
    private var recorder: AudioRecorder!
    private var checkpointCleanupIDs: [UUID] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BgTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "BgTests-\(UUID().uuidString)")!)
        store.load()
        service = TranscriptionService()
        service.attach(store: store, chatService: nil)
        recorder = AudioRecorder()
        coordinator = TranscriptionBackgroundCoordinator()
        coordinator.attach(transcriptionService: service, audioRecorder: recorder)
    }

    override func tearDown() async throws {
        for id in checkpointCleanupIDs {
            try? FileManager.default.removeItem(at: CheckpointLocation.url(for: id))
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func addRecording(_ name: String) -> Recording {
        let url = tempDir.appendingPathComponent("\(name).wav")
        try? Data(count: 8192).write(to: url)
        let recording = Recording(fileURL: url, date: .now, duration: 60)
        checkpointCleanupIDs.append(recording.id)
        store.insert(recording)
        return recording
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testExpirationPausesActiveJobAndForegroundResumesIt() async {
        let recording = addRecording("bg")
        service.engineOverride = MockTranscriptionEngine { request in
            try Data("{}".utf8).write(to: request.checkpointURL)
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }
        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }

        coordinator.appDidEnterBackground()
        coordinator.checkpointNow()   // simulate grace expiry
        await waitUntil { self.store.recording(with: recording.id)?.status == .paused }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .paused)
        XCTAssertTrue(coordinator.systemPausedIDs.contains(recording.id))

        coordinator.appDidBecomeActive()
        XCTAssertTrue(coordinator.systemPausedIDs.isEmpty)
        await waitUntil { self.service.isActive(recording.id) || self.service.queuePosition(of: recording.id) != nil }
        XCTAssertTrue(service.isActive(recording.id) || service.queuePosition(of: recording.id) != nil,
                      "system-paused job must auto-resume on foreground")
        service.pause(recording.id)   // stop the mock job for teardown
    }

    func testUserPauseIsNeverAutoResumed() async {
        let recording = addRecording("userpause")
        service.engineOverride = MockTranscriptionEngine { request in
            try Data("{}".utf8).write(to: request.checkpointURL)
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }
        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }

        service.pause(recording.id)   // the USER paused
        await waitUntil { self.store.recording(with: recording.id)?.status == .paused }

        coordinator.appDidEnterBackground()
        coordinator.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.recording(with: recording.id)?.status, .paused,
                       "a user pause must survive a background/foreground cycle")
    }

    func testBackgroundingWhileRecordingDoesNothing() async {
        let recording = addRecording("rec")
        service.engineOverride = MockTranscriptionEngine { _ in
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }
        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }

        recorder.isRecording = true   // background audio keeps everything alive
        coordinator.appDidEnterBackground()   // must no-op: no background task armed
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(service.isActive(recording.id),
                      "no checkpoint task while recording — background audio keeps the app running")
        XCTAssertTrue(coordinator.systemPausedIDs.isEmpty)
        recorder.isRecording = false
        service.pause(recording.id)
    }
}

@MainActor
final class SleepGuardRefcountTests: XCTestCase {
    private func drainMainQueue() async {
        // SleepGuard mutates state via Task { @MainActor } hops.
        for _ in 0..<3 { await Task.yield() }
    }

    func testTwoGuardsKeepIdleTimerDisabledUntilBothReleased() async {
        UIApplication.shared.isIdleTimerDisabled = false

        var recorderGuard: SleepGuard? = SleepGuard(reason: "recording")
        var transcriberGuard: SleepGuard? = SleepGuard(reason: "transcribing")
        await drainMainQueue()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        recorderGuard = nil
        await drainMainQueue()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled,
                      "one holder remaining must keep the device awake")

        transcriberGuard = nil
        await drainMainQueue()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        _ = recorderGuard; _ = transcriberGuard
    }
}
#endif
