import Foundation

/// Single choke point for whole-file writes into the library (manifest,
/// sidecars, speaker library, checkpoints). Always atomic-replace: a reader
/// (or a sync agent uploading the folder) can never observe a partial file.
/// When iCloud sync lands, this is the one place that grows an
/// NSFileCoordinator branch for in-container URLs.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
