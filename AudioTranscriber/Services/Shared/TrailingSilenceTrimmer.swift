import AVFoundation
import Foundation

/// Cuts the silent tail off a finished recording — the hours a forgotten
/// recording captured after everyone left, which cost real disk (and iCloud)
/// space.
///
/// The cut point comes from the SAME `SilenceDetector` policy the recorder's
/// auto-stop uses, so "silence" means one thing in this app, and the bias is
/// identical: anything that might be audio counts as audio. On top of that the
/// trim keeps `padding` seconds after the last sound, so even a
/// misclassification loses nothing audible.
enum TrailingSilenceTrimmer {
    /// Audio kept after the last detected sound.
    static let defaultPadding: TimeInterval = 15
    /// Shorter tails aren't worth rewriting a file for.
    static let defaultMinimumTrim: TimeInterval = 60

    struct Plan: Equatable {
        var originalDuration: TimeInterval
        /// Audio retained from the start of the file, padding included.
        var keepDuration: TimeInterval
        var originalBytes: Int64

        var trimmedDuration: TimeInterval { max(0, originalDuration - keepDuration) }
        /// Proportional estimate — exact only for constant-bitrate content.
        var estimatedBytesSaved: Int64 {
            guard originalDuration > 0, originalBytes > 0 else { return 0 }
            return Int64(Double(originalBytes) * (trimmedDuration / originalDuration))
        }
    }

    enum TrimError: LocalizedError {
        case unreadable(URL)
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "\(url.lastPathComponent) could not be read."
            case .exportUnavailable: return "This audio format can't be trimmed on this system."
            case .exportFailed(let reason): return reason
            }
        }
    }

    /// Replays the file exactly as the capture tap would (≈93 ms buffers) and
    /// reports what could be cut. Returns nil when there's nothing worth
    /// trimming. Decode-bound — call it off the main thread.
    static func plan(for url: URL,
                     config: SilenceDetector.Config = .default,
                     padding: TimeInterval = defaultPadding,
                     minimumTrim: TimeInterval = defaultMinimumTrim) throws -> Plan? {
        guard let file = try? AVAudioFile(forReading: url) else { throw TrimError.unreadable(url) }
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw TrimError.unreadable(url)
        }

        var detector = SilenceDetector(config: config)
        var time: TimeInterval = 0
        // AVAudioFile.read throws at EOF instead of returning 0 frames.
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(4_096), remaining))
            guard frames > 0 else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            time += Double(buffer.frameLength) / format.sampleRate
            let (rms, peak) = AudioLevel.levels(of: buffer)
            detector.observe(rmsDB: rms, peakDB: peak, at: time)
        }
        guard time > 0 else { return nil }

        let keep = min(time, detector.lastSoundTime + padding)
        let plan = Plan(originalDuration: time, keepDuration: keep,
                        originalBytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0) ?? 0)
        return plan.trimmedDuration >= minimumTrim ? plan : nil
    }

    /// Writes the first `seconds` of `source` to `destination`, preserving the
    /// encoded audio untouched where the container allows it (passthrough) and
    /// falling back to a decode/re-encode copy otherwise.
    static func trim(_ source: URL, keepingFirst seconds: TimeInterval, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        do {
            try await exportPassthrough(source, keepingFirst: seconds, to: destination)
        } catch {
            // WAV and other uncompressed containers aren't always passthrough
            // exportable; rewriting them is cheap and lossless anyway.
            try? FileManager.default.removeItem(at: destination)
            try rewrite(source, keepingFirst: seconds, to: destination)
        }
    }

    private static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "wav": return .wav
        case "caf": return .caf
        case "aiff", "aif": return .aiff
        case "mp3": return .mp3
        default: return .m4a
        }
    }

    private static func exportPassthrough(_ source: URL, keepingFirst seconds: TimeInterval,
                                          to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw TrimError.exportUnavailable
        }
        session.outputURL = destination
        session.outputFileType = fileType(for: destination)
        session.timeRange = CMTimeRange(start: .zero,
                                        duration: CMTime(seconds: seconds, preferredTimescale: 600))
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        switch session.status {
        case .completed:
            return
        default:
            throw TrimError.exportFailed(session.error?.localizedDescription ?? "the export did not finish")
        }
    }

    /// Decode/re-encode fallback: reads frames up to the cut point and writes
    /// them with the source file's own settings.
    private static func rewrite(_ source: URL, keepingFirst seconds: TimeInterval, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let wanted = AVAudioFramePosition(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw TrimError.unreadable(source)
        }
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            while input.framePosition < min(wanted, input.length) {
                let remaining = min(wanted, input.length) - input.framePosition
                let frames = AVAudioFrameCount(min(AVAudioFramePosition(16_384), remaining))
                guard frames > 0 else { break }
                try input.read(into: buffer, frameCount: frames)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
    }
}
