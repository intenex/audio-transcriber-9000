import AppKit
import Foundation
import Observation
import UserNotifications

/// Queue-based transcription orchestrator. Jobs run serially through a
/// pluggable TranscriptionEngine (local FluidAudio by default, cloud engines
/// by choice); progress/ETA are published for the UI; jobs are pausable
/// (checkpoint kept), cancellable (checkpoint discarded), and resumable.
@Observable @MainActor
final class TranscriptionService {

    struct QueuedJob: Equatable {
        let recordingID: UUID
        let engineKind: TranscriptionEngineKind
    }

    private enum StopIntent { case pause, cancel }

    // Published state
    private(set) var activeRecordingID: UUID? = nil
    private(set) var queue: [QueuedJob] = []
    var errorMessage: String? = nil

    // Back-compat surface used by existing views
    var isTranscribing: Bool { activeRecordingID != nil }
    private(set) var progress: String = ""
    private(set) var progressPercent: Double = 0
    private(set) var etaText: String? = nil

    // Wiring
    private weak var store: RecordingStore?
    private var chatService: ChatService? = nil
    private var speakerLibrary: SpeakerLibraryStore? = nil

    // Engines: local engine is retained so models stay loaded between jobs.
    private let localEngine = LocalFluidAudioEngine()
    /// Cloud engines are created per job via this factory (set up in app wiring).
    var cloudEngineFactory: ((TranscriptionEngineKind) -> (any TranscriptionEngine)?)? = nil

    private var workerTask: Task<Void, Never>? = nil
    private var jobTask: Task<TranscriptionOutput, Error>? = nil
    private var stopIntents: [UUID: StopIntent] = [:]
    private var sleepGuard: SleepGuard? = nil
    private var didRequestNotificationAuth = false

    func attach(store: RecordingStore, chatService: ChatService?, speakerLibrary: SpeakerLibraryStore? = nil) {
        self.store = store
        self.chatService = chatService
        self.speakerLibrary = speakerLibrary
    }

    /// Test hook: when set, used for every engine kind.
    var engineOverride: (any TranscriptionEngine)? = nil

    func engine(for kind: TranscriptionEngineKind) -> (any TranscriptionEngine)? {
        if let engineOverride { return engineOverride }
        if kind == .local { return localEngine }
        return cloudEngineFactory?(kind)
    }

    var localFluidEngine: LocalFluidAudioEngine { localEngine }

    // MARK: - Queue API

    func queuePosition(of recordingID: UUID) -> Int? {
        queue.firstIndex { $0.recordingID == recordingID }.map { $0 + 1 }
    }

    func isActive(_ recordingID: UUID) -> Bool { activeRecordingID == recordingID }

    func enqueue(_ recordingID: UUID, using kind: TranscriptionEngineKind = .local) {
        guard let store, let recording = store.recording(with: recordingID) else { return }
        guard recording.status.canStartTranscription else { return }
        guard !isActive(recordingID), queuePosition(of: recordingID) == nil else { return }

        requestNotificationAuthIfNeeded()
        store.update(recordingID) { $0.status = .processing }
        queue.append(QueuedJob(recordingID: recordingID, engineKind: kind))
        startWorkerIfNeeded()
    }

    /// Pause the active job (checkpoint kept for resume) or unqueue a waiting one.
    func pause(_ recordingID: UUID) {
        if isActive(recordingID) {
            stopIntents[recordingID] = .pause
            jobTask?.cancel()
        } else if let idx = queue.firstIndex(where: { $0.recordingID == recordingID }) {
            queue.remove(at: idx)
            let status = statusForExistingCheckpoint(recordingID)
            store?.update(recordingID) { $0.status = status }
        }
    }

    /// Cancel entirely: discard checkpoint, back to pending.
    func cancel(_ recordingID: UUID) {
        if isActive(recordingID) {
            stopIntents[recordingID] = .cancel
            jobTask?.cancel()
        } else if let idx = queue.firstIndex(where: { $0.recordingID == recordingID }) {
            queue.remove(at: idx)
            deleteCheckpoint(recordingID)
            store?.update(recordingID) { $0.status = .pending }
        }
    }

    private func statusForExistingCheckpoint(_ recordingID: UUID) -> TranscriptionStatus {
        guard let recording = store?.recording(with: recordingID) else { return .pending }
        return FileManager.default.fileExists(atPath: recording.checkpointURL.path) ? .paused : .pending
    }

