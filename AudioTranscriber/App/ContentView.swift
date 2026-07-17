import SwiftUI

struct ContentView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService
    @State private var selectedRecordingID: UUID? = nil
    @State private var showGlobalChat = false

    var selectedRecording: Recording? {
        store.recordings.first { $0.id == selectedRecordingID }
    }

    var body: some View {
        NavigationSplitView {
            RecordingListView(selectedRecordingID: $selectedRecordingID, showGlobalChat: $showGlobalChat)
        } detail: {
            if showGlobalChat {
                ChatSessionView(context: .global)
            } else if let recording = selectedRecording {
                TranscriptionView(recording: recording)
            } else {
                RecordingControlView()
            }
        }
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
