import AVFoundation
import XCTest
@testable import AudioTranscriber

/// The .meta.json sidecar makes recordings.json a rebuildable cache: identity
/// (UUID), names, categories, and engine attribution must survive a deleted
/// manifest and reflect external (synced-in) edits.
@MainActor
final class RecordingMetaTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "MetaTests-\(UUID().uuidString)")!)
        store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRealWav(_ name: String, seconds: Double = 0.6) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
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

    private func readMeta(_ recording: Recording) throws -> RecordingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: Data(contentsOf: recording.metaURL))
    }

    func testInsertWritesMetaSidecar() throws {
        let wav = try makeRealWav("a.wav")
        let recording = Recording(fileURL: wav, date: .now,
                                  duration: RecordingStore.audioDuration(for: wav), name: "Kickoff")
        store.insert(recording)

        let meta = try readMeta(recording)
        XCTAssertEqual(meta.id, recording.id)
        XCTAssertEqual(meta.name, "Kickoff")
        XCTAssertEqual(meta.version, RecordingMeta.currentVersion)
    }

    func testUpdateRewritesMetaOnChangeOnly() throws {
        let wav = try makeRealWav("b.wav")
        let recording = Recording(fileURL: wav, date: .now,
                                  duration: RecordingStore.audioDuration(for: wav))
        store.insert(recording)
        let original = try Data(contentsOf: recording.metaURL)

        // No-op update: file bytes must be untouched (updatedAt not bumped).
        store.update(recording.id) { _ in }
        XCTAssertEqual(try Data(contentsOf: recording.metaURL), original)

        store.update(recording.id) { $0.name = "Renamed"; $0.category = "Work" }
        let meta = try readMeta(store.recording(with: recording.id)!)
        XCTAssertEqual(meta.name, "Renamed")
        XCTAssertEqual(meta.category, "Work")
    }

    /// The headline guarantee: delete recordings.json → the directory alone
    /// reconstructs an identical library (stable IDs included).
    func testLibraryReconstructsFromDirectoryAlone() throws {
        let wav1 = try makeRealWav("first.wav")
        let wav2 = try makeRealWav("second.wav")
        let r1 = Recording(fileURL: wav1, date: .now, duration: 0.6, name: "Therapy — Alice")
        let r2 = Recording(fileURL: wav2, date: .now.addingTimeInterval(-60), duration: 0.6)
        store.insert(r1)
        store.insert(r2)
        store.addCategory("Therapy")
        store.update(r1.id) { $0.category = "Therapy"; $0.engineUsed = "On-Device · Parakeet v3" }
        store.saveNow()

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent(RecordingStore.manifestFileName))

        let store2 = RecordingStore(storageDirectory: tempDir,
                                    defaults: UserDefaults(suiteName: "MetaTests-r-\(UUID().uuidString)")!)
        store2.load()

        XCTAssertEqual(Set(store2.recordings.map(\.id)), Set([r1.id, r2.id]), "IDs must be stable")
        let rebuilt1 = store2.recording(with: r1.id)
        XCTAssertEqual(rebuilt1?.name, "Therapy — Alice")
        XCTAssertEqual(rebuilt1?.category, "Therapy")
        XCTAssertEqual(rebuilt1?.engineUsed, "On-Device · Parakeet v3")
        XCTAssertTrue(store2.categories.contains("Therapy"), "categories survive via library.json")
    }

    /// A newer .meta.json written by another device must win over the local
    /// manifest cache on reload.
    func testExternalMetaEditWinsOnReload() throws {
        let wav = try makeRealWav("c.wav")
        let recording = Recording(fileURL: wav, date: .now, duration: 0.6, name: "Local Name")
        store.insert(recording)
        store.saveNow()

        var meta = try readMeta(recording)
        meta.name = "Remote Name"
        meta.updatedAt = .now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(meta)).write(to: recording.metaURL, options: .atomic)

        let store2 = RecordingStore(storageDirectory: tempDir,
                                    defaults: UserDefaults(suiteName: "MetaTests-e-\(UUID().uuidString)")!)
        store2.load()
        XCTAssertEqual(store2.recording(with: recording.id)?.name, "Remote Name")
    }

    func testBackfillCreatesMetaForLegacyLibraries() throws {
        let wav = try makeRealWav("d.wav")
        let recording = Recording(fileURL: wav, date: .now, duration: 0.6, name: "Old-World")
        store.insert(recording)
        store.saveNow()
        try FileManager.default.removeItem(at: recording.metaURL)

        let store2 = RecordingStore(storageDirectory: tempDir,
                                    defaults: UserDefaults(suiteName: "MetaTests-b-\(UUID().uuidString)")!)
        store2.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.metaURL.path),
                      "load() must backfill missing meta sidecars")
        XCTAssertEqual(try readMeta(recording).name, "Old-World")
    }

    func testDeleteRemovesMetaSidecar() throws {
        let wav = try makeRealWav("e.wav")
        let recording = Recording(fileURL: wav, date: .now, duration: 0.6)
        store.insert(recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.metaURL.path))
        store.delete(recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.metaURL.path))
    }
}
