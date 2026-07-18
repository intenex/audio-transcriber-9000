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
        .serviceAlerts()
    }
}
