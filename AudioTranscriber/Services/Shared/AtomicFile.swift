import Foundation

/// Single choke point for whole-file writes into the library (manifest,
/// sidecars, speaker library, checkpoints). Always atomic-replace: a reader
/// (or a sync agent uploading the folder) can never observe a partial file.
/// When iCloud sync lands, this is the one place that grows an
/// NSFileCoordinator branch for in-container URLs.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        noteSelfWrite(url)
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

    // MARK: - Self-write ledger

    /// Every write this process makes into a synced library comes back as an
    /// NSMetadataQuery change, indistinguishable from an edit on another
    /// device. Acting on that echo means reloading the whole library while the
    /// app is mid-operation — which once rolled a running transcription's
    /// status back to "pending". The ledger lets the sync watcher recognise
    /// its own footprints and stay quiet.
    private static let ledgerLock = NSLock()
    nonisolated(unsafe) private static var selfWrites: [String: Date] = [:]
    /// How long a write stays recognisable. iCloud's change notification is
    /// usually sub-second; this is generous on purpose, and the cost of an
    /// over-long window is only a skipped reload of state we already hold.
    static let selfWriteWindow: TimeInterval = 20

    static func noteSelfWrite(_ url: URL) {
        let name = url.lastPathComponent
        let now = Date()
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        selfWrites[name] = now
        if selfWrites.count > 64 {
            selfWrites = selfWrites.filter { now.timeIntervalSince($0.value) < selfWriteWindow }
        }
    }

    /// True when THIS process wrote a file of that name moments ago.
    static func isRecentSelfWrite(_ fileName: String, now: Date = Date()) -> Bool {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        guard let written = selfWrites[fileName] else { return false }
        return now.timeIntervalSince(written) < selfWriteWindow
    }

    /// Test hook.
    static func resetSelfWriteLedger() {
        ledgerLock.lock()
        selfWrites.removeAll()
        ledgerLock.unlock()
    }
}
