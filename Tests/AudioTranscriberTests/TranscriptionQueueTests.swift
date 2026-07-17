import XCTest
@testable import AudioTranscriber

/// Scriptable engine for queue tests — no models, no audio.
final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "mock.engine"
    let kind = TranscriptionEngineKind.local
    let modelDescription = "Mock Engine"

    var handler: @Sendable (TranscriptionRequest) async throws -> TranscriptionOutput
    private(set) var transcribedIDs: [UUID] = []
    private let lock = NSLock()

    init(handler: @escaping @Sendable (TranscriptionRequest) async throws -> TranscriptionOutput) {
        self.handler = handler
    }

    static func instantSuccess() -> MockTranscriptionEngine {
        MockTranscriptionEngine { _ in
            let segments = [TranscriptionSegment(start: 0, end: 1, text: "hello world", speaker: "SPEAKER_00",
                                                 words: [TranscriptionWord(word: "hello", start: 0, end: 0.5),
                                                         TranscriptionWord(word: "world", start: 0.5, end: 1)])]
            return TranscriptionOutput(
                result: TranscriptionResult(segments: segments, language: "en", numSpeakers: 1))
        }
    }

    func prepare(progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws {}

    func transcribe(_ request: TranscriptionRequest,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void)
        async throws -> TranscriptionOutput {
        lock.lock()
        transcribedIDs.append(request.recordingID)
        lock.unlock()
        return try await handler(request)
    }
}

@MainActor
final class TranscriptionQueueTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!
    private var service: TranscriptionService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "QueueTests-\(UUID().uuidString)")!)
        store.load()
        service = TranscriptionService()
        service.attach(store: store, chatService: nil)
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

    func testEnqueueSetsProcessingAndCompletes() async {
        let recording = addRecording("a")
        service.engineOverride = MockTranscriptionEngine.instantSuccess()

        service.enqueue(recording.id)
        XCTAssertEqual(store.recording(with: recording.id)?.status, .processing)

        await waitUntil { self.store.recording(with: recording.id)?.status == .done }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.markdownURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.segmentsURL.path))

        // Sidecar decodes back to the same segment shape
        let data = try? Data(contentsOf: recording.segmentsURL)
        let segments = data.flatMap { try? JSONDecoder().decode([TranscriptionSegment].self, from: $0) }
        XCTAssertEqual(segments?.first?.text, "hello world")
        XCTAssertEqual(segments?.first?.words.count, 2)
    }

    func testSerialOrdering() async {
        let first = addRecording("first")
        let second = addRecording("second")
        let engine = MockTranscriptionEngine { _ in
            try await Task.sleep(for: .milliseconds(100))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }
        service.engineOverride = engine

        service.enqueue(first.id)
        service.enqueue(second.id)
        XCTAssertNotNil(service.queuePosition(of: second.id))

        await waitUntil { self.store.recording(with: second.id)?.status == .done }
        XCTAssertEqual(engine.transcribedIDs, [first.id, second.id])
    }

    func testDuplicateEnqueueIgnored() async {
        let recording = addRecording("dup")
        let engine = MockTranscriptionEngine { _ in
            try await Task.sleep(for: .milliseconds(200))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }
        service.engineOverride = engine

        service.enqueue(recording.id)
        service.enqueue(recording.id)
        service.enqueue(recording.id)

        await waitUntil { self.store.recording(with: recording.id)?.status == .done }
        XCTAssertEqual(engine.transcribedIDs.count, 1)
    }

    func testCancelActiveDiscardsCheckpointAndResetsToPending() async {
        let recording = addRecording("cancelme")
        try? Data("{}".utf8).write(to: recording.checkpointURL)
        service.engineOverride = MockTranscriptionEngine { _ in
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }

        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }
        service.cancel(recording.id)

        await waitUntil { self.store.recording(with: recording.id)?.status == .pending }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.checkpointURL.path))
    }

    func testPauseActiveKeepsCheckpointAndSetsPaused() async {
        let recording = addRecording("pauseme")
        service.engineOverride = MockTranscriptionEngine { request in
            // Simulate the engine writing a checkpoint before the long haul
            try Data("{}".utf8).write(to: request.checkpointURL)
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }

        service.enqueue(recording.id)
        await waitUntil { self.service.isActive(recording.id) }
        // Give the engine a beat to write the checkpoint
        await waitUntil { FileManager.default.fileExists(atPath: recording.checkpointURL.path) }
        service.pause(recording.id)

        await waitUntil { self.store.recording(with: recording.id)?.status == .paused }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.checkpointURL.path))
        // Checkpoints live in real Application Support (ID-keyed) — clean up.
        try? FileManager.default.removeItem(at: recording.checkpointURL)
    }

    func testFailureSetsFailedStatus() async {
        let recording = addRecording("failme")
        service.engineOverride = MockTranscriptionEngine { _ in
            throw TranscriptionEngineError.engineFailure("boom")
        }

        service.enqueue(recording.id)
        await waitUntil { self.store.recording(with: recording.id)?.status == .failed }
        XCTAssertEqual(store.recording(with: recording.id)?.status, .failed)
        XCTAssertNotNil(service.errorMessage)
    }

    func testUnqueueWaitingJob() async {
        let first = addRecording("busy")
        let second = addRecording("waiting")
        service.engineOverride = MockTranscriptionEngine { _ in
            try await Task.sleep(for: .seconds(30))
            return TranscriptionOutput(result: TranscriptionResult(segments: [], language: "en", numSpeakers: 0))
        }

        service.enqueue(first.id)
        service.enqueue(second.id)
        await waitUntil { self.service.isActive(first.id) }

        service.cancel(second.id)
        XCTAssertNil(service.queuePosition(of: second.id))
        XCTAssertEqual(store.recording(with: second.id)?.status, .pending)

        service.cancel(first.id)
    }
}
