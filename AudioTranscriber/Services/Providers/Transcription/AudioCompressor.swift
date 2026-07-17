import AVFoundation
import Foundation

/// Target spec for cloud uploads: speech models resample to 16 kHz anyway, so
/// 16 kHz mono AAC at 32 kbps ≈ 14.4 MB/hour — a 1h45m recording fits OpenAI's
/// 25 MB limit in one part, and multi-GB WAVs upload in seconds to AssemblyAI.
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

/// AAC compression via AVAssetReader → AVAssetWriter (AVAssetExportSession's
/// M4A preset offers no bitrate control). Supports optional time-range slicing,
/// which also powers reference-clip extraction.
enum AudioCompressor {
    /// Output profile. `.cloudUpload` (16 kHz mono 32 kbps) minimizes upload
    /// size for speech APIs; `.storage` (48 kHz mono 96 kbps) is the archival
    /// profile — transparent for speech, ~45 MB/hour.
    struct Spec: Sendable {
        let sampleRate: Double
        let channels: Int
        let bitrate: Int

        static let cloudUpload = Spec(sampleRate: CloudAudioSpec.sampleRate,
                                      channels: 1, bitrate: CloudAudioSpec.bitrate)
        static let storage = Spec(sampleRate: 48_000, channels: 1, bitrate: 96_000)

        func estimatedBytes(forSeconds seconds: Double) -> Int {
            Int(seconds * Double(bitrate) / 8)
        }
    }

    static func compress(source: URL, timeRange: CMTimeRange? = nil,
                         to destination: URL, spec: Spec = .cloudUpload) async throws -> URL {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioCompressorError.cannotRead("no audio track in \(source.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange {
            reader.timeRange = timeRange
        }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
        ])
        guard reader.canAdd(readerOutput) else {
            throw AudioCompressorError.cannotRead("reader output rejected")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: spec.channels,
            AVEncoderBitRateKey: spec.bitrate,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioCompressorError.cannotWrite("writer input rejected")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioCompressorError.cannotRead(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            throw AudioCompressorError.cannotWrite(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let queue = DispatchQueue(label: "audio.compressor.pump")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw AudioCompressorError.cannotRead(reader.error?.localizedDescription ?? "read failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioCompressorError.exportFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return destination
    }
}
