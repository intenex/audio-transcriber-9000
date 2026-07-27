import AVFoundation
import XCTest
@testable import AudioTranscriber

/// The unattended-recording guardrails: level measurement, silence detection,
/// and the long-recording check-in.
///
/// Most of this file exists to prove the ONE property that matters — a
/// recording that is capturing audio is never stopped. Every "there was sound"
/// case is asserted over hours of simulated time.
final class RecordingGuardrailTests: XCTestCase {

    // MARK: - Level measurement

    func testLevelsMatchKnownAmplitudes() {
        let count = 4_800
        var samples = [Float](repeating: 0, count: count)
        // Full-cycle sine at amplitude 0.5: peak = -6.02 dBFS, RMS = -9.03 dBFS.
        for i in 0..<count {
            samples[i] = 0.5 * sinf(2 * .pi * Float(i) / 48)
        }
        let (rms, peak) = samples.withUnsafeBufferPointer {
            AudioLevel.levels(of: $0.baseAddress!, count: count)
        }
        XCTAssertEqual(peak, -6.02, accuracy: 0.1)
        XCTAssertEqual(rms, -9.03, accuracy: 0.1)
    }

    func testDigitalSilenceReportsTheFloor() {
        let samples = [Float](repeating: 0, count: 1_024)
        let (rms, peak) = samples.withUnsafeBufferPointer {
            AudioLevel.levels(of: $0.baseAddress!, count: 1_024)
        }
        XCTAssertEqual(rms, AudioLevel.minimumDB)
        XCTAssertEqual(peak, AudioLevel.minimumDB)
    }

