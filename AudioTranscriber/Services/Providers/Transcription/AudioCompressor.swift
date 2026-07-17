import AVFoundation
import Foundation

/// Target spec for cloud uploads: speech models resample to 16 kHz anyway, so
/// 16 kHz mono AAC at 32 kbps minimizes upload size for speech APIs.
enum CloudAudioSpec {
    static let sampleRate: Double = 16_000
    static let bitrate = 32_000                       // bits/second
    static let uploadLimitBytes = 25 * 1024 * 1024    // OpenAI per-request cap
    static let headroom = 0.88                        // container overhead margin

    static func estimatedBytes(forSeconds seconds: Double) -> Int {
        Int(seconds * Double(bitrate) / 8)
    }
}

enum AudioCompressorError: LocalizedError {
    case cannotRead(String)
    case cannotWrite(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let msg): return "Couldn't read audio: \(msg)"
        case .cannotWrite(let msg): return "Couldn't write compressed audio: \(msg)"
        case .exportFailed(let msg): return "Audio compression failed: \(msg)"
        }
    }
}

/// AAC transcoding via windowed AVAudioFile reads + a persistent
/// AVAudioConverter + AVAudioFile AAC writes.
///
/// Why not AVAssetReader/AVAssetWriter: AVAssetReader mis-handles some WAVs
/// this app's older versions produced (stale/quirky headers) — it stopped a
/// 2-hour file after ~2.5 minutes, while AVAudioFile reads the same file
/// completely (the entire transcription pipeline depends on that). This path
/// reuses the exact read machinery proven by WindowedAudioLoader and the
/// write machinery proven by the AAC recorder.
enum AudioCompressor {
    /// Output profile.
    struct Spec: Sendable {
        let sampleRate: Double
        let channels: Int
        let bitrate: Int

        /// 16 kHz mono 32 kbps — minimal upload size for speech APIs.
        static let cloudUpload = Spec(sampleRate: CloudAudioSpec.sampleRate,
                                      channels: 1, bitrate: CloudAudioSpec.bitrate)
        /// 48 kHz mono 96 kbps — archival: transparent for speech, ~45 MB/hour.
        static let storage = Spec(sampleRate: 48_000, channels: 1, bitrate: 96_000)
        /// 48 kHz mono 48 kbps — compact archival, ~22 MB/hour.
        static let storageCompact = Spec(sampleRate: 48_000, channels: 1, bitrate: 48_000)

        func estimatedBytes(forSeconds seconds: Double) -> Int {
            Int(seconds * Double(bitrate) / 8)
        }
    }

    static let windowSeconds: Double = 60

    static func compress(source: URL, timeRange: CMTimeRange? = nil,
                         to destination: URL, spec: Spec = .cloudUpload,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try? FileManager.default.removeItem(at: destination)
        // Heavy blocking I/O — keep it off the Swift-concurrency cooperative pool.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try transcodeSync(source: source, timeRange: timeRange,
                                      destination: destination, spec: spec, progress: progress)
                    continuation.resume(returning: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func transcodeSync(source: URL, timeRange: CMTimeRange?,
                                      destination: URL, spec: Spec,
                                      progress: (@Sendable (Double) -> Void)?) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioCompressorError.cannotRead(error.localizedDescription)
        }
        let inputFormat = input.processingFormat
        let inputRate = inputFormat.sampleRate

        // Frame range (whole file, or the requested slice for reference clips / parts).
        var startFrame: AVAudioFramePosition = 0
        var endFrame: AVAudioFramePosition = input.length
        if let timeRange {
            startFrame = AVAudioFramePosition(max(0, timeRange.start.seconds) * inputRate)
            endFrame = min(input.length, AVAudioFramePosition(timeRange.end.seconds * inputRate))
        }
        guard endFrame > startFrame else {
            throw AudioCompressorError.cannotRead("empty time range")
        }
        let totalFrames = endFrame - startFrame
        input.framePosition = startFrame

        guard let pcmOutFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: spec.sampleRate,
                                               channels: AVAudioChannelCount(spec.channels),
                                               interleaved: false) else {
            throw AudioCompressorError.cannotWrite("invalid output format spec")
        }

        let needsConversion = inputRate != spec.sampleRate
            || inputFormat.channelCount != AVAudioChannelCount(spec.channels)
            || inputFormat.commonFormat != .pcmFormatFloat32
        let converter: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: inputFormat, to: pcmOutFormat) else {
                throw AudioCompressorError.cannotWrite("no converter from \(inputFormat)")
            }
            converter = c
        } else {
            converter = nil
        }

        let windowFrames = AVAudioFrameCount(windowSeconds * inputRate)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: windowFrames) else {
            throw AudioCompressorError.cannotRead("couldn't allocate read buffer")
        }
        let outCapacity = AVAudioFrameCount(windowSeconds * spec.sampleRate * 1.2) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: pcmOutFormat, frameCapacity: outCapacity) else {
            throw AudioCompressorError.cannotWrite("couldn't allocate write buffer")
        }

        // Scope the writer so the m4a container is finalized (AVAudioFile
        // finalizes on deinit) before this function returns.
        try autoreleasepool {
            let output: AVAudioFile
            do {
                output = try AVAudioFile(forWriting: destination, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: spec.sampleRate,
                    AVNumberOfChannelsKey: spec.channels,
                    AVEncoderBitRateKey: spec.bitrate,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw AudioCompressorError.cannotWrite(error.localizedDescription)
            }

            func convertAndWrite(_ window: AVAudioPCMBuffer, endOfStream: Bool) throws {
                guard let converter else {
                    if window.frameLength > 0 { try output.write(from: window) }
                    return
                }
                var fed = false
                while true {
                    outBuffer.frameLength = 0
                    var conversionError: NSError?
                    let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                        if fed {
                            outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                            return nil
                        }
                        fed = true
                        if window.frameLength == 0 && endOfStream {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        outStatus.pointee = .haveData
                        return window
                    }
                    if let conversionError {
                        throw AudioCompressorError.exportFailed(conversionError.localizedDescription)
                    }
                    if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
                    switch status {
                    case .haveData: continue
                    case .inputRanDry, .endOfStream: return
                    case .error: throw AudioCompressorError.exportFailed("converter error")
                    @unknown default: return
                    }
                }
            }

            var framesRead: AVAudioFramePosition = 0
            while framesRead < totalFrames {
                let remaining = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), totalFrames - framesRead))
                inBuffer.frameLength = 0
                try input.read(into: inBuffer, frameCount: remaining)
                if inBuffer.frameLength == 0 { break }
                framesRead += AVAudioFramePosition(inBuffer.frameLength)
                try convertAndWrite(inBuffer, endOfStream: false)
                progress?(min(1, Double(framesRead) / Double(totalFrames)))
            }

            // Flush the resampler tail.
            inBuffer.frameLength = 0
            try convertAndWrite(inBuffer, endOfStream: true)
        }
        progress?(1.0)
    }
}
