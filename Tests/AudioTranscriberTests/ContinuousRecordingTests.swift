import AVFoundation
import XCTest
@testable import AudioTranscriber

final class ContinuousRecordingTests: XCTestCase {
    func testMixerKeepsSystemSoundAcrossMicrophoneGapsAndWraps() throws {
        var mixer = RecordingTimelineMixer(capacity: 32)
        for block in 0..<100 {
            let frame = Int64(block * 8)
            try mixer.add(Array(repeating: 0.25, count: 8), at: frame)
            if block % 3 != 0 { try mixer.add(Array(repeating: 0.5, count: 8), at: frame) }
            XCTAssertEqual(mixer.take(8), Array(repeating: block % 3 == 0 ? 0.25 : 0.75, count: 8))
        }
        XCTAssertEqual(mixer.nextFrame, 800)
        XCTAssertEqual(mixer.capacity, 32)
    }

    func testMixerRejectsOverflowInsteadOfOverwritingAudio() throws {
        var mixer = RecordingTimelineMixer(capacity: 8)
        XCTAssertThrowsError(try mixer.add([1, 1], at: 7))
        try mixer.add([0.5, 0.75], at: 0)
        XCTAssertEqual(mixer.take(2), [0.5, 0.75])
    }

    func testOpenCAFRemainsReadableWithoutFinalization() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recover-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecoverablePCMFile(url: url, sampleRate: 48_000)
        try writer.append(Array(repeating: 0.25, count: 48_000))
        try writer.synchronize()
        // Read while the writer is STILL OPEN: the same bytes survive SIGKILL.
        let input = try AVAudioFile(forReading: url)
        XCTAssertEqual(input.length, 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 128)!
        try input.read(into: buffer, frameCount: 128)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.25, accuracy: 0.001)
        try writer.close()
    }

    func testDisplayHandlesInvalidUserEnteredTrimValues() {
        XCTAssertEqual(RecordingClock.display(.nan), "--:--")
        XCTAssertEqual(RecordingClock.display(.infinity), "--:--")
        XCTAssertEqual(RecordingClock.display(1e100), "--:--")
        XCTAssertEqual(RecordingClock.display(-1), "00:00")
    }

    func testMixerReportsLateAudioAndClearsFutureSamplesOnResume() throws {
        var mixer = RecordingTimelineMixer(capacity: 10_000)
        _ = mixer.take(5_000)
        XCTAssertThrowsError(try mixer.add([0.5], at: 0))
        try mixer.add([0.5], at: 5_010)
        mixer.clearPending()
        XCTAssertTrue(mixer.take(100).allSatisfy { $0 == 0 })
    }

    func testClockDoesNotWrapOrResetWhenCheckInIsAcknowledged() {
        var clock = RecordingClock()
        clock.start(at: 100)
        var checkIn = LongRecordingCheckIn()
        XCTAssertTrue(checkIn.isDue(at: clock.elapsed(at: 7300)))
        checkIn.acknowledged(at: clock.elapsed(at: 10900))
        XCTAssertEqual(clock.elapsed(at: 10900), 10800)
        XCTAssertEqual(RecordingClock.display(10800), "3:00:00")
        clock.pause(at: 10900)
        XCTAssertEqual(clock.elapsed(at: 15000), 10800)
        clock.resume(at: 15000)
        XCTAssertEqual(clock.elapsed(at: 15060), 10860)
    }
    func testEightHourTimelineHasConstantStorageAndNoWrapLoss() throws {
        var mixer = RecordingTimelineMixer(capacity: 48_000 * 3)
        let secondOfAudio = Array(repeating: Float(0.25), count: 48_000)
        for second in 0..<(8 * 3600) {
            let frame = Int64(second * 48_000)
            try mixer.add(secondOfAudio, at: frame)
            let output = mixer.take(48_000)
            XCTAssertEqual(output.first, 0.25)
            XCTAssertEqual(output.last, 0.25)
        }
        XCTAssertEqual(mixer.nextFrame, 8 * 3600 * 48_000)
        XCTAssertEqual(mixer.capacity, 48_000 * 3)
    }

    func testEightHourCAFCanSeekPastTwoGigabytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EightHour-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try RecoverablePCMFile(url: url, sampleRate: 48_000)
        try header.close()
        // Sparse silence proves the real container/seek offsets without writing
        // gigabytes of test data or simulating eight hours of wall-clock time.
        let frames: Int64 = 8 * 3600 * 48_000
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(68 + frames * 2))
        try handle.seek(toOffset: UInt64(68 + (frames - 4_800) * 2))
        let tail = Array(repeating: Int16(16_384).littleEndian, count: 4_800)
        try tail.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        try handle.close()
        let input = try AVAudioFile(forReading: url)
        XCTAssertEqual(input.length, frames)
        input.framePosition = frames - 4_800
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4_800)!
        try input.read(into: buffer, frameCount: 4_800)
        XCTAssertEqual(buffer.frameLength, 4_800)
        XCTAssertEqual(buffer.floatChannelData![0][4_799], 0.5, accuracy: 0.001)
    }

    func testPlaybackIndexMatchesLinearLookupIncludingOverlaps() {
        let words = (0..<60_000).map { i in
            TranscriptWordRange(range: NSRange(location: i * 5, length: 4),
                                start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.7)
        }
        let index = TranscriptPlaybackIndex(words)
        for time in stride(from: 0.0, through: 30_001.0, by: 113.11) {
            XCTAssertEqual(index.word(at: time), TranscriptTextBuilder.wordRange(at: time, in: words))
        }
    }

    func testUnicodeSearchUsesOriginalCharacterOffsets() {
        let text = "İ 😊 CAFÉ café"
        let ranges = TranscriptTextBuilder.searchRanges(in: text, query: "café")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "CAFÉ")
        XCTAssertEqual((text as NSString).substring(with: ranges[1]), "café")
    }

}
