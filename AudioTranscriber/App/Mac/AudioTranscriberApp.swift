import SwiftUI

@main
struct AudioTranscriberApp: App {
    @State private var recordingStore = RecordingStore()
    @State private var audioRecorder = AudioRecorder()
    @State private var transcriptionService = TranscriptionService()
    @State private var chatService = ChatService()
    @State private var modelManager = ModelManager()
    @State private var speakerLibrary = SpeakerLibraryStore()
    @State private var liveTranscriber = LiveTranscriber()
    @State private var cloudSync = CloudSyncManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingStore)
                .environment(audioRecorder)
                .environment(transcriptionService)
                .environment(chatService)
                .environment(modelManager)
                .environment(speakerLibrary)
                .environment(liveTranscriber)
                .environment(cloudSync)
                .onAppear {
                    AppBootstrap.wire(recordingStore: recordingStore,
                                      audioRecorder: audioRecorder,
                                      transcriptionService: transcriptionService,
                                      chatService: chatService,
                                      modelManager: modelManager,
                                      speakerLibrary: speakerLibrary,
                                      liveTranscriber: liveTranscriber,
                                      cloudSync: cloudSync)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    recordingStore.saveNow()
                }
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio Files...") {
                    recordingStore.importAudioFiles()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(recordingStore)
                .environment(audioRecorder)
                .environment(transcriptionService)
                .environment(chatService)
                .environment(modelManager)
                .environment(speakerLibrary)
                .environment(cloudSync)
        }
    }
}
