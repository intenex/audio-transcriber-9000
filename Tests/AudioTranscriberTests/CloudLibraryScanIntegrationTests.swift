import XCTest
@testable import AudioTranscriber

/// Gated, read-only, and pointed at the REAL iCloud library.
///
/// The iOS app used to be killed on every launch by the scene-update watchdog
/// (0x8BADF00D): the library scan read a `.meta.json` per recording, those
/// files were dataless iCloud items, and each read blocked the main thread on
/// a download. With ~244 recordings the 10-second allowance was long gone.
///
/// This walks the same hot path over the same real files — the meta gate and
/// the duration gate — and asserts it stays cheap and materializes nothing.
/// Nothing here writes: the user's library is only read.
@MainActor
final class CloudLibraryScanIntegrationTests: XCTestCase {

    private let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aac", "flac"]

    func testRealContainerHotPathIsCheapAndMaterializesNothing() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled, "marker file not present")

        let engine = ICloudSyncEngine()
        try XCTSkipUnless(engine.isAvailable, "not signed into iCloud")
        let docs = await Task.detached { engine.resolveContainerDocumentsURL() }.value
        let container = try XCTUnwrap(docs, "an entitled build should resolve the container")

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let audio = entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        try XCTSkipUnless(audio.count >= 10,
                          "container holds \(audio.count) recordings — too few to say anything")

        let downloadedBefore = audio.filter { CloudPlaceholder.isDownloaded($0) }.count

        // The scan's hot path, unchanged: for every recording, consult the
        // sidecar and the audio header — through the gates.
        let started = Date()
        var metaRead = 0
        var pending: [String] = []
        var durationsRead = 0
        for url in audio {
            let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
            if CloudPlaceholder.dataIfDownloaded(metaURL) != nil {
                metaRead += 1
            } else if CloudPlaceholder.awaitingDownload(metaURL) {
                pending.append(url.lastPathComponent)
            }
            if RecordingStore.audioDurationIfDownloaded(for: url) > 0 { durationsRead += 1 }
        }
        let metaPending = pending.count
        let elapsed = Date().timeIntervalSince(started)

        let downloadedAfter = audio.filter { CloudPlaceholder.isDownloaded($0) }.count
        NSLog("[CloudScan] \(audio.count) recordings, \(metaRead) sidecars read, "
              + "\(metaPending) still in the cloud, \(durationsRead) headers read, "
              + "\(String(format: "%.2f", elapsed))s")
        if !pending.isEmpty {
            NSLog("[CloudScan] waiting on: \(pending.prefix(12).joined(separator: ", "))")
        }

        XCTAssertLessThan(elapsed, 5.0,
                          "the launch scan has a 10-second watchdog budget on iOS; this pass took \(elapsed)s")
        XCTAssertEqual(downloadedAfter, downloadedBefore,
                       "walking the library must not pull audio down from iCloud")
    }

    /// The other half of the contract: what the scan refuses to read, tapping
    /// Play must be able to fetch. Uses the smallest not-yet-downloaded
    /// recording and puts it back the way it was found.
    func testTheSmallestPlaceholderDownloadsOnRequestAndPlaysBack() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled, "marker file not present")

        let engine = ICloudSyncEngine()
        try XCTSkipUnless(engine.isAvailable, "not signed into iCloud")
        let docs = await Task.detached { engine.resolveContainerDocumentsURL() }.value
        let container = try XCTUnwrap(docs)

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let candidates = entries
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !CloudPlaceholder.isDownloaded($0) }
            .sorted { RecordingStore.fileSize(of: $0) < RecordingStore.fileSize(of: $1) }
        guard let target = candidates.first else {
            throw XCTSkip("every recording is already downloaded on this device")
        }
        NSLog("[CloudScan] requesting \(target.lastPathComponent) "
              + "(\(RecordingStore.fileSize(of: target)) bytes)")
        XCTAssertTrue(CloudPlaceholder.isPlaceholderOnly(target))
        XCTAssertEqual(RecordingStore.audioDurationIfDownloaded(for: target), 0,
                       "the gate must report nothing for a file that isn't here")

        CloudPlaceholder.requestDownload(target)
        let deadline = Date().addingTimeInterval(120)
        while !CloudPlaceholder.isDownloaded(target) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        try XCTSkipUnless(CloudPlaceholder.isDownloaded(target),
                          "iCloud did not deliver the file within 2 minutes — network, not logic")

        XCTAssertFalse(CloudPlaceholder.isPlaceholderOnly(target))
        XCTAssertGreaterThan(RecordingStore.audioDurationIfDownloaded(for: target), 0,
                             "a downloaded recording reads its header — this is what Play needs")

        // Leave the device as we found it (this is the "Remove Download" path).
        try? FileManager.default.evictUbiquitousItem(at: target)
    }
}
