import XCTest
@testable import AudioTranscriber

final class TranscriptionServiceTests: XCTestCase {

    // MARK: - JSON Parsing

    func testParseValidTranscriptionJSON() throws {
        let json = """
        {
            "segments": [
                {"start": 0.5, "end": 3.2, "text": "Hello everyone.", "speaker": "SPEAKER_00"},
                {"start": 3.5, "end": 6.1, "text": "Welcome to the meeting.", "speaker": "SPEAKER_01"}
            ],
            "language": "en",
            "num_speakers": 2
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.numSpeakers, 2)
    }

    func testParseSegmentFields() throws {
        let json = """
        {
            "segments": [
                {"start": 1.23, "end": 4.56, "text": "Test segment.", "speaker": "SPEAKER_00"}
            ],
            "language": "fr",
            "num_speakers": 1
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        let seg = result.segments[0]

        XCTAssertEqual(seg.start, 1.23, accuracy: 0.001)
        XCTAssertEqual(seg.end, 4.56, accuracy: 0.001)
        XCTAssertEqual(seg.text, "Test segment.")
        XCTAssertEqual(seg.speaker, "SPEAKER_00")
    }

    func testParseEmptySegments() throws {
        let json = """
        {"segments": [], "language": "en", "num_speakers": 0}
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.numSpeakers, 0)
    }

    func testInvalidJSONThrows() {
        let data = "not valid json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionResult.self, from: data))
    }

    // MARK: - Markdown Formatting

    func testMarkdownHasHeader() throws {
        let result = makeResult(segments: [
            TranscriptionSegment(start: 0, end: 2, text: "Hello.", speaker: "SPEAKER_00"),
        ])
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"), date: Date(timeIntervalSince1970: 0))
        let markdown = MarkdownFormatter.format(result: result, recording: recording)

        XCTAssertTrue(markdown.contains("# Transcription —"))
    }

    func testMarkdownHasSpeakerLabels() throws {
        let result = makeResult(segments: [
            TranscriptionSegment(start: 0, end: 2, text: "Hello.", speaker: "SPEAKER_00"),
            TranscriptionSegment(start: 2, end: 4, text: "Hi there.", speaker: "SPEAKER_01"),
        ])
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        let markdown = MarkdownFormatter.format(result: result, recording: recording)

        XCTAssertTrue(markdown.contains("**Speaker 1**"))
        XCTAssertTrue(markdown.contains("**Speaker 2**"))
    }

    func testMarkdownGroupsConsecutiveSpeaker() throws {
        let result = makeResult(segments: [
            TranscriptionSegment(start: 0, end: 1, text: "First.", speaker: "SPEAKER_00"),
            TranscriptionSegment(start: 1, end: 2, text: "Second.", speaker: "SPEAKER_00"),
            TranscriptionSegment(start: 2, end: 3, text: "Third.", speaker: "SPEAKER_01"),
        ])
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        let markdown = MarkdownFormatter.format(result: result, recording: recording)

        // Should only have Speaker 1 appear once for the first two segments
        let speaker1Count = markdown.components(separatedBy: "**Speaker 1**").count - 1
        XCTAssertEqual(speaker1Count, 1)
    }

    func testMarkdownContainsTimestamps() throws {
        let result = makeResult(segments: [
            TranscriptionSegment(start: 65, end: 70, text: "At one minute.", speaker: "SPEAKER_00"),
        ])
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        let markdown = MarkdownFormatter.format(result: result, recording: recording)

        XCTAssertTrue(markdown.contains("0:01:05"))
    }

    func testMarkdownHasDurationAndSpeakerCount() throws {
        var recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        recording.duration = 263  // 4:23
        let result = makeResult(segments: [], numSpeakers: 3)
        let markdown = MarkdownFormatter.format(result: result, recording: recording)

        XCTAssertTrue(markdown.contains("**Duration:**"))
        XCTAssertTrue(markdown.contains("**Speakers detected:** 3"))
    }

    // MARK: - Timestamp Formatting

    func testFormatTimestampSeconds() {
        XCTAssertEqual(MarkdownFormatter.formatTimestamp(45), "0:00:45")
    }

    func testFormatTimestampMinutes() {
        XCTAssertEqual(MarkdownFormatter.formatTimestamp(90), "0:01:30")
    }

    func testFormatTimestampHours() {
        XCTAssertEqual(MarkdownFormatter.formatTimestamp(3661), "1:01:01")
    }

    // MARK: - TranscriptionService Initial State

    func testServiceInitialState() {
        let service = TranscriptionService()
        XCTAssertFalse(service.isTranscribing)
        XCTAssertTrue(service.progress.isEmpty)
        XCTAssertNil(service.errorMessage)
    }

    // MARK: - Helpers

    private func makeResult(
        segments: [TranscriptionSegment],
        language: String = "en",
        numSpeakers: Int? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            segments: segments,
            language: language,
            numSpeakers: numSpeakers ?? Set(segments.map(\.speaker)).count
        )
    }
}
