import Foundation

/// The one place the service graph is wired. Both platform scenes call this
/// from their root onAppear — the ORDER matters (docs/DEVELOPMENT.md):
/// migrator → store.load → speakerLibrary.attach → recorder.attach →
/// transcriptionService.attach + engine factory → auto-transcribe hook →
/// permissions/model refresh.
@MainActor
enum AppBootstrap {
    /// Retained for the app's lifetime (observes defaults + the KV store).
    private static var syncedDefaults: SyncedDefaults? = nil

    static func wire(recordingStore: RecordingStore,
                     audioRecorder: AudioRecorder,
                     transcriptionService: TranscriptionService,
                     chatService: ChatService,
                     modelManager: ModelManager,
                     speakerLibrary: SpeakerLibraryStore,
                     liveTranscriber: LiveTranscriber,
                     cloudSync: CloudSyncManager? = nil) {
        LegacySettingsMigrator.runOnce()
        // Promote device-local API keys to iCloud-synchronizable items when
        // signing allows (no-op otherwise; retried each launch).
        KeychainStore.shared.migrateLegacyItemsIfPossible()
        if syncedDefaults == nil {
            let synced = SyncedDefaults()
            synced.activate()
            syncedDefaults = synced
        }
        // The directory resolves synchronously (cheap) so everything wired
        // below sees the final value; the library SCAN runs off the main
        // thread — in cloud mode it reads the ubiquity container, and a
        // blocking scan there killed the iOS app on the launch watchdog.
        recordingStore.prepareStorageDirectory()
        Task { await recordingStore.loadAsync() }
        if let cloudSync {
            cloudSync.attach(recordingStore: recordingStore, speakerLibrary: speakerLibrary)
            Task { await cloudSync.bootstrap() }
        }
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
        // summary + smart auto-naming follow transcription. Optional silent-tail
        // trim runs FIRST (default OFF) so transcription sees the final file.
        recordingStore.onRecordingAdded = { [weak transcriptionService, weak recordingStore] id in
            let auto = UserDefaults.standard.object(forKey: "autoTranscribeNewRecordings") as? Bool ?? true
            let autoTrim = UserDefaults.standard.bool(forKey: "autoTrimTrailingSilence")
            guard autoTrim, let recordingStore else {
                if auto { transcriptionService?.enqueue(id) }
                return
            }
            Task { @MainActor in
                if let recording = recordingStore.recording(with: id) {
                    await recordingStore.trimTrailingSilence(recording, announce: false)
                }
                if auto { transcriptionService?.enqueue(id) }
            }
        }
        // Owns the notification-center delegate: the long-recording check-in
        // banner's Keep/Stop actions route back into the recorder.
        RecordingNotifier.shared.activate(recorder: audioRecorder)
        audioRecorder.requestMicPermission()
        modelManager.refreshStatus()
        Task { await chatService.checkLocalAvailability() }
    }
}
