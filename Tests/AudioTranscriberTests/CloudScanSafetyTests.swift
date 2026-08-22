import XCTest
@testable import AudioTranscriber

/// The library scan runs against the iCloud container, where an item is
/// *dataless* until something reads it — and that read blocks the caller for
/// as long as the download takes. Doing it on the main thread killed the iOS
/// app on every launch (0x8BADF00D scene-update watchdog, 244-file library).
///
/// These tests pin the two rules that came out of that: never read what isn't
/// on the device, and never scan on the main thread.
@MainActor
final class CloudScanSafetyTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "CloudScan-\(UUID().uuidString)")!
        defaults.set(dir.path, forKey: "storageDirectory")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStub(for url: URL) {
        FileManager.default.createFile(
            atPath: CloudPlaceholder.placeholderURL(for: url).path, contents: Data())
    }

    private func writeMeta(named name: String, at metaURL: URL, for audio: URL) throws {
        let source = Recording(fileURL: audio, date: Date(timeIntervalSince1970: 2_000),
                               duration: 9, name: name, fileSizeBytes: 8_192)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingMeta(recording: source)).write(to: metaURL)
    }

    private func waitUntil(timeout: TimeInterval,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition never became true"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - The download gate

    func testAnOrdinaryLocalFileCountsAsDownloaded() throws {
        let file = dir.appendingPathComponent("local.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertTrue(CloudPlaceholder.isDownloaded(file))
        XCTAssertFalse(CloudPlaceholder.awaitingDownload(file))
        XCTAssertFalse(CloudPlaceholder.isPlaceholderOnly(file))
        XCTAssertEqual(CloudPlaceholder.dataIfDownloaded(file), Data("{}".utf8))
    }

    func testAMissingFileIsNeitherDownloadedNorAwaited() {
        let file = dir.appendingPathComponent("nothing.json")
        XCTAssertFalse(CloudPlaceholder.isDownloaded(file))
        XCTAssertFalse(CloudPlaceholder.awaitingDownload(file), "absent is not pending")
        XCTAssertNil(CloudPlaceholder.dataIfDownloaded(file))
    }

    func testAStubMeansTheContentIsStillInTheCloud() {
        let file = dir.appendingPathComponent("evicted.m4a")
        makeStub(for: file)
        XCTAssertTrue(CloudPlaceholder.existsIncludingPlaceholder(file))
        XCTAssertTrue(CloudPlaceholder.isPlaceholderOnly(file))
        XCTAssertTrue(CloudPlaceholder.awaitingDownload(file))
        XCTAssertNil(CloudPlaceholder.dataIfDownloaded(file), "never read a placeholder")
    }

    // MARK: - Scan behavior

    func testOrphanAdoptionWaitsForAMetaSidecarStillInTheCloud() throws {
        let audio = dir.appendingPathComponent("waiting.m4a")
        try Data(count: 8_192).write(to: audio)
        let metaURL = dir.appendingPathComponent("waiting.meta.json")
        makeStub(for: metaURL)

        let store = RecordingStore(defaults: defaults)
        store.load()
        XCTAssertTrue(store.recordings.isEmpty,
                      "adopting now would mint a UUID the sidecar is about to contradict")

        // The sidecar lands: the recording adopts with its real identity.
        try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: metaURL))
        let id = UUID()
        let source = Recording(id: id, fileURL: audio, date: Date(timeIntervalSince1970: 1_000),
                               duration: 12, name: "From The Sidecar", category: "Calls",
                               fileSizeBytes: 8_192)
        let meta = RecordingMeta(recording: source)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL)

        store.load()
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.id, id)
        XCTAssertEqual(store.recordings.first?.name, "From The Sidecar")
        XCTAssertEqual(store.recordings.first?.category, "Calls")
    }

    func testTheLibraryPicksUpASidecarThatArrivesAfterTheScan() async throws {
        let audio = dir.appendingPathComponent("late.m4a")
        try Data(count: 8_192).write(to: audio)
        let metaURL = dir.appendingPathComponent("late.meta.json")
        makeStub(for: metaURL)

        let store = RecordingStore(defaults: defaults)
        store.sidecarRetryDelay = 0.1
        store.load()
        XCTAssertTrue(store.recordings.isEmpty, "still waiting on the sidecar")

        // iCloud finishes the download. Nothing tells the app — a completed
        // download is not a change notification we can count on — so the
        // store has to come back and look for itself.
        try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: metaURL))
        try writeMeta(named: "Arrived Late", at: metaURL, for: audio)

        try await waitUntil(timeout: 5) { store.recordings.count == 1 }
        XCTAssertEqual(store.recordings.first?.name, "Arrived Late")
    }

    func testARecordingIsAdoptedEvenIfItsSidecarNeverArrives() async throws {
        let audio = dir.appendingPathComponent("orphaned.m4a")
        try Data(count: 8_192).write(to: audio)
        makeStub(for: dir.appendingPathComponent("orphaned.meta.json"))

        let store = RecordingStore(defaults: defaults)
        store.sidecarRetryDelay = 0.05
        store.sidecarRetryLimit = 2
        store.load()
        XCTAssertTrue(store.recordings.isEmpty)

        // The sidecar is gone for good (deleted elsewhere, say). After the
        // retries are spent the audio is taken in anyway — a missing sidecar
        // must not hide a recording forever.
        try await waitUntil(timeout: 5) { store.recordings.count == 1 }
        XCTAssertEqual(store.recordings.first?.fileURL.lastPathComponent, "orphaned.m4a")
    }

    func testTheCategoriesMasterListIsNotClobberedWhileItIsStillInTheCloud() throws {
        let libraryFile = dir.appendingPathComponent("library.json")
        makeStub(for: libraryFile)

        let store = RecordingStore(defaults: defaults)
        store.load()
        store.addCategory("Work")
        store.saveNow()

        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile.path),
                       "writing over a master list we could not read would drop another device's categories")
    }

    func testTheSpeakerLibraryKeepsItsSpeakersWhenItsFileIsStillInTheCloud() throws {
        let speakerDir = dir.appendingPathComponent("SpeakerLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: speakerDir, withIntermediateDirectories: true)
        let libraryFile = speakerDir.appendingPathComponent("library.json")
        let json = """
        {"version":1,"autoMatchThreshold":0.7,"speakers":[{"id":"\(UUID().uuidString)",
        "name":"Ben","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
        "embeddings":[],"clips":[],"recordingIDs":[]}]}
        """
        try Data(json.utf8).write(to: libraryFile)

        let library = SpeakerLibraryStore(storageDirectory: dir)
        library.load()
        XCTAssertEqual(library.speakers.count, 1)

        // Evicted to the cloud: a reload must not read it — and must not
        // mistake "can't read it" for "there are no speakers".
        try FileManager.default.removeItem(at: libraryFile)
        makeStub(for: libraryFile)
        library.load()
        XCTAssertEqual(library.speakers.count, 1, "an unreadable cloud file must not wipe the library")
    }

    func testAsyncLoadReturnsTheSameLibraryAsTheSynchronousOne() async throws {
        for i in 0..<12 {
            let audio = dir.appendingPathComponent("rec\(i).m4a")
            try Data(count: 8_192).write(to: audio)
        }
        let sync = RecordingStore(defaults: defaults)
        sync.load()
        let syncNames = sync.recordings.map(\.fileURL.lastPathComponent).sorted()

        let async = RecordingStore(defaults: defaults)
        await async.loadAsync()
        XCTAssertEqual(async.recordings.map(\.fileURL.lastPathComponent).sorted(), syncNames)
        XCTAssertEqual(async.recordings.count, 12)
    }

    func testAsyncLoadLeavesTheMainThreadFreeWhileItScans() async throws {
        // Enough files that the scan is not instantaneous; the point is that
        // the main actor keeps running work while it happens.
        for i in 0..<600 {
            try Data(count: 8_192).write(to: dir.appendingPathComponent("bulk\(i).m4a"))
        }
        let store = RecordingStore(defaults: defaults)

        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await store.loadAsync()
        ticker.cancel()

        XCTAssertEqual(store.recordings.count, 600)
        XCTAssertGreaterThan(ticks, 0,
                             "the main actor was blocked for the whole scan — this is the launch watchdog kill")
    }
}
