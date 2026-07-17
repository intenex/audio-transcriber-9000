import XCTest
@testable import AudioTranscriber

final class AudioSplitPlannerTests: XCTestCase {

    func testShortFileSinglePart() {
        let parts = AudioSplitPlanner.plan(durationSeconds: 3600)   // 1h @32kbps ≈ 14.4MB < 25MB
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].startSeconds, 0)
        XCTAssertEqual(parts[0].endSeconds, 3600)
    }

    func testLongFileSplitsUnderLimit() {
        // 4h56m (the real 3.2GB sample) @32kbps ≈ 71MB → 4 parts
        let duration: Double = 17_781
        let parts = AudioSplitPlanner.plan(durationSeconds: duration)
        XCTAssertGreaterThan(parts.count, 1)

        let maxSeconds = Double(CloudAudioSpec.uploadLimitBytes) * CloudAudioSpec.headroom * 8 / Double(CloudAudioSpec.bitrate)
        for part in parts {
            XCTAssertLessThanOrEqual(part.duration, maxSeconds + 1)
        }
        // Contiguous full coverage
        XCTAssertEqual(parts.first?.startSeconds, 0)
        XCTAssertEqual(parts.last?.endSeconds ?? 0, duration, accuracy: 0.001)
        for (a, b) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(a.endSeconds, b.startSeconds, accuracy: 0.001)
        }
    }

    func testZeroDuration() {
        XCTAssertTrue(AudioSplitPlanner.plan(durationSeconds: 0).isEmpty)
    }
}

final class PartMergerTests: XCTestCase {

    private func segment(_ speaker: String?, _ start: Double, _ end: Double, _ text: String = "hello") -> DiarizedJSONResponse.Segment {
        .init(id: nil, start: start, end: end, text: text, speaker: speaker, type: nil)
    }

    func testTimeOffsetsApplied() {
        var merger = PartMerger()
        let merged = merger.merge(segments: [segment("A", 5, 10)], offsetSeconds: 100)
        XCTAssertEqual(merged[0].start, 105)
        XCTAssertEqual(merged[0].end, 110)
    }

    func testCanonicalMinting() {
        var merger = PartMerger()
        let merged = merger.merge(segments: [
            segment("A", 0, 1), segment("B", 1, 2), segment("A", 2, 3),
        ], offsetSeconds: 0)
        XCTAssertEqual(merged.map(\.speaker), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
    }

    func testEnrolledNamePropagatesToSpeakerNames() {
        var merger = PartMerger(enrolledNames: ["Ben"])
        _ = merger.merge(segments: [segment("Ben", 0, 1), segment("A", 1, 2)], offsetSeconds: 0)
        XCTAssertEqual(merger.speakerNames["SPEAKER_00"], "Ben")
        XCTAssertNil(merger.speakerNames["SPEAKER_01"])
    }

    func testContinuityTokenMapsBackToCanonical() {
        var merger = PartMerger()
        _ = merger.merge(segments: [segment("A", 0, 1)], offsetSeconds: 0)      // SPEAKER_00
        let token = merger.continuityToken(for: "SPEAKER_00")
        XCTAssertEqual(token, "S1")
        merger.registerAlias(label: token, canonical: "SPEAKER_00")
        // Part 2 returns the token as the speaker label
        let merged = merger.merge(segments: [segment("S1", 0, 1)], offsetSeconds: 60)
        XCTAssertEqual(merged[0].speaker, "SPEAKER_00")
    }

    func testEmptyTextSkipped() {
        var merger = PartMerger()
        let merged = merger.merge(segments: [segment("A", 0, 1, "  ")], offsetSeconds: 0)
        XCTAssertTrue(merged.isEmpty)
    }
}

final class DiarizedJSONParsingTests: XCTestCase {

    func testFullPayload() throws {
        let json = """
        {"text": "Hello world", "duration": 12.5, "task": "transcribe",
         "segments": [
            {"id": "seg_0", "start": 0.1, "end": 4.9, "text": "Hello", "speaker": "A", "type": "transcript.text.segment"},
            {"id": "seg_1", "start": 5.0, "end": 12.4, "text": "world", "speaker": "Ben", "extra_future_field": 42}
         ], "usage": {"type": "duration", "seconds": 13}}
        """
        let response = try JSONDecoder().decode(DiarizedJSONResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.segments.count, 2)
        XCTAssertEqual(response.segments[1].speaker, "Ben")
    }

    func testMissingSpeakerTolerated() throws {
        let json = #"{"segments": [{"start": 0, "end": 1, "text": "hi"}]}"#
        let response = try JSONDecoder().decode(DiarizedJSONResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.segments[0].speaker)
    }
}

final class AssemblyAIMappingTests: XCTestCase {

