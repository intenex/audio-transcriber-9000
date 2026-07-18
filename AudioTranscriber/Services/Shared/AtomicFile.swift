import Foundation

/// Single choke point for whole-file writes into the library (manifest,
/// sidecars, speaker library, checkpoints). Always atomic-replace: a reader
/// (or a sync agent uploading the folder) can never observe a partial file.
/// When iCloud sync lands, this is the one place that grows an
/// NSFileCoordinator branch for in-container URLs.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        // Inside the active iCloud container, writes go through
        // NSFileCoordinator(.forReplacing) so the sync daemon never observes
        // a torn replace. (No NSFilePresenter — NSMetadataQuery drives change
        // detection; presenters are deadlock-prone here.)
        if isInActiveCloudContainer(url) {
            var coordinatorError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forReplacing, error: &coordinatorError
            ) { actualURL in
                do { try data.write(to: actualURL, options: .atomic) } catch { writeError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let writeError { throw writeError }
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private static func isInActiveCloudContainer(_ url: URL) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: CloudSyncManager.enabledKey),
              let path = defaults.string(forKey: CloudSyncManager.containerPathKey),
              !path.isEmpty else { return false }
        return url.standardizedFileURL.path.hasPrefix(path + "/")
    }

    static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
