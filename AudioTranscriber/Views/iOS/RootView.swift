#if os(iOS)
import SwiftUI

/// iOS root: navigation + the shared service-error alert surface.
struct RootView: View {
    var body: some View {
        NavigationStack {
            RecordingsHomeView()
        }
        .serviceAlerts()
    }
}

/// Full-screen record surface hosting the shared RecordingControlView.
/// Dismissal is blocked while recording — stop first, then leave.
struct RecordSheet: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecordingControlView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .disabled(audioRecorder.isRecording)
                    }
                }
        }
        .recordingCheckInAlert()
        .interactiveDismissDisabled(audioRecorder.isRecording)
    }
}
#endif
