import Foundation
import FluidAudio
import Observation

enum ModelSetupState: Equatable {
    case unknown
    case notDownloaded
    case downloading(Double)   // 0...1
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Tracks and manages the on-disk speech models (Parakeet ASR + pyannote
/// diarizer + Silero VAD). Downloading happens automatically on first
/// transcription; this surface also lets Settings show status and pre-download.
@Observable @MainActor
final class ModelManager {
    var asrState: ModelSetupState = .unknown
    var diarizerState: ModelSetupState = .unknown

    var allReady: Bool { asrState.isReady && diarizerState.isReady }

    var summaryText: String {
        switch (asrState, diarizerState) {
        case (.ready, .ready): return "Downloaded — transcription runs fully offline"
        case (.downloading(let f), _): return "Downloading speech model… \(Int(f * 100))%"
        case (_, .downloading(let f)): return "Downloading speaker model… \(Int(f * 100))%"
        case (.failed(let msg), _), (_, .failed(let msg)): return "Download failed: \(msg)"
        case (.notDownloaded, _), (_, .notDownloaded): return "Not downloaded (~1.5 GB, one-time)"
        default: return "Checking…"
        }
    }

    func refreshStatus() {
        let asrDir = AsrModels.defaultCacheDirectory()
        asrState = AsrModels.modelsExist(at: asrDir) ? .ready : .notDownloaded
        let diarDir = DiarizerModels.defaultModelsDirectory()
        let diarExists = FileManager.default.fileExists(atPath: diarDir.path)
            && ((try? FileManager.default.contentsOfDirectory(atPath: diarDir.path))?.isEmpty == false)
        diarizerState = diarExists ? .ready : .notDownloaded
    }

    func downloadAll() async {
        do {
            asrState = .downloading(0)
            _ = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] progress in
                Task { @MainActor in self?.asrState = .downloading(progress.fractionCompleted) }
            }
            asrState = .ready

            diarizerState = .downloading(0)
            _ = try await DiarizerModels.downloadIfNeeded { [weak self] progress in
                Task { @MainActor in self?.diarizerState = .downloading(progress.fractionCompleted) }
            }
            diarizerState = .ready
        } catch {
            let message = error.localizedDescription
            if case .downloading = asrState { asrState = .failed(message) }
            if case .downloading = diarizerState { diarizerState = .failed(message) }
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory())
        try? FileManager.default.removeItem(at: DiarizerModels.defaultModelsDirectory())
        refreshStatus()
    }
}
