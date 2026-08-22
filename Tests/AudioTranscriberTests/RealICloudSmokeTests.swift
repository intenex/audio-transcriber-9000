import AVFoundation
import XCTest
@testable import AudioTranscriber

// Mac-only: exercises the real ubiquity container (requires full team
// signing + an iCloud-signed-in account).
#if os(macOS)

/// Gated end-to-end smoke of REAL iCloud: migrate a scratch library into the
/// actual container with the real ICloudSyncEngine, verify placement and
/// item states, then remove every scratch file from the container.
/// Uses isolated defaults — the user's real library/settings are untouched.
@MainActor
final class RealICloudSmokeTests: XCTestCase {

    private var enabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    func testScratchLibraryMigratesIntoRealContainer() async throws {
        try XCTSkipUnless(enabled, "marker file not present")

        let engine = ICloudSyncEngine()
        try XCTSkipUnless(engine.isAvailable, "not signed into iCloud")

        let stamp = "icloud-smoke-\(UUID().uuidString.prefix(8))"
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: stamp)!
        defaults.set(localDir.path, forKey: "storageDirectory")

        let store = RecordingStore(defaults: defaults)
        store.load()
        let speakerLibrary = SpeakerLibraryStore(storageDirectory: localDir)
        let cloudSync = CloudSyncManager(engine: engine, defaults: defaults)
        cloudSync.attach(recordingStore: store, speakerLibrary: speakerLibrary)
        await cloudSync.bootstrap()

        guard let containerDocs = cloudSync.containerDocumentsURL else {
            return XCTFail("entitled build should resolve the ubiquity container")
        }
        XCTAssertTrue(containerDocs.path.contains("Mobile Documents"),
                      "expected the real iCloud Drive container, got \(containerDocs.path)")

        // Scratch content: a real 1 s wav (will be compressed to m4a) + transcript.
        // Writer scoped: AVAudioFile finalizes only on release (see DEVELOPMENT.md).
        let wavURL = localDir.appendingPathComponent("\(stamp).wav")
        try autoreleasepool {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: wavURL, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(48_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
            try file.write(from: buffer)
        }

        var recording = Recording(fileURL: wavURL, date: .now, duration: 1.0, name: "iCloud Smoke")
        recording.status = .done
        try "# smoke transcript".write(to: recording.markdownURL, atomically: true, encoding: .utf8)
        store.insert(recording)
        store.saveNow()

        // Cleanup runs no matter how assertions go: remove every scratch file
        // from the real container (removal = deletion from iCloud).
        defer {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: containerDocs, includingPropertiesForKeys: nil, options: []) {
                for url in contents where url.lastPathComponent.contains(stamp) {
                    try? FileManager.default.removeItem(at: url)
                }
                // The migrator also copies these two scratch-library files.
                for name in ["library.json", ".global-chat.json"] {
                    let url = containerDocs.appendingPathComponent(name)
                    // Only remove if OUR scratch run created them just now.
                    if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       abs(created.timeIntervalSinceNow) < 300,
                       (try? Data(contentsOf: url)).map({ $0.count < 4096 }) == true {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            try? FileManager.default.removeItem(at: localDir)
        }

        try await LibraryMigrator.enableSync(store: store, speakerLibrary: speakerLibrary,
                                             cloudSync: cloudSync, isBusy: false,
                                             status: { NSLog("[icloud-smoke] \($0)") })

        XCTAssertNil(store.errorMessage, "store error during migration: \(store.errorMessage ?? "")")
        XCTAssertTrue(cloudSync.isEnabled)
        XCTAssertEqual(store.storageDirectory.standardizedFileURL, containerDocs.standardizedFileURL,
                       "scratch store repointed into the REAL container")
        let migrated = try XCTUnwrap(store.recording(with: recording.id))
        XCTAssertEqual(migrated.fileURL.pathExtension, "m4a", "wav compressed before upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.markdownURL.path))

        // The sync daemon should know the item (uploading or already current).
        let state = engine.itemState(for: migrated.fileURL)
        XCTAssertTrue(state == .uploading || state == .current,
                      "expected uploading/current from the real engine, got \(state)")

        await LibraryMigrator.disableSync(store: store, speakerLibrary: speakerLibrary, cloudSync: cloudSync)
        XCTAssertEqual(store.storageDirectory.standardizedFileURL, localDir.standardizedFileURL)
    }
}
#endif
