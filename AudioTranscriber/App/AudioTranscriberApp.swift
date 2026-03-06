import SwiftUI

@main
struct AudioTranscriberApp: App {
    @State private var audioRecorder = AudioRecorder()
    @State private var transcriptionService = TranscriptionService()
    @State private var llmService = LLMService()
    @State private var searchService = SearchService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(audioRecorder)
                .environment(transcriptionService)
                .environment(llmService)
                .environment(searchService)
                .onAppear {
                    audioRecorder.loadRecordings()
                    audioRecorder.requestMicPermission()
                    Task { await llmService.checkAvailability() }
                }
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio Files...") {
                    audioRecorder.importAudioFiles()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(llmService)
        }
    }
}
