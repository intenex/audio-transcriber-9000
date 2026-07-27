import Accelerate
import AVFAudio
import Foundation

/// Guardrails against recordings that run forever unattended (one ran for
/// 70 hours once):
///
/// * `SilenceDetector` — stops a recording after a long stretch during which
///   nothing was captured.
/// * `LongRecordingCheckIn` — asks "still recording?" at fixed intervals.
///
/// Both are pure value types so the policy is unit-testable without audio
/// hardware; `RecordingLevelMonitor` is the thread-safe shell the capture tap
/// talks to.
///
/// DESIGN BIAS: every ambiguous case must resolve to "there was sound".
/// Ending a live recording by mistake destroys something irreplaceable;
/// failing to end a silent one costs disk space. Three independent rules can
/// each mark a buffer as sound (loud in absolute terms, a transient peak, or
/// energy above the ambient floor), a single sounding buffer resets the whole
/// silence clock, and the clock has to run uninterrupted for the full limit.

// MARK: - Level measurement

enum AudioLevel {
    /// Digital silence has no dB value; this is the floor we report instead.
    static let minimumDB: Float = -120

    /// RMS and peak level, in dBFS, of one mono float32 buffer.
    /// Measured on the same downmixed buffer that gets written to the file, so
    /// the numbers describe what the recording actually contains.
    static func levels(of samples: UnsafePointer<Float>, count: Int) -> (rmsDB: Float, peakDB: Float) {
        guard count > 0 else { return (minimumDB, minimumDB) }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        return (decibels(rms), decibels(peak))
    }

    static func levels(of buffer: AVAudioPCMBuffer) -> (rmsDB: Float, peakDB: Float) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            return (minimumDB, minimumDB)
        }
        // Multi-channel input: report the loudest channel, never an average —
        // one live channel among silent ones still means sound was captured.
        var rms = minimumDB
        var peak = minimumDB
        for channel in 0..<Int(buffer.format.channelCount) {
            let (r, p) = levels(of: data[channel], count: Int(buffer.frameLength))
            rms = max(rms, r)
            peak = max(peak, p)
        }
        return (rms, peak)
    }

    static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return minimumDB }
        return max(minimumDB, 20 * log10(amplitude))
    }
}

// MARK: - Silence detection

/// Decides whether a recording has gone quiet for long enough to stop it.
///
/// A buffer counts as SOUND when any of these hold:
///  1. RMS ≥ `alwaysSoundRMSDB` (-45 dBFS) — loud in absolute terms.
///  2. Peak ≥ `alwaysSoundPeakDB` (-35 dBFS) — a transient (word onset, click)
///     that a 90 ms RMS window would average away.
///  3. RMS ≥ noise floor + `activityMarginDB`, and ≥ `audibleFloorDB`
///     (-70 dBFS) — activity standing out from the ambient level.
///
/// The noise floor tracks the quietest recent level (instant fall, at most
/// `floorRiseDBPerSecond` rise, capped at `alwaysSoundRMSDB`), so continuous
/// content — music, a fan, a far-off lecture — cannot pull the floor up past
/// the point where it would be mistaken for silence.
struct SilenceDetector {
    struct Config: Equatable {
        /// Continuous silence that triggers an auto-stop. 0 disables it.
        var silenceLimit: TimeInterval = 20 * 60
        /// Continuous silence after which capture is rebuilt once, in case the
        /// input died while still delivering (empty) buffers. 0 disables it.
        /// Two of the user's real recordings contain 47 min / 113 min of
        /// all-zero samples from exactly that failure. Capped by
        /// `maxSilenceRecoveryAttempts` so a genuinely quiet room can't churn.
        var silenceRecoveryDelay: TimeInterval = 120
        var maxSilenceRecoveryAttempts = 3
        var alwaysSoundRMSDB: Float = -45
        var alwaysSoundPeakDB: Float = -35
        var audibleFloorDB: Float = -70
        var activityMarginDB: Float = 8
        /// 3 dB/min: a noise floor climbing toward steady content stays far
        /// below it for many minutes, and the cap keeps it out of "audible".
        var floorRiseDBPerSecond: Float = 0.05
        var minimumFloorDB: Float = -100

        static let `default` = Config()

        /// Reads the user-tunable limit (`silenceAutoStopMinutes`, 0 = off).
        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Config {
            var config = Config()
            let minutes = defaults.object(forKey: "silenceAutoStopMinutes") as? Double ?? 20
            config.silenceLimit = max(0, minutes * 60)
            return config
        }
    }

    private(set) var config: Config
    private(set) var noiseFloorDB: Float?
    /// Time of the most recent buffer that contained sound.
    private(set) var lastSoundTime: TimeInterval
    private var lastObservationTime: TimeInterval

    init(config: Config = .default, startTime: TimeInterval = 0) {
        self.config = config
        self.lastSoundTime = startTime
        self.lastObservationTime = startTime
    }

