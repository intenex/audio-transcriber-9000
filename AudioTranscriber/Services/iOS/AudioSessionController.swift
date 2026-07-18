#if os(iOS)
import AVFoundation
import Foundation

/// Owns the AVAudioSession lifecycle on iOS (macOS has no session): category
/// switching for record vs playback, and interruption/route-change handling.
/// AVAudioSession itself is thread-safe; callbacks are delivered on main.
///
/// Policy (v1, deliberately conservative):
/// - Interruption or route loss while RECORDING → finalize-and-save via
///   `onRecordingInterrupted` (never convert formats mid-tap — historic crash
///   class; a seamless continuation file is documented future work).
/// - Interruption while PLAYING → stop playback (AVAudioPlayer state is cheap
///   to re-create; resume-on-end is a refinement).
final class AudioSessionController {
    static let shared = AudioSessionController()

    /// Recording must end (already-captured audio is finalized + saved).
    var onRecordingInterrupted: ((String) -> Void)?
    /// Playback should stop.
    var onPlaybackInterrupted: (() -> Void)?

    private(set) var isRecordingSessionActive = false

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: nil, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    func activateRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        isRecordingSessionActive = true
    }

    func activatePlayback() throws {
        // An active record session already permits playback.
        guard !isRecordingSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    func endRecordingSession() {
        isRecordingSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        guard type == .began else { return }
        if isRecordingSessionActive {
            onRecordingInterrupted?("interrupted by a call or another app")
        } else {
            onPlaybackInterrupted?()
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        // The input/output we were using disappeared (headset unplugged, …).
        // A mid-recording route change invalidates the tap format that the
        // AVAudioFile commonFormat pinning depends on — finalize and save.
        if isRecordingSessionActive {
            onRecordingInterrupted?("the microphone in use was disconnected")
        } else {
            onPlaybackInterrupted?()
        }
    }
}
#endif
