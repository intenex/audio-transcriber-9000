import Foundation

/// Per-file sync status as shown in the UI.
enum SyncItemState: Equatable {
    case notTracked            // local-only mode, or file outside the container
    case placeholder           // cloud item not downloaded (.<name>.icloud stub)
    case downloading(Double)   // 0…1
    case current               // content local and up to date
    case uploading
}

/// An externally observed change inside the synced library.
struct SyncChange: Equatable {
    enum Kind: Equatable { case added, changed, removed }
    let kind: Kind
    let fileName: String       // last path component within the library
}

/// Everything the app needs from "a synced folder", abstracted so ALL sync
/// logic is testable against a plain local directory (LocalFolderSyncEngine).
/// The real implementation is ICloudSyncEngine (ubiquity container +
/// NSMetadataQuery). Deliberately NO NSFilePresenter — deadlock-prone and
/// unnecessary when every write is a whole-file atomic replace.
protocol SyncEngine: AnyObject {
    /// Signed in + entitlements resolve a container.
    var isAvailable: Bool { get }

    /// The container's Documents directory. Blocking on first call —
    /// MUST be resolved off the main thread; callers cache the result.
    func resolveContainerDocumentsURL() -> URL?

    func startDownload(_ url: URL) throws
    func evict(_ url: URL) throws
    func itemState(for url: URL) -> SyncItemState

    /// Begin observing external changes (debounced batches).
    func startWatching(onChanges: @escaping @Sendable ([SyncChange]) -> Void)
    func stopWatching()
}

/// Maps a possibly-placeholder URL pair. iCloud represents not-downloaded
/// items as hidden ".<name>.icloud" stubs next to where the file would be.
enum CloudPlaceholder {
    static func placeholderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
    }

    /// The real file name for a placeholder stub name, or nil.
    static func fileName(forPlaceholderName name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// True when the file's content is local OR a placeholder stands in for it.
    static func existsIncludingPlaceholder(_ fileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: placeholderURL(for: fileURL).path)
    }

    /// True when the bytes are on THIS device.
    ///
    /// A current iCloud item usually keeps its real name and turns *dataless*:
    /// it stats normally, reports its full size, and materializes on the first
    /// read — which blocks the calling thread until the download finishes.
    /// (The hidden ".<name>.icloud" stub is the older shape and still occurs.)
    /// Anything on a hot path must ask this before reading; on iOS a library
    /// scan that ignored it exhausted the 10-second scene-update watchdog and
    /// the app was killed on every launch.
    static func isDownloaded(_ fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else {
            // Not an iCloud item (or gone): local files read without blocking.
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current), .some(.downloaded): return true
        default: return false
        }
    }

    /// The file's contents, but only when reading cannot block on a download.
    static func dataIfDownloaded(_ fileURL: URL) -> Data? {
        guard isDownloaded(fileURL) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// True when the item is known to the library but its content still has to
    /// come down — the caller should ask for it and try again later.
    static func awaitingDownload(_ fileURL: URL) -> Bool {
        existsIncludingPlaceholder(fileURL) && !isDownloaded(fileURL)
    }

    /// Ask iCloud to fetch a file in the background. Cheap, idempotent, never
    /// blocks; a no-op for files that aren't ubiquitous.
    static func requestDownload(_ fileURL: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
    }

    static func isPlaceholderOnly(_ fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return FileManager.default.fileExists(atPath: placeholderURL(for: fileURL).path)
        }
        // Present in name only: reading would block on the download.
        return !isDownloaded(fileURL)
    }
}