    /// Feeds one measured buffer. `time` is seconds since the recording began
    /// and must be non-decreasing.
    @discardableResult
    mutating func observe(rmsDB: Float, peakDB: Float, at time: TimeInterval) -> Bool {
        let elapsed = max(0, time - lastObservationTime)
        lastObservationTime = time

        let floor = noiseFloorDB ?? rmsDB
        let relativeThreshold = max(floor + config.activityMarginDB, config.audibleFloorDB)
        // min() with the absolute rule: anything at or above `alwaysSoundRMSDB`
        // is sound no matter what the floor has drifted to.
        let threshold = min(config.alwaysSoundRMSDB, relativeThreshold)
        let isSound = rmsDB >= threshold || peakDB >= config.alwaysSoundPeakDB

        // Floor tracking: fall instantly to a new minimum, rise slowly, never
        // above the current level, never past the always-sound cap.
        var updatedFloor: Float
        if rmsDB < floor {
            updatedFloor = rmsDB
        } else {
            updatedFloor = min(rmsDB, floor + config.floorRiseDBPerSecond * Float(elapsed))
        }
        updatedFloor = min(max(updatedFloor, config.minimumFloorDB), config.alwaysSoundRMSDB)
        noiseFloorDB = updatedFloor

        if isSound { lastSoundTime = time }
        return isSound
    }

    func silenceDuration(at time: TimeInterval) -> TimeInterval {
        max(0, time - lastSoundTime)
    }

    func shouldAutoStop(at time: TimeInterval) -> Bool {
        config.silenceLimit > 0 && silenceDuration(at: time) >= config.silenceLimit
    }

    /// Capture was rebuilt (device change, engine restart). The new device has
    /// its own noise characteristics and the gap wasn't measured, so the floor
    /// estimate starts over — and, by default, so does the silence clock:
    /// always the direction that keeps recording.
    ///
    /// `resetSilenceClock: false` is for a rotation the silence rule itself
    /// asked for (reopening a possibly-dead input): the clock must keep running
    /// so recovery attempts can't postpone the limit indefinitely. Real sound
    /// from the reopened device resets it immediately anyway.
    mutating func captureRestarted(at time: TimeInterval, resetSilenceClock: Bool = true) {
        noiseFloorDB = nil
        if resetSilenceClock { lastSoundTime = time }
        lastObservationTime = time
    }
}

// MARK: - Long-recording check-in

/// Fires at every multiple of `interval` so a forgotten recording surfaces
/// itself. An unanswered check-in never stops the recording — only the user
/// (or the silence rule) does.
struct LongRecordingCheckIn {
    /// 0 disables check-ins.
    var interval: TimeInterval
    private var nextDue: TimeInterval

    init(interval: TimeInterval = 2 * 3600) {
        self.interval = interval
        self.nextDue = interval
    }

    /// Reads the user-tunable interval (`longRecordingCheckInHours`, 0 = off).
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> LongRecordingCheckIn {
        let hours = defaults.object(forKey: "longRecordingCheckInHours") as? Double ?? 2
        return LongRecordingCheckIn(interval: max(0, hours * 3600))
    }

    /// True once per interval, at `elapsed` seconds into the recording.
    mutating func isDue(at elapsed: TimeInterval) -> Bool {
        guard interval > 0, elapsed >= nextDue else { return false }
        // Re-arm relative to now: a check-in delivered late (app asleep)
        // shouldn't immediately fire again for every interval it slept through.
        nextDue = elapsed + interval
        return true
    }

    /// The user chose to keep recording — next check-in a full interval later.
    mutating func acknowledged(at elapsed: TimeInterval) {
        guard interval > 0 else { return }
        nextDue = elapsed + interval
    }
}

// MARK: - Thread-safe monitor

/// The capture tap's view of the guardrails: measures each buffer and folds it
/// into the detector under a lock; the recorder's 1 Hz timer polls the result
/// from the main actor.
final class RecordingLevelMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: SilenceDetector
    private let start: Date
    private var observedBuffers = 0

    init(config: SilenceDetector.Config = .default, start: Date = Date()) {
        self.detector = SilenceDetector(config: config, startTime: 0)
        self.start = start
    }

    /// Called from the capture tap for every buffer written to disk.
    func observe(buffer: AVAudioPCMBuffer, at date: Date = Date()) {
        let (rmsDB, peakDB) = AudioLevel.levels(of: buffer)
        observe(rmsDB: rmsDB, peakDB: peakDB, at: date)
    }

    func observe(rmsDB: Float, peakDB: Float, at date: Date = Date()) {
        let time = date.timeIntervalSince(start)
        lock.lock(); defer { lock.unlock() }
        observedBuffers += 1
        detector.observe(rmsDB: rmsDB, peakDB: peakDB, at: time)
    }

    func captureRestarted(at date: Date = Date(), resetSilenceClock: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        detector.captureRestarted(at: date.timeIntervalSince(start),
                                  resetSilenceClock: resetSilenceClock)
    }

    /// Monitor-relative time of the last buffer that contained sound.
    var lastSoundTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return detector.lastSoundTime
    }

    /// Seconds since the last buffer that contained sound.
    func silenceDuration(now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return detector.silenceDuration(at: now.timeIntervalSince(start))
    }

    func shouldAutoStop(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return detector.shouldAutoStop(at: now.timeIntervalSince(start))
    }

    var bufferCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observedBuffers
    }
}
