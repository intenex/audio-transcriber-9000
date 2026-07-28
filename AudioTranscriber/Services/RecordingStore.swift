import AVFoundation
import Foundation
import Observation

/// Single source of truth for the recordings library: the in-memory array, the
/// `recordings.json` manifest in the storage directory, categories, and all
/// file lifecycle operations (import, delete, orphan adoption, legacy migration).
@Observable @MainActor
final class RecordingStore {
    var recordings: [Recording] = []
    var categories: [String] = []
    var errorMessage: String? = nil

    /// Fired for genuinely NEW recordings entering the library (finished
    /// recordings and imports — not migration/orphan adoption). Used for the
    /// auto-transcribe setting.
    var onRecordingAdded: ((UUID) -> Void)? = nil

    /// The file the recorder is actively streaming into (in the spool).
    /// The launch/reload spool sweep must never touch it.
    var activeRecordingURL: URL? = nil

    /// Recordings the transcription queue is running or holding right now,
    /// maintained by TranscriptionService. `load()` is not only a launch path —
    /// an iCloud change reloads the library at any moment — and its repair pass
    /// would otherwise roll a live job back to `.pending` from disk, hiding the
    /// progress UI while the job keeps running. In-memory truth wins for these.
    var inFlightTranscriptionIDs: Set<UUID> = []

    private(set) var storageDirectory: URL

    private let defaults: UserDefaults
    private let fixedStorageDirectory: URL?
    private var saveTask: Task<Void, Never>? = nil

