import Foundation

/// "Enable iCloud Sync": compress legacy WAVs, copy the library into the
/// container, verify, then repoint the store. Every per-file step is
/// idempotent (skip-if-present), the store is repointed only at the END, and
/// the old local library is left in place as a backup — an abort or crash at
/// any point leaves a fully working local setup.
@MainActor
enum LibraryMigrator {
    enum MigrationError: LocalizedError {
        case containerUnavailable
        case busy
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                return "iCloud isn't available. Sign into iCloud (with iCloud Drive on) and try again."
            case .busy:
                return "Finish or pause recording/transcription before enabling sync."
            case .verificationFailed(let detail):
                return "Migration verification failed: \(detail). Nothing was switched over; your library is untouched."
            }
        }
    }

    /// Runs the full migration. `status` receives human-readable step updates.
    static func enableSync(store: RecordingStore,
                           speakerLibrary: SpeakerLibraryStore,
                           cloudSync: CloudSyncManager,
                           isBusy: Bool,
                           status: @escaping (String) -> Void) async throws {
        guard !isBusy else { throw MigrationError.busy }
        guard let containerDocs = cloudSync.containerDocumentsURL else {
            throw MigrationError.containerUnavailable
        }
        let sourceDir = store.storageDirectory
        guard sourceDir.standardizedFileURL != containerDocs.standardizedFileURL else {
            return // already there
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: containerDocs, withIntermediateDirectories: true)

        // 1. Compress legacy uncompressed recordings (in place, verified swap).
        let compressibles = store.recordings.filter {
            RecordingStore.compressibleExtensions.contains($0.fileURL.pathExtension.lowercased())
        }
        for (index, recording) in compressibles.enumerated() {
            try Task.checkCancellation()
            status("Compressing \(recording.displayName) (\(index + 1) of \(compressibles.count))…")
            await store.compressAudio(recording)
        }

        // 2. Copy audio + sidecars (skip files already present with the same
        //    size, so an aborted run resumes instead of re-uploading).
        let recordings = store.recordings
        for (index, recording) in recordings.enumerated() {
            try Task.checkCancellation()
            status("Copying \(recording.displayName) (\(index + 1) of \(recordings.count))…")
            try copyIfNeeded(recording.fileURL, into: containerDocs)
            for sidecar in recording.allSidecarURLs where sidecar != recording.checkpointURL {
                try? copyIfNeeded(sidecar, into: containerDocs)
            }
        }

        status("Copying categories, chats, and speaker voices…")
        try? copyIfNeeded(sourceDir.appendingPathComponent("library.json"), into: containerDocs)
        try? copyIfNeeded(sourceDir.appendingPathComponent(".global-chat.json"), into: containerDocs)
        try copyTreeIfNeeded(sourceDir.appendingPathComponent("SpeakerLibrary", isDirectory: true),
                             to: containerDocs.appendingPathComponent("SpeakerLibrary", isDirectory: true))

        // 3. Verify: every recording's audio landed with matching size, and
        //    its meta decodes with the same identity. Pure checks — no store
        //    writes into the container before the switch.
        status("Verifying copied library…")
        for recording in recordings {
            try Task.checkCancellation()
            let dest = containerDocs.appendingPathComponent(recording.fileURL.lastPathComponent)
            guard fm.fileExists(atPath: dest.path),
                  RecordingStore.fileSize(of: dest) == RecordingStore.fileSize(of: recording.fileURL) else {
                throw MigrationError.verificationFailed("\(recording.fileURL.lastPathComponent) did not copy completely")
            }
            let metaDest = dest.deletingPathExtension().appendingPathExtension("meta.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: metaDest),
                  let meta = try? decoder.decode(RecordingMeta.self, from: data),
                  meta.id == recording.id else {
                throw MigrationError.verificationFailed("metadata for \(recording.displayName) is missing or mismatched")
            }
        }

        // 4. Repoint: from here on the container IS the library. The old
        //    directory stays untouched as a backup (and the storageDirectory
        //    setting still points at it, so disabling sync returns there).
        status("Switching to the iCloud library…")
        cloudSync.isEnabled = true
        store.reloadFromStorageDirectory()
        speakerLibrary.attach(storageDirectory: store.storageDirectory)
        cloudSync.startWatching()
        status("iCloud sync is on.")
    }

    /// Turn sync off: repoint back to the previous local library. Files
    /// already in iCloud stay there (nothing is deleted).
    static func disableSync(store: RecordingStore,
                            speakerLibrary: SpeakerLibraryStore,
                            cloudSync: CloudSyncManager) {
        cloudSync.stopWatching()
        cloudSync.isEnabled = false
        store.reloadFromStorageDirectory()
        speakerLibrary.attach(storageDirectory: store.storageDirectory)
    }

    // MARK: - Copy helpers

    private static func copyIfNeeded(_ source: URL, into directory: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            if RecordingStore.fileSize(of: dest) == RecordingStore.fileSize(of: source) { return }
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
    }

    private static func copyTreeIfNeeded(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = dest.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                if fm.fileExists(atPath: target.path) {
                    if RecordingStore.fileSize(of: target) == RecordingStore.fileSize(of: item) { continue }
                    try fm.removeItem(at: target)
                }
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}
