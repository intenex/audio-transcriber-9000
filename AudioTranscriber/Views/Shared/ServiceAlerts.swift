import SwiftUI

/// Surfaces the four service error/info channels as alerts. Both platform
/// roots apply this — a silent failure channel is how "compression died at
/// 1.8 MB with no message" happened once.
struct ServiceAlertsModifier: ViewModifier {
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: .constant(audioRecorder.errorMessage != nil)) {
                Button("OK") { audioRecorder.errorMessage = nil }
            } message: {
                Text(audioRecorder.errorMessage ?? "")
            }
            .alert("Transcription Error", isPresented: .constant(transcriptionService.errorMessage != nil)) {
                Button("OK") { transcriptionService.errorMessage = nil }
            } message: {
                Text(transcriptionService.errorMessage ?? "")
            }
            .alert("Library Error", isPresented: .constant(store.errorMessage != nil)) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .alert("Done", isPresented: .constant(store.infoMessage != nil)) {
                Button("OK") { store.infoMessage = nil }
            } message: {
                Text(store.infoMessage ?? "")
            }
            #if os(macOS)
            // One window, no competing sheets — the root can own this alert.
            // iOS attaches it per-screen instead (a fullScreenCover would
            // swallow a root-level presentation).
            .recordingCheckInAlert()
            #endif
    }
}

/// "You've been recording for 2h — keep going?" The same question the
/// notification banner asks, for when the app IS in front.
struct RecordingCheckInAlert: ViewModifier {
    @Environment(AudioRecorder.self) private var audioRecorder
    /// False on screens that are currently covered by another presentation.
    var enabled: Bool = true

    func body(content: Content) -> some View {
        content
            .alert("Still recording?",
                   isPresented: .constant(enabled && audioRecorder.pendingCheckIn != nil)) {
                // "Keep Recording" carries the cancel role on purpose: without
                // one, SwiftUI synthesizes its own Cancel button that would
                // dismiss the alert without answering (and, against a constant
                // binding, leave it stuck re-presenting). Escaping the alert
                // must mean "keep going" — never end a live recording.
                Button("Keep Recording", role: .cancel) { audioRecorder.acknowledgeCheckIn() }
                Button("Stop & Save", role: .destructive) { audioRecorder.stopRecordingFromCheckIn() }
            } message: {
                Text("This recording has been running for \(RecordingNotifier.durationText(audioRecorder.pendingCheckIn?.elapsed ?? 0)).")
            }
    }
}

extension View {
    func serviceAlerts() -> some View {
        modifier(ServiceAlertsModifier())
    }

    func recordingCheckInAlert(enabled: Bool = true) -> some View {
        modifier(RecordingCheckInAlert(enabled: enabled))
    }
}
