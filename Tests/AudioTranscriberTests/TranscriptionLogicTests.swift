import XCTest
@testable import AudioTranscriber

// MARK: - ChunkPlanner

final class ChunkPlannerTests: XCTestCase {

    func testShortFileSingleChunk() {
        let plan = ChunkPlanner.plan(durationSeconds: 63, speechSegments: [])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].startSeconds, 0)
        XCTAssertEqual(plan[0].endSeconds, 63)
    }

    func testPlanCoversFullDurationContiguously() {
        let plan = ChunkPlanner.plan(durationSeconds: 3600, speechSegments: [])
        XCTAssertEqual(plan.first?.startSeconds, 0)
        XCTAssertEqual(plan.last?.endSeconds, 3600)
        for (a, b) in zip(plan, plan.dropFirst()) {
            XCTAssertEqual(a.endSeconds, b.startSeconds, accuracy: 0.0001, "no holes/overlap")
            XCTAssertGreaterThan(a.duration, 0)
        }
        // ~3600/180 = 20 chunks expected (±1 for tail merge)
        XCTAssertTrue((19...21).contains(plan.count), "got \(plan.count)")
    }

    func testBoundarySnapsToSilenceGap() {
        // Speech: [0, 170], [190, 400] — gap midpoint at 180... exactly target.
        // Move gap: [0, 160], [200, 400] → midpoint 180 == target 180, snaps trivially.
        // Use an offset gap: [0, 150], [165, 400] → midpoint 157.5, within ±30 of 180.
        let plan = ChunkPlanner.plan(
            durationSeconds: 400,
            speechSegments: [0...150, 165...400],
            targetChunkSeconds: 180,
            snapWindowSeconds: 30
        )
        // First boundary snaps to the gap midpoint; remaining 242.5s splits again.
        XCTAssertEqual(plan[0].endSeconds, 157.5, accuracy: 0.001)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.last?.endSeconds ?? 0, 400, accuracy: 0.001)
    }

    func testNoGapInWindowHardCutsAtTarget() {
        let plan = ChunkPlanner.plan(
            durationSeconds: 400,
            speechSegments: [0...400],   // continuous speech, no gaps
            targetChunkSeconds: 180,
            snapWindowSeconds: 30
        )
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].endSeconds, 180, accuracy: 0.001)
    }

    func testDeterministic() {
        let a = ChunkPlanner.plan(durationSeconds: 7200, speechSegments: [0...7200])
        let b = ChunkPlanner.plan(durationSeconds: 7200, speechSegments: [0...7200])
        XCTAssertEqual(a, b)
    }

    func testZeroDuration() {
        XCTAssertTrue(ChunkPlanner.plan(durationSeconds: 0, speechSegments: []).isEmpty)
    }
}

// MARK: - SpeakerAssigner

final class SpeakerAssignerTests: XCTestCase {
    private let turns = [
        SpeakerTurn(start: 0, end: 10, speaker: "A"),
        SpeakerTurn(start: 10, end: 20, speaker: "B"),
        SpeakerTurn(start: 25, end: 30, speaker: "A"),
    ]

    func testMaxOverlapWins() {
        let words = [("hello", 9.0, 12.0)]  // 1s overlap with A, 2s with B
        let labeled = SpeakerAssigner.assign(words: words.map { (word: $0.0, start: $0.1, end: $0.2) }, turns: turns)
        XCTAssertEqual(labeled[0].speaker, "B")
    }

    func testTieGoesToEarlierTurn() {
        let words = [(word: "mid", start: 9.0, end: 11.0)]  // 1s overlap each
        let labeled = SpeakerAssigner.assign(words: words, turns: turns)
        XCTAssertEqual(labeled[0].speaker, "A")
    }

    func testZeroOverlapNearestMidpoint() {
        let words = [(word: "gap", start: 21.0, end: 22.0)]  // between B(10-20) and A(25-30)
        let labeled = SpeakerAssigner.assign(words: words, turns: turns)
        // word midpoint 21.5; B midpoint 15 (d=6.5), A(25-30) midpoint 27.5 (d=6.0) → A
        XCTAssertEqual(labeled[0].speaker, "A")
    }

    func testEmptyTurnsFallback() {
        let words = [(word: "solo", start: 0.0, end: 1.0)]
        let labeled = SpeakerAssigner.assign(words: words, turns: [])
        XCTAssertEqual(labeled[0].speaker, "SPEAKER_00")
    }

