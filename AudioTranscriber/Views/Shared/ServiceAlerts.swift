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
    }
}

extension View {
    func serviceAlerts() -> some View {
        modifier(ServiceAlertsModifier())
    }
}
