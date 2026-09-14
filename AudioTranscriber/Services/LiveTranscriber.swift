import AVFoundation
import FluidAudio
import Foundation
import Observation

/// A preview window has a fixed capacity. Preview may skip incoming audio while
/// inference is busy; the independent recording writer always saves that audio.
struct LivePreviewWindow {
    let capacity: Int
    private(set) var samples: [Float] = []
    init(capacity: Int = 16_000 * 8) { self.capacity = capacity }
    mutating func append(_ input: [Float]) -> [Float]? {
        samples.append(contentsOf: input.prefix(max(0, capacity - samples.count)))
        guard samples.count == capacity else { return nil }
        let window = samples
        samples = []; samples.reserveCapacity(capacity)
        return window
    }
}

/// Uses independent short ASR calls. StreamingAsrManager's input AsyncStream and
/// token history are unbounded in FluidAudio 0.12.6, so they are unsuitable for
/// an unattended multi-hour preview when inference falls behind.
actor LivePreviewWorker {
    private let converter = AudioConverter()
    private var window = LivePreviewWindow()
    private var manager: AsrManager?
    private var stopped = false
    private var processing = false

    func initialize(models: AsrModels) async throws {
        guard !stopped else { return }
        let manager = AsrManager()
        try await manager.initialize(models: models)
        guard !stopped else { await manager.cleanup(); return }
        self.manager = manager
    }
    func append(_ buffer: AVAudioPCMBuffer) async throws -> String? {
        guard !stopped, let manager else { return nil }
        let samples = try converter.resampleBuffer(buffer)
        guard let audio = window.append(samples) else { return nil }
        processing = true
        do {
            let result = try await manager.transcribe(audio, source: .microphone)
            processing = false
            if stopped { await shutdown(); return nil }
            return result.text
        } catch {
            processing = false
            await shutdown()
            throw error
        }
    }
    func shutdown() async {
        stopped = true
        guard !processing else { return }
        window = LivePreviewWindow()
        if let manager { await manager.cleanup() }
        manager = nil
    }
}

/// Best-effort local preview. The final transcript still comes from the full
/// saved audio and includes diarization. Model downloads never start here.
@Observable @MainActor
final class LiveTranscriber {
    private(set) var confirmedText = ""
    private(set) var volatileText = ""
    private(set) var isRunning = false
    nonisolated private let previewGate = DispatchSemaphore(value: 1)
    private var worker: LivePreviewWorker?
    private var setupTask: Task<Void, Never>?
    private var generation = UUID()

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "liveTranscriptionPreview") == nil ? true : UserDefaults.standard.bool(forKey: "liveTranscriptionPreview")
    }
    var displayText: String { confirmedText }

    func start() {
        guard isEnabled, !isRunning,
              AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory()) else { return }
        confirmedText = ""; volatileText = ""
        generation = UUID()
        let generation = generation
        let worker = LivePreviewWorker()
        self.worker = worker; isRunning = true
        setupTask = Task { [weak self] in
            do {
                let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory())
                try Task.checkCancellation()
                try await worker.initialize(models: models)
            } catch {
                await worker.shutdown()
                guard self?.generation == generation else { return }
                self?.isRunning = false
            }
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        guard previewGate.wait(timeout: .now()) == .success else { return }
        let gate = previewGate
        Task { @MainActor [weak self] in
            defer { gate.signal() }
            guard let self, self.isRunning, let worker = self.worker else { return }
            let generation = self.generation
            do {
                if let text = try await worker.append(buffer), self.generation == generation, self.isRunning {
                    self.confirmedText = String((self.confirmedText + " " + text).suffix(6_000))
                }
            } catch {
                if self.generation == generation { self.isRunning = false }
            }
        }
    }

    func stop() {
        generation = UUID(); isRunning = false
        setupTask?.cancel(); setupTask = nil
        if let worker { Task { await worker.shutdown() } }
        worker = nil
        confirmedText = ""; volatileText = ""
    }
}
