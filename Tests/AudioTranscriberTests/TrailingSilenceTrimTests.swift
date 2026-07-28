import AVFoundation
import XCTest
@testable import AudioTranscriber

/// Trimming the silent tail off a recording: what gets cut, what must never be
/// cut, and the in-place swap that only ever replaces a verified file.
@MainActor
final class TrailingSilenceTrimTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Writes `speech` seconds of tone followed by `silence` seconds of
    /// near-zero dither (what a live-but-empty room encodes to).
    @discardableResult
    private func makeFile(name: String, speech: Double, silence: Double,
                          sampleRate: Double = 16_000, compressed: Bool = false) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = AVAudioFrameCount(sampleRate)   // 1 s at a time
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            buffer.frameLength = chunk
            var phase: Float = 0
            for _ in 0..<Int(speech) {
                for i in 0..<Int(chunk) {
                    phase += 0.05
                    buffer.floatChannelData![0][i] = 0.35 * sinf(phase)
                }
                try file.write(from: buffer)
            }
            for _ in 0..<Int(silence) {
                for i in 0..<Int(chunk) {
                    buffer.floatChannelData![0][i] = Float.random(in: -0.00002...0.00002)
                }
                try file.write(from: buffer)
            }
        }
        return url
    }

    // MARK: - Planning

    func testPlanCutsTheSilentTailAndKeepsPadding() throws {
        let url = try makeFile(name: "tail.wav", speech: 20, silence: 180)
        let plan = try XCTUnwrap(TrailingSilenceTrimmer.plan(for: url))
        XCTAssertEqual(plan.originalDuration, 200, accuracy: 1)
        // Sound ends at 20 s; 15 s of padding is kept after it.
        XCTAssertEqual(plan.keepDuration, 35, accuracy: 1.5)
        XCTAssertEqual(plan.trimmedDuration, 165, accuracy: 1.5)
        XCTAssertGreaterThan(plan.estimatedBytesSaved, 0)
    }

    /// A recording that is sound all the way to the end must be left alone —
    /// this is the "never cut audio" case.
    func testPlanIsNilWhenAudioRunsToTheEnd() throws {
        let url = try makeFile(name: "full.wav", speech: 120, silence: 0)
        XCTAssertNil(try TrailingSilenceTrimmer.plan(for: url))
    }

    /// A short gap at the end isn't worth rewriting the file for.
    func testPlanIsNilForAShortTail() throws {
        let url = try makeFile(name: "short-tail.wav", speech: 30, silence: 20)
        XCTAssertNil(try TrailingSilenceTrimmer.plan(for: url))
    }

    /// The padding is what protects against a borderline classification: even
    /// with a tail that qualifies, the cut lands well after the last sound.
    func testCutNeverLandsBeforeTheLastSound() throws {
        let url = try makeFile(name: "pad.wav", speech: 45, silence: 200)
        let plan = try XCTUnwrap(TrailingSilenceTrimmer.plan(for: url))
        XCTAssertGreaterThan(plan.keepDuration, 45, "the cut must sit after the last sound, not on it")
    }

    func testPlanRejectsUnreadableFiles() throws {
        let url = tempDir.appendingPathComponent("garbage.m4a")
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        XCTAssertThrowsError(try TrailingSilenceTrimmer.plan(for: url))
    }

    // MARK: - Trimming

    func testTrimProducesTheKeptDurationForWAV() async throws {
        let url = try makeFile(name: "cut.wav", speech: 20, silence: 180)
        let out = tempDir.appendingPathComponent("cut-out.wav")
        try await TrailingSilenceTrimmer.trim(url, keepingFirst: 35, to: out)
        XCTAssertEqual(RecordingStore.audioDuration(for: out), 35, accuracy: 1)
    }

    /// Compressed recordings are the common case; the cut goes through the
    /// passthrough export (no re-encode).
    func testTrimProducesTheKeptDurationForM4A() async throws {
        let url = try makeFile(name: "cut.m4a", speech: 20, silence: 180, compressed: true)
        let out = tempDir.appendingPathComponent("cut-out.m4a")
        try await TrailingSilenceTrimmer.trim(url, keepingFirst: 35, to: out)
        XCTAssertEqual(RecordingStore.audioDuration(for: out), 35, accuracy: 1.5)
        XCTAssertLessThan(RecordingStore.fileSize(of: out), RecordingStore.fileSize(of: url))
    }

    /// The kept audio must be the ORIGINAL audio, not silence: the tone has to
    /// survive the trim.
    func testTrimmedFileStillContainsTheAudio() async throws {
        let url = try makeFile(name: "keep.wav", speech: 20, silence: 180)
        let out = tempDir.appendingPathComponent("keep-out.wav")
        try await TrailingSilenceTrimmer.trim(url, keepingFirst: 35, to: out)

        let file = try AVAudioFile(forReading: out)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)!
        var loudest = AudioLevel.minimumDB
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(8_192), remaining))
            guard frames > 0 else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            loudest = max(loudest, AudioLevel.levels(of: buffer).peakDB)
        }
        XCTAssertGreaterThan(loudest, -20, "the kept audio was lost")
    }

    // MARK: - Store operation

    private func makeStore() -> RecordingStore {
        let store = RecordingStore(storageDirectory: tempDir,
                                   defaults: UserDefaults(suiteName: "Trim-\(UUID().uuidString)")!)
        store.load()
        return store
    }

    func testStoreTrimSwapsInPlaceAndUpdatesMetadata() async throws {
        let url = try makeFile(name: "recording_2026-07-27_10-00-00.wav", speech: 20, silence: 200)
        let store = makeStore()
        let recording = Recording(fileURL: url, date: Date(), duration: 220)
        store.insert(recording)
        let originalBytes = RecordingStore.fileSize(of: url)

        let trimmed = await store.trimTrailingSilence(recording)
        XCTAssertTrue(trimmed)

        // Same URL and stem — sidecars keep matching.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let updated = try XCTUnwrap(store.recording(with: recording.id))
        XCTAssertEqual(updated.fileURL, url)
        XCTAssertEqual(updated.duration, 35, accuracy: 2)
        XCTAssertEqual(RecordingStore.audioDuration(for: url), 35, accuracy: 2)
        XCTAssertLessThan(try XCTUnwrap(updated.fileSizeBytes), originalBytes)
        XCTAssertNotNil(store.infoMessage)
        XCTAssertTrue(store.trimmingIDs.isEmpty)
    }

    func testStoreTrimReportsWhenThereIsNothingToTrim() async throws {
        let url = try makeFile(name: "recording_2026-07-27_11-00-00.wav", speech: 60, silence: 0)
        let store = makeStore()
        let recording = Recording(fileURL: url, date: Date(), duration: 60)
        store.insert(recording)
        let before = RecordingStore.fileSize(of: url)

        let trimmed = await store.trimTrailingSilence(recording)
        XCTAssertFalse(trimmed)
        XCTAssertEqual(RecordingStore.fileSize(of: url), before, "the file must be untouched")
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.infoMessage)
    }

    /// Trimming a file the transcription engine is currently reading would move
    /// the ground under it.
    func testStoreRefusesWhileTranscribing() async throws {
        let url = try makeFile(name: "recording_2026-07-27_12-00-00.wav", speech: 20, silence: 200)
        let store = makeStore()
        let recording = Recording(fileURL: url, date: Date(), duration: 220)
        store.insert(recording)
        store.update(recording.id) { $0.status = .processing }
        let before = RecordingStore.fileSize(of: url)

        let trimmed = await store.trimTrailingSilence(recording)
        XCTAssertFalse(trimmed)
        XCTAssertEqual(RecordingStore.fileSize(of: url), before)
        XCTAssertNotNil(store.errorMessage)
    }

    /// A live recording is never a trim candidate.
    func testStoreRefusesTheActiveRecording() async throws {
        let url = try makeFile(name: "recording_2026-07-27_13-00-00.wav", speech: 20, silence: 200)
        let store = makeStore()
        let recording = Recording(fileURL: url, date: Date(), duration: 220)
        store.insert(recording)
        store.activeRecordingURL = url

        let trimmed = await store.trimTrailingSilence(recording)
        XCTAssertFalse(trimmed)
        XCTAssertNotNil(store.errorMessage)
    }

    /// Sidecars are keyed off the file stem — trimming must not orphan them.
    func testTrimKeepsSidecarsMatching() async throws {
        let url = try makeFile(name: "recording_2026-07-27_14-00-00.wav", speech: 20, silence: 200)
        let transcript = url.deletingPathExtension().appendingPathExtension("md")
        try "# transcript".write(to: transcript, atomically: true, encoding: .utf8)
        let store = makeStore()
        let recording = Recording(fileURL: url, date: Date(), duration: 220)
        store.insert(recording)

        let trimmed = await store.trimTrailingSilence(recording)
        XCTAssertTrue(trimmed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path),
                      "the transcript sidecar still matches the audio stem")
    }

    func testAutoTrimSettingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "TrimDefault-\(UUID().uuidString)")!
        XCTAssertFalse(defaults.bool(forKey: "autoTrimTrailingSilence"))
    }
}
