import XCTest
@testable import AudioTranscriber

/// Auto-retry on transient engine failures + the launch repair that trusts an
/// existing transcript over a stale persisted status.
@MainActor
final class TranscriptionRetryTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var store: RecordingStore!
    private var service: TranscriptionService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "RetryTests-\(UUID().uuidString)")!
        store = RecordingStore(storageDirectory: tempDir, defaults: defaults)
        store.load()
        service = TranscriptionService()
        service.attach(store: store, chatService: nil)
        service.retryDelaySeconds = 0.01
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func addRecording(_ name: String) -> Recording {
        let url = tempDir.appendingPathComponent("\(name).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10_000))
        let recording = Recording(fileURL: url, date: .now, duration: 60)
        store.insert(recording)
        return recording
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private struct FlakyError: LocalizedError {
        var errorDescription: String? { "ANE hiccup" }
    }

    /// A scriptable engine that fails the first N attempts, then succeeds.
    private func flakyEngine(failuresBeforeSuccess: Int) -> MockTranscriptionEngine {
        let counter = Counter()
        return MockTranscriptionEngine { _ in
            if counter.next() <= failuresBeforeSuccess { throw FlakyError() }
            let segments = [TranscriptionSegment(start: 0, end: 1, text: "ok", speaker: "SPEAKER_00", words: [])]
            return TranscriptionOutput(
                result: TranscriptionResult(segments: segments, language: "en", numSpeakers: 1))
        }
    }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    func testTransientFailureRetriesToSuccess() async {
        let recording = addRecording("flaky")
        let engine = flakyEngine(failuresBeforeSuccess: 2)
        service.engineOverride = engine

        service.enqueue(recording.id)
        await waitUntil { self.store.recording(with: recording.id)?.status == .done }

        let final = store.recording(with: recording.id)
        XCTAssertEqual(final?.status, .done, "two transient failures should be retried through")
        XCTAssertNil(final?.lastError)
        XCTAssertEqual(engine.transcribedIDs.count, 3, "expected exactly 3 attempts")
    }

    func testPersistentFailureGivesUpAndPersistsError() async {
        let recording = addRecording("broken")
        let engine = flakyEngine(failuresBeforeSuccess: 99)
        service.engineOverride = engine

        service.enqueue(recording.id)
        await waitUntil { self.store.recording(with: recording.id)?.status == .failed }

        let final = store.recording(with: recording.id)
        XCTAssertEqual(final?.status, .failed)
        XCTAssertEqual(final?.lastError, "ANE hiccup", "error detail must be persisted for the failed view")
        XCTAssertEqual(engine.transcribedIDs.count, 3, "must stop after maxAttempts")
        XCTAssertNotNil(service.errorMessage)

        // Re-enqueue clears the stale error.
        service.engineOverride = MockTranscriptionEngine.instantSuccess()
        service.enqueue(recording.id)
        await waitUntil { self.store.recording(with: recording.id)?.status == .done }
        XCTAssertNil(store.recording(with: recording.id)?.lastError)
    }

    func testUserCancelDuringBackoffWins() async {
        let recording = addRecording("cancelme")
        service.retryDelaySeconds = 0.5
        service.engineOverride = flakyEngine(failuresBeforeSuccess: 99)

        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }
        // Give the first attempt time to fail into the backoff sleep.
        try? await Task.sleep(for: .milliseconds(150))
        service.cancel(recording.id)
        await waitUntil { !self.service.isActive(recording.id) }

        XCTAssertEqual(store.recording(with: recording.id)?.status, .pending,
                       "cancel during retry backoff must return to pending, not keep retrying")
    }

    // MARK: - Launch repair

    /// A finished transcript on disk beats a stale persisted status: this is
    /// the exact regression where a completed hour-long recording showed
    /// "partially transcribed" after relaunch.
    func testLaunchRepairPromotesFinishedTranscript() throws {
        var ids: [TranscriptionStatus: UUID] = [:]
        for (i, staleStatus) in [TranscriptionStatus.processing, .partial, .paused].enumerated() {
            let url = tempDir.appendingPathComponent("finished-\(i).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data(count: 10_000))
            var recording = Recording(fileURL: url, date: .now, duration: 60)
            try "# transcript".write(to: recording.markdownURL, atomically: true, encoding: .utf8)
            recording.status = staleStatus
            store.insert(recording)
            ids[staleStatus] = recording.id
        }
        store.saveNow()

        let reloaded = RecordingStore(storageDirectory: tempDir, defaults: defaults)
        reloaded.load()
        for (staleStatus, id) in ids {
            XCTAssertEqual(reloaded.recording(with: id)?.status, .done,
                           "\(staleStatus) with a transcript and no checkpoint must repair to done")
        }
    }

    func testLaunchRepairKeepsResumableCheckpoint() throws {
        let url = tempDir.appendingPathComponent("resumable.wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10_000))
        var recording = Recording(fileURL: url, date: .now, duration: 60)
        recording.status = .processing
        try "# stale transcript from an earlier run".write(
            to: recording.markdownURL, atomically: true, encoding: .utf8)
        try "{}".write(to: recording.checkpointURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: recording.checkpointURL) }
        store.insert(recording)
        store.saveNow()

        let reloaded = RecordingStore(storageDirectory: tempDir, defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.recording(with: recording.id)?.status, .partial,
                       "an on-disk checkpoint means in-flight work — resume beats the old transcript")
    }

    func testLaunchRepairWithNothingOnDiskGoesPending() throws {
        let url = tempDir.appendingPathComponent("bare.wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10_000))
        var recording = Recording(fileURL: url, date: .now, duration: 60)
        recording.status = .processing
        store.insert(recording)
        store.saveNow()

        let reloaded = RecordingStore(storageDirectory: tempDir, defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.recording(with: recording.id)?.status, .pending)
    }
}
