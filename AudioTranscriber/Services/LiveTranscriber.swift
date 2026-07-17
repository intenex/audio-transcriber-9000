import AVFoundation
import FluidAudio
import Foundation
import Observation

/// Real-time transcript preview while recording, via FluidAudio's streaming
/// ASR. Preview-only: discarded at stop — the batch pipeline produces the real
/// transcript (with diarization). Degrades silently on any failure.
@Observable @MainActor
final class LiveTranscriber {
    private(set) var confirmedText = ""
    private(set) var volatileText = ""
    private(set) var isRunning = false

    private var manager: StreamingAsrManager? = nil
    private var updatesTask: Task<Void, Never>? = nil

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "liveTranscriptionPreview") as? Bool ?? true
    }

    var displayText: String {
        (confirmedText + volatileText).trimmingCharacters(in: .whitespaces)
    }

    func start() {
        guard isEnabled, !isRunning else { return }
        // Never trigger a model download mid-recording; preview only when ready.
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory()) else { return }

        confirmedText = ""
        volatileText = ""
        let streamingManager = StreamingAsrManager(config: .streaming)
        manager = streamingManager
        isRunning = true

        updatesTask = Task { [weak self] in
            do {
                let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory())
                try await streamingManager.start(models: models, source: .microphone)
                for await update in await streamingManager.transcriptionUpdates {
                    guard let self, self.isRunning else { break }
                    if update.isConfirmed {
                        self.confirmedText += update.text
                        self.volatileText = ""
                    } else {
                        self.volatileText = update.text
                    }
                }
            } catch {
                // Preview is best-effort; just turn it off.
                self?.isRunning = false
            }
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, let manager = self.manager else { return }
            await manager.streamAudio(buffer)
        }
    }

    func stop() {
        guard isRunning || manager != nil else { return }
        isRunning = false
        updatesTask?.cancel()
        updatesTask = nil
        if let manager {
            Task { await manager.cancel() }
        }
        manager = nil
        confirmedText = ""
        volatileText = ""
    }
}
