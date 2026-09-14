#if os(iOS)
import AVFoundation
import Foundation

/// Owns the AVAudioSession lifecycle on iOS (macOS has no session): category
/// switching for record vs playback, and interruption/route-change handling.
/// AVAudioSession itself is thread-safe; callbacks are delivered on main.
///
/// Policy (v1, deliberately conservative):
/// - Interruption or route loss while RECORDING → pause and preserve via
///   `onRecordingInterrupted`; resuming reopens the input and keeps the same CAF.
/// - Interruption while PLAYING → stop playback (AVPlayer state is cheap
///   to re-create; resume-on-end is a refinement).
final class AudioSessionController {
    static let shared = AudioSessionController()

    /// Recording must pause (already-captured audio is synchronized and preserved).
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
        // input converter depends on — pause before rebuilding on resume.
        if isRecordingSessionActive {
            onRecordingInterrupted?("the microphone in use was disconnected")
        } else {
            onPlaybackInterrupted?()
        }
    }
}
#endif
