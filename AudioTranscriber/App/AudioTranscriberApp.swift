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
                .onAppear {
                    LegacySettingsMigrator.runOnce()
                    recordingStore.load()
                    speakerLibrary.attach(storageDirectory: recordingStore.storageDirectory)
                    audioRecorder.attach(store: recordingStore)
                    audioRecorder.liveTranscriber = liveTranscriber
                    transcriptionService.attach(store: recordingStore, chatService: chatService,
                                                speakerLibrary: speakerLibrary)
                    transcriptionService.cloudEngineFactory = { kind in
                        switch kind {
                        case .openAI: return OpenAITranscriptionEngine()
                        case .assemblyAI: return AssemblyAITranscriptionEngine()
                        case .local: return nil
                        }
                    }
                    // Auto-transcribe every new recording/import (default ON);
                    // summary + smart auto-naming follow transcription.
                    recordingStore.onRecordingAdded = { id in
                        let auto = UserDefaults.standard.object(forKey: "autoTranscribeNewRecordings") as? Bool ?? true
                        if auto {
                            transcriptionService.enqueue(id)
                        }
                    }
                    audioRecorder.requestMicPermission()
                    modelManager.refreshStatus()
                    Task { await chatService.checkLocalAvailability() }
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
        }
    }
}
