import AVFoundation
import Foundation

/// On-disk format for NEW recordings. Compressed AAC is the default — WAV at
/// the old settings cost ~346 MB/hour; AAC high-quality speech is ~45 MB/hour
/// with no practical quality loss for transcription or listening.
enum RecordingFormat: String, CaseIterable, Identifiable {
    case aacHigh = "aacHigh"       // default
    case aacCompact = "aacCompact"
    case wav = "wav"

    var id: String { rawValue }

    static var selected: RecordingFormat {
        let raw = UserDefaults.standard.string(forKey: "recordingFormat") ?? RecordingFormat.aacHigh.rawValue
        return RecordingFormat(rawValue: raw) ?? .aacHigh
    }

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aacHigh, .aacCompact: return "m4a"
        }
    }

    var bitrate: Int? {
        switch self {
        case .aacHigh: return 96_000
        case .aacCompact: return 48_000
        case .wav: return nil
        }
    }

    var displayName: String {
        switch self {
        case .aacHigh: return "Compressed — High Quality (AAC, ~45 MB/hr)"
        case .aacCompact: return "Compressed — Compact (AAC, ~22 MB/hr)"
        case .wav: return "Uncompressed (WAV, ~350 MB/hr)"
        }
    }

    /// AVAudioFile settings for writing the recording. The tap stays in the
    /// native input format; AVAudioFile's processingFormat is pinned to that
    /// via `commonFormat:` so encoding happens internally (never a converter
    /// in the tap callback — the historic crash).
    func fileSettings(for inputFormat: AVAudioFormat) -> [String: Any] {
        switch self {
        case .wav:
            var settings = inputFormat.settings
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            return settings
        case .aacHigh, .aacCompact:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                // AAC supports up to 48 kHz; never upsample the input.
                AVSampleRateKey: min(inputFormat.sampleRate, 48_000),
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVEncoderBitRateKey: bitrate ?? 96_000,
            ]
        }
    }
}
