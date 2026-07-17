import Foundation

/// Persisted realtime-factor calibration per engine (audio seconds processed per
/// wall-clock second). Updated with an EMA after every chunk so ETAs converge
/// within the first minute of the first real run on this machine.
enum RTFStore {
    static let emaAlpha = 0.3
    static let defaultASR = 20.0        // deliberately conservative; real M1 Max ~80-120x
    static let defaultDiarizer = 50.0

    static func rtf(engineID: String, defaults: UserDefaults = .standard, fallback: Double = defaultASR) -> Double {
        let value = defaults.double(forKey: key(engineID))
        return value > 0 ? value : fallback
    }

    static func hasCalibration(engineID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.double(forKey: key(engineID)) > 0
    }

    static func record(engineID: String, audioSeconds: Double, processingSeconds: Double,
                       defaults: UserDefaults = .standard) {
        guard processingSeconds > 0.01, audioSeconds > 0 else { return }
        let measured = audioSeconds / processingSeconds
        let existing = defaults.double(forKey: key(engineID))
        let updated = existing > 0 ? emaAlpha * measured + (1 - emaAlpha) * existing : measured
        defaults.set(updated, forKey: key(engineID))
    }

    private static func key(_ engineID: String) -> String { "rtf.\(engineID)" }
}

/// Computes remaining-time estimates for a chunked ASR + full-file diarization job.
struct ETACalculator {
    let asrRTF: Double
    let diarizerRTF: Double
    let totalAudioSeconds: Double

    func estimate(completedAudioSeconds: Double, diarizationPending: Bool) -> TimeInterval? {
        guard asrRTF > 0, totalAudioSeconds > 0 else { return nil }
        let remainingASR = max(0, totalAudioSeconds - completedAudioSeconds) / asrRTF
        let diarization = diarizationPending && diarizerRTF > 0 ? totalAudioSeconds / diarizerRTF : 0
        return remainingASR + diarization
    }
}

enum ETAFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "a few seconds remaining" }
        if seconds < 60 {
            let rounded = max(10, Int((seconds / 10).rounded() * 10))
            return "~\(rounded) sec remaining"
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 {
            return "~\(max(1, minutes)) min remaining"
        }
        let hours = Int(seconds / 3600)
        let remMinutes = Int((seconds - Double(hours) * 3600) / 60)
        if remMinutes > 0 {
            return "~\(hours) hr \(remMinutes) min remaining"
        }
        return "~\(hours) hr remaining"
    }
}
