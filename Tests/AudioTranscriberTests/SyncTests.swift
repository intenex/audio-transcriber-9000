import AVFoundation
import XCTest
@testable import AudioTranscriber

// MARK: - Conflict policies (pure)

final class ConflictMergeTests: XCTestCase {

    private func meta(_ name: String, updatedAt: Date) -> RecordingMeta {
        var m = RecordingMeta(recording: Recording(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"),
                                                   date: .init(timeIntervalSince1970: 0),
                                                   duration: 10, name: name))
        m.updatedAt = updatedAt
        return m
    }

    func testMetaLastWriterWins() {
        let older = meta("Old Name", updatedAt: .init(timeIntervalSince1970: 100))
        let newer = meta("New Name", updatedAt: .init(timeIntervalSince1970: 200))
        XCTAssertEqual(ConflictResolver.mergeMeta(older, newer).name, "New Name")
        XCTAssertEqual(ConflictResolver.mergeMeta(newer, older).name, "New Name")
    }

    func testSpeakerNamesUnionWithNewerWinningCollisions() {
        let mac = ["SPEAKER_00": "Ben", "SPEAKER_01": "Alice"]
        let phone = ["SPEAKER_00": "Benjamin", "SPEAKER_02": "Carol"]

        let phoneNewer = ConflictResolver.mergeSpeakerNames(mac, phone, aNewer: false)
        XCTAssertEqual(phoneNewer, ["SPEAKER_00": "Benjamin", "SPEAKER_01": "Alice", "SPEAKER_02": "Carol"])

        let macNewer = ConflictResolver.mergeSpeakerNames(mac, phone, aNewer: true)
        XCTAssertEqual(macNewer["SPEAKER_00"], "Ben")
        XCTAssertEqual(macNewer.count, 3)
    }

    func testCategoriesUnion() {
        let a = LibraryFile(categories: ["Therapy", "Work"], updatedAt: .init(timeIntervalSince1970: 100))
        let b = LibraryFile(categories: ["Work", "Family"], updatedAt: .init(timeIntervalSince1970: 200))
        let merged = ConflictResolver.mergeCategories(a, b)
        XCTAssertEqual(Set(merged.categories), Set(["Therapy", "Work", "Family"]))
        XCTAssertEqual(merged.categories.first, "Work", "newer file's ordering leads")
    }

    func testEnrolledSpeakersMergeByID() {
        let id = UUID()
        let clipA = EnrolledSpeaker.Clip(file: "clips/a/1.m4a", duration: 8, sourceRecordingID: nil, start: 0, end: 8)
        let clipB = EnrolledSpeaker.Clip(file: "clips/a/2.m4a", duration: 9, sourceRecordingID: nil, start: 9, end: 18)
        let recA = UUID(), recB = UUID()
        let older = EnrolledSpeaker(id: id, name: "Ben", createdAt: .init(timeIntervalSince1970: 0),
                                    updatedAt: .init(timeIntervalSince1970: 100),
                                    embeddings: [[1, 0]], clips: [clipA], recordingIDs: [recA])
        let newer = EnrolledSpeaker(id: id, name: "Benjamin", createdAt: .init(timeIntervalSince1970: 0),
                                    updatedAt: .init(timeIntervalSince1970: 200),
                                    embeddings: [[0, 1]], clips: [clipB], recordingIDs: [recB])
        let other = EnrolledSpeaker(id: UUID(), name: "Alice", createdAt: .init(timeIntervalSince1970: 50),
                                    updatedAt: .init(timeIntervalSince1970: 50),
                                    embeddings: [], clips: [], recordingIDs: [])

        let merged = ConflictResolver.mergeEnrolledSpeakers([older, other], [newer])
        XCTAssertEqual(merged.count, 2)
        let ben = merged.first { $0.id == id }!
        XCTAssertEqual(ben.name, "Benjamin", "newer updatedAt wins scalar fields")
        XCTAssertEqual(Set(ben.clips.map(\.file)), Set(["clips/a/1.m4a", "clips/a/2.m4a"]), "clips union")
        XCTAssertEqual(Set(ben.recordingIDs), Set([recA, recB]))
        XCTAssertEqual(ben.embeddings.count, 2)
    }
}

// MARK: - Cloud-mode store behavior (against a plain folder)

@MainActor
final class CloudModeStoreTests: XCTestCase {
    private var containerDir: URL!
    private var localDir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudMode-\(UUID().uuidString)", isDirectory: true)
        containerDir = base.appendingPathComponent("Container/Documents", isDirectory: true)
        localDir = base.appendingPathComponent("Local", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "CloudMode-\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: containerDir.deletingLastPathComponent().deletingLastPathComponent())
        // The cloud manifest cache is global — remove so tests stay hermetic.
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTranscriber/Cache/recordings-cloud.json")
        try? FileManager.default.removeItem(at: cache)
    }

    private func enableCloud() {
        defaults.set(true, forKey: CloudSyncManager.enabledKey)
        defaults.set(containerDir.path, forKey: CloudSyncManager.containerPathKey)
    }

    func testStorageDirectoryResolvesToContainerInCloudMode() {
        enableCloud()
        let store = RecordingStore(defaults: defaults)
        store.load()
        XCTAssertEqual(store.storageDirectory.standardizedFileURL, containerDir.standardizedFileURL)
    }

