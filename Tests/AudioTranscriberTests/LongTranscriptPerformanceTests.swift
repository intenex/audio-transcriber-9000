import XCTest
@testable import AudioTranscriber

final class LongTranscriptPerformanceTests: XCTestCase {
    func testEightHourTranscriptHasBoundedParagraphsAndFastPlaybackLookup() {
        let segments = (0..<960).map { i in
            TranscriptionSegment(start: Double(i * 30), end: Double((i + 1) * 30),
                                 text: Array(repeating: "word", count: 75).joined(separator: " "), speaker: "SPEAKER_00")
        }
        let start = Date()
        let output = TranscriptTextBuilder.build(segments: segments, speakerNames: [:])
        XCTAssertEqual(output.wordRanges.count, 72_000)
        XCTAssertLessThan(output.text.string.components(separatedBy: "\n").map(\.count).max() ?? 0, 500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "72,000-word preparation should remain fast")
        let index = TranscriptPlaybackIndex(output.wordRanges)
        let lookupStart = Date()
        for i in 0..<10_000 { XCTAssertNotNil(index.word(at: Double(i) * 2.8)) }
        XCTAssertLessThan(Date().timeIntervalSince(lookupStart), 1)
    }

    #if os(macOS)
    func testRealFiveHourTranscriptLoadsAndBuilds() throws {
        try XCTSkipUnless(IntegrationGate.isEnabled, "integration gate not present")
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/iCloud~com~audiortranscriber~AudioTranscriber/Documents/recording_2026-09-11_12-20-04.segments.json")
        guard let data = CloudPlaceholder.dataIfDownloaded(file) else { throw XCTSkip("local long transcript unavailable") }
        let start = Date()
        let segments = try JSONDecoder().decode([TranscriptionSegment].self, from: data)
        let decoded = Date().timeIntervalSince(start)
        let output = TranscriptTextBuilder.build(segments: segments, speakerNames: [:])
        let elapsed = Date().timeIntervalSince(start)
        print("[long transcript] segments=\(segments.count), words=\(output.wordRanges.count), decode=\(decoded)s, total=\(elapsed)s")
        XCTAssertGreaterThan(output.wordRanges.count, 40_000)
        XCTAssertLessThan(elapsed, 5)
    }
    #endif
}
