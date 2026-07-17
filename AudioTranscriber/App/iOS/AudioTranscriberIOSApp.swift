#if os(iOS)
import SwiftUI

@main
struct AudioTranscriberIOSApp: App {
    @State private var recordingStore = RecordingStore()
    @State private var audioRecorder = AudioRecorder()
    @State private var transcriptionService = TranscriptionService()
    @State private var chatService = ChatService()
    @State private var modelManager = ModelManager()
    @State private var speakerLibrary = SpeakerLibraryStore()
    @State private var liveTranscriber = LiveTranscriber()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recordingStore)
                .environment(audioRecorder)
                .environment(transcriptionService)
                .environment(chatService)
                .environment(modelManager)
                .environment(speakerLibrary)
                .environment(liveTranscriber)
                .onAppear {
                    AppBootstrap.wire(recordingStore: recordingStore,
                                      audioRecorder: audioRecorder,
                                      transcriptionService: transcriptionService,
                                      chatService: chatService,
                                      modelManager: modelManager,
                                      speakerLibrary: speakerLibrary,
                                      liveTranscriber: liveTranscriber)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS has no willTerminate equivalent worth relying on —
            // backgrounding is the save point.
            if phase == .background {
                recordingStore.saveNow()
            }
        }
    }
}
#endif
