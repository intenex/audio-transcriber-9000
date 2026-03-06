import SwiftUI

struct ContentView: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService
    @State private var selectedRecordingID: UUID? = nil
    @State private var showGlobalChat = false

    var selectedRecording: Recording? {
        audioRecorder.recordings.first { $0.id == selectedRecordingID }
    }

    var body: some View {
        NavigationSplitView {
            RecordingListView(selectedRecordingID: $selectedRecordingID, showGlobalChat: $showGlobalChat)
        } detail: {
            if showGlobalChat {
                GlobalChatView()
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
    }
}
