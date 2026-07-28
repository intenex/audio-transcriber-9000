import Foundation

/// Device-local spool for files that are being written incrementally (the
/// active recording, in-flight compressions/imports). Nothing may stream a
/// growing file into the library — the library may be synced, and a sync
/// agent would upload a half-written, unfinalized container. Files land in
/// the library only via a rename after they are complete and verified.
enum SpoolLocation {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTranscriber/InProgress", isDirectory: true)
    }

    /// Spool path for a file name; ensures the directory exists.
    static func url(fileName: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    /// Where crash leftovers whose container was never finalized go. They hold
    /// real audio data but no index, so nothing can play them — putting one in
    /// the library just shows the user an unplayable 0-second "recording"
    /// (that is exactly how a 619 MB phantom entry appeared once). They are
    /// kept, never deleted: a repair tool can still get at the bytes.
    static var unfinishedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTranscriber/Unfinished", isDirectory: true)
    }
}
