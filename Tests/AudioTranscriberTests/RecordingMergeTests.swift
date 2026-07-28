import AVFoundation
import XCTest
@testable import AudioTranscriber

/// Combining recordings, with real audio: the order the user picked has to be
/// the order that comes out, and nothing may be destroyed unless it was asked
/// for and the replacement is already verified on disk.
@MainActor
final class RecordingMergeTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "MergeTests-\(UUID().uuidString)")!)
        store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A tone at `amplitude` — loud and quiet parts are what let a test tell
    /// which half of the merged file it is looking at.
    @discardableResult
    private func makeRecording(_ name: String, seconds: Double, amplitude: Float,
                               date: Date = .now) throws -> Recording {
        let url = tempDir.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * 24_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = sinf(Float(i) * 0.08) * amplitude
            }
            try file.write(from: buffer)
        }
        let recording = Recording(fileURL: url, date: date,
                                  duration: RecordingStore.audioDuration(for: url))
        store.insert(recording)
        return recording
    }

    /// Mean square level of one time window of a file, in dBFS.
    private func level(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(start * format.sampleRate)
        let endFrame = min(file.length, AVAudioFramePosition(end * format.sampleRate))
        file.framePosition = startFrame
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        var sum: Double = 0
        var count: Double = 0
        while file.framePosition < endFrame {
            let remaining = endFrame - file.framePosition
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(4_096), remaining))
            guard frames > 0 else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            for i in 0..<Int(buffer.frameLength) {
                let sample = Double(buffer.floatChannelData![0][i])
                sum += sample * sample
                count += 1
            }
        }
        guard count > 0, sum > 0 else { return -120 }
        return 20 * log10f(Float(sqrt(sum / count)))
    }

    func testCombineJoinsPartsInTheGivenOrder() async throws {
        let loud = try makeRecording("loud", seconds: 2, amplitude: 0.5,
                                     date: Date(timeIntervalSince1970: 2_000))
        let quiet = try makeRecording("quiet", seconds: 2, amplitude: 0.0004,
                                      date: Date(timeIntervalSince1970: 1_000))

        let combined = await store.combine([loud, quiet], name: "Loud then quiet", format: .wav)
        let result = try XCTUnwrap(combined)

        XCTAssertEqual(result.duration, 4, accuracy: 0.2, "the parts' durations add up")
        XCTAssertEqual(result.status, .pending, "the combined audio has no transcript yet")
        XCTAssertEqual(result.name, "Loud then quiet")
        XCTAssertEqual(result.date, Date(timeIntervalSince1970: 1_000),
                       "dated from the earliest part — when the conversation happened")

        let first = try level(of: result.fileURL, from: 0.2, to: 1.8)
        let second = try level(of: result.fileURL, from: 2.2, to: 3.8)
        XCTAssertGreaterThan(first, -20, "the loud part came first")
        XCTAssertLessThan(second, -50, "the quiet part came second")
    }

    func testReversingTheOrderReversesTheAudio() async throws {
        let loud = try makeRecording("loud", seconds: 2, amplitude: 0.5)
        let quiet = try makeRecording("quiet", seconds: 2, amplitude: 0.0004)

        let combined = await store.combine([quiet, loud], format: .wav)
        let result = try XCTUnwrap(combined)
        let first = try level(of: result.fileURL, from: 0.2, to: 1.8)
        let second = try level(of: result.fileURL, from: 2.2, to: 3.8)
        XCTAssertLessThan(first, -50, "the quiet part was put first this time")
        XCTAssertGreaterThan(second, -20)
    }

    func testOriginalsAreKeptByDefault() async throws {
        let a = try makeRecording("a", seconds: 1, amplitude: 0.3)
        let b = try makeRecording("b", seconds: 1, amplitude: 0.3)

        _ = await store.combine([a, b], format: .wav)
        XCTAssertEqual(store.recordings.count, 3, "combined file added, originals untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.fileURL.path))
        XCTAssertTrue(store.mergingIDs.isEmpty)
    }

    func testDeleteOriginalsRemovesPartsAndTheirSidecars() async throws {
        let a = try makeRecording("a", seconds: 1, amplitude: 0.3)
        let b = try makeRecording("b", seconds: 1, amplitude: 0.3)
        try "# part a".write(to: a.markdownURL, atomically: true, encoding: .utf8)

        let combined = await store.combine([a, b], deleteOriginals: true, format: .wav)
        let result = try XCTUnwrap(combined)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.id, result.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.markdownURL.path), "sidecars go too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path),
                      "and the combined file is the one that survives")
    }

    func testRefusesFewerThanTwoParts() async throws {
        let a = try makeRecording("a", seconds: 1, amplitude: 0.3)
        let result = await store.combine([a], format: .wav)
        XCTAssertNil(result)
        XCTAssertNotNil(store.errorMessage)
    }

    func testRefusesAPartThatIsBeingTranscribed() async throws {
        let a = try makeRecording("a", seconds: 1, amplitude: 0.3)
        let b = try makeRecording("b", seconds: 1, amplitude: 0.3)
        store.update(a.id) { $0.status = .processing }

        let result = await store.combine([store.recording(with: a.id)!, b], format: .wav)
        XCTAssertNil(result, "moving the file under a running engine is not allowed")
        XCTAssertTrue(store.errorMessage?.contains("transcribed") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL.path))
    }

    func testRefusesTheRecordingBeingCapturedRightNow() async throws {
        let a = try makeRecording("a", seconds: 1, amplitude: 0.3)
        let b = try makeRecording("b", seconds: 1, amplitude: 0.3)
        store.activeRecordingURL = a.fileURL

        let result = await store.combine([a, b], format: .wav)
        XCTAssertNil(result)
        XCTAssertTrue(store.errorMessage?.contains("still being recorded") == true)
    }

    func testPlanRejectsAnUnreadablePart() throws {
        let good = try makeRecording("good", seconds: 1, amplitude: 0.3)
        let brokenURL = tempDir.appendingPathComponent("broken.m4a")
        FileManager.default.createFile(atPath: brokenURL.path, contents: Data(count: 4_096))
        let broken = Recording(fileURL: brokenURL, date: .now, duration: 30)

        XCTAssertThrowsError(try RecordingMerger.plan(for: [good, broken])) { error in
            guard case RecordingMerger.MergeError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testPlanTotalsComeFromTheFilesNotTheManifest() throws {
        var a = try makeRecording("a", seconds: 2, amplitude: 0.3)
        let b = try makeRecording("b", seconds: 1, amplitude: 0.3)
        // A legacy manifest duration that is nowhere near the truth.
        a.duration = 9_999
        let plan = try RecordingMerger.plan(for: [a, b], format: .wav)
        XCTAssertEqual(plan.totalDuration, 3, accuracy: 0.1)
        XCTAssertTrue(plan.isValid)
    }
}
