import XCTest
@testable import AudioTranscriber

/// Checkpoints must live in Application Support (ID-keyed), never inside the
/// (potentially synced) library, and legacy in-library checkpoints migrate.
@MainActor
final class CheckpointRelocationTests: XCTestCase {
    private var tempDir: URL!
    private var cleanupIDs: [UUID] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CkptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cleanupIDs = []
    }

    override func tearDown() async throws {
        for id in cleanupIDs {
            try? FileManager.default.removeItem(at: CheckpointLocation.url(for: id))
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> RecordingStore {
        RecordingStore(storageDirectory: tempDir,
                       defaults: UserDefaults(suiteName: "CkptTests-\(UUID().uuidString)")!)
    }

    /// A real-enough wav: orphan adoption skips files ≤4096 bytes.
    private func writeFakeWav(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: 8192).write(to: url)
        return url
    }

    func testCheckpointURLIsIDKeyedOutsideLibrary() throws {
        let wav = try writeFakeWav("x.wav")
        let recording = Recording(fileURL: wav, date: .now, duration: 10)
        cleanupIDs.append(recording.id)

        XCTAssertFalse(recording.checkpointURL.path.hasPrefix(tempDir.path),
                       "checkpoint must not live inside the library")
        XCTAssertTrue(recording.checkpointURL.path.contains("Application Support"))
        XCTAssertEqual(recording.checkpointURL.lastPathComponent,
                       "\(recording.id.uuidString).partial.json")
    }

    func testLegacyCheckpointMigratesOnLoadAndRepairsStatus() throws {
        let store = makeStore()
        store.load()
        let wav = try writeFakeWav("interrupted.wav")
        var rec = Recording(fileURL: wav, date: .now, duration: 10)
        rec.status = .processing
        cleanupIDs.append(rec.id)
        store.insert(rec)
        store.saveNow()

        // Old-world checkpoint beside the audio.
        let legacy = wav.deletingPathExtension().appendingPathExtension("partial.json")
        try Data(#"{"legacy":true}"#.utf8).write(to: legacy)

        let store2 = makeStore()
        store2.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy file moved away")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.checkpointURL.path), "…to the ID-keyed location")
        XCTAssertEqual(store2.recording(with: rec.id)?.status, .partial,
                       "launch repair must see the migrated checkpoint")
    }

    func testDeleteRemovesRelocatedCheckpoint() throws {
        let store = makeStore()
        store.load()
        let wav = try writeFakeWav("del.wav")
        let rec = Recording(fileURL: wav, date: .now, duration: 10)
        cleanupIDs.append(rec.id)
        store.insert(rec)
        try Data("{}".utf8).write(to: rec.checkpointURL)

        store.delete(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.checkpointURL.path))
    }
}
