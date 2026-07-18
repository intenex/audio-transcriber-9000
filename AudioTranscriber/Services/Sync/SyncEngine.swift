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

    static func isPlaceholderOnly(_ fileURL: URL) -> Bool {
        !FileManager.default.fileExists(atPath: fileURL.path)
            && FileManager.default.fileExists(atPath: placeholderURL(for: fileURL).path)
    }
}
