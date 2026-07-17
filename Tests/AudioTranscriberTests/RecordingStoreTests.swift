import XCTest
@testable import AudioTranscriber

@MainActor
final class RecordingStoreTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "RecordingStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> RecordingStore {
        RecordingStore(storageDirectory: tempDir, defaults: defaults)
    }

    private func writeWav(_ name: String, bytes: Int = 10_000) -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    // MARK: - Manifest round-trip

    func testManifestRoundTrip() {
        let store = makeStore()
        store.load()
        let wav = writeWav("a.wav")
        store.insert(Recording(fileURL: wav, date: .now, duration: 12.5, name: "Test", category: "Work"))
        store.addCategory("Work")
        store.saveNow()

        let store2 = makeStore()
        store2.load()
        XCTAssertEqual(store2.recordings.count, 1)
        XCTAssertEqual(store2.recordings.first?.name, "Test")
        XCTAssertEqual(store2.recordings.first?.category, "Work")
        XCTAssertEqual(store2.recordings.first?.duration ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(store2.categories, ["Work"])
        XCTAssertEqual(store2.recordings.first?.fileURL.standardizedFileURL.path,
                       wav.standardizedFileURL.path)
    }

    // MARK: - Legacy migration

    func testLegacyUserDefaultsMigration() throws {
        let wav = writeWav("legacy.wav")
        var legacy = Recording(fileURL: wav, date: .now, duration: 42)
        legacy.name = "Old Recording"
        legacy.status = .done
        let data = try JSONEncoder().encode([legacy])
        defaults.set(data, forKey: RecordingStore.legacyDefaultsKey)

        let store = makeStore()
        store.load()

        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.name, "Old Recording")
        // Migration writes the manifest
        let manifestURL = tempDir.appendingPathComponent(RecordingStore.manifestFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        // Legacy key intentionally left as rollback backup
        XCTAssertNotNil(defaults.data(forKey: RecordingStore.legacyDefaultsKey))
    }

    func testMigrationSkipsMissingFiles() throws {
        let missing = tempDir.appendingPathComponent("gone.wav")
        let legacy = Recording(fileURL: missing, date: .now, duration: 5)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: RecordingStore.legacyDefaultsKey)

        let store = makeStore()
        store.load()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    // MARK: - Orphan adoption

    func testOrphanWavAdopted() {
        _ = writeWav("orphan.wav")
        let store = makeStore()
        store.load()
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.status, .pending)
    }

    func testOrphanWithTranscriptAdoptedAsDone() throws {
        let wav = writeWav("done.wav")
        let md = wav.deletingPathExtension().appendingPathExtension("md")
        try "# Transcript".write(to: md, atomically: true, encoding: .utf8)

        let store = makeStore()
        store.load()
        XCTAssertEqual(store.recordings.first?.status, .done)
        XCTAssertEqual(store.recordings.first?.transcriptionURL?.lastPathComponent, "done.md")
    }

    func testTinyCrashArtifactsSkipped() {
        _ = writeWav("artifact.wav", bytes: 4096)
        let store = makeStore()
        store.load()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    // MARK: - Status repair

    func testProcessingRepairedToPartialWithCheckpoint() throws {
        let store = makeStore()
        store.load()
        let wav = writeWav("interrupted.wav")
        var rec = Recording(fileURL: wav, date: .now, duration: 100)
        rec.status = .processing
        try Data("{}".utf8).write(to: rec.checkpointURL)
        store.insert(rec)
        store.saveNow()

        let store2 = makeStore()
        store2.load()
        XCTAssertEqual(store2.recordings.first?.status, .partial)
    }

    func testProcessingRepairedToPendingWithoutCheckpoint() {
        let store = makeStore()
        store.load()
        let wav = writeWav("interrupted2.wav")
        var rec = Recording(fileURL: wav, date: .now, duration: 100)
        rec.status = .processing
        store.insert(rec)
        store.saveNow()

        let store2 = makeStore()
        store2.load()
        XCTAssertEqual(store2.recordings.first?.status, .pending)
    }

    // MARK: - Categories

    func testRenameCategoryCascades() {
        let store = makeStore()
        store.load()
        let wav = writeWav("cat.wav")
        store.addCategory("Old")
        store.insert(Recording(fileURL: wav, date: .now, duration: 1, category: "Old"))

        store.renameCategory("Old", to: "New")
        XCTAssertEqual(store.categories, ["New"])
        XCTAssertEqual(store.recordings.first?.category, "New")
    }

    func testDeleteCategoryFallsBackToUncategorized() {
        let store = makeStore()
        store.load()
        let wav = writeWav("cat2.wav")
        store.addCategory("Temp")
        store.insert(Recording(fileURL: wav, date: .now, duration: 1, category: "Temp"))

        store.deleteCategory("Temp")
        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertNil(store.recordings.first?.category)
    }

    // MARK: - Delete removes sidecars

    func testDeleteRemovesAllSidecars() throws {
        let store = makeStore()
        store.load()
        let wav = writeWav("full.wav")
        let rec = Recording(fileURL: wav, date: .now, duration: 1)
        for sidecar in rec.allSidecarURLs {
            try Data("x".utf8).write(to: sidecar)
        }
        store.insert(rec)

        store.delete(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        for sidecar in rec.allSidecarURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), sidecar.lastPathComponent)
        }
        XCTAssertTrue(store.recordings.isEmpty)
    }

    // MARK: - Status decode tolerance

    func testUnknownStatusDecodesToPending() throws {
        let json = #"{"id":"\#(UUID().uuidString)","fileURL":"file:///tmp/x.wav","date":0,"duration":1,"status":"someFutureStatus"}"#
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .pending)
    }

    func testOldStatusValuesStillDecode() throws {
        for raw in ["pending", "processing", "done", "failed"] {
            let json = #"{"id":"\#(UUID().uuidString)","fileURL":"file:///tmp/x.wav","date":0,"duration":1,"status":"\#(raw)"}"#
            let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.status.rawValue, raw)
        }
    }
}