    static let manifestFileName = "recordings.json"
    static let legacyDefaultsKey = "recordings"

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fixedStorageDirectory = storageDirectory
        self.storageDirectory = storageDirectory ?? Self.resolveStorageDirectory(defaults: defaults)
    }

    private static func resolveStorageDirectory(defaults: UserDefaults) -> URL {
        // Cloud mode: the ubiquity container's Documents IS the library.
        // The path is cached by CloudSyncManager.bootstrap (resolving it is a
        // blocking call that must not happen here on the main thread).
        if defaults.bool(forKey: CloudSyncManager.enabledKey),
           let cloudPath = defaults.string(forKey: CloudSyncManager.containerPathKey),
           !cloudPath.isEmpty,
           FileManager.default.fileExists(atPath: cloudPath) {
            return URL(fileURLWithPath: cloudPath, isDirectory: true)
        }
        if let custom = defaults.string(forKey: "storageDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("AudioTranscriber", isDirectory: true)
    }

    private var manifestURL: URL {
        // In cloud mode the manifest cache stays OUT of the synced tree —
        // it's debounce-churned and fully rebuildable from meta sidecars.
        if defaults.bool(forKey: CloudSyncManager.enabledKey) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AudioTranscriber/Cache", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("recordings-cloud.json")
        }
        return storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    /// Synced master list of categories (the manifest's copy is a local cache).
    private var libraryFileURL: URL {
        storageDirectory.appendingPathComponent("library.json")
    }

    // MARK: - Load / migrate

    func load() {
        storageDirectory = fixedStorageDirectory ?? Self.resolveStorageDirectory(defaults: defaults)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        // Salvage finalized-but-unmoved recordings from the spool (crash
        // between finalize and move); orphan adoption below picks them up.
        sweepSpool()

        var loaded: [Recording] = []
        var loadedCategories: [String] = []

        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? Self.decoder().decode(RecordingManifest.self, from: data) {
            loadedCategories = manifest.categories
            loaded = manifest.recordings.compactMap { $0.toRecording(storageDirectory: storageDirectory) }
        } else if let legacy = migrateLegacyDefaultsIfPresent() {
            loaded = legacy
        }

        // .meta.json is the durable metadata source; the manifest is a cache.
        // Applying it here is what makes edits from another synced device land.
        loaded = loaded.map { applyMetaIfPresent(to: $0) }

        // Drop entries whose audio file no longer exists. A not-downloaded
        // iCloud placeholder counts as existing — evicted ≠ deleted.
        loaded = loaded.filter { CloudPlaceholder.existsIncludingPlaceholder($0.fileURL) }

        // Orphan adoption: any .wav in the storage dir not in the manifest becomes a recording.
        let known = Set(loaded.map { $0.fileURL.standardizedFileURL.path })
        for orphan in orphanAudioFiles(excluding: known) {
            loaded.append(orphan)
        }

        // Migrate legacy in-library checkpoints (<stem>.partial.json) to the
        // device-local ID-keyed location.
        for recording in loaded {
            let legacy = recording.fileURL.deletingPathExtension().appendingPathExtension("partial.json")
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
            let target = recording.checkpointURL
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: legacy)
            } else {
                try? FileManager.default.moveItem(at: legacy, to: target)
            }
        }

        // Launch repair: a persisted .processing job was interrupted mid-run,
        // and .partial/.paused entries can go stale (their checkpoint is
        // consumed by a later successful run). A checkpoint on disk means
        // resumable work in flight; otherwise a completed transcript on disk
        // is the truth — never demote a finished recording.
        for idx in loaded.indices {
            let recording = loaded[idx]
            // A job this process is running right now is not stale state — it
            // simply hasn't written its checkpoint or transcript yet.
            if inFlightTranscriptionIDs.contains(recording.id) {
                loaded[idx].status = .processing
                continue
            }
            switch recording.status {
            case .processing:
                if FileManager.default.fileExists(atPath: recording.checkpointURL.path) {
                    loaded[idx].status = .partial
                } else if FileManager.default.fileExists(atPath: recording.markdownURL.path) {
                    loaded[idx].status = .done
                    loaded[idx].transcriptionURL = recording.markdownURL
                } else {
                    loaded[idx].status = .pending
                }
            case .partial, .paused:
                guard !FileManager.default.fileExists(atPath: recording.checkpointURL.path) else { break }
                if FileManager.default.fileExists(atPath: recording.markdownURL.path) {
                    loaded[idx].status = .done
                    loaded[idx].transcriptionURL = recording.markdownURL
                } else {
                    loaded[idx].status = .pending
                }
            default:
                break
            }
        }

        // Fill in missing file sizes (cheap stat calls, cached in the manifest).
        // Placeholders keep whatever the meta sidecar knew.
        for idx in loaded.indices where loaded[idx].fileSizeBytes == nil {
            let size = Self.fileSize(of: loaded[idx].fileURL)
            if size > 0 { loaded[idx].fileSizeBytes = size }
        }

        // Heal stale durations: data migrated from the old app carried
        // timer-accumulated durations that can be wildly wrong (a 2h07m file
        // stored as 4h05m). The audio header is the truth.
        for idx in loaded.indices {
            let actual = Self.audioDuration(for: loaded[idx].fileURL)
            guard actual > 0 else { continue }
            let stored = loaded[idx].duration
            if abs(stored - actual) > max(2.0, actual * 0.02) {
                NSLog("[RecordingStore] Healing stale duration for \(loaded[idx].fileURL.lastPathComponent): \(Int(stored))s -> \(Int(actual))s")
                loaded[idx].duration = actual
            }
        }

        // Categories: union of manifest cache, the synced library.json master
        // list, and whatever adopted recordings reference.
        if let data = try? Data(contentsOf: libraryFileURL),
           let file = try? Self.decoder().decode(LibraryFile.self, from: data) {
            for cat in file.categories where !loadedCategories.contains(cat) {
                loadedCategories.append(cat)
            }
        }
        for cat in loaded.compactMap(\.category).sorted() where !loadedCategories.contains(cat) {
            loadedCategories.append(cat)
        }

        recordings = loaded.sorted { $0.date > $1.date }
        categories = loadedCategories
        saveNow()

        // Backfill/refresh .meta.json sidecars (no-op when content is current).
        for recording in recordings {
            writeMetaIfChanged(for: recording)
        }
    }

    /// Re-resolve the storage directory from settings and reload the library
    /// (used when the user changes the storage location).
    func reloadFromStorageDirectory() {
        saveTask?.cancel()
        load()
    }

    private func migrateLegacyDefaultsIfPresent() -> [Recording]? {
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey),
              let saved = try? JSONDecoder().decode([Recording].self, from: data) else {
            return nil
        }
        // Leave the legacy key in place as a rollback backup; the presence of
        // recordings.json is the migration marker.
        return saved
    }

    private func orphanAudioFiles(excluding known: Set<String>) -> [Recording] {
        let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aac", "flac"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var orphans: [Recording] = []
        for url in contents where audioExtensions.contains(url.pathExtension.lowercased()) {
            let path = url.standardizedFileURL.path
            guard !known.contains(path) else { continue }
            // Skip crash artifacts from old builds (header-only WAVs).
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096 { continue }

            let markdown = url.deletingPathExtension().appendingPathExtension("md")
            let hasTranscript = FileManager.default.fileExists(atPath: markdown.path)

            var recording: Recording
            if let meta = Self.readMeta(besides: url) {
                // A .meta.json sibling restores full identity — same UUID,
                // name, category, attribution — so a rebuilt (or synced-in)
                // library is indistinguishable from the original.
                recording = Recording(id: meta.id, fileURL: url, date: meta.date,
                                      duration: meta.duration,
                                      name: meta.name, category: meta.category,
                                      engineUsed: meta.engineUsed,
                                      fileSizeBytes: meta.fileSizeBytes)
            } else {
                let creation = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                recording = Recording(fileURL: url, date: creation, duration: Self.audioDuration(for: url))
            }
            if hasTranscript {
                recording.transcriptionURL = markdown
                recording.status = .done
            }
            orphans.append(recording)
        }

        // Cloud mode: not-downloaded items exist only as hidden
        // ".<name>.icloud" stubs (skipsHiddenFiles misses them). Adopt via the
        // meta sidecar — identity, duration, and size without the content.
        let allEntries = (try? FileManager.default.contentsOfDirectory(
            at: storageDirectory, includingPropertiesForKeys: nil, options: []
        )) ?? []
        let adopted = Set(orphans.map { $0.fileURL.standardizedFileURL.path })
        for stub in allEntries {
            guard let realName = CloudPlaceholder.fileName(forPlaceholderName: stub.lastPathComponent) else { continue }
            let realURL = storageDirectory.appendingPathComponent(realName)
            let path = realURL.standardizedFileURL.path
            guard audioExtensions.contains(realURL.pathExtension.lowercased()),
                  !known.contains(path), !adopted.contains(path),
                  !FileManager.default.fileExists(atPath: realURL.path),
                  let meta = Self.readMeta(besides: realURL) else { continue }
            var recording = Recording(id: meta.id, fileURL: realURL, date: meta.date,
                                      duration: meta.duration,
                                      name: meta.name, category: meta.category,
                                      engineUsed: meta.engineUsed,
                                      fileSizeBytes: meta.fileSizeBytes)
            if CloudPlaceholder.existsIncludingPlaceholder(recording.markdownURL) {
                recording.transcriptionURL = recording.markdownURL
                recording.status = .done
            }
            orphans.append(recording)
        }
        return orphans
    }

    // MARK: - Spool

    /// Move a finalized spool file into the library (rename; copy+delete
    /// across volumes). On total failure the data stays in the spool and the
    /// spool URL is returned — never lose a finished recording.
    func finalizeRecordingFile(at spoolURL: URL) -> URL {
        let dest = uniqueURL(for: storageDirectory.appendingPathComponent(spoolURL.lastPathComponent))
        do {
            try FileManager.default.moveItem(at: spoolURL, to: dest)
            return dest
        } catch {
            do {
                try FileManager.default.copyItem(at: spoolURL, to: dest)
                try? FileManager.default.removeItem(at: spoolURL)
                return dest
            } catch {
                NSLog("[RecordingStore] Could not move recording into library: \(error)")
                errorMessage = "The recording was saved to a temporary location but could not be moved into the library: \(error.localizedDescription)"
                return spoolURL
            }
        }
    }

    /// Crash salvage: adopt finalized-but-unmoved recordings left in the spool.
    /// MUST never touch live capture files — the recorder streams the active
    /// recording's segments (`<stem>.segN.<ext>`) there, and load() can run
    /// mid-recording (cloud watcher reloads). Two guards: anything sharing the
    /// active recording's stem is the recorder's, and anything modified in the
    /// last 60 s is presumed live (a real crash leftover is stale by the next
    /// load; a growing capture file's mtime is always fresh).
    private func sweepSpool() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: SpoolLocation.directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        let activeStem = activeRecordingURL?.deletingPathExtension().lastPathComponent
        for url in contents {
            guard url != activeRecordingURL else { continue }
            if let activeStem, url.lastPathComponent.hasPrefix(activeStem) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let modified = values?.contentModificationDate,
               Date().timeIntervalSince(modified) < 60 {
                continue
            }
            let size = values?.fileSize ?? 0
            if size > 4096 {
                // An unfinalized container (interrupted stop/merge) carries
                // audio data but no index — unplayable. Set it aside instead
                // of showing a 0-second entry in the library.
                guard Self.audioDuration(for: url) > 0 else {
                    quarantineUnfinished(url)
                    continue
                }
                _ = finalizeRecordingFile(at: url)
            } else {
                // Header-only stubs and abandoned temp work files.
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Moves an unfinalized crash leftover out of the spool without deleting it.
    private func quarantineUnfinished(_ url: URL) {
        let directory = SpoolLocation.unfinishedDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueURL(for: directory.appendingPathComponent(url.lastPathComponent))
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            NSLog("[RecordingStore] Unfinalized leftover set aside: \(destination.lastPathComponent)")
        } catch {
            NSLog("[RecordingStore] Couldn't quarantine \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - Metadata sidecars

    private static func readMeta(besides audioURL: URL) -> RecordingMeta? {
        let metaURL = audioURL.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? Self.decoder().decode(RecordingMeta.self, from: data)
    }

    /// Overlay the durable sidecar metadata onto a manifest entry. The
    /// sidecar wins for identity and user-edited fields; runtime state
    /// (status, transcriptionURL, fileURL) stays with the entry.
    private func applyMetaIfPresent(to entry: Recording) -> Recording {
        guard let meta = Self.readMeta(besides: entry.fileURL) else { return entry }
        var merged = Recording(id: meta.id, fileURL: entry.fileURL, date: meta.date,
                               duration: meta.duration > 0 ? meta.duration : entry.duration,
                               transcriptionURL: entry.transcriptionURL, status: entry.status,
                               name: meta.name, category: meta.category,
                               engineUsed: meta.engineUsed,
                               fileSizeBytes: meta.fileSizeBytes ?? entry.fileSizeBytes)
        if merged.transcriptionURL == nil,
           FileManager.default.fileExists(atPath: merged.markdownURL.path) {
            merged.transcriptionURL = merged.markdownURL
        }
        return merged
    }

    /// Write `<stem>.meta.json` when its content differs from the recording
    /// (skipping no-ops keeps `updatedAt` an honest last-edit marker).
    private func writeMetaIfChanged(for recording: Recording) {
        let meta = RecordingMeta(recording: recording)
        if let existing = Self.readMeta(besides: recording.fileURL), meta.sameContent(as: existing) {
            return
        }
        if let data = try? Self.encoder().encode(meta) {
            try? AtomicFile.write(data, to: recording.metaURL)
        }
    }

    // MARK: - Save

    /// Debounced save — coalesces bursts of updates into one disk write.
    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let manifest = RecordingManifest(
            categories: categories,
            recordings: recordings.map { RecordingManifest.Entry(recording: $0, storageDirectory: storageDirectory) }
        )
        do {
            let data = try Self.encoder().encode(manifest)
            try AtomicFile.write(data, to: manifestURL)
        } catch {
            NSLog("[RecordingStore] Failed to save manifest: \(error)")
        }

        // Keep the synced categories master list current (skip no-op rewrites
        // so updatedAt stays an honest last-edit marker).
        let existing = (try? Data(contentsOf: libraryFileURL))
            .flatMap { try? Self.decoder().decode(LibraryFile.self, from: $0) }
        if existing?.categories != categories,
           let data = try? Self.encoder().encode(LibraryFile(categories: categories)) {
            try? AtomicFile.write(data, to: libraryFileURL)
        }
    }

    // MARK: - Mutations

    func insert(_ recording: Recording) {
        var entry = recording
        if entry.fileSizeBytes == nil {
            entry.fileSizeBytes = Self.fileSize(of: entry.fileURL)
        }
        recordings.insert(entry, at: 0)
        recordings.sort { $0.date > $1.date }
        writeMetaIfChanged(for: entry)
        save()
        onRecordingAdded?(entry.id)
    }

    func update(_ id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        let oldMetaURL = recordings[idx].metaURL
        mutate(&recordings[idx])
        // Compress-in-place swaps the audio extension; the meta sidecar keeps
        // the stem, but remove a stale copy if the stem ever changed.
        if recordings[idx].metaURL != oldMetaURL {
            try? FileManager.default.removeItem(at: oldMetaURL)
        }
        writeMetaIfChanged(for: recordings[idx])
        save()
    }

    func recording(with id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        // Deleting a not-downloaded item = removing its placeholder stub
        // (which deletes the cloud copy).
        try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: recording.fileURL))
        for sidecar in recording.allSidecarURLs {
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: sidecar))
        }
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    // MARK: - Categories

    func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !categories.contains(trimmed) else { return }
        categories.append(trimmed)
        save()
    }

    func renameCategory(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old, let idx = categories.firstIndex(of: old) else { return }
        if categories.contains(trimmed) {
            // Renaming onto an existing category = merge: drop the old name so
            // no duplicate entries end up in the sidebar/manifest.
            categories.remove(at: idx)
        } else {
            categories[idx] = trimmed
        }
        for rIdx in recordings.indices where recordings[rIdx].category == old {
            recordings[rIdx].category = trimmed
            writeMetaIfChanged(for: recordings[rIdx])
        }
        save()
    }

    func deleteCategory(_ name: String) {
        categories.removeAll { $0 == name }
        for idx in recordings.indices where recordings[idx].category == name {
            recordings[idx].category = nil
            writeMetaIfChanged(for: recordings[idx])
        }
        save()
    }

    // MARK: - Import

    /// File types worth converting to AAC on import (already-compressed
    /// formats like mp3/m4a are always copied as-is).
    static let compressibleExtensions: Set<String> = ["wav", "aiff", "aif", "caf", "flac"]

    enum ImportCompressionPolicy { case always, never, ask }

    /// Settings-driven policy for compress-on-import (the platform view layer
    /// decides how to "ask" — NSAlert on Mac, confirmationDialog on iOS).
    func resolveImportCompressionPolicy() -> ImportCompressionPolicy {
        switch defaults.string(forKey: "importCompression") {
        case "always": return .always
        case "never": return .never
        default: return .ask
        }
    }

    /// Size math for the compress-on-import prompt (pure; shared by both
    /// platforms' UIs).
    func importCompressionEstimate(for urls: [URL]) -> (originalBytes: Int64, compressedBytes: Int64, compressibleCount: Int) {
        let compressibles = urls.filter {
            Self.compressibleExtensions.contains($0.pathExtension.lowercased())
        }
        let originalBytes = compressibles.reduce(Int64(0)) { $0 + Self.fileSize(of: $1) }
        let totalSeconds = compressibles.reduce(0.0) { $0 + Self.audioDuration(for: $1) }
        let compressedBytes = Int64(AudioCompressor.Spec.storage.estimatedBytes(forSeconds: totalSeconds))
        return (originalBytes, compressedBytes, compressibles.count)
    }

    /// Platform-neutral import. `compress` applies only to compressible
    /// sources; already-compressed formats are always copied as-is.
    @discardableResult
    func importAudioFiles(urls: [URL], compress: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for sourceURL in urls {
                let doCompress = compress
                    && Self.compressibleExtensions.contains(sourceURL.pathExtension.lowercased())
                await self.importOne(sourceURL, compress: doCompress)
            }
        }
    }

    private func importOne(_ sourceURL: URL, compress: Bool) async {
        do {
            // Write into the spool first, then rename into the library — a
            // synced library must never see a growing file.
            let recording: Recording
            if compress {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let workURL = SpoolLocation.url(fileName: "import-\(UUID().uuidString).m4a")
                _ = try await AudioCompressor.compress(source: sourceURL, to: workURL, spec: .storage)
                let destURL = uniqueURL(for: storageDirectory.appendingPathComponent("\(stem).m4a"))
                try FileManager.default.moveItem(at: workURL, to: destURL)
                recording = Recording(fileURL: destURL, date: .now,
                                      duration: Self.audioDuration(for: destURL))
            } else {
                let workURL = SpoolLocation.url(fileName: "import-\(UUID().uuidString).\(sourceURL.pathExtension)")
                try FileManager.default.copyItem(at: sourceURL, to: workURL)
                let destURL = uniqueURL(for: storageDirectory.appendingPathComponent(sourceURL.lastPathComponent))
                try FileManager.default.moveItem(at: workURL, to: destURL)
                recording = Recording(fileURL: destURL, date: .now,
                                      duration: Self.audioDuration(for: destURL))
            }
            insert(recording)
        } catch {
            errorMessage = "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Compress in place

    /// Non-error notices (e.g. compression results) surfaced as an alert.
    var infoMessage: String? = nil

    /// Live conversion progress per recording (0…1); presence = converting.
    private(set) var compressingProgress: [UUID: Double] = [:]

    var compressingIDs: Set<UUID> { Set(compressingProgress.keys) }

    /// Recordings whose silent tail is being cut (presence = in progress).
    private(set) var trimmingIDs: Set<UUID> = []

    /// Drops the silent tail of a recording, in place: same URL and stem, so
    /// every sidecar keeps matching and transcript timings (which all precede
    /// the cut) stay valid. The replacement is written to the spool and
    /// duration-verified before it replaces the original — never the other way
    /// around.
    ///
    /// Returns true when something was actually trimmed. `announce: false`
    /// keeps the automatic post-recording pass quiet unless it fails.
    @discardableResult
    func trimTrailingSilence(_ recording: Recording, announce: Bool = true) async -> Bool {
        guard !trimmingIDs.contains(recording.id) else { return false }
        guard recording.fileURL != activeRecordingURL else {
            if announce { errorMessage = "That recording is still being captured." }
            return false
        }
        // The engine is reading this file right now; don't move the ground.
        if let current = self.recording(with: recording.id), current.status == .processing {
            if announce { errorMessage = "“\(recording.displayName)” is being transcribed — trim it when that finishes." }
            return false
        }
        trimmingIDs.insert(recording.id)
        defer { trimmingIDs.remove(recording.id) }

        let sourceURL = recording.fileURL
        let plan: TrailingSilenceTrimmer.Plan?
        do {
            plan = try await Task.detached(priority: .userInitiated) {
                try TrailingSilenceTrimmer.plan(for: sourceURL)
            }.value
        } catch {
            if announce { errorMessage = "Couldn't examine “\(recording.displayName)”: \(error.localizedDescription)" }
            return false
        }
        guard let plan else {
            if announce {
                infoMessage = "“\(recording.displayName)” has no silent tail worth trimming."
            }
            return false
        }

        let workURL = SpoolLocation.url(fileName: "trim-\(recording.id.uuidString).\(sourceURL.pathExtension)")
        try? FileManager.default.removeItem(at: workURL)
        do {
            try await TrailingSilenceTrimmer.trim(sourceURL, keepingFirst: plan.keepDuration, to: workURL)
            let newDuration = Self.audioDuration(for: workURL)
            let tolerance = max(2.0, plan.keepDuration * 0.02)
            guard newDuration > 0, abs(newDuration - plan.keepDuration) <= tolerance else {
                try? FileManager.default.removeItem(at: workURL)
                errorMessage = "Trim aborted for “\(recording.displayName)”: the trimmed file holds \(Int(newDuration))s instead of \(Int(plan.keepDuration))s. Original kept."
                return false
            }
            // Atomic in-place swap; the original only disappears once the
            // replacement is on disk and verified.
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: workURL)
            let newBytes = Self.fileSize(of: sourceURL)
            update(recording.id) {
                $0.duration = newDuration
                $0.fileSizeBytes = newBytes
            }
            if announce {
                let saved = ByteCountFormatter.string(fromByteCount: max(0, plan.originalBytes - newBytes),
                                                      countStyle: .file)
                infoMessage = "Trimmed \(Self.durationLabel(plan.trimmedDuration)) of silence from “\(recording.displayName)” — \(saved) saved."
            }
            NSLog("[RecordingStore] Trimmed \(Int(plan.trimmedDuration))s of silence from \(sourceURL.lastPathComponent)")
            return true
        } catch {
            try? FileManager.default.removeItem(at: workURL)
            errorMessage = "Couldn't trim “\(recording.displayName)”: \(error.localizedDescription). Original kept."
            return false
        }
    }

    // MARK: - Combine

    /// Recordings being folded into a combined file right now.
    private(set) var mergingIDs: Set<UUID> = []

    /// Joins `recordings` — in the order given — into one new recording.
    ///
    /// The combined file is written to the spool and its duration checked
    /// against the sum of the parts before anything enters the library; the
    /// originals are only removed if the caller asked for it, and only after
    /// the result is in place. The new recording is dated from the earliest
    /// part, because that is when the conversation actually happened.
    @discardableResult
    func combine(_ recordings: [Recording], name: String? = nil,
                 deleteOriginals: Bool = false,
                 format: RecordingFormat = .selected) async -> Recording? {
        guard recordings.count >= 2 else {
            errorMessage = RecordingMerger.MergeError.tooFewParts.localizedDescription
            return nil
        }
        for recording in recordings {
            if recording.fileURL == activeRecordingURL {
                errorMessage = "“\(recording.displayName)” is still being recorded."
                return nil
            }
            if recording.status == .processing || inFlightTranscriptionIDs.contains(recording.id) {
                errorMessage = "“\(recording.displayName)” is being transcribed — combine it when that finishes."
                return nil
            }
            if compressingProgress[recording.id] != nil || trimmingIDs.contains(recording.id)
                || mergingIDs.contains(recording.id) {
                errorMessage = "“\(recording.displayName)” is busy — try again in a moment."
                return nil
            }
            if CloudPlaceholder.isPlaceholderOnly(recording.fileURL) {
                errorMessage = "“\(recording.displayName)” hasn't been downloaded from iCloud yet."
                return nil
            }
        }

        let ids = Set(recordings.map(\.id))
        mergingIDs.formUnion(ids)
        defer { mergingIDs.subtract(ids) }

        let plan: RecordingMerger.Plan
        do {
            plan = try RecordingMerger.plan(for: recordings, format: format)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let workURL = SpoolLocation.url(fileName: "merge-\(UUID().uuidString).\(format.fileExtension)")
        do {
            try await RecordingMerger.merge(plan, to: workURL)
        } catch {
            try? FileManager.default.removeItem(at: workURL)
            errorMessage = "Couldn't combine the recordings: \(error.localizedDescription)"
            return nil
        }

        let earliest = recordings.map(\.date).min() ?? .now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let destURL = uniqueURL(for: storageDirectory
            .appendingPathComponent("recording_\(formatter.string(from: earliest)).\(format.fileExtension)"))
        do {
            try FileManager.default.moveItem(at: workURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: workURL)
            errorMessage = "Couldn't move the combined recording into the library: \(error.localizedDescription)"
            return nil
        }

        let duration = Self.audioDuration(for: destURL)
        var combined = Recording(fileURL: destURL, date: earliest, duration: duration)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        combined.name = (trimmedName?.isEmpty == false) ? trimmedName : nil
        combined.category = recordings.first?.category
        combined.fileSizeBytes = Self.fileSize(of: destURL)

        let partCount = recordings.count
        let partLabel = RecordingMerger.summary(for: plan)
        if deleteOriginals {
            // Only now that the combined file is on disk and verified.
            for recording in recordings { delete(recording) }
        }
        insert(combined)

        NSLog("[RecordingStore] Combined \(partCount) recordings into \(destURL.lastPathComponent) (\(Int(duration))s)")
        infoMessage = deleteOriginals
            ? "Combined \(partCount) recordings into one — \(partLabel). The originals were deleted."
            : "Combined \(partCount) recordings into one — \(partLabel). The originals were kept."
        return combined
    }

    /// "3 h 12 m" / "8 m" — for user-facing trim/skip messages.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) m" }
        if minutes > 0 { return "\(minutes) m" }
        return "\(total) s"
    }

    /// Converts an uncompressed recording to AAC in place: same file stem (so
    /// every sidecar keeps matching), duration-verified, original deleted only
    /// after the replacement checks out.
    func compressAudio(_ recording: Recording, spec: AudioCompressor.Spec = .storage) async {
        guard Self.compressibleExtensions.contains(recording.fileURL.pathExtension.lowercased()),
              compressingProgress[recording.id] == nil else { return }
        compressingProgress[recording.id] = 0
        defer { compressingProgress[recording.id] = nil }

        let destURL = recording.fileURL.deletingPathExtension().appendingPathExtension("m4a")
        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            errorMessage = "\(destURL.lastPathComponent) already exists."
            return
        }
        // Encode into the spool; only a verified, complete file is renamed
        // into the library (which may be synced).
        let workURL = SpoolLocation.url(fileName: "compress-\(recording.id.uuidString).m4a")
        try? FileManager.default.removeItem(at: workURL)

        let originalBytes = Self.fileSize(of: recording.fileURL)
        let recordingID = recording.id

        // Verify against the SOURCE FILE's actual duration — the manifest value
        // can be stale legacy-timer garbage (e.g. 14720s stored for a 7630s
        // file), and comparing against it aborted perfectly good conversions.
        let sourceDuration = Self.audioDuration(for: recording.fileURL)
        let referenceDuration = sourceDuration > 0 ? sourceDuration : recording.duration

        do {
            _ = try await AudioCompressor.compress(
                source: recording.fileURL, to: workURL, spec: spec,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        if self?.compressingProgress[recordingID] != nil {
                            self?.compressingProgress[recordingID] = fraction
                        }
                    }
                })
            let newDuration = Self.audioDuration(for: workURL)
            let tolerance = max(1.0, referenceDuration * 0.01)
            guard newDuration > 0, abs(newDuration - referenceDuration) <= tolerance else {
                try? FileManager.default.removeItem(at: workURL)
                errorMessage = "Compression aborted for \(recording.displayName): the converted file is \(Int(newDuration))s but the source contains \(Int(referenceDuration))s of audio. Original kept."
                return
            }
            try FileManager.default.moveItem(at: workURL, to: destURL)
            let originalURL = recording.fileURL
            let newBytes = Self.fileSize(of: destURL)
            update(recording.id) {
                $0.fileURL = destURL
                $0.duration = newDuration
                $0.fileSizeBytes = newBytes
            }
            try? FileManager.default.removeItem(at: originalURL)

            let before = ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)
            let after = ByteCountFormatter.string(fromByteCount: newBytes, countStyle: .file)
            let saved = originalBytes > 0 ? Int((1 - Double(newBytes) / Double(originalBytes)) * 100) : 0
            infoMessage = "Compressed “\(recording.displayName)”: \(before) → \(after) (\(saved)% smaller)."
        } catch {
            try? FileManager.default.removeItem(at: workURL)
            errorMessage = "Compression failed for \(recording.displayName): \(error.localizedDescription)"
        }
    }

    nonisolated static func fileSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem)_\(counter).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    nonisolated static func audioDuration(for url: URL) -> TimeInterval {
        // AVAudioFile is fast (header read) and not deprecated, unlike asset.duration.
        if let file = try? AVAudioFile(forReading: url) {
            return Double(file.length) / file.processingFormat.sampleRate
        }
        return 0
    }

    // MARK: - Coding helpers

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
