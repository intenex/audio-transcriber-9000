import AppKit
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
        if let custom = defaults.string(forKey: "storageDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("AudioTranscriber", isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    // MARK: - Load / migrate

    func load() {
        storageDirectory = fixedStorageDirectory ?? Self.resolveStorageDirectory(defaults: defaults)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        var loaded: [Recording] = []
        var loadedCategories: [String] = []

        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? Self.decoder().decode(RecordingManifest.self, from: data) {
            loadedCategories = manifest.categories
            loaded = manifest.recordings.compactMap { $0.toRecording(storageDirectory: storageDirectory) }
        } else if let legacy = migrateLegacyDefaultsIfPresent() {
            loaded = legacy
        }

        // Drop entries whose audio file no longer exists.
        loaded = loaded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }

        // Orphan adoption: any .wav in the storage dir not in the manifest becomes a recording.
        let known = Set(loaded.map { $0.fileURL.standardizedFileURL.path })
        for orphan in orphanAudioFiles(excluding: known) {
            loaded.append(orphan)
        }

        // Launch repair: a persisted .processing job was interrupted.
        for idx in loaded.indices where loaded[idx].status == .processing {
            let hasCheckpoint = FileManager.default.fileExists(atPath: loaded[idx].checkpointURL.path)
            loaded[idx].status = hasCheckpoint ? .partial : .pending
        }

        recordings = loaded.sorted { $0.date > $1.date }
        categories = loadedCategories
        saveNow()
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

            let creation = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let markdown = url.deletingPathExtension().appendingPathExtension("md")
            let hasTranscript = FileManager.default.fileExists(atPath: markdown.path)
            var recording = Recording(fileURL: url, date: creation, duration: Self.audioDuration(for: url))
            if hasTranscript {
                recording.transcriptionURL = markdown
                recording.status = .done
            }
            orphans.append(recording)
        }
        return orphans
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
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            NSLog("[RecordingStore] Failed to save manifest: \(error)")
        }
    }

    // MARK: - Mutations

    func insert(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        recordings.sort { $0.date > $1.date }
        save()
        onRecordingAdded?(recording.id)
    }

    func update(_ id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&recordings[idx])
        save()
    }

    func recording(with id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        for sidecar in recording.allSidecarURLs {
            try? FileManager.default.removeItem(at: sidecar)
        }
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    func showInFinder(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
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
        }
        save()
    }

    func deleteCategory(_ name: String) {
        categories.removeAll { $0 == name }
        for idx in recordings.indices where recordings[idx].category == name {
            recordings[idx].category = nil
        }
        save()
    }

    // MARK: - Import

    /// File types worth converting to AAC on import (already-compressed
    /// formats like mp3/m4a are always copied as-is).
    static let compressibleExtensions: Set<String> = ["wav", "aiff", "aif", "caf", "flac"]

    func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        panel.message = "Select audio files to import for transcription"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls

        let compressibles = urls.filter {
            Self.compressibleExtensions.contains($0.pathExtension.lowercased())
        }
        let shouldCompress = compressibles.isEmpty ? false : askImportCompression(for: compressibles)

        Task { [weak self] in
            guard let self else { return }
            for sourceURL in urls {
                let compress = shouldCompress
                    && Self.compressibleExtensions.contains(sourceURL.pathExtension.lowercased())
                await self.importOne(sourceURL, compress: compress)
            }
        }
    }

    private func importOne(_ sourceURL: URL, compress: Bool) async {
        do {
            let recording: Recording
            if compress {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let destURL = uniqueURL(for: storageDirectory.appendingPathComponent("\(stem).m4a"))
                _ = try await AudioCompressor.compress(source: sourceURL, to: destURL, spec: .storage)
                recording = Recording(fileURL: destURL, date: .now,
                                      duration: Self.audioDuration(for: destURL))
            } else {
                let destURL = uniqueURL(for: storageDirectory.appendingPathComponent(sourceURL.lastPathComponent))
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                recording = Recording(fileURL: destURL, date: .now,
                                      duration: Self.audioDuration(for: destURL))
            }
            insert(recording)
        } catch {
            errorMessage = "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Resolve the import-compression choice: settings can force always/never,
    /// default is to ask per batch with an estimated size comparison.
    private func askImportCompression(for files: [URL]) -> Bool {
        switch defaults.string(forKey: "importCompression") {
        case "always": return true
        case "never": return false
        default: break
        }

        let originalBytes = files.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let totalSeconds = files.reduce(0.0) { $0 + Self.audioDuration(for: $1) }
        let compressedBytes = Int64(AudioCompressor.Spec.storage.estimatedBytes(forSeconds: totalSeconds))

        let alert = NSAlert()
        alert.messageText = "Compress imported audio?"
        alert.informativeText = """
        \(files.count) file\(files.count == 1 ? "" : "s") can be converted to high-quality AAC:
        \(ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)) → ~\(ByteCountFormatter.string(fromByteCount: compressedBytes, countStyle: .file)).
        Quality remains excellent for listening and transcription. Originals are not modified.
        """
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Keep Original Format")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Compress in place

    /// Recordings currently being converted (UI shows progress / disables actions).
    private(set) var compressingIDs: Set<UUID> = []

    /// Converts an uncompressed recording to AAC in place: same file stem (so
    /// every sidecar keeps matching), duration-verified, original deleted only
    /// after the replacement checks out.
    func compressAudio(_ recording: Recording) async {
        guard Self.compressibleExtensions.contains(recording.fileURL.pathExtension.lowercased()),
              !compressingIDs.contains(recording.id) else { return }
        compressingIDs.insert(recording.id)
        defer { compressingIDs.remove(recording.id) }

        let destURL = recording.fileURL.deletingPathExtension().appendingPathExtension("m4a")
        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            errorMessage = "\(destURL.lastPathComponent) already exists."
            return
        }

        do {
            _ = try await AudioCompressor.compress(source: recording.fileURL, to: destURL, spec: .storage)
            let newDuration = Self.audioDuration(for: destURL)
            let tolerance = max(1.0, recording.duration * 0.01)
            guard newDuration > 0, abs(newDuration - recording.duration) <= tolerance else {
                try? FileManager.default.removeItem(at: destURL)
                errorMessage = "Compression aborted for \(recording.displayName): duration mismatch (\(Int(newDuration))s vs \(Int(recording.duration))s). Original kept."
                return
            }
            let originalURL = recording.fileURL
            update(recording.id) {
                $0.fileURL = destURL
                $0.duration = newDuration
            }
            try? FileManager.default.removeItem(at: originalURL)
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            errorMessage = "Compression failed for \(recording.displayName): \(error.localizedDescription)"
        }
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