    private func deleteCheckpoint(_ recordingID: UUID) {
        guard let recording = store?.recording(with: recordingID) else { return }
        try? FileManager.default.removeItem(at: recording.checkpointURL)
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainQueue()
            self?.workerTask = nil
        }
    }

    private func drainQueue() async {
        sleepGuard = SleepGuard(reason: "Transcribing audio")
        defer {
            sleepGuard = nil
            activeRecordingID = nil
            progress = ""
            progressPercent = 0
            etaText = nil
        }

        while !queue.isEmpty {
            let job = queue.removeFirst()
            await run(job)
        }
    }

    private func run(_ job: QueuedJob) async {
        guard let store, let recording = store.recording(with: job.recordingID) else { return }
        guard let engine = engine(for: job.engineKind) else {
            store.update(job.recordingID) { $0.status = .failed }
            errorMessage = "\(job.engineKind.displayName) isn't configured. Add its API key in Settings."
            return
        }

        activeRecordingID = job.recordingID
        progress = "Starting transcription…"
        progressPercent = 0
        etaText = nil

        let knownSpeakers = speakerLibrary?.referenceCandidates(limit: 4) ?? []
        let request = TranscriptionRequest(
            recordingID: recording.id,
            audioURL: recording.fileURL,
            durationSeconds: recording.duration,
            language: nil,
            checkpointURL: recording.checkpointURL,
            knownSpeakers: knownSpeakers
        )

        let task = Task { [weak self] () throws -> TranscriptionOutput in
            try await engine.transcribe(request) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.activeRecordingID == request.recordingID else { return }
                    self.progress = update.message
                    self.progressPercent = update.fractionComplete
                    self.etaText = update.etaSeconds.map { ETAFormatter.string($0) }
                }
            }
        }
        jobTask = task

        do {
            let output = try await task.value
            try finish(recording: recording, output: output, engine: engine)
            stopIntents[job.recordingID] = nil
        } catch is CancellationError {
            handleStop(job)
        } catch {
            // Engine may wrap the cancellation; honor an explicit stop intent first.
            if stopIntents[job.recordingID] != nil {
                handleStop(job)
            } else {
                store.update(job.recordingID) { $0.status = .failed }
                errorMessage = error.localizedDescription
            }
        }
        jobTask = nil
        activeRecordingID = nil
    }

    private func handleStop(_ job: QueuedJob) {
        let intent = stopIntents[job.recordingID] ?? .pause
        stopIntents[job.recordingID] = nil
        switch intent {
        case .pause:
            let status = statusForExistingCheckpoint(job.recordingID)
            store?.update(job.recordingID) { $0.status = status }
        case .cancel:
            deleteCheckpoint(job.recordingID)
            store?.update(job.recordingID) { $0.status = .pending }
        }
    }

    private func finish(recording: Recording, output: TranscriptionOutput,
                        engine: any TranscriptionEngine) throws {
        guard let store else { return }

        // Write sidecars in the existing formats.
        let markdown = MarkdownFormatter.format(result: output.result, recording: recording,
                                                engineAttribution: engine.modelDescription)
        try markdown.write(to: recording.markdownURL, atomically: true, encoding: .utf8)
        if let segmentData = try? JSONEncoder().encode(output.result.segments) {
            try? segmentData.write(to: recording.segmentsURL)
        }

        // Merge auto-identified speaker names, never overwriting user-set names.
        if !output.speakerNames.isEmpty {
            var names = (try? Data(contentsOf: recording.speakersURL))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            for (id, name) in output.speakerNames where names[id] == nil {
                names[id] = name
            }
            if let data = try? JSONEncoder().encode(names) {
                try? data.write(to: recording.speakersURL)
            }
        }

        // Let the speaker library match/annotate (voice enrollment, local engine).
        speakerLibrary?.handleTranscriptionCompleted(
            recording: recording, output: output)

        try? FileManager.default.removeItem(at: recording.checkpointURL)

        let attribution = engine.modelDescription
        store.update(recording.id) {
            $0.transcriptionURL = recording.markdownURL
            $0.status = .done
            $0.engineUsed = attribution
        }

        notifyCompletion(recording: recording)

        // Fire-and-forget auto-summarize.
        if UserDefaults.standard.object(forKey: "autoSummarize") as? Bool ?? true {
            Task { [weak self] in
                await self?.autoSummarize(markdown: markdown, recordingID: recording.id)
            }
        }
    }

    private func autoSummarize(markdown: String, recordingID: UUID) async {
        guard let chatService else { return }
        if chatService.activeProvider.id == .localMLX, !chatService.isLocalMLXAvailable {
            await chatService.checkLocalAvailability()
        }
        guard chatService.isActiveProviderReady,
              let store, let recording = store.recording(with: recordingID) else { return }

        do {
            let summary = try await SummarizationService.summarize(
                transcript: markdown,
                provider: chatService.activeProvider,
                namingContext: namingContext(for: recording))
            SummarizationService.saveSummary(summary, for: recording)
            if store.recording(with: recordingID)?.name == nil {
                store.update(recordingID) { $0.name = summary.generatedName }
            }
        } catch {
            // Non-fatal: summarization failure shouldn't affect transcription success.
        }
    }

    /// Builds context for smart auto-naming: who was identified in this call
    /// (via the voice library / speaker renames) and how past calls with the
    /// same people were named, so new names follow established series patterns
    /// (e.g. recurring therapy sessions keep a consistent naming style).
    func namingContext(for recording: Recording) -> String? {
        guard let speakerData = try? Data(contentsOf: recording.speakersURL),
              let names = try? JSONDecoder().decode([String: String].self, from: speakerData),
              !names.isEmpty else { return nil }

        let speakerNames = Array(Set(names.values)).sorted()
        var lines = ["Known speakers in this call: \(speakerNames.joined(separator: ", "))."]

        if let speakerLibrary, let store {
            var pastNames: [String] = []
            var seen = Set<String>()
            for enrolled in speakerLibrary.speakers
            where speakerNames.contains(where: { $0.caseInsensitiveCompare(enrolled.name) == .orderedSame }) {
                for pastID in enrolled.recordingIDs where pastID != recording.id {
                    guard let past = store.recording(with: pastID),
                          let pastName = past.name,
                          !seen.contains(pastName) else { continue }
                    seen.insert(pastName)
                    pastNames.append(pastName)
                }
            }
            if !pastNames.isEmpty {
                lines.append("Previous calls with these speakers were named: \(pastNames.suffix(12).joined(separator: "; ")).")
                lines.append("If this call is clearly part of the same series, follow the same naming pattern.")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Notifications

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func requestNotificationAuthIfNeeded() {
        guard !didRequestNotificationAuth, !isRunningTests else { return }
        didRequestNotificationAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompletion(recording: Recording) {
        guard !isRunningTests, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcription complete"
        content.body = recording.displayName
        content.sound = .default
        let request = UNNotificationRequest(identifier: recording.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
