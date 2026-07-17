import XCTest
@testable import AudioTranscriber

/// The platform-neutral transcript renderer both text views consume. The
/// range→time map must be exact — it drives click-to-seek and highlighting.
final class TranscriptTextBuilderTests: XCTestCase {

    private func seg(_ speaker: String, _ start: Double, _ end: Double, _ text: String,
                     words: [TranscriptionWord] = []) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text, speaker: speaker, words: words)
    }

    func testWordRangesMapBackToExactText() {
        let words = [
            TranscriptionWord(word: "hello", start: 0.0, end: 0.5),
            TranscriptionWord(word: "world", start: 0.5, end: 1.0),
        ]
        let output = TranscriptTextBuilder.build(
            segments: [seg("SPEAKER_00", 0, 1, "hello world", words: words)],
            speakerNames: [:])

        XCTAssertEqual(output.wordRanges.count, 2)
        let full = output.text.string as NSString
        XCTAssertEqual(full.substring(with: output.wordRanges[0].range), "hello")
        XCTAssertEqual(full.substring(with: output.wordRanges[1].range), "world")
        XCTAssertEqual(output.wordRanges[0].start, 0.0)
        XCTAssertEqual(output.wordRanges[1].start, 0.5)
        XCTAssertTrue(full.contains("Speaker 1   [0:00:00]"))
    }

    func testConsecutiveSameSpeakerSegmentsMergeIntoOneHeader() {
        let output = TranscriptTextBuilder.build(
            segments: [seg("SPEAKER_00", 0, 1, "one"), seg("SPEAKER_00", 1, 2, "two"),
                       seg("SPEAKER_01", 2, 3, "three")],
            speakerNames: ["SPEAKER_01": "Alice"])

        let text = output.text.string
        XCTAssertEqual(text.components(separatedBy: "Speaker 1").count - 1, 1,
                       "consecutive same-speaker segments share one header")
        XCTAssertTrue(text.contains("Alice   ["))
    }

    func testInterpolationFallbackWhenNoWordTimings() {
        let output = TranscriptTextBuilder.build(
            segments: [seg("SPEAKER_00", 10, 14, "a b c d")], speakerNames: [:])
        XCTAssertEqual(output.wordRanges.count, 4)
        XCTAssertEqual(output.wordRanges[0].start, 10.0, accuracy: 0.001)
        XCTAssertEqual(output.wordRanges[3].end, 14.0, accuracy: 0.001)
    }

    func testSearchRangesAreCaseInsensitiveAndComplete() {
        let ranges = TranscriptTextBuilder.searchRanges(in: "Foo bar foo FOO", query: "foo")
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(TranscriptTextBuilder.searchRanges(in: "anything", query: "").count, 0)
    }

    func testWordRangeAtTimeAndSeekLookup() {
        let words = [
            TranscriptionWord(word: "hello", start: 0.0, end: 0.5),
            TranscriptionWord(word: "world", start: 0.5, end: 1.0),
        ]
        let output = TranscriptTextBuilder.build(
            segments: [seg("SPEAKER_00", 0, 1, "hello world", words: words)],
            speakerNames: [:])

        XCTAssertEqual(TranscriptTextBuilder.wordRange(at: 0.25, in: output.wordRanges),
                       output.wordRanges[0].range)
        XCTAssertEqual(TranscriptTextBuilder.wordRange(at: 0.75, in: output.wordRanges),
                       output.wordRanges[1].range)
        XCTAssertNil(TranscriptTextBuilder.wordRange(at: 5.0, in: output.wordRanges))

        let tapIndex = output.wordRanges[1].range.location + 1
        XCTAssertEqual(TranscriptTextBuilder.seekTime(forCharacterAt: tapIndex, in: output.wordRanges), 0.5)
    }
}
