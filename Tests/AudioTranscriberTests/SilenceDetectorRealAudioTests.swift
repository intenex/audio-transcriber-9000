import AVFoundation
import XCTest
@testable import AudioTranscriber

/// Runs the silence guardrail over REAL recordings and asserts it would never
/// have stopped them. Synthetic level sequences (RecordingGuardrailTests) can
/// only prove the policy; these prove it against actual microphone content —
/// the property the user cares about is "never stop a recording that is
/// capturing audio".
final class SilenceDetectorRealAudioTests: XCTestCase {

    private var integrationEnabled: Bool {
        FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-integration-tests")
    }

    /// One stretch the detector considered silent, with the loudest thing that
    /// actually happened inside it.
    private struct SilenceRun {
        var start: TimeInterval
        var end: TimeInterval
        var loudestPeakDB: Float
        var loudestRMSDB: Float
        var duration: TimeInterval { end - start }
    }

    /// Replays a file through the detector exactly as the capture tap would:
    /// ~93 ms buffers, levels measured on the decoded float samples.
    private func silenceRuns(in url: URL, config: SilenceDetector.Config = .default)
        throws -> (runs: [SilenceRun], duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable format: \(url.lastPathComponent)"])
        }
        var detector = SilenceDetector(config: config)
        var time: TimeInterval = 0
        var runs: [SilenceRun] = []
        var current: SilenceRun?
        // AVAudioFile.read throws at EOF rather than returning 0 frames, so
        // walk the frame count explicitly.
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(4_096), remaining))
            guard frames > 0 else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            time += Double(buffer.frameLength) / format.sampleRate
            let (rms, peak) = AudioLevel.levels(of: buffer)
            let isSound = detector.observe(rmsDB: rms, peakDB: peak, at: time)
            if isSound {
                if var run = current {
                    run.end = time
                    runs.append(run)
                    current = nil
                }
            } else if current == nil {
                current = SilenceRun(start: detector.lastSoundTime, end: time,
                                     loudestPeakDB: peak, loudestRMSDB: rms)
            } else {
                current!.end = time
                current!.loudestPeakDB = max(current!.loudestPeakDB, peak)
                current!.loudestRMSDB = max(current!.loudestRMSDB, rms)
            }
        }
        if let run = current { runs.append(run) }
        return (runs, time)
    }

    private func longestSilenceRun(in url: URL, config: SilenceDetector.Config = .default)
        throws -> (longest: TimeInterval, duration: TimeInterval) {
        let (runs, duration) = try silenceRuns(in: url, config: config)
        return (runs.map(\.duration).max() ?? 0, duration)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AudioTranscriberTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("test_recording.wav")
    }

    /// The repo's two-speaker conversation fixture: real speech, real pauses,
    /// real room tone. Nothing in it may read as silence for long.
    func testConversationFixtureIsNeverMistakenForSilence() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureURL.path), "fixture missing")
        let (longest, duration) = try longestSilenceRun(in: fixtureURL)
        print("[guardrail] \(fixtureURL.lastPathComponent): \(String(format: "%.1f", duration))s, "
              + "longest silence run \(String(format: "%.1f", longest))s")
        XCTAssertGreaterThan(duration, 30, "fixture should be the 63 s conversation")
        // Conversational pauses are seconds, not minutes.
        XCTAssertLessThan(longest, 30, "real speech classified as silence for \(longest)s")
    }

    /// Same audio, but pitched down to a whisper: a quiet recording is still a
    /// recording. -30 dB on every sample puts most of it under the absolute
    /// thresholds, so only the noise-floor-relative rule can save it.
    func testVeryQuietSpeechIsNeverMistakenForSilence() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureURL.path), "fixture missing")
        let quiet = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiet-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: quiet) }

        let source = try AVAudioFile(forReading: fixtureURL)
        let format = source.processingFormat
        try autoreleasepool {
            let out = try AVAudioFile(forWriting: quiet, settings: source.fileFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
            let gain: Float = 0.0316   // -30 dB
            while source.framePosition < source.length {
                let remaining = source.length - source.framePosition
                let frames = AVAudioFrameCount(min(AVAudioFramePosition(8_192), remaining))
                guard frames > 0 else { break }
                try source.read(into: buffer, frameCount: frames)
                if buffer.frameLength == 0 { break }
                for channel in 0..<Int(format.channelCount) {
                    let samples = buffer.floatChannelData![channel]
                    for i in 0..<Int(buffer.frameLength) { samples[i] *= gain }
                }
                try out.write(from: buffer)
            }
        }

        let (longest, duration) = try longestSilenceRun(in: quiet)
        print("[guardrail] whisper-level copy: \(String(format: "%.1f", duration))s, "
              + "longest silence run \(String(format: "%.1f", longest))s")
        XCTAssertLessThan(longest, 30, "quiet speech classified as silence for \(longest)s")
    }

    #if os(macOS)
    /// Gated: replays the user's ENTIRE real library and checks the property
    /// that matters — the guardrail may only ever act on a stretch that
    /// contains no audible signal whatsoever.
    ///
    /// Two of the library's recordings do contain stretches past the limit
    /// (47 min and 113 min): both are literal all-zero samples, the dead-input
    /// failure this feature exists to end. Every such stretch must be
    /// inaudible — that is what this asserts, file by file.
    func testRealLibraryOnlyFlagsStretchesWithNoAudibleSignal() throws {
        try XCTSkipUnless(integrationEnabled, "marker file not present")
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioTranscriber")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "no real library")

        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aac", "caf"]
        let files = (try FileManager.default.contentsOfDirectory(at: library,
                                                                 includingPropertiesForKeys: [.fileSizeKey]))
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipUnless(!files.isEmpty, "library has no audio")

        let limit = SilenceDetector.Config.default.silenceLimit
        // Inaudibility bars for a stretch the guardrail would act on. AAC's
        // reconstruction of digital silence isn't bit-exact — the March 30
        // recording's dead stretch peaks at -69 dBFS of codec noise over an
        // RMS of -87 dBFS — so the peak bar allows for that while staying
        // ~50 dB below any real speech in these files.
        let inaudiblePeakDB: Float = -60
        let inaudibleRMSDB: Float = -70
        var checked = 0
        var flagged = 0
        for url in files {
            // Read-only replay of user data.
            guard let (runs, duration) = try? silenceRuns(in: url) else {
                print("[guardrail] skipped unreadable \(url.lastPathComponent)")
                continue
            }
            checked += 1
            let longest = runs.map(\.duration).max() ?? 0
            print("[guardrail] \(url.lastPathComponent): \(String(format: "%.0f", duration))s, "
                  + "longest silence run \(String(format: "%.0f", longest))s")
            for run in runs where run.duration >= limit {
                flagged += 1
                print("[guardrail]   would stop at \(String(format: "%.0f", run.start))s–"
                      + "\(String(format: "%.0f", run.end))s; loudest inside: "
                      + "peak \(String(format: "%.1f", run.loudestPeakDB)) dBFS, "
                      + "rms \(String(format: "%.1f", run.loudestRMSDB)) dBFS")
                XCTAssertLessThan(run.loudestPeakDB, inaudiblePeakDB,
                                  "\(url.lastPathComponent) would be stopped over a stretch containing audible audio (peak \(run.loudestPeakDB) dBFS at \(run.start)s)")
                XCTAssertLessThan(run.loudestRMSDB, inaudibleRMSDB,
                                  "\(url.lastPathComponent) would be stopped over a stretch carrying real energy (rms \(run.loudestRMSDB) dBFS at \(run.start)s)")
            }
        }
        XCTAssertGreaterThan(checked, 0, "no real recordings were checked")
        print("[guardrail] checked \(checked) real recordings; \(flagged) stretch(es) past the limit, all inaudible")
    }
    #endif

    /// The other direction, on real audio: a genuinely empty capture (what a
    /// forgotten recording produces) does trip the limit.
    func testSilentCaptureTripsTheLimit() throws {
        let silent = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: silent) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: silent, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            // A muted input isn't perfectly zero — dither it at ~-90 dBFS.
            for i in 0..<16_000 {
                buffer.floatChannelData![0][i] = Float.random(in: -0.00002...0.00002)
            }
            for _ in 0..<70 { try file.write(from: buffer) }   // 70 s
        }
        var config = SilenceDetector.Config.default
        config.silenceLimit = 60
        let (longest, duration) = try longestSilenceRun(in: silent, config: config)
        XCTAssertEqual(duration, 70, accuracy: 1)
        XCTAssertGreaterThan(longest, config.silenceLimit)
    }
}
