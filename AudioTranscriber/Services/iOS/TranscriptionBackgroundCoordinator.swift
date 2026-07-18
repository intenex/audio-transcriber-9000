#if os(iOS)
import UIKit

/// Keeps long transcriptions honest across iOS backgrounding. The existing
/// chunk-level checkpoint (~2 s granularity) is exactly the interruption
/// design to exploit: when the background-task grace expires we PAUSE (which
/// checkpoints), and when the app returns we auto-resume only what WE paused
/// — a user's own pause is never overridden.
///
/// Recording is untouched here: UIBackgroundModes(audio) + an active record
/// session keep the recorder running in the background natively.
@MainActor
final class TranscriptionBackgroundCoordinator {
    private weak var transcriptionService: TranscriptionService?
    private weak var audioRecorder: AudioRecorder?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var systemPausedIDs: Set<UUID> = []

    func attach(transcriptionService: TranscriptionService, audioRecorder: AudioRecorder) {
        self.transcriptionService = transcriptionService
        self.audioRecorder = audioRecorder
    }

    func appDidEnterBackground() {
        guard let service = transcriptionService, service.isTranscribing,
              audioRecorder?.isRecording != true else { return }
        // Ask for grace time; if it expires, checkpoint via pause.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "transcription-checkpoint") { [weak self] in
            Task { @MainActor in self?.checkpointNow() }
        }
    }

    func appDidBecomeActive() {
        endBackgroundTask()
        guard let service = transcriptionService else { return }
        // Resume only system pauses, in a stable order.
        for id in systemPausedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            service.enqueue(id)
        }
        systemPausedIDs = []
    }

    /// Internal (not private) so tests can drive the expiration path —
    /// UIKit's expiration handler can't be triggered synthetically.
    func checkpointNow() {
        guard let service = transcriptionService else { return endBackgroundTask() }
        if let activeID = service.activeRecordingID {
            systemPausedIDs.insert(activeID)
            service.pause(activeID)
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
#endif
