import AVFoundation
import Foundation

/// Selects and extracts clean reference clips of a named speaker from a
/// transcribed recording, for voice enrollment.
enum ReferenceClipExtractor {
    struct Candidate: Equatable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    static let minCleanSeconds = 3.0
    static let maxClipSeconds = 10.0
    static let targetTotalSeconds = 15.0
    static let maxClips = 3

    /// Minimum RMS for a clip to count as actual speech. Anything quieter is
    /// silence/room noise — enrolling it poisons recognition and produces the
    /// "empty voice clip" symptom.
    static let minimumSpeechRMS: Float = 0.004

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    static func isLikelySpeech(_ samples: [Float]) -> Bool {
        rms(samples) >= minimumSpeechRMS
    }

    /// Pure candidate selection: the speaker's longest segments that don't
    /// overlap any other speaker's speech, trimmed to 10s, 8-15s total, max 3.
    /// Falls back to the 2 longest segments when nothing clean qualifies.
    static func selectCandidates(segments: [TranscriptionSegment], speakerID: String) -> [Candidate] {
        let mine = segments.filter { $0.speaker == speakerID }
        let others = segments.filter { $0.speaker != speakerID }

        func overlapsOther(_ segment: TranscriptionSegment) -> Bool {
            others.contains { other in
                max(segment.start, other.start) < min(segment.end, other.end)
            }
        }

        var pool = mine
            .filter { ($0.end - $0.start) >= minCleanSeconds && !overlapsOther($0) }
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }

        if pool.isEmpty {
            // Fallback: 2 longest regardless of overlap.
            pool = Array(mine.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(2))
        }

        var candidates: [Candidate] = []
        var total = 0.0
        for segment in pool {
            guard candidates.count < maxClips, total < targetTotalSeconds else { break }
            var start = segment.start
            var end = segment.end
            if end - start > maxClipSeconds {
                // Take the middle of long segments (steadier speech than edges).
                let mid = (start + end) / 2
                start = mid - maxClipSeconds / 2
                end = mid + maxClipSeconds / 2
            }
            candidates.append(Candidate(start: start, end: end))
            total += end - start
        }
        return candidates
    }

    /// Read mono Float32 samples for a time range, resampled to 16 kHz for the
    /// speaker-embedding model.
    static func samples16k(from audioURL: URL, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate

        let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, end - start) * sampleRate)
        guard frameCount > 0, startFrame < file.length else { return [] }

        file.framePosition = startFrame
        let clampedCount = min(frameCount, AVAudioFrameCount(file.length - startFrame))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: clampedCount) else { return [] }
        try file.read(into: buffer, frameCount: clampedCount)

        // Mixdown to mono Float32
        guard let channelData = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let data = channelData[channel]
            for i in 0..<frames {
                mono[i] += data[i] / Float(channels)
            }
        }

        if abs(sampleRate - 16_000) < 1 { return mono }
        return resampleLinear(mono, from: sampleRate, to: 16_000)
    }

    /// Simple linear resampler — adequate for speaker-embedding input.
    static func resampleLinear(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return samples }
        let ratio = sourceRate / targetRate
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }
}
