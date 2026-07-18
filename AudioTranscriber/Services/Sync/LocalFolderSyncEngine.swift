import Foundation

/// Test double: a plain local folder pretending to be a ubiquity container.
/// Placeholders are simulated with real ".<name>.icloud" stub files, and
/// change batches are injected by tests via `simulateChanges`.
final class LocalFolderSyncEngine: SyncEngine {
    private let documentsURL: URL
    private var onChanges: (@Sendable ([SyncChange]) -> Void)? = nil
    private(set) var downloadRequests: [URL] = []
    private(set) var evictRequests: [URL] = []

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
    }

    var isAvailable: Bool { true }

    func resolveContainerDocumentsURL() -> URL? {
        try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        return documentsURL
    }

    func startDownload(_ url: URL) throws {
        downloadRequests.append(url)
        // Simulate a completed download: replace the stub with an empty file.
        let placeholder = CloudPlaceholder.placeholderURL(for: url)
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.removeItem(at: placeholder)
            FileManager.default.createFile(atPath: url.path, contents: Data(count: 8192))
        }
    }

    func evict(_ url: URL) throws {
        evictRequests.append(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: CloudPlaceholder.placeholderURL(for: url).path, contents: Data())
    }

    func itemState(for url: URL) -> SyncItemState {
        if CloudPlaceholder.isPlaceholderOnly(url) { return .placeholder }
        if FileManager.default.fileExists(atPath: url.path) { return .current }
        return .notTracked
    }

    func startWatching(onChanges: @escaping @Sendable ([SyncChange]) -> Void) {
        self.onChanges = onChanges
    }

    func stopWatching() {
        onChanges = nil
    }

    /// Test hook: pretend the cloud pushed these changes.
    func simulateChanges(_ changes: [SyncChange]) {
        onChanges?(changes)
    }
}