    func testManyWordsAcrossTurns() {
        let words = (0..<30).map { (word: "w\($0)", start: Double($0), end: Double($0) + 0.9) }
        let labeled = SpeakerAssigner.assign(words: words, turns: turns)
        XCTAssertEqual(labeled[5].speaker, "A")
        XCTAssertEqual(labeled[15].speaker, "B")
        XCTAssertEqual(labeled[27].speaker, "A")
    }

    func testNormalizeFirstAppearanceOrder() {
        let words = [
            LabeledWord(word: "a", start: 0, end: 1, speaker: "raw_B"),
            LabeledWord(word: "b", start: 1, end: 2, speaker: "raw_A"),
            LabeledWord(word: "c", start: 2, end: 3, speaker: "raw_B"),
        ]
        let (normalized, mapping) = SpeakerAssigner.normalizeSpeakerIDs(words)
        XCTAssertEqual(normalized.map(\.speaker), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        XCTAssertEqual(mapping["raw_B"], "SPEAKER_00")
        XCTAssertEqual(mapping["raw_A"], "SPEAKER_01")
    }
}

// MARK: - TranscriptMerger

final class TranscriptMergerTests: XCTestCase {

    private func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String = "SPEAKER_00") -> LabeledWord {
        LabeledWord(word: text, start: start, end: end, speaker: speaker)
    }

