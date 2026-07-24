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

    /// The record screen is showing — the big timer is already visible there.
    private var isOnRecordScreen: Bool {
        !showGlobalChat && selectedRecording == nil
    }

    var body: some View {
        NavigationSplitView {
            RecordingListView(selectedRecordingID: $selectedRecordingID, showGlobalChat: $showGlobalChat)
        } detail: {
            Group {
                if showGlobalChat {
                    ChatSessionView(context: .global)
                } else if let recording = selectedRecording {
                    TranscriptionView(recording: recording)
                } else {
                    RecordingControlView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // A live recording stays visible (timer + source + stop) no
                // matter which page is open.
                if (audioRecorder.isRecording || audioRecorder.isFinalizingRecording) && !isOnRecordScreen {
                    RecordingStatusBar {
                        showGlobalChat = false
                        selectedRecordingID = nil
                    }
                }
            }
        }
        .serviceAlerts()
    }
}
