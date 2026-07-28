import AVFoundation
import XCTest
@testable import AudioTranscriber

/// The spool keeps growing files out of the (potentially synced) library:
/// recordings finalize in Application Support and are renamed in afterward,
/// and the launch sweep salvages anything a crash left behind.
@MainActor
final class SpoolTests: XCTestCase {
    private var tempDir: URL!
    private var spooled: [URL] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        spooled = []
    }

    override func tearDown() async throws {
        for url in spooled { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> RecordingStore {
        RecordingStore(storageDirectory: tempDir,
                       defaults: UserDefaults(suiteName: "SpoolTests-\(UUID().uuidString)")!)
    }

    /// A real, readable audio leftover (a finalized container the app crashed
    /// before moving). `playable: false` writes the other kind: data with no
    /// index, which is what an interrupted stop or merge leaves behind.
    private func spoolFile(_ name: String, bytes: Int, ageSeconds: TimeInterval = 0,
                           playable: Bool = true) throws -> URL {
        let url = SpoolLocation.url(fileName: name)
        if playable {
            try writeTone(to: url, seconds: max(1.0, Double(bytes) / 32_000))
        } else {
            try Data(count: bytes).write(to: url)
        }
        if ageSeconds > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)], ofItemAtPath: url.path)
        }
        spooled.append(url)
        return url
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let isWAV = url.pathExtension.lowercased() == "wav"
        let settings: [String: Any] = isWAV
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * sinf(Float(i) * 0.05) }
            try file.write(from: buffer)
        }
    }

    func testFinalizeMovesSpoolFileIntoLibrary() throws {
        let store = makeStore()
        store.load()
        let spool = try spoolFile("recording_spool-\(UUID().uuidString).m4a", bytes: 10_000)

        let final = store.finalizeRecordingFile(at: spool)

        XCTAssertTrue(final.path.hasPrefix(tempDir.path), "moved into the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "spool copy gone")
    }

    func testLoadSweepsLeftoversAndDeletesStubs() throws {
        // Crash leftovers are stale by definition — the sweep ignores fresh
        // files (a growing capture keeps its mtime current).
        let salvage = try spoolFile("recording_crash-\(UUID().uuidString).wav", bytes: 10_000, ageSeconds: 300)
        let stub = try spoolFile("recording_stub-\(UUID().uuidString).wav", bytes: 100, ageSeconds: 300)

        let store = makeStore()
        store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: salvage.path), "salvaged out of spool")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(salvage.lastPathComponent).path),
            "…into the library, where orphan adoption finds it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stub.path), "stub deleted")
    }

    func testSweepSkipsTheActiveRecording() throws {
        let active = try spoolFile("recording_live-\(UUID().uuidString).m4a", bytes: 50_000, ageSeconds: 300)

        let store = makeStore()
        store.activeRecordingURL = active
        store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path),
                      "the live recording must never be moved out from under the writer")
    }

    /// The recorder's per-configuration segment files share the active
    /// recording's stem — a mid-recording reload (cloud watcher) must not
    /// steal them, even when their mtime is somehow stale.
    func testSweepSkipsActiveRecordingSegments() throws {
        let stamp = UUID().uuidString
        let active = SpoolLocation.url(fileName: "recording_live-\(stamp).m4a")
        spooled.append(active)
        let segment = try spoolFile("recording_live-\(stamp).seg0.m4a", bytes: 50_000, ageSeconds: 300)

        let store = makeStore()
        store.activeRecordingURL = active
        store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path),
                      "segments of the live recording belong to the recorder, not the sweep")
    }

    /// An interrupted stop or merge leaves a container with audio data but no
    /// index — unplayable. Adopting it puts a 0-second, 619 MB phantom
    /// "recording" in the library (that happened); it must be set aside
    /// instead, and never deleted.
    func testSweepQuarantinesUnfinalizedLeftovers() throws {
        let broken = try spoolFile("recording_broken-\(UUID().uuidString).m4a",
                                   bytes: 200_000, ageSeconds: 300, playable: false)
        let store = makeStore()
        store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path), "moved out of the spool")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(broken.lastPathComponent).path),
            "an unplayable file must not enter the library")
        let quarantined = SpoolLocation.unfinishedDirectory
            .appendingPathComponent(broken.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path),
                      "the bytes are kept for recovery")
        XCTAssertTrue(store.recordings.isEmpty)
        try? FileManager.default.removeItem(at: quarantined)
    }

    /// Cross-instance protection: files modified moments ago are presumed to
    /// be someone's live capture (another store instance can't know the
    /// active URL) and are left alone.
    func testSweepLeavesFreshFilesAlone() throws {
        let fresh = try spoolFile("recording_fresh-\(UUID().uuidString).m4a", bytes: 50_000)

        let store = makeStore()
        store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "a file written seconds ago is not a crash leftover")
    }
}
