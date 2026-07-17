import Foundation

/// Plans equal-duration upload parts that each fit under the provider's size
/// limit at the target bitrate. Pure math, unit-testable.
enum AudioSplitPlanner {
    struct Part: Equatable {
        let index: Int
        let startSeconds: Double
        let endSeconds: Double

        var duration: Double { endSeconds - startSeconds }
    }

    static func plan(durationSeconds: Double,
                     bitrate: Int = CloudAudioSpec.bitrate,
                     limitBytes: Int = CloudAudioSpec.uploadLimitBytes,
                     headroom: Double = CloudAudioSpec.headroom) -> [Part] {
        guard durationSeconds > 0 else { return [] }
        let usableBytes: Double = Double(limitBytes) * headroom
        let maxPartSeconds: Double = usableBytes * 8.0 / Double(bitrate)
        let partCount: Int = max(1, Int(ceil(durationSeconds / maxPartSeconds)))
        let partDuration: Double = durationSeconds / Double(partCount)

        var parts: [Part] = []
        for i in 0..<partCount {
            let start: Double = Double(i) * partDuration
            let end: Double = (i == partCount - 1) ? durationSeconds : Double(i + 1) * partDuration
            parts.append(Part(index: i, startSeconds: start, endSeconds: end))
        }
        return parts
    }
}
