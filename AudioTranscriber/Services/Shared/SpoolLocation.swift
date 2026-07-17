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
}
