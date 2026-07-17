import Foundation

/// Duration-based cost estimates for cloud engines (list-price constants).
enum TranscriptionCostEstimator {
    static let perMinuteUSD: [TranscriptionEngineKind: Double] = [
        .openAI: 0.006,       // gpt-4o-transcribe-diarize
        .assemblyAI: 0.005,   // speech-to-text w/ speaker labels
    ]

    static func estimateUSD(duration: TimeInterval, kind: TranscriptionEngineKind) -> Double? {
        guard let rate = perMinuteUSD[kind] else { return nil }
        return duration / 60 * rate
    }

    static func estimateString(duration: TimeInterval, kind: TranscriptionEngineKind) -> String? {
        guard let cost = estimateUSD(duration: duration, kind: kind) else { return nil }
        if cost < 0.01 { return "≈ <$0.01" }
        return String(format: "≈ $%.2f", cost)
    }
}