    func testUtteranceMapping() throws {
        let json = """
        {"id": "t1", "status": "completed", "language_code": "en",
         "utterances": [
            {"speaker": "A", "start": 500, "end": 3200, "text": "Hi there",
             "words": [{"text": "Hi", "start": 500, "end": 900, "speaker": "A"},
                       {"text": "there", "start": 1000, "end": 3200, "speaker": "A"}]},
            {"speaker": "B", "start": 3500, "end": 6000, "text": "Hello"}
         ]}
        """
        let response = try JSONDecoder().decode(AssemblyAITranscriptionEngine.TranscriptResponse.self, from: Data(json.utf8))
        let segments = AssemblyAITranscriptionEngine.mapToSegments(response)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(segments[1].speaker, "SPEAKER_01")
        XCTAssertEqual(segments[0].start, 0.5, accuracy: 0.001)
        XCTAssertEqual(segments[0].words.count, 2)
        XCTAssertEqual(segments[0].words[1].start ?? 0, 1.0, accuracy: 0.001)
    }

    func testWordsOnlyFallback() throws {
        let json = """
        {"id": "t2", "status": "completed",
         "words": [{"text": "solo", "start": 0, "end": 800, "speaker": null}]}
        """
        let response = try JSONDecoder().decode(AssemblyAITranscriptionEngine.TranscriptResponse.self, from: Data(json.utf8))
        let segments = AssemblyAITranscriptionEngine.mapToSegments(response)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "solo")
    }

    func testEmpty() throws {
        let json = #"{"id": "t3", "status": "completed"}"#
        let response = try JSONDecoder().decode(AssemblyAITranscriptionEngine.TranscriptResponse.self, from: Data(json.utf8))
        XCTAssertTrue(AssemblyAITranscriptionEngine.mapToSegments(response).isEmpty)
    }
}

final class CostEstimatorTests: XCTestCase {
    func testEstimates() {
        XCTAssertEqual(TranscriptionCostEstimator.estimateUSD(duration: 3600, kind: .openAI) ?? 0, 0.36, accuracy: 0.001)
        XCTAssertEqual(TranscriptionCostEstimator.estimateString(duration: 3600, kind: .openAI), "≈ $0.36")
        XCTAssertEqual(TranscriptionCostEstimator.estimateString(duration: 30, kind: .openAI), "≈ <$0.01")
        XCTAssertNil(TranscriptionCostEstimator.estimateUSD(duration: 100, kind: .local))
    }
}

/// Mocked HTTP flow for the AssemblyAI engine (upload → create → poll → completed).
final class AssemblyAIEngineFlowTests: XCTestCase {

    func testFullFlowAgainstMockServer() async throws {
        // Use the real test fixture so compression genuinely runs.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test_recording.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path))

        let secrets = InMemorySecretsStore([.assemblyAI: "aai-key"])
        let engine = AssemblyAITranscriptionEngine(secrets: secrets, session: MockURLProtocol.makeSession())

        nonisolated(unsafe) var pollCount = 0
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            let ok = { (json: String) in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 Data(json.utf8))
            }
            switch path {
            case "/v2/upload":
                XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "aai-key")
                return ok(#"{"upload_url": "https://cdn.assemblyai.com/upload/xyz"}"#)
            case "/v2/transcript":
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                XCTAssertEqual(body?["speaker_labels"] as? Bool, true)
                return ok(#"{"id": "job1", "status": "queued"}"#)
            case "/v2/transcript/job1":
                pollCount += 1
                if pollCount < 2 {
                    return ok(#"{"id": "job1", "status": "processing"}"#)
                }
                return ok("""
                {"id": "job1", "status": "completed", "language_code": "en",
                 "utterances": [{"speaker": "A", "start": 0, "end": 2000, "text": "Test complete"}]}
                """)
            default:
                XCTFail("unexpected path \(path)")
                throw URLError(.badURL)
            }
        }
        defer { MockURLProtocol.requestHandler = nil }

        let request = TranscriptionRequest(
            recordingID: UUID(), audioURL: fixture, durationSeconds: 63,
            language: nil, checkpointURL: FileManager.default.temporaryDirectory.appendingPathComponent("x.partial.json"))

        let output = try await engine.transcribe(request) { _ in }
        XCTAssertEqual(output.result.segments.count, 1)
        XCTAssertEqual(output.result.segments[0].text, "Test complete")
        XCTAssertEqual(output.result.segments[0].speaker, "SPEAKER_00")
    }
}
