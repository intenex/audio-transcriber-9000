import AVFoundation
import XCTest
@testable import AudioTranscriber

@MainActor
final class RecordingReviewAndRecoveryTests: XCTestCase {
    func testCaptureOwnershipProtectsLiveFileAndRecoveryIsImmediateAfterClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = SpoolLocation.url(fileName: "recover-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecoverablePCMFile(url: url, sampleRate: 48_000)
        try writer.append(Array(repeating: 0.25, count: 48_000))
        try writer.synchronize()
        let store = RecordingStore(storageDirectory: directory, defaults: UserDefaults(suiteName: "Recovery-\(UUID())")!)
        store.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "another store must not move live audio")
        XCTAssertTrue(store.recordings.isEmpty)
        try writer.close() // Process death releases exactly this OS ownership lock.
        store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.recordings.count, 1, "no 60-second wait to recover a killed recording")
        XCTAssertEqual(store.recordings.first?.duration ?? 0, 1, accuracy: 0.01)
    }

    func testReviewTruncationKeepsExactPrefixAndDefersAutomaticProcessing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Review-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.caf")
        let writer = try RecoverablePCMFile(url: url, sampleRate: 48_000)
        try writer.append(Array(repeating: 0.25, count: 48_000 * 3)); try writer.close()
        let store = RecordingStore(storageDirectory: directory, defaults: UserDefaults(suiteName: "Review-\(UUID())")!)
        var processed = 0
        store.onRecordingAdded = { _ in processed += 1 }
        let recording = Recording(fileURL: url, duration: 3)
        store.insert(recording, notify: false)
        let success = await store.truncateReviewedRecording(recording, keeping: 1.25)
        XCTAssertTrue(success, store.errorMessage ?? "")
        XCTAssertEqual(processed, 0)
        XCTAssertEqual(RecordingStore.audioDuration(for: url), 1.25, accuracy: 0.02)
        XCTAssertEqual(store.recording(with: recording.id)?.duration ?? 0, 1.25, accuracy: 0.02)
        let input = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 128)!
        try input.read(into: buffer, frameCount: 128)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.25, accuracy: 0.001)
    }

    func testWriterResamplesIndependentSourcesThroughMicrophoneFormatChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mixed-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ContinuousRecordingWriter(url: url, monitor: RecordingLevelMonitor()) { error in XCTFail(error) }
        for step in 0..<30 {
            let rate = step < 15 ? 24_000.0 : 48_000.0
            let micFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let mic = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(rate / 10))!
            mic.frameLength = mic.frameCapacity
            mic.floatChannelData![0].initialize(repeating: 0.2, count: Int(mic.frameLength))
            let systemFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let system = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: 4_800)!
            system.frameLength = 4_800
            system.floatChannelData![0].initialize(repeating: 0.1, count: 4_800)
            let timestamp = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
            writer.submit(mic, source: 0, hostTime: timestamp)
            writer.submit(system, source: 1, hostTime: timestamp)
            try await Task.sleep(for: .milliseconds(100))
        }
        let duration = try writer.finish()
        XCTAssertGreaterThan(duration, 2.9)
        let input = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4_800)!
        var mixedFrames = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4_800, input.length - input.framePosition)))
            for i in 0..<Int(buffer.frameLength) where buffer.floatChannelData![0][i] > 0.25 { mixedFrames += 1 }
        }
        XCTAssertGreaterThan(mixedFrames, 48_000 * 2, "both sources must remain mixed across the 24k → 48k change")
    }
}
