import Foundation

/// The real ubiquity-container engine: NSMetadataQuery over the documents
/// scope for change detection + download state, FileManager ubiquity APIs for
/// download/evict. All change callbacks are debounced batches.
final class ICloudSyncEngine: NSObject, SyncEngine {
    static let containerIdentifier = "iCloud.com.audiortranscriber.AudioTranscriber"

    private var query: NSMetadataQuery? = nil
    private var onChanges: (@Sendable ([SyncChange]) -> Void)? = nil
    private var knownNames: Set<String> = []
    private var debounceTimer: Timer? = nil
    private var pendingChanges: [SyncChange] = []

    var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    func resolveContainerDocumentsURL() -> URL? {
        // Blocking (performs first-time container setup) — call off-main.
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: Self.containerIdentifier) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    func startDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    func itemState(for url: URL) -> SyncItemState {
        if CloudPlaceholder.isPlaceholderOnly(url) {
            // Downloading progress, if the query knows this item.
            if let item = metadataItem(for: url),
               let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
               let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                return .downloading(percent / 100.0)
            }
            return .placeholder
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .notTracked }
        if let item = metadataItem(for: url) {
            if let isUploading = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool,
               isUploading {
                return .uploading
            }
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                return .placeholder
            }
        }
        return .current
    }

    private func metadataItem(for url: URL) -> NSMetadataItem? {
        guard let query else { return nil }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let target = url.standardizedFileURL.path
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let itemURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            if itemURL.standardizedFileURL.path == target { return item }
        }
        return nil
    }

    func startWatching(onChanges: @escaping @Sendable ([SyncChange]) -> Void) {
        stopWatching()
        self.onChanges = onChanges

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        self.query = query

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(queryUpdated(_:)),
                       name: .NSMetadataQueryDidFinishGathering, object: query)
        nc.addObserver(self, selector: #selector(queryUpdated(_:)),
                       name: .NSMetadataQueryDidUpdate, object: query)
        DispatchQueue.main.async {
            query.start()
        }
    }

    func stopWatching() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
        }
        query = nil
        onChanges = nil
        knownNames = []
    }

    @objc private func queryUpdated(_ note: Notification) {
        guard let query else { return }
        query.disableUpdates()
        var names: Set<String> = []
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String {
                names.insert(name)
            }
        }
        query.enableUpdates()

        var changes: [SyncChange] = []
        if note.name == .NSMetadataQueryDidUpdate {
            let added = names.subtracting(knownNames)
            let removed = knownNames.subtracting(names)
            changes.append(contentsOf: added.map { SyncChange(kind: .added, fileName: $0) })
            changes.append(contentsOf: removed.map { SyncChange(kind: .removed, fileName: $0) })
            // Changed items (metadata updates on existing names)
            if let updated = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] {
                for item in updated {
                    if let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String {
                        changes.append(SyncChange(kind: .changed, fileName: name))
                    }
                }
            }
        }
        knownNames = names
        guard !changes.isEmpty else { return }

        // Debounce bursts (~1 s) into one batch.
        pendingChanges.append(contentsOf: changes)
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            let batch = self.pendingChanges
            self.pendingChanges = []
            self.onChanges?(batch)
        }
    }
}
