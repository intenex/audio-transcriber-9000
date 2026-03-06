import XCTest
@testable import AudioTranscriber

final class AudioRecorderTests: XCTestCase {

    // MARK: - File Naming

    func testRecordingHasUniqueIDs() {
        let r1 = Recording(fileURL: URL(fileURLWithPath: "/tmp/test1.wav"))
        let r2 = Recording(fileURL: URL(fileURLWithPath: "/tmp/test2.wav"))
        XCTAssertNotEqual(r1.id, r2.id)
    }

    func testRecordingDefaultStatus() {
        let r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertEqual(r.status, .pending)
    }

    func testRecordingDefaultTranscriptionURL() {
        let r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertNil(r.transcriptionURL)
    }

    // MARK: - Duration Formatting

    func testDurationStringUnderOneMinute() {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        r.duration = 45
        XCTAssertEqual(r.durationString, "0:45")
    }

    func testDurationStringOneMinute() {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        r.duration = 90
        XCTAssertEqual(r.durationString, "1:30")
    }

    func testDurationStringOverOneHour() {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        r.duration = 3661
        XCTAssertEqual(r.durationString, "1:01:01")
    }

    func testDurationStringZero() {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        r.duration = 0
        XCTAssertEqual(r.durationString, "0:00")
    }

    // MARK: - State Transitions

    func testStatusTransitions() {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertEqual(r.status, .pending)

        r.status = .processing
        XCTAssertEqual(r.status, .processing)

        r.status = .done
        XCTAssertEqual(r.status, .done)

        r.status = .failed
        XCTAssertEqual(r.status, .failed)
    }

    // MARK: - Codable

    func testRecordingCodableRoundTrip() throws {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.wav"), date: Date(timeIntervalSince1970: 0))
        r.duration = 120.5
        r.status = .done
        r.transcriptionURL = URL(fileURLWithPath: "/tmp/test.md")

        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)

        XCTAssertEqual(r.id, decoded.id)
        XCTAssertEqual(r.fileURL, decoded.fileURL)
        XCTAssertEqual(r.duration, decoded.duration)
        XCTAssertEqual(r.status, decoded.status)
        XCTAssertEqual(r.transcriptionURL, decoded.transcriptionURL)
    }

    // MARK: - AudioRecorder State

    func testAudioRecorderInitialState() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.recordingDuration, 0)
        XCTAssertTrue(recorder.recordings.isEmpty)
        XCTAssertNil(recorder.errorMessage)
    }
}
