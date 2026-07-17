import SwiftUI

@main
struct AudioTranscriberApp: App {
    @State private var recordingStore = RecordingStore()
    @State private var audioRecorder = AudioRecorder()
    @State private var transcriptionService = TranscriptionService()
    @State private var llmService = LLMService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingStore)
                .environment(audioRecorder)
                .environment(transcriptionService)
                .environment(llmService)
                .onAppear {
                    recordingStore.load()
                    audioRecorder.attach(store: recordingStore)
                    audioRecorder.requestMicPermission()
                    Task { await llmService.checkAvailability() }
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
                .environment(llmService)
        }
    }
}
