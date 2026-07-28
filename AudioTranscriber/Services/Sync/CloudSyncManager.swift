import Foundation
import Observation

/// App-facing sync coordinator: resolves the container once (off-main),
/// publishes per-file sync state for the UI, funnels external change batches
/// into store reloads, and runs the conflict sweep. Inert while disabled.
@Observable @MainActor
final class CloudSyncManager {
    static let enabledKey = "iCloudSyncEnabled"          // device-local
    static let containerPathKey = "iCloudContainerPath"  // device-local cache

    private(set) var containerDocumentsURL: URL? = nil
    private(set) var isCloudAvailable = false
    /// Bumped whenever item states may have changed (placeholder badges etc.).
    private(set) var stateVersion = 0

    private let engine: any SyncEngine
    private let defaults: UserDefaults
    private weak var recordingStore: RecordingStore?
    private weak var speakerLibrary: SpeakerLibraryStore?
    private var reloadDebounce: Task<Void, Never>? = nil

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    init(engine: any SyncEngine = ICloudSyncEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
    }

    func attach(recordingStore: RecordingStore, speakerLibrary: SpeakerLibraryStore) {
        self.recordingStore = recordingStore
        self.speakerLibrary = speakerLibrary
    }

    /// Resolve the container off-main and (when sync is on) start watching.
    /// Caches the resolved path in UserDefaults so RecordingStore's
    /// synchronous storage-dir resolution can use it at next launch.
    func bootstrap() async {
        isCloudAvailable = engine.isAvailable
        guard isCloudAvailable else { return }
        let engine = engine
        let url = await Task.detached(priority: .userInitiated) {
            engine.resolveContainerDocumentsURL()
        }.value
        containerDocumentsURL = url
        defaults.set(url?.path ?? "", forKey: Self.containerPathKey)

        if isEnabled, let url {
            // First launch after enabling on another device (or a cleared
            // cache): the store loaded against the local fallback — repoint
            // now that the container is known.
            if let store = recordingStore,
               store.storageDirectory.standardizedFileURL != url.standardizedFileURL {
                store.reloadFromStorageDirectory()
                speakerLibrary?.attach(storageDirectory: store.storageDirectory)
            }
            startWatching()
            sweepConflicts()
        }
    }

    func startWatching() {
        engine.startWatching { [weak self] changes in
            Task { @MainActor [weak self] in
                self?.handleExternalChanges(changes)
            }
        }
    }

    func stopWatching() {
        engine.stopWatching()
    }

    private func handleExternalChanges(_ changes: [SyncChange]) {
        guard isEnabled else { return }
        stateVersion += 1
        // Our own writes come back through the same notification. Reloading on
        // them is pure waste at best; at worst it rebuilds the library from
        // disk in the middle of an operation whose state lives in memory
        // (a running transcription's .processing status). Only genuinely
        // foreign changes are worth a reload.
        guard changes.contains(where: { !AtomicFile.isRecentSelfWrite($0.fileName) }) else { return }
        // Coalesce bursts into one reload.
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.recordingStore?.reloadFromStorageDirectory()
            self.speakerLibrary?.load()
            self.sweepConflicts()
            self.stateVersion += 1
        }
    }

    /// Resolve NSFileVersion conflicts across every known library file.
    func sweepConflicts() {
        guard let store = recordingStore else { return }
        for recording in store.recordings {
            ConflictResolver.resolveConflicts(at: recording.metaURL)
            ConflictResolver.resolveConflicts(at: recording.speakersURL)
            ConflictResolver.resolveConflicts(at: recording.markdownURL)
            ConflictResolver.resolveConflicts(at: recording.segmentsURL)
            ConflictResolver.resolveConflicts(at: recording.summaryURL)
            ConflictResolver.resolveConflicts(at: recording.chatURL)
            ConflictResolver.resolveConflicts(at: recording.fileURL)
        }
        ConflictResolver.resolveConflicts(at: store.storageDirectory.appendingPathComponent("library.json"))
        if let library = speakerLibrary {
            ConflictResolver.resolveConflicts(at: library.libraryURL)
        }
    }

    // MARK: - Per-item state

    func state(for recording: Recording) -> SyncItemState {
        guard isEnabled else { return .notTracked }
        return engine.itemState(for: recording.fileURL)
    }

    func requestDownload(_ recording: Recording) {
        try? engine.startDownload(recording.fileURL)
        stateVersion += 1
    }

    func evictAudio(_ recording: Recording) {
        try? engine.evict(recording.fileURL)
        stateVersion += 1
    }
}