    func testManifestCacheStaysOutOfTheContainer() throws {
        enableCloud()
        let store = RecordingStore(defaults: defaults)
        store.load()
        let wav = containerDir.appendingPathComponent("a.wav")
        try Data(count: 8192).write(to: wav)
        store.insert(Recording(fileURL: wav, date: .now, duration: 3))
        store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: containerDir.appendingPathComponent("recordings.json").path),
            "the debounce-churned manifest must never enter the synced tree")
    }

    func testPlaceholderRecordingSurvivesLoadViaMeta() throws {
        enableCloud()
        let store = RecordingStore(defaults: defaults)
        store.load()

        // A fully materialized recording, then simulate eviction: replace the
        // audio with a hidden .icloud stub (meta + transcript stay local).
        let wav = containerDir.appendingPathComponent("evicted.wav")
        try Data(count: 8192).write(to: wav)
        let recording = Recording(fileURL: wav, date: .now, duration: 42, name: "Kept Name")
        store.insert(recording)
        try "# transcript".write(to: recording.markdownURL, atomically: true, encoding: .utf8)
        store.saveNow()

        try FileManager.default.removeItem(at: wav)
        FileManager.default.createFile(
            atPath: CloudPlaceholder.placeholderURL(for: wav).path, contents: Data())

        let store2 = RecordingStore(defaults: defaults)
        store2.load()
        let survived = store2.recording(with: recording.id)
        XCTAssertNotNil(survived, "evicted ≠ deleted: the placeholder row must survive")
        XCTAssertEqual(survived?.name, "Kept Name")
        XCTAssertEqual(survived?.duration ?? 0, 42, accuracy: 0.5, "duration from meta, not the missing file")

        // Deleting a placeholder row removes the stub (the cloud copy).
        store2.delete(survived!)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CloudPlaceholder.placeholderURL(for: wav).path))
    }
}

// MARK: - Migration + watcher (against the fake engine)

@MainActor
final class MigrationAndWatcherTests: XCTestCase {
    private var base: URL!
    private var localDir: URL!
    private var containerDir: URL!
    private var defaults: UserDefaults!
    private var store: RecordingStore!
    private var speakerLibrary: SpeakerLibraryStore!
    private var cloudSync: CloudSyncManager!
    private var engine: LocalFolderSyncEngine!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Migrate-\(UUID().uuidString)", isDirectory: true)
        localDir = base.appendingPathComponent("Local", isDirectory: true)
        containerDir = base.appendingPathComponent("Container/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "Migrate-\(UUID().uuidString)")!
        defaults.set(localDir.path, forKey: "storageDirectory")

        store = RecordingStore(defaults: defaults)
        store.load()
        speakerLibrary = SpeakerLibraryStore(storageDirectory: localDir)
        engine = LocalFolderSyncEngine(documentsURL: containerDir)
        cloudSync = CloudSyncManager(engine: engine, defaults: defaults)
        cloudSync.attach(recordingStore: store, speakerLibrary: speakerLibrary)
        await cloudSync.bootstrap()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTranscriber/Cache/recordings-cloud.json")
        try? FileManager.default.removeItem(at: cache)
    }

    private func makeRealWav(_ name: String, seconds: Double = 1.0) throws -> URL {
        let url = localDir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3
        }
        try file.write(from: buffer)
        return url
    }

    func testEnableSyncCompressesCopiesVerifiesAndRepoints() async throws {
        let wav = try makeRealWav("legacy.wav", seconds: 2)
        var recording = Recording(fileURL: wav, date: .now, duration: 2, name: "Legacy Call")
        recording.status = .done
        try "# transcript".write(to: recording.markdownURL, atomically: true, encoding: .utf8)
        store.insert(recording)
        store.addCategory("Therapy")
        store.saveNow()

        var statuses: [String] = []
        try await LibraryMigrator.enableSync(store: store, speakerLibrary: speakerLibrary,
                                             cloudSync: cloudSync, isBusy: false,
                                             status: { statuses.append($0) })

        XCTAssertTrue(cloudSync.isEnabled)
        XCTAssertEqual(store.storageDirectory.standardizedFileURL, containerDir.standardizedFileURL,
                       "store repointed to the container")
        let migrated = store.recording(with: recording.id)
        XCTAssertNotNil(migrated, "identity preserved across the migration (meta sidecar)")
        XCTAssertEqual(migrated?.fileURL.pathExtension, "m4a", "legacy WAV compressed before upload")
        XCTAssertEqual(migrated?.name, "Legacy Call")
        XCTAssertTrue(store.categories.contains("Therapy"), "categories travel via library.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated!.markdownURL.path), "sidecars copied")
        // Old library untouched (backup) — the compressed m4a stays behind too.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: localDir.appendingPathComponent("legacy.m4a").path))

        LibraryMigrator.disableSync(store: store, speakerLibrary: speakerLibrary, cloudSync: cloudSync)
        XCTAssertEqual(store.storageDirectory.standardizedFileURL, localDir.standardizedFileURL,
                       "disable returns to the previous local library")
    }

    func testExternalChangeBatchTriggersDebouncedReload() async throws {
        // Start in cloud mode with an empty container library.
        defaults.set(true, forKey: CloudSyncManager.enabledKey)
        defaults.set(containerDir.path, forKey: CloudSyncManager.containerPathKey)
        try? FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        store.reloadFromStorageDirectory()
        XCTAssertEqual(store.recordings.count, 0)
        cloudSync.startWatching()

        // Another device dropped in a recording (file + meta appear).
        let wav = containerDir.appendingPathComponent("from-phone.wav")
        try Data(count: 8192).write(to: wav)
        engine.simulateChanges([SyncChange(kind: .added, fileName: "from-phone.wav")])

        let deadline = Date().addingTimeInterval(5)
        while store.recordings.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.recordings.count, 1, "watcher batch must reload the library")
        XCTAssertEqual(store.recordings.first?.fileURL.lastPathComponent, "from-phone.wav")
    }
}
