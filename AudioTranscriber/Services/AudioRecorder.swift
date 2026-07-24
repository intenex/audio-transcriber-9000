import AVFoundation
import AVFAudio
import Foundation
import Observation
#if os(macOS)
import CoreAudio
#endif

/// Records audio via AVAudioEngine and plays recordings back. Library state
/// (the recordings list, import, delete, persistence) lives in RecordingStore.
///
/// Resilience model: macOS silently STOPS an AVAudioEngine whenever its input
/// device changes shape (AirPods connecting/disconnecting, HFP profile
/// switches, an interface unplugged). Every such interruption finalizes the
/// current segment file and starts a fresh one in the new native format —
/// never a converter inside the tap (historic ExtAudioFile::WriteInputProc
/// crash) — and stop stitches the segments into one file offline. A watchdog
/// catches anything the config-change notification misses, and repeated
/// rebuild failures save what was captured instead of losing it.
@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    var isPlaying = false
    var playingRecordingID: UUID? = nil
    var recordingDuration: TimeInterval = 0
    var playbackTime: Double = 0.0
    var playbackRate: Float = Float(UserDefaults.standard.object(forKey: "playbackRate") as? Double ?? 1.0)
    var errorMessage: String? = nil
    /// Human-readable capture source, e.g. "AirPods Pro + system audio".
    private(set) var inputDescription: String = ""
    /// True while a stopped multi-segment recording is being stitched.
    private(set) var isFinalizingRecording = false

    private weak var store: RecordingStore?
    /// Live transcript preview sink (optional; fed from the tap callback).
    var liveTranscriber: LiveTranscriber? = nil
    #if os(macOS)
    /// Device selection/monitoring (wired by the Mac app scene).
    weak var inputDeviceStore: AudioInputDeviceStore? = nil
    private var systemCapture: SystemAudioCapture? = nil
    #endif
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var currentRecordingURL: URL?
    private var recordingStartDate: Date?
    private var sleepGuard: SleepGuard? = nil

    // Segmented capture state
    private var segmentURLs: [URL] = []
    private var activeFormat: RecordingFormat = .aacHigh
    private var configObserver: NSObjectProtocol? = nil
    private var isRebuildingCapture = false
    private var tapHealth: TapHealth? = nil
    // Watchdog: written-frame growth tracking
    private var lastObservedLength: AVAudioFramePosition = 0
    private var lastGrowthDate = Date()

    var recordSystemAudioPreference: Bool {
        get { UserDefaults.standard.object(forKey: "recordSystemAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "recordSystemAudio") }
    }

    /// Consecutive tap-write-failure tracking, shared with the render thread.
    private final class TapHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var consecutiveFailures = 0
        private var reportedFatal = false
        /// Returns true exactly once, when sustained failure crosses the
        /// threshold (~2 s of lost buffers).
        func record(writeSucceeded: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if writeSucceeded {
                consecutiveFailures = 0
                return false
            }
            consecutiveFailures += 1
            if consecutiveFailures >= 25 && !reportedFatal {
                reportedFatal = true
                return true
            }
            return false
        }
    }

    @MainActor
    func attach(store: RecordingStore) {
        self.store = store
        #if os(iOS)
        AudioSessionController.shared.onRecordingInterrupted = { [weak self] reason in
            guard let self, self.isRecording else { return }
            self.stopRecording()
            self.errorMessage = "Recording saved — \(reason)."
        }
        AudioSessionController.shared.onPlaybackInterrupted = { [weak self] in
            self?.stopPlayback()
        }
        #endif
    }

    // MARK: - Permissions

    func requestMicPermission() {
        NSLog("[AudioRecorder] Requesting mic permission...")
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                NSLog("[AudioRecorder] Mic permission result: \(granted)")
                if !granted {
                    DispatchQueue.main.async {
                        self.errorMessage = "Microphone access denied. Grant permission in System Settings > Privacy > Microphone."
                    }
                }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        self.errorMessage = "Microphone access denied. Grant permission in System Settings > Privacy > Microphone."
                    }
                }
            }
        }
    }

    // MARK: - Recording

    @MainActor
    func startRecording() {
        guard !isRecording else { return }
        guard let store else { return }

        #if os(iOS)
        // The session must be active before the engine touches the input node.
        do {
            try AudioSessionController.shared.activateRecording()
        } catch {
            errorMessage = "Could not activate the audio session: \(error.localizedDescription)"
            return
        }
        #endif

        activeFormat = RecordingFormat.selected
        let filename = "recording_\(dateString()).\(activeFormat.fileExtension)"
        // Record into the device-local spool; the file moves into the library
        // only after the container is finalized at stop (sync safety).
        let url = SpoolLocation.url(fileName: filename)
        currentRecordingURL = url
        segmentURLs = []
        store.activeRecordingURL = url
        NSLog("[AudioRecorder] Starting recording to: \(url.path)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.beginCaptureSegment()
                self.isRecording = true
                self.recordingDuration = 0
                self.recordingStartDate = Date()
                self.sleepGuard = SleepGuard(reason: "Recording audio")
                self.startTimer()
                self.liveTranscriber?.start()
                NSLog("[AudioRecorder] Recording state updated")
            } catch {
                NSLog("[AudioRecorder] Failed: \(error)")
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                self.store?.activeRecordingURL = nil
                self.currentRecordingURL = nil
                self.segmentURLs = []
            }
        }
    }

    /// Builds one capture chain (engine + optional system-audio aggregate) and
    /// opens the next segment file. Called at start and after every capture
    /// interruption; each call appends a new segment.
    @MainActor
    private func beginCaptureSegment() async throws {
        guard let baseURL = currentRecordingURL else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no active recording URL"])
        }
        let format = activeFormat
        let segmentIndex = segmentURLs.count
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let segmentURL = baseURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).seg\(segmentIndex).\(baseURL.pathExtension)")
        try? FileManager.default.removeItem(at: segmentURL)

        #if os(macOS)
        let micDevice = inputDeviceStore?.effectiveDevice
        let wantSystemAudio = recordSystemAudioPreference && SystemAudioCapture.isSupported
        #endif
        let live = liveTranscriber
        let health = TapHealth()
        let onTapDead: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleCaptureFailure(reason: "audio writes started failing")
            }
        }

        // Blocking audio-hardware init stays off the main thread —
        // AVAudioEngine.inputNode triggers a TCC check via coreaudiod that
        // deadlocks if called synchronously on the main thread.
        #if os(macOS)
        let (engine, file, capture, description) = try await Task.detached(priority: .userInitiated) {
            () async throws -> (AVAudioEngine, AVAudioFile, SystemAudioCapture?, String) in
            let engine = AVAudioEngine()
            var capture: SystemAudioCapture? = nil
            var description = micDevice?.name ?? "Default input"
            var pinnedDeviceID: AudioObjectID? = nil

            if wantSystemAudio, let micDevice {
                let candidate = SystemAudioCapture()
                do {
                    pinnedDeviceID = try candidate.activate(micUID: micDevice.uid)
                    capture = candidate
                    description = "\(micDevice.name) + system audio"
                } catch {
                    // Degrade to mic-only (permission denied, older OS, …).
                    NSLog("[AudioRecorder] System audio unavailable, mic only: \(error)")
                    description = "\(micDevice.name) (mic only)"
                }
            }
            if pinnedDeviceID == nil, let micDevice {
                pinnedDeviceID = AudioObjectID(micDevice.id)
            }
            if let pinnedDeviceID {
                do {
                    try engine.inputNode.auAudioUnit.setDeviceID(pinnedDeviceID)
                } catch {
                    capture?.deactivate()
                    capture = nil
                    NSLog("[AudioRecorder] Couldn't pin input device, using default: \(error)")
                    description = micDevice?.name ?? "Default input"
                }
            }

            do {
                let file = try await Self.installCapture(on: engine, writingTo: segmentURL, format: format,
                                                         live: live, health: health, onTapDead: onTapDead)
                return (engine, file, capture, description)
            } catch {
                capture?.deactivate()
                throw error
            }
        }.value
        #else
        let (engine, file, description) = try await Task.detached(priority: .userInitiated) {
            () async throws -> (AVAudioEngine, AVAudioFile, String) in
            let engine = AVAudioEngine()
            let file = try await Self.installCapture(on: engine, writingTo: segmentURL, format: format,
                                                     live: live, health: health, onTapDead: onTapDead)
            return (engine, file, "Microphone")
        }.value
        #endif

        // If a stop raced the rebuild, tear the fresh chain right back down.
        if segmentIndex > 0 && !isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            #if os(macOS)
            capture?.deactivate()
            #endif
            try? FileManager.default.removeItem(at: segmentURL)
            return
        }

        audioEngine = engine
        audioFile = file
        #if os(macOS)
        systemCapture = capture
        #endif
        tapHealth = health
        inputDescription = description
        segmentURLs.append(segmentURL)
        lastObservedLength = 0
        lastGrowthDate = Date()
        installConfigObserver(for: engine)
        NSLog("[AudioRecorder] Capture segment \(segmentIndex) started (\(description))")
    }

    /// Everything that runs against the live audio hardware: mono capture file
    /// + downmix tap + engine start + first-write probe. The tap does pure
    /// float arithmetic only — never an AVAudioConverter (historic crash).
    private static func installCapture(on engine: AVAudioEngine, writingTo url: URL,
                                       format: RecordingFormat, live: LiveTranscriber?,
                                       health: TapHealth, onTapDead: @escaping @Sendable () -> Void)
        async throws -> AVAudioFile {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioRecorder] Input format: \(inputFormat)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "input device reports an unusable format (\(inputFormat))"])
        }

        // The file is always mono: multi-channel input (stereo interfaces, the
        // mic+system-audio aggregate) is summed in the tap. processingFormat
        // is pinned via commonFormat: so AAC encoding happens inside
        // AVAudioFile, not in the tap.
        var settings = format.fileSettings(for: inputFormat)
        settings[AVNumberOfChannelsKey] = 1
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 16_384) else {
            throw NSError(domain: "AudioRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "couldn't allocate the capture buffer"])
        }

        var firstWriteError: Error? = nil
        var didAttemptFirstWrite = false
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let source = buffer.floatChannelData else { return }
            let frames = Int(min(buffer.frameLength, monoBuffer.frameCapacity))
            guard frames > 0 else { return }
            monoBuffer.frameLength = AVAudioFrameCount(frames)
            let out = monoBuffer.floatChannelData![0]
            let channels = Int(buffer.format.channelCount)
            // Sum all channels at unity gain (each voice lives in one channel),
            // then hard-clamp. Pure arithmetic — safe on the render thread.
            out.update(from: source[0], count: frames)
            for channel in 1..<channels {
                let data = source[channel]
                for i in 0..<frames { out[i] += data[i] }
            }
            if channels > 1 {
                for i in 0..<frames { out[i] = max(-1.0, min(1.0, out[i])) }
            }

            do {
                try file.write(from: monoBuffer)
                _ = health.record(writeSucceeded: true)
            } catch {
                if !didAttemptFirstWrite { firstWriteError = error }
                if health.record(writeSucceeded: false) { onTapDead() }
            }
            didAttemptFirstWrite = true
            live?.feed(buffer)
        }

        engine.prepare()
        try engine.start()

        // Give the tap a moment to deliver the first buffer so a broken
        // write path surfaces immediately instead of producing a 4KB file.
        try await Task.sleep(for: .milliseconds(300))
        if let error = firstWriteError {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        return file
    }

    // MARK: - Capture interruption / recovery

    private func installConfigObserver(for engine: AVAudioEngine) {
        removeConfigObserver()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCaptureFailure(reason: "the audio device changed")
            }
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// The input device changed while recording (AirPods on/off, default
    /// switched, …) — called by the device store in Automatic mode and by the
    /// selector UI.
    @MainActor
    func captureInputChanged() {
        handleCaptureFailure(reason: "the input device changed")
    }

    /// Finalize the current segment and rebuild the capture chain. On repeated
    /// failure, stop and SAVE what was captured — never lose audio silently.
    @MainActor
    private func handleCaptureFailure(reason: String) {
        guard isRecording, !isRebuildingCapture else { return }
        isRebuildingCapture = true
        NSLog("[AudioRecorder] Capture interrupted (\(reason)) — rotating segment")
        finalizeCurrentSegmentChain()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                guard self.isRecording else { break }
                do {
                    try await self.beginCaptureSegment()
                    self.isRebuildingCapture = false
                    return
                } catch {
                    NSLog("[AudioRecorder] Capture rebuild attempt \(attempt) failed: \(error)")
                    try? await Task.sleep(for: .milliseconds(700 * attempt))
                }
            }
            self.isRebuildingCapture = false
            guard self.isRecording else { return }
            NSLog("[AudioRecorder] Capture could not be rebuilt — saving what was recorded")
            self.stopRecording()
            self.errorMessage = "Recording stopped and saved: \(reason), and the microphone couldn't be reopened."
        }
    }

    /// Tears down engine/tap/aggregate and finalizes the open segment file.
    @MainActor
    private func finalizeCurrentSegmentChain() {
        removeConfigObserver()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioFile = nil   // releases the writer → container finalized
        tapHealth = nil
        #if os(macOS)
        systemCapture?.deactivate()
        systemCapture = nil
        #endif
    }

    @MainActor
    @discardableResult
    func stopRecording() -> Recording? {
        guard isRecording, let baseURL = currentRecordingURL else { return nil }
        isRecording = false   // watchdog/config handlers become no-ops first

        var writtenFrames: AVAudioFramePosition = 0
        var sampleRate: Double = 0
        if let file = audioFile {
            writtenFrames = file.length
            sampleRate = file.processingFormat.sampleRate
        }
        finalizeCurrentSegmentChain()

        stopTimer()
        sleepGuard = nil
        liveTranscriber?.stop()
        #if os(iOS)
        AudioSessionController.shared.endRecordingSession()
        #endif

        let wallClock = recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let date = recordingStartDate ?? Date()
        recordingStartDate = nil
        currentRecordingURL = nil
        inputDescription = ""

        let segments = segmentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSLog("[AudioRecorder] Stopping: \(segmentURLs.count) segment(s), \(segments.count) on disk")
        segmentURLs = []
        guard !segments.isEmpty else {
            NSLog("[AudioRecorder] Nothing captured — no recording saved")
            store?.activeRecordingURL = nil
            return nil
        }

        if segments.count == 1 {
            // Fast path: uninterrupted recording — one segment becomes the file.
            do {
                try? FileManager.default.removeItem(at: baseURL)
                try FileManager.default.moveItem(at: segments[0], to: baseURL)
            } catch {
                NSLog("[AudioRecorder] Finalize move failed: \(error)")
                errorMessage = "Couldn't finalize the recording file: \(error.localizedDescription)"
                store?.activeRecordingURL = nil
                return nil
            }
            // Authoritative duration = frames actually written; wall-clock fallback.
            let fileDuration = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
            let duration = fileDuration > 0 ? fileDuration : wallClock
            store?.activeRecordingURL = nil
            let finalURL = store?.finalizeRecordingFile(at: baseURL) ?? baseURL
            let recording = Recording(fileURL: finalURL, date: date, duration: duration)
            store?.insert(recording)
            return recording
        }

        // Interrupted recording: stitch the segments offline (device changes
        // can leave them at different sample rates), then insert. Heavy — off
        // the main thread; the UI shows "Saving…" via isFinalizingRecording.
        isFinalizingRecording = true
        let format = activeFormat
        NSLog("[AudioRecorder] Stitching \(segments.count) segments…")
        Task { @MainActor [weak self] in
            defer { self?.isFinalizingRecording = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AudioCompressor.concatenateSync(segments: segments, to: baseURL, as: format)
                }.value
                for segment in segments {
                    try? FileManager.default.removeItem(at: segment)
                }
                guard let self else { return }
                let duration = RecordingStore.audioDuration(for: baseURL)
                self.store?.activeRecordingURL = nil
                let finalURL = self.store?.finalizeRecordingFile(at: baseURL) ?? baseURL
                let recording = Recording(fileURL: finalURL, date: date,
                                          duration: duration > 0 ? duration : wallClock)
                self.store?.insert(recording)
                NSLog("[AudioRecorder] Stitched \(segments.count) segments into \(finalURL.lastPathComponent)")
            } catch {
                // Keep the segments (the spool sweep will adopt them at next
                // launch) — never delete unsaved audio on a failed stitch.
                NSLog("[AudioRecorder] Stitch failed: \(error)")
                self?.store?.activeRecordingURL = nil
                self?.errorMessage = "Couldn't merge the recording's segments: \(error.localizedDescription). The raw segments were kept and will appear in the library after a relaunch."
            }
        }
        return nil
    }

    // MARK: - Playback

    func playRecording(_ recording: Recording) {
        if isPlaying, playingRecordingID == recording.id {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            #if os(iOS)
            try AudioSessionController.shared.activatePlayback()
            #endif
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.rate = playbackRate
            audioPlayer?.play()
            isPlaying = true
            playingRecordingID = recording.id
            startPlaybackTimer()
        } catch {
            errorMessage = "Failed to play recording: \(error.localizedDescription)"
        }
    }

    func seekAndPlay(to time: TimeInterval, recording: Recording) {
        if isPlaying, playingRecordingID == recording.id, let player = audioPlayer {
            player.currentTime = time
            playbackTime = time
            return
        }
        stopPlayback()
        do {
            #if os(iOS)
            try AudioSessionController.shared.activatePlayback()
            #endif
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.rate = playbackRate
            audioPlayer?.currentTime = time
            audioPlayer?.play()
            isPlaying = true
            playingRecordingID = recording.id
            playbackTime = time
            startPlaybackTimer()
        } catch {
            errorMessage = "Failed to play recording: \(error.localizedDescription)"
        }
    }

    /// Seek without changing play/pause state (used by the scrubber).
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = time
        playbackTime = time
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        UserDefaults.standard.set(Double(rate), forKey: "playbackRate")
        audioPlayer?.rate = rate
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingRecordingID = nil
        stopPlaybackTimer()
        playbackTime = 0.0
    }

    // MARK: - Private

    /// WAV's 32-bit size header caps files at 4 GB; stop safely before that.
    private static let maxRecordingBytes: Int64 = 3_900_000_000

    private func startTimer() {
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartDate else { return }
            // Wall-clock, not accumulation — immune to timer drift on long recordings.
            self.recordingDuration = Date().timeIntervalSince(start)

            // Watchdog (1 Hz): catches capture death the config-change
            // notification missed — a stopped engine, or a running engine
            // whose tap stopped delivering (no frame growth for 8 s).
            tick += 1
            if tick % 10 == 0, self.isRecording, !self.isRebuildingCapture {
                if let engine = self.audioEngine, !engine.isRunning {
                    Task { @MainActor [weak self] in
                        self?.handleCaptureFailure(reason: "the audio engine stopped")
                    }
                } else if let file = self.audioFile {
                    if file.length > self.lastObservedLength {
                        self.lastObservedLength = file.length
                        self.lastGrowthDate = Date()
                    } else if Date().timeIntervalSince(self.lastGrowthDate) > 8 {
                        self.lastGrowthDate = Date()   // don't re-fire while rebuilding
                        Task { @MainActor [weak self] in
                            self?.handleCaptureFailure(reason: "no audio was arriving from the input")
                        }
                    }
                }
            }

            // WAV's 32-bit header caps files at 4 GB — check every ~10s.
            // Compressed (m4a) recordings have no such limit.
            if tick % 100 == 0, let file = self.audioFile,
               file.url.pathExtension.lowercased() == "wav" {
                let bytesPerFrame = Int64(file.fileFormat.streamDescription.pointee.mBytesPerFrame)
                let approximateBytes = Int64(file.length) * max(1, bytesPerFrame)
                if approximateBytes > Self.maxRecordingBytes {
                    Task { @MainActor in
                        self.stopRecording()
                        self.errorMessage = "Recording stopped automatically: the WAV format's 4 GB limit was reached. The recording so far has been saved. Tip: switch to compressed recording in Settings → Storage to avoid this limit."
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer, player.isPlaying else { return }
            self.playbackTime = player.currentTime
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playingRecordingID = nil
        stopPlaybackTimer()
        playbackTime = 0.0
    }
}
