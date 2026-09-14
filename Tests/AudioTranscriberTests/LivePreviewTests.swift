import AVFoundation
import FluidAudio
import XCTest
@testable import AudioTranscriber

final class LivePreviewTests: XCTestCase {
    func testPreviewWindowsNeverGrowWithRecordingDuration() {
        var window = LivePreviewWindow(capacity: 80)
        let input = Array(repeating: Float(0.25), count: 10)
        var outputs = 0
        for _ in 0..<(8 * 3600 * 10) {
            if let audio = window.append(input) {
                XCTAssertEqual(audio.count, 80)
                XCTAssertEqual(audio.first, 0.25)
                outputs += 1
            }
            XCTAssertLessThan(window.samples.count, 80)
        }
        XCTAssertEqual(outputs, 36_000)
        XCTAssertTrue(window.samples.isEmpty)
    }
    func testOversizedPreviewInputCannotCreateAnUnboundedWindow() {
        var window = LivePreviewWindow(capacity: 8)
        XCTAssertNil(window.append([1, 2]))
        XCTAssertEqual(window.append(Array(repeating: 3, count: 100)), [1, 2, 3, 3, 3, 3, 3, 3])
        XCTAssertTrue(window.samples.isEmpty)
    }
    func testRealLocalPreviewProducesTextFromABoundedWindow() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled, "real model gate not present")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("test_recording.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "local speech fixture not present")
        let worker = LivePreviewWorker()
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory())
        try await worker.initialize(models: models)
        let file = try AVAudioFile(forReading: fixture)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
        var result: String?
        while file.framePosition < file.length && result == nil {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_800, file.length - file.framePosition)))
            result = try await worker.append(buffer)
        }
        XCTAssertFalse((result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        await worker.shutdown()
    }
}
