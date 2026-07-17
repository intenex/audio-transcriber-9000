import XCTest
@testable import AudioTranscriber

final class SpeakerMatcherTests: XCTestCase {

    func testCosineSimilarityIdentical() {
        let v: [Float] = [0.5, 0.5, 0.5, 0.5]
        XCTAssertEqual(SpeakerMatcher.cosineSimilarity(v, v), 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOrthogonal() {
        XCTAssertEqual(SpeakerMatcher.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarityMismatchedLengths() {
        XCTAssertEqual(SpeakerMatcher.cosineSimilarity([1, 0], [1]), 0)
    }

    private func speaker(_ name: String, embeddings: [[Float]]) -> EnrolledSpeaker {
        EnrolledSpeaker(id: UUID(), name: name, createdAt: .now, updatedAt: .now,
                        embeddings: embeddings, clips: [], recordingIDs: [])
    }

    func testThresholdBoundary() {
        let ben = speaker("Ben", embeddings: [[1, 0, 0]])
        // similarity with [0.7, 0.714, 0] ≈ 0.7
        let probe: [Float] = [0.7, 0.7141428, 0]
        XCTAssertNil(SpeakerMatcher.match(embedding: probe, against: [ben], threshold: 0.71))
        XCTAssertNotNil(SpeakerMatcher.match(embedding: probe, against: [ben], threshold: 0.69))
    }

    func testBestOfMultipleEmbeddings() {
        let ben = speaker("Ben", embeddings: [[0, 1, 0], [1, 0, 0]])   // second matches probe
        let alice = speaker("Alice", embeddings: [[0.9, 0.1, 0]])
        let probe: [Float] = [1, 0, 0]
        let match = SpeakerMatcher.match(embedding: probe, against: [ben, alice], threshold: 0.7)
        XCTAssertEqual(match?.speaker.name, "Ben")
        XCTAssertEqual(match?.score ?? 0, 1.0, accuracy: 0.0001)
    }
}

@MainActor
final class SpeakerLibraryStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerLibTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> SpeakerLibraryStore {
        let store = SpeakerLibraryStore()
        store.attach(storageDirectory: tempDir)
        return store
    }

    func testEnrollAndRoundTrip() {
        let store = makeStore()
        store.enroll(name: "Ben", embeddings: [[0.1, 0.2]],
                     clips: [.init(file: "clips/x/clip-1.m4a", duration: 8, sourceRecordingID: nil, start: 10, end: 18)],
                     recordingID: UUID())

        let store2 = makeStore()
        XCTAssertEqual(store2.speakers.count, 1)
        XCTAssertEqual(store2.speakers[0].name, "Ben")
        XCTAssertEqual(store2.speakers[0].embeddings.count, 1)
        XCTAssertEqual(store2.speakers[0].clips.count, 1)
    }

    func testUpsertByNameCaseInsensitive() {
        let store = makeStore()
        let recordingA = UUID()
        let recordingB = UUID()
        store.enroll(name: "Ben", embeddings: [[1, 0]], clips: [], recordingID: recordingA)
        store.enroll(name: "ben", embeddings: [[0, 1]], clips: [], recordingID: recordingB)

        XCTAssertEqual(store.speakers.count, 1)
        XCTAssertEqual(store.speakers[0].embeddings.count, 2)
        XCTAssertEqual(Set(store.speakers[0].recordingIDs), Set([recordingA, recordingB]))
    }

    func testAutoMatchWritesSpeakersJSON() throws {
        let store = makeStore()
        store.enroll(name: "Ben", embeddings: [[1, 0, 0]], clips: [], recordingID: nil)

        let wav = tempDir.appendingPathComponent("rec.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data(count: 100))
        let recording = Recording(fileURL: wav, date: .now, duration: 10)

        let output = TranscriptionOutput(
            result: TranscriptionResult(segments: [], language: "en", numSpeakers: 2),
            speakerNames: [:],
            speakerEmbeddings: ["SPEAKER_00": [0.99, 0.05, 0], "SPEAKER_01": [0, 1, 0]])

        store.handleTranscriptionCompleted(recording: recording, output: output)

        let data = try Data(contentsOf: recording.speakersURL)
        let names = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(names["SPEAKER_00"], "Ben")
        XCTAssertNil(names["SPEAKER_01"])
        XCTAssertTrue(store.speakers[0].recordingIDs.contains(recording.id))
    }

    func testAutoMatchNeverOverwritesUserNames() throws {
        let store = makeStore()
        store.enroll(name: "Ben", embeddings: [[1, 0]], clips: [], recordingID: nil)

        let wav = tempDir.appendingPathComponent("rec2.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data(count: 100))
        let recording = Recording(fileURL: wav, date: .now, duration: 10)
        try #"{"SPEAKER_00": "Dr. Smith"}"#.write(to: recording.speakersURL, atomically: true, encoding: .utf8)

        let output = TranscriptionOutput(
            result: TranscriptionResult(segments: [], language: "en", numSpeakers: 1),
            speakerEmbeddings: ["SPEAKER_00": [1, 0]])
        store.handleTranscriptionCompleted(recording: recording, output: output)

        let names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recording.speakersURL))
        XCTAssertEqual(names["SPEAKER_00"], "Dr. Smith")
    }
}

final class ReferenceClipExtractorTests: XCTestCase {

    private func segment(_ speaker: String, _ start: Double, _ end: Double) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: "text", speaker: speaker)
    }

    func testSelectsLongCleanSegments() {
        let segments = [
            segment("SPEAKER_00", 0, 8),       // clean, 8s
            segment("SPEAKER_01", 8, 12),
            segment("SPEAKER_00", 12, 14),     // 2s — too short
            segment("SPEAKER_00", 20, 26),     // clean, 6s
        ]
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: "SPEAKER_00")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].start, 0)   // longest first
        XCTAssertEqual(candidates[0].end, 8)
    }

    func testExcludesOverlappingSegments() {
        let segments = [
            segment("SPEAKER_00", 0, 6),
            segment("SPEAKER_01", 4, 10),      // overlaps the above
            segment("SPEAKER_00", 12, 18),     // clean
        ]
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: "SPEAKER_00")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].start, 12)
    }

    func testLongSegmentTrimmedToMiddleTen() {
        let segments = [segment("SPEAKER_00", 0, 30)]
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: "SPEAKER_00")
        XCTAssertEqual(candidates[0].duration, 10, accuracy: 0.001)
        XCTAssertEqual(candidates[0].start, 10, accuracy: 0.001)   // middle of 0-30
    }

    func testFallbackWhenNothingClean() {
        let segments = [
            segment("SPEAKER_00", 0, 2),
            segment("SPEAKER_01", 1, 3),
            segment("SPEAKER_00", 5, 7.5),
        ]
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: "SPEAKER_00")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].start, 5)   // longest first
    }

    func testMaxThreeClips() {
        let segments = (0..<6).map { segment("SPEAKER_00", Double($0) * 10, Double($0) * 10 + 4) }
        let candidates = ReferenceClipExtractor.selectCandidates(segments: segments, speakerID: "SPEAKER_00")
        XCTAssertLessThanOrEqual(candidates.count, 3)
    }

    func testResampleLinearHalvesCount() {
        let samples = [Float](repeating: 0.5, count: 32_000)
        let out = ReferenceClipExtractor.resampleLinear(samples, from: 32_000, to: 16_000)
        XCTAssertEqual(out.count, 16_000)
    }
}