    /// One live channel among silent ones still means audio was captured.
    func testMultichannelReportsLoudestChannel() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        buffer.frameLength = 1_024
        for i in 0..<1_024 {
            buffer.floatChannelData![0][i] = 0                       // silent channel
            buffer.floatChannelData![1][i] = 0.5 * sinf(Float(i))    // live channel
        }
        let (rms, peak) = AudioLevel.levels(of: buffer)
        XCTAssertGreaterThan(rms, -12)
        XCTAssertGreaterThan(peak, -7)
    }

    func testEmptyBufferIsSafe() {
        let samples = [Float](repeating: 0, count: 8)
        let (rms, peak) = samples.withUnsafeBufferPointer {
            AudioLevel.levels(of: $0.baseAddress!, count: 0)
        }
        XCTAssertEqual(rms, AudioLevel.minimumDB)
        XCTAssertEqual(peak, AudioLevel.minimumDB)
    }

    // MARK: - Silence detection: it must stop when nothing is captured

    func testContinuousDigitalSilenceStopsExactlyAtTheLimit() {
        var detector = SilenceDetector()
        for step in 1..<12_000 {   // 0.1 s steps, up to 19:59.9
            let time = Double(step) * 0.1
            detector.observe(rmsDB: AudioLevel.minimumDB, peakDB: AudioLevel.minimumDB, at: time)
            XCTAssertFalse(detector.shouldAutoStop(at: time), "stopped early at \(time)s")
        }
        detector.observe(rmsDB: AudioLevel.minimumDB, peakDB: AudioLevel.minimumDB, at: 20 * 60)
        XCTAssertTrue(detector.shouldAutoStop(at: 20 * 60))
    }

    /// A muted or unplugged mic that still delivers buffers: dead-quiet room
    /// tone well under the audible floor.
    func testDeadQuietRoomStopsAfterTheLimit() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 25 * 60, by: 0.5) {
            detector.observe(rmsDB: -84, peakDB: -78, at: step)
        }
        XCTAssertTrue(detector.shouldAutoStop(at: 25 * 60))
    }

    func testAutoStopHonoursAConfiguredLimit() {
        var config = SilenceDetector.Config.default
        config.silenceLimit = 5
        var detector = SilenceDetector(config: config)
        for step in stride(from: 0.1, through: 4.9, by: 0.1) {
            detector.observe(rmsDB: -90, peakDB: -90, at: step)
        }
        XCTAssertFalse(detector.shouldAutoStop(at: 4.9))
        detector.observe(rmsDB: -90, peakDB: -90, at: 5.0)
        XCTAssertTrue(detector.shouldAutoStop(at: 5.0))
    }

    func testZeroLimitDisablesAutoStop() {
        var config = SilenceDetector.Config.default
        config.silenceLimit = 0
        var detector = SilenceDetector(config: config)
        for step in stride(from: 1.0, through: 10 * 3_600, by: 30) {
            detector.observe(rmsDB: AudioLevel.minimumDB, peakDB: AudioLevel.minimumDB, at: step)
        }
        XCTAssertFalse(detector.shouldAutoStop(at: 10 * 3_600))
    }

    func testConfigFromDefaultsReadsMinutes() {
        let defaults = UserDefaults(suiteName: "guardrails-\(UUID().uuidString)")!
        XCTAssertEqual(SilenceDetector.Config.fromDefaults(defaults).silenceLimit, 20 * 60)
        defaults.set(45.0, forKey: "silenceAutoStopMinutes")
        XCTAssertEqual(SilenceDetector.Config.fromDefaults(defaults).silenceLimit, 45 * 60)
        defaults.set(0.0, forKey: "silenceAutoStopMinutes")
        XCTAssertEqual(SilenceDetector.Config.fromDefaults(defaults).silenceLimit, 0)
        defaults.set(-5.0, forKey: "silenceAutoStopMinutes")
        XCTAssertEqual(SilenceDetector.Config.fromDefaults(defaults).silenceLimit, 0)
    }

    // MARK: - Silence detection: it must NEVER stop while sound is captured

    /// A three-hour conversation: bursts of speech separated by pauses.
    func testConversationWithPausesNeverStops() {
        var detector = SilenceDetector()
        var time: TimeInterval = 0
        var speaking = true
        while time < 3 * 3_600 {
            // 8 s of speech, then a 25 s pause of ordinary room tone.
            let segment: TimeInterval = speaking ? 8 : 25
            let end = time + segment
            while time < end {
                time += 0.1
                if speaking {
                    detector.observe(rmsDB: -26, peakDB: -14, at: time)
                } else {
                    detector.observe(rmsDB: -55, peakDB: -46, at: time)
                }
                XCTAssertFalse(detector.shouldAutoStop(at: time), "stopped mid-conversation at \(time)s")
            }
            speaking.toggle()
        }
    }

    /// Distant, quiet speech (a lecture across a room) — under every absolute
    /// threshold, caught only by the noise-floor-relative rule.
    func testQuietDistantSpeechNeverStops() {
        var detector = SilenceDetector()
        var time: TimeInterval = 0
        while time < 3 * 3_600 {
            // 4 s of faint speech, 12 s of even fainter room tone.
            for _ in 0..<40 {
                time += 0.1
                detector.observe(rmsDB: -52, peakDB: -41, at: time)
            }
            for _ in 0..<120 {
                time += 0.1
                detector.observe(rmsDB: -66, peakDB: -58, at: time)
            }
            XCTAssertFalse(detector.shouldAutoStop(at: time), "stopped on quiet speech at \(time)s")
        }
    }

    /// Steady loud content (music, a call on speaker) with no gaps at all.
    func testSteadyLoudContentNeverStops() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 6 * 3_600, by: 0.5) {
            detector.observe(rmsDB: -30, peakDB: -18, at: step)
            XCTAssertFalse(detector.shouldAutoStop(at: step))
        }
    }

    /// Content sitting exactly on the absolute always-sound line stays sound
    /// forever, however far the noise floor drifts.
    func testContentAtTheAbsoluteThresholdNeverStops() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 4 * 3_600, by: 0.5) {
            detector.observe(rmsDB: -45, peakDB: -44, at: step)
            XCTAssertFalse(detector.shouldAutoStop(at: step))
        }
    }

    /// Sparse transients (typing, a door, a cough) that an RMS window averages
    /// away still prove the mic is live.
    func testSparseTransientsKeepTheRecordingAlive() {
        var detector = SilenceDetector()
        var time: TimeInterval = 0
        while time < 4 * 3_600 {
            // One transient every 15 minutes, silence in between.
            for _ in 0..<9_000 {
                time += 0.1
                detector.observe(rmsDB: -95, peakDB: -88, at: time)
            }
            time += 0.1
            detector.observe(rmsDB: -62, peakDB: -30, at: time)   // peak rule
            XCTAssertFalse(detector.shouldAutoStop(at: time), "stopped despite transients at \(time)s")
        }
    }

    /// One sounding buffer just before the deadline resets the whole clock.
    func testSingleSoundingBufferResetsTheClock() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 19 * 60 + 59, by: 0.5) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
        }
        XCTAssertFalse(detector.shouldAutoStop(at: 19 * 60 + 59))
        detector.observe(rmsDB: -20, peakDB: -8, at: 19 * 60 + 59.5)
        // The clock restarts from the sounding buffer, not from zero.
        XCTAssertFalse(detector.shouldAutoStop(at: 30 * 60))
        for step in stride(from: 1_800.0, through: 2_340.0, by: 1.0) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
        }
        XCTAssertFalse(detector.shouldAutoStop(at: 39 * 60))
        XCTAssertTrue(detector.shouldAutoStop(at: 19 * 60 + 59.5 + 20 * 60))
    }

    /// Rebuilding capture (AirPods swap) restarts the clock — the gap was never
    /// measured, so it must not count against the recording.
    func testCaptureRestartResetsTheClock() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 19 * 60, by: 1) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
        }
        detector.captureRestarted(at: 19 * 60)
        XCTAssertNil(detector.noiseFloorDB)
        for step in stride(from: 1_141.0, through: 2_280.0, by: 1.0) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
            XCTAssertFalse(detector.shouldAutoStop(at: step))
        }
        XCTAssertTrue(detector.shouldAutoStop(at: 2_341))
    }

    /// A rotation the silence rule itself asked for (reopening a possibly-dead
    /// input) must NOT reset the clock — otherwise recovery attempts would
    /// defer the limit forever.
    func testSilenceTriggeredRestartKeepsTheClockRunning() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 1_140.0, by: 1.0) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
        }
        detector.captureRestarted(at: 1_140, resetSilenceClock: false)
        XCTAssertNil(detector.noiseFloorDB, "the reopened device gets a fresh floor")
        for step in stride(from: 1_141.0, through: 1_199.0, by: 1.0) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
            XCTAssertFalse(detector.shouldAutoStop(at: step))
        }
        detector.observe(rmsDB: -95, peakDB: -90, at: 1_200)
        XCTAssertTrue(detector.shouldAutoStop(at: 1_200), "the limit still lands at 20 min")
    }

    /// …but if reopening the input actually fixed it, the first real sound
    /// clears everything.
    func testSoundAfterSilenceRecoveryResetsTheClock() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 1_140.0, by: 1.0) {
            detector.observe(rmsDB: -95, peakDB: -90, at: step)
        }
        detector.captureRestarted(at: 1_140, resetSilenceClock: false)
        detector.observe(rmsDB: -22, peakDB: -10, at: 1_141)
        XCTAssertFalse(detector.shouldAutoStop(at: 2_000))
        XCTAssertEqual(detector.silenceDuration(at: 1_200), 59, accuracy: 0.01)
    }

    /// The noise floor may only creep upward, so faint-but-real content is
    /// treated as sound for many minutes even if it never varies — and the
    /// 20-minute clock only starts after that.
    func testNoiseFloorRisesSlowlyEnoughToProtectFaintContent() {
        var detector = SilenceDetector()
        // Ten minutes of a dead-quiet room establishes a very low floor.
        for step in stride(from: 0.1, through: 10 * 60, by: 0.5) {
            detector.observe(rmsDB: -85, peakDB: -80, at: step)
        }
        // Then an unvarying faint hum, below every absolute threshold.
        var firstStopTime: TimeInterval?
        for step in stride(from: 10 * 60 + 0.5, through: 60 * 60, by: 0.5) {
            detector.observe(rmsDB: -56, peakDB: -48, at: step)
            if detector.shouldAutoStop(at: step), firstStopTime == nil { firstStopTime = step }
        }
        // Sound for minutes while the floor climbs, then a full silence limit.
        let earliestAcceptableStop: TimeInterval = 2_040   // 10 min quiet + 20 min limit + 4 min grace
        XCTAssertNotNil(firstStopTime)
        XCTAssertGreaterThan(firstStopTime ?? 0, earliestAcceptableStop)
    }

    /// Sound at the very start, then genuine silence: the limit runs from the
    /// last sound, not from the start of the recording.
    func testSilenceClockRunsFromLastSound() {
        var detector = SilenceDetector()
        for step in stride(from: 0.1, through: 60, by: 0.1) {
            detector.observe(rmsDB: -24, peakDB: -12, at: step)
        }
        for step in stride(from: 60.1, through: 19 * 60 + 60, by: 0.5) {
            detector.observe(rmsDB: -100, peakDB: -100, at: step)
            XCTAssertFalse(detector.shouldAutoStop(at: step))
        }
        XCTAssertTrue(detector.shouldAutoStop(at: 60 + 20 * 60))
    }

    // MARK: - Long-recording check-in

    func testCheckInFiresAtEachInterval() {
        var checkIn = LongRecordingCheckIn(interval: 2 * 3_600)
        XCTAssertFalse(checkIn.isDue(at: 0))
        XCTAssertFalse(checkIn.isDue(at: 2 * 3_600 - 1))
        XCTAssertTrue(checkIn.isDue(at: 2 * 3_600))
        XCTAssertFalse(checkIn.isDue(at: 2 * 3_600 + 1), "fired twice for one interval")
        XCTAssertFalse(checkIn.isDue(at: 4 * 3_600 - 1))
        XCTAssertTrue(checkIn.isDue(at: 4 * 3_600))
    }

    /// A check-in delivered late (Mac asleep for 6 h) fires once, then re-arms
    /// a full interval from now — not once per interval it slept through.
    func testLateCheckInDoesNotBurstFire() {
        var checkIn = LongRecordingCheckIn(interval: 2 * 3_600)
        XCTAssertTrue(checkIn.isDue(at: 8 * 3_600))
        XCTAssertFalse(checkIn.isDue(at: 8 * 3_600 + 60))
        XCTAssertTrue(checkIn.isDue(at: 10 * 3_600))
    }

    func testAcknowledgingPushesTheNextCheckIn() {
        var checkIn = LongRecordingCheckIn(interval: 2 * 3_600)
        XCTAssertTrue(checkIn.isDue(at: 2 * 3_600))
        checkIn.acknowledged(at: 2 * 3_600 + 30)
        XCTAssertFalse(checkIn.isDue(at: 4 * 3_600))
        XCTAssertTrue(checkIn.isDue(at: 4 * 3_600 + 30))
    }

    func testZeroIntervalDisablesCheckIns() {
        var checkIn = LongRecordingCheckIn(interval: 0)
        XCTAssertFalse(checkIn.isDue(at: 100 * 3_600))
    }

    func testCheckInFromDefaultsReadsHours() {
        let defaults = UserDefaults(suiteName: "guardrails-\(UUID().uuidString)")!
        XCTAssertEqual(LongRecordingCheckIn.fromDefaults(defaults).interval, 2 * 3_600)
        defaults.set(0.5, forKey: "longRecordingCheckInHours")
        XCTAssertEqual(LongRecordingCheckIn.fromDefaults(defaults).interval, 1_800)
        defaults.set(0.0, forKey: "longRecordingCheckInHours")
        XCTAssertEqual(LongRecordingCheckIn.fromDefaults(defaults).interval, 0)
    }

    // MARK: - Thread-safe monitor

    func testMonitorTracksSilenceAgainstWallClock() {
        let start = Date()
        var config = SilenceDetector.Config.default
        config.silenceLimit = 4
        let monitor = RecordingLevelMonitor(config: config, start: start)
        monitor.observe(rmsDB: -20, peakDB: -8, at: start.addingTimeInterval(1))
        XCTAssertEqual(monitor.silenceDuration(now: start.addingTimeInterval(3)), 2, accuracy: 0.01)
        XCTAssertFalse(monitor.shouldAutoStop(now: start.addingTimeInterval(4)))
        XCTAssertTrue(monitor.shouldAutoStop(now: start.addingTimeInterval(5)))
        monitor.captureRestarted(at: start.addingTimeInterval(5))
        XCTAssertFalse(monitor.shouldAutoStop(now: start.addingTimeInterval(6)))
    }

    /// Buffers that stop arriving entirely (a dead tap) also count as silence —
    /// the recorder's watchdog gets first crack at rebuilding capture.
    func testMonitorCountsMissingBuffersAsSilence() {
        let start = Date()
        var config = SilenceDetector.Config.default
        config.silenceLimit = 10
        let monitor = RecordingLevelMonitor(config: config, start: start)
        monitor.observe(rmsDB: -20, peakDB: -8, at: start)
        XCTAssertTrue(monitor.shouldAutoStop(now: start.addingTimeInterval(11)))
    }

    func testMonitorIsSafeUnderConcurrentObservation() {
        let start = Date()
        let monitor = RecordingLevelMonitor(start: start)
        let group = DispatchGroup()
        for worker in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<500 {
                    monitor.observe(rmsDB: -30, peakDB: -12,
                                    at: start.addingTimeInterval(Double(worker) * 0.001 + Double(i) * 0.01))
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(monitor.bufferCount, 2_000)
        XCTAssertFalse(monitor.shouldAutoStop(now: start.addingTimeInterval(6)))
    }

    /// The monitor measures the real downmixed buffer type the tap writes.
    func testMonitorAcceptsRealBuffers() {
        let start = Date()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 4_096
        for i in 0..<4_096 { buffer.floatChannelData![0][i] = 0.2 * sinf(Float(i) * 0.05) }
        var config = SilenceDetector.Config.default
        config.silenceLimit = 2
        let monitor = RecordingLevelMonitor(config: config, start: start)
        monitor.observe(buffer: buffer, at: start.addingTimeInterval(1))
        XCTAssertFalse(monitor.shouldAutoStop(now: start.addingTimeInterval(2.5)))
        XCTAssertTrue(monitor.shouldAutoStop(now: start.addingTimeInterval(3.5)))
    }
}