    func testSplitsOnSpeakerChange() {
        let segments = TranscriptMerger.makeSegments(from: [
            word("hi", 0, 0.5, "SPEAKER_00"),
            word("there", 0.6, 1.0, "SPEAKER_00"),
            word("hello", 1.1, 1.5, "SPEAKER_01"),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "hi there")
        XCTAssertEqual(segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(segments[1].speaker, "SPEAKER_01")
    }

    func testSplitsOnLongGap() {
        let segments = TranscriptMerger.makeSegments(from: [
            word("one", 0, 0.5),
            word("two", 2.0, 2.5),   // 1.5s gap > 0.8
        ])
        XCTAssertEqual(segments.count, 2)
    }

    func testSplitsAfterSentencePunctuationWithSmallGap() {
        let segments = TranscriptMerger.makeSegments(from: [
            word("done.", 0, 0.5),
            word("Next", 0.9, 1.3),   // 0.4s gap > 0.3 after "."
        ])
        XCTAssertEqual(segments.count, 2)
    }

    func testNoSplitOnTinyGapWithoutPunctuation() {
        let segments = TranscriptMerger.makeSegments(from: [
            word("continuing", 0, 0.5),
            word("speech", 0.9, 1.3),
        ])
        XCTAssertEqual(segments.count, 1)
    }

    func testSegmentTimesAndWords() {
        let segments = TranscriptMerger.makeSegments(from: [
            word("a", 5.0, 5.5),
            word("b", 5.6, 6.0),
        ])
        XCTAssertEqual(segments[0].start, 5.0)
        XCTAssertEqual(segments[0].end, 6.0)
        XCTAssertEqual(segments[0].words.count, 2)
        XCTAssertEqual(segments[0].words[1].start, 5.6)
    }

    func testMaxLengthCap() {
        // 40s of continuous words, no punctuation, same speaker
        let words = (0..<80).map { word("w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        let segments = TranscriptMerger.makeSegments(from: words)
        XCTAssertGreaterThan(segments.count, 1)
        for seg in segments {
            XCTAssertLessThanOrEqual(seg.end - seg.start, TranscriptMerger.maxSegmentSeconds + 1)
        }
    }

    func testEmptyInput() {
        XCTAssertTrue(TranscriptMerger.makeSegments(from: []).isEmpty)
    }

    func testInterpolateWords() {
        let words = TranscriptMerger.interpolateWords(text: "one two three four", start: 10, end: 14)
        XCTAssertEqual(words.count, 4)
        XCTAssertEqual(words[0].start, 10.0, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 11.0, accuracy: 0.001)
        XCTAssertEqual(words[3].end, 14.0, accuracy: 0.001)
    }

    func testInterpolateEmptyText() {
        XCTAssertTrue(TranscriptMerger.interpolateWords(text: "  ", start: 0, end: 5).isEmpty)
    }
}

// MARK: - Checkpoint

final class TranscriptionCheckpointTests: XCTestCase {
    private var tempURL: URL!
    private let fingerprint = TranscriptionCheckpoint.AudioFingerprint(fileSizeBytes: 1000, durationSeconds: 300)

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString).partial.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func makeCheckpoint() -> TranscriptionCheckpoint {
        TranscriptionCheckpoint(
            engineID: "test.engine",
            recordingID: UUID(),
            audioFingerprint: fingerprint,
            chunkPlan: [
                ChunkSpec(index: 0, startSeconds: 0, endSeconds: 150),
                ChunkSpec(index: 1, startSeconds: 150, endSeconds: 300),
            ]
        )
    }

    func testRoundTrip() {
        var checkpoint = makeCheckpoint()
        checkpoint.record(.init(index: 0, text: "hello world",
                                words: [TranscriptionWord(word: "hello", start: 0.1, end: 0.4)],
                                processingSeconds: 1.5))
        checkpoint.save(to: tempURL)

        let loaded = TranscriptionCheckpoint.loadIfValid(from: tempURL, engineID: "test.engine", fingerprint: fingerprint)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.chunks.count, 1)
        XCTAssertEqual(loaded?.chunks.first?.text, "hello world")
        XCTAssertEqual(loaded?.chunkPlan.count, 2)
        XCTAssertEqual(loaded?.completedChunkIndices, [0])
    }

    func testCompletedAudioSeconds() {
        var checkpoint = makeCheckpoint()
        XCTAssertEqual(checkpoint.completedAudioSeconds, 0)
        checkpoint.record(.init(index: 1, text: "x", words: [], processingSeconds: 1))
        XCTAssertEqual(checkpoint.completedAudioSeconds, 150, accuracy: 0.001)
    }

    func testEngineMismatchDiscards() {
        makeCheckpoint().save(to: tempURL)
        let loaded = TranscriptionCheckpoint.loadIfValid(from: tempURL, engineID: "other.engine", fingerprint: fingerprint)
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "stale checkpoint deleted")
    }

    func testFingerprintMismatchDiscards() {
        makeCheckpoint().save(to: tempURL)
        let other = TranscriptionCheckpoint.AudioFingerprint(fileSizeBytes: 999, durationSeconds: 300)
        XCTAssertNil(TranscriptionCheckpoint.loadIfValid(from: tempURL, engineID: "test.engine", fingerprint: other))
    }

    func testRecordReplacesSameIndex() {
        var checkpoint = makeCheckpoint()
        checkpoint.record(.init(index: 0, text: "first", words: [], processingSeconds: 1))
        checkpoint.record(.init(index: 0, text: "second", words: [], processingSeconds: 1))
        XCTAssertEqual(checkpoint.chunks.count, 1)
        XCTAssertEqual(checkpoint.chunks[0].text, "second")
    }
}

// MARK: - RTF / ETA

final class RTFCalibrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "RTFTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultWhenUnset() {
        XCTAssertEqual(RTFStore.rtf(engineID: "x", defaults: defaults), RTFStore.defaultASR)
        XCTAssertFalse(RTFStore.hasCalibration(engineID: "x", defaults: defaults))
    }

    func testFirstRecordSetsMeasured() {
        RTFStore.record(engineID: "x", audioSeconds: 180, processingSeconds: 2, defaults: defaults)
        XCTAssertEqual(RTFStore.rtf(engineID: "x", defaults: defaults), 90, accuracy: 0.001)
    }

    func testEMABlending() {
        RTFStore.record(engineID: "x", audioSeconds: 100, processingSeconds: 1, defaults: defaults)  // 100
        RTFStore.record(engineID: "x", audioSeconds: 50, processingSeconds: 1, defaults: defaults)   // measured 50
        // 0.3*50 + 0.7*100 = 85
        XCTAssertEqual(RTFStore.rtf(engineID: "x", defaults: defaults), 85, accuracy: 0.001)
    }

    func testIgnoresDegenerateSamples() {
        RTFStore.record(engineID: "x", audioSeconds: 100, processingSeconds: 0, defaults: defaults)
        XCTAssertFalse(RTFStore.hasCalibration(engineID: "x", defaults: defaults))
    }

    func testETAFormula() {
        let calc = ETACalculator(asrRTF: 100, diarizerRTF: 50, totalAudioSeconds: 3600)
        // Remaining ASR: 1800/100 = 18s; diarization: 3600/50 = 72s
        XCTAssertEqual(calc.estimate(completedAudioSeconds: 1800, diarizationPending: true) ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(calc.estimate(completedAudioSeconds: 3600, diarizationPending: false) ?? -1, 0, accuracy: 0.001)
    }

    func testETAFormatterRanges() {
        XCTAssertEqual(ETAFormatter.string(3), "a few seconds remaining")
        XCTAssertEqual(ETAFormatter.string(42), "~40 sec remaining")
        XCTAssertEqual(ETAFormatter.string(300), "~5 min remaining")
        XCTAssertEqual(ETAFormatter.string(5700), "~1 hr 35 min remaining")
        XCTAssertEqual(ETAFormatter.string(7200), "~2 hr remaining")
    }
}
