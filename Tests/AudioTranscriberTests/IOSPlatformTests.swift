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
