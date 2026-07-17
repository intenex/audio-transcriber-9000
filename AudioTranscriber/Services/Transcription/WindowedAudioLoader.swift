import AVFoundation
import Foundation

enum WindowedAudioLoaderError: LocalizedError {
    case cannotOpen(String)
    case conversionFailed(String)
    case tooLittleData(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let msg): return "Couldn't open audio: \(msg)"
        case .conversionFailed(let msg): return "Couldn't convert audio: \(msg)"
        case .tooLittleData(let msg): return msg
        }
    }
}

/// Loads audio of ANY size as 16 kHz mono Float32 using windowed reads.
///
/// Why this exists: a single whole-file `AVAudioFile.read`/`ExtAudioFileRead`
/// fails with com.apple.coreaudio.avfaudio error -40 (internal 32-bit
/// overflow) once the PCM payload exceeds ~2 GB — i.e. every recording longer
/// than ~3 hours of Float32/48 kHz. FluidAudio's `resampleAudioFile` does a
/// single-shot read, so the local engine uses this loader instead.
///
/// One persistent AVAudioConverter is used across windows so the resampler's
/// filter state carries over — no seam artifacts at window boundaries.
enum WindowedAudioLoader {
    static let targetSampleRate: Double = 16_000
    static let defaultWindowSeconds: Double = 60

    static func load16kMono(from url: URL, windowSeconds: Double = defaultWindowSeconds) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WindowedAudioLoaderError.cannotOpen(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1, interleaved: false) else {
            throw WindowedAudioLoaderError.conversionFailed("couldn't create output format")
        }

        let totalFrames = file.length
        let expectedOutSamples = Int(Double(totalFrames) / inputFormat.sampleRate * targetSampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(expectedOutSamples + 16_000)

        let windowFrames = AVAudioFrameCount(windowSeconds * inputFormat.sampleRate)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: windowFrames) else {
            throw WindowedAudioLoaderError.conversionFailed("couldn't allocate read buffer")
        }

        let needsConversion = inputFormat.sampleRate != targetSampleRate
            || inputFormat.channelCount != 1
            || inputFormat.commonFormat != .pcmFormatFloat32
        let converter: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw WindowedAudioLoaderError.conversionFailed(
                    "no converter from \(inputFormat) to 16kHz mono")
            }
            converter = c
        } else {
            converter = nil
        }

        let outCapacity = AVAudioFrameCount(windowSeconds * targetSampleRate * 1.2) + 4096
        let outBuffer: AVAudioPCMBuffer?
        if converter != nil {
            outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity)
        } else {
            outBuffer = nil
        }

        func appendMono(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let channels = Int(buffer.format.channelCount)
            if channels == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
            } else {
                let scale = 1 / Float(channels)
                var mixed = [Float](repeating: 0, count: frames)
                for channel in 0..<channels {
                    let data = channelData[channel]
                    for i in 0..<frames { mixed[i] += data[i] * scale }
                }
                samples.append(contentsOf: mixed)
            }
        }

        func convertWindow(_ window: AVAudioPCMBuffer, endOfStream: Bool) throws {
            guard let converter, let outBuffer else {
                appendMono(window)
                return
            }
            // Feed this one window (or signal end of stream), draining the
            // converter until it stops producing output.
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
                    throw WindowedAudioLoaderError.conversionFailed(conversionError.localizedDescription)
                }
                appendMono(outBuffer)
                switch status {
                case .haveData:
                    continue          // more output pending for this input
                case .inputRanDry, .endOfStream:
                    return
                case .error:
                    throw WindowedAudioLoaderError.conversionFailed("converter error")
                @unknown default:
                    return
                }
            }
        }

        // Windowed read loop. Mid-file read errors (e.g. a header that claims
        // more frames than were actually written by a crashed recorder) end the
        // loop gracefully — we transcribe what exists rather than failing a
        // multi-hour job outright.
        var framesRead: AVAudioFramePosition = 0
        var readError: Error? = nil
        while framesRead < totalFrames {
            inBuffer.frameLength = 0
            do {
                try file.read(into: inBuffer, frameCount: windowFrames)
            } catch {
                readError = error
                break
            }
            if inBuffer.frameLength == 0 { break }
            framesRead += AVAudioFramePosition(inBuffer.frameLength)
            try convertWindow(inBuffer, endOfStream: false)
        }

        // Flush the resampler tail.
        inBuffer.frameLength = 0
        try? convertWindow(inBuffer, endOfStream: true)

        // If a read error left us with almost nothing, surface it.
        let minimumSamples = Int(targetSampleRate * 0.5)
        if samples.count < minimumSamples {
            if let readError {
                throw WindowedAudioLoaderError.cannotOpen(readError.localizedDescription)
            }
            throw WindowedAudioLoaderError.tooLittleData(
                "Audio file contains less than half a second of readable audio.")
        }
        if let readError {
            NSLog("[WindowedAudioLoader] Read stopped early at frame \(framesRead)/\(totalFrames): \(readError.localizedDescription) — continuing with \(samples.count) samples")
        }
        return samples
    }
}
