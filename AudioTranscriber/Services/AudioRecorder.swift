import AVFoundation
import Foundation
import Observation
#if os(macOS)
import CoreAudio
#endif

@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    private(set) var isPaused = false
    private(set) var isStartingRecording = false
    private(set) var isFinalizingRecording = false
    var isPlaying = false
    var playingRecordingID: UUID?
    var recordingDuration: TimeInterval = 0
    var playbackTime: Double = 0
    var playbackRate: Float = Float(UserDefaults.standard.object(forKey: "playbackRate") as? Double ?? 1)
    var errorMessage: String?
    private(set) var inputDescription = ""
    var pendingCheckIn: CheckInPrompt?
    var recordingToReview: Recording?
    struct CheckInPrompt: Identifiable, Equatable {
        enum Reason: Equatable { case duration, silence }
        let id = UUID()
        let elapsed: TimeInterval
        var reason: Reason = .duration
    }
    private weak var store: RecordingStore?
    var liveTranscriber: LiveTranscriber?
    #if os(macOS)
    weak var inputDeviceStore: AudioInputDeviceStore?
    private var systemCapture: SystemAudioCapture?
    #endif
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVPlayer?
    private var playbackStatusObserver: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackTimer: Timer?
    private var timer: Timer?
    private var writer: ContinuousRecordingWriter?
    private var recordingClock = RecordingClock()
    private var recordingStartDate: Date?
    private var sleepGuard: SleepGuard?
    private var configObserver: NSObjectProtocol?
    private var isRebuildingCapture = false
    private var pendingInputChange = false
    private var isRebuildingSystemAudio = false
    private var captureGeneration = UUID()
    private var levelMonitor: RecordingLevelMonitor?
    private var microphoneMonitor: RecordingLevelMonitor?
    private var lastMicrophoneBufferCount = 0
    private var lastMicrophoneGrowth = ProcessInfo.processInfo.systemUptime
    private var checkIn = LongRecordingCheckIn()
    private var guardrailConfig = SilenceDetector.Config.default
    private var silenceRecoveryAttempts = 0
    private var recoveryBaselineSoundTime: TimeInterval = 0
    private(set) var segmentCount = 0
    private var activeFormat = RecordingFormat.aacHigh
    var silenceConfigOverride: SilenceDetector.Config?
    var checkInIntervalOverride: TimeInterval?
    var silenceWarningIntervalOverride: TimeInterval?
    var recordSystemAudioPreference: Bool {
        get { UserDefaults.standard.object(forKey: "recordSystemAudio") == nil ? true : UserDefaults.standard.bool(forKey: "recordSystemAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "recordSystemAudio") }
    }
    var silenceDuration: TimeInterval { levelMonitor?.silenceDuration() ?? 0 }

    @MainActor func attach(store: RecordingStore) {
        self.store = store
        #if os(iOS)
        AudioSessionController.shared.onRecordingInterrupted = { [weak self] reason in
            guard let self, self.isRecording else { return }
            self.pauseRecording()
            self.errorMessage = "Recording paused: \(reason). Resume when ready; the audio is preserved."
        }
        AudioSessionController.shared.onPlaybackInterrupted = { [weak self] in self?.stopPlayback() }
        #endif
    }
    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            if !granted { DispatchQueue.main.async { self?.errorMessage = "Enable microphone access in System Settings → Privacy & Security → Microphone." } }
        }
    }

    @MainActor func startRecording() {
        guard !isRecording, !isStartingRecording, !isFinalizingRecording, let store else { return }
        isStartingRecording = true
        stopPlayback()
        captureGeneration = UUID()
        let generation = captureGeneration
        activeFormat = RecordingFormat.selected
        guardrailConfig = silenceConfigOverride ?? .fromDefaults()
        let monitor = RecordingLevelMonitor(config: guardrailConfig)
        levelMonitor = monitor
        checkIn = checkInIntervalOverride.map { LongRecordingCheckIn(interval: $0) } ?? .fromDefaults()
        silenceRecoveryAttempts = 0
        pendingCheckIn = nil; recordingToReview = nil; segmentCount = 0
        recordingDuration = 0
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = SpoolLocation.url(fileName: "recording_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).caf")
        store.activeRecordingURL = url
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStartingRecording = false }
            do {
                #if os(iOS)
                try AudioSessionController.shared.activateRecording()
                #endif
                let live = self.liveTranscriber
                let writer = try ContinuousRecordingWriter(url: url, monitor: monitor,
                    preview: { buffer in live?.feed(buffer) }, onError: { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.writer?.url == url else { return }
                            self.pauseRecording(); self.errorMessage = message
                        }
                    })
                self.writer = writer
                self.recordingStartDate = Date()
                self.recordingClock.start(at: ProcessInfo.processInfo.systemUptime)
                #if os(macOS)
                if self.recordSystemAudioPreference {
                    let capture = try await AudioCaptureStartup.runAsync {
                        let capture = SystemAudioCapture(); try await capture.activate(writer: writer); return capture
                    } discard: { $0.deactivate() }
                    guard self.captureGeneration == generation else { capture.deactivate(); return }
                    self.systemCapture = capture
                }
                #endif
                try await self.beginMicrophoneWithRetries(generation: generation)
                guard self.captureGeneration == generation else { return }
                self.levelMonitor?.captureRestarted()
                self.isRecording = true; self.isPaused = false
                self.sleepGuard = SleepGuard(reason: "Recording audio")
                self.startTimer(); self.liveTranscriber?.start()
                RecordingNotifier.shared.requestAuthorizationIfNeeded()
            } catch {
                self.teardownMicrophone()
                #if os(macOS)
                self.systemCapture?.deactivate(); self.systemCapture = nil
                #endif
                _ = try? self.writer?.finish(); self.writer = nil
                store.activeRecordingURL = nil
                self.errorMessage = "Recording could not start: \(error.localizedDescription)"
            }
        }
    }

    @MainActor private func beginMicrophoneWithRetries(generation: UUID) async throws {
        var lastError: Error = RecordingWriterError.unsupportedFormat
        for attempt in 1...3 {
            do { try await beginMicrophone(generation: generation); return }
            catch is CancellationError { throw CancellationError() }
            catch { lastError = error; if attempt < 3 { try await Task.sleep(for: .milliseconds(300 * attempt)) } }
        }
        throw lastError
    }

    @MainActor private func beginMicrophone(generation: UUID) async throws {
        guard let writer else { throw RecordingWriterError.unsupportedFormat }
        let monitor = RecordingLevelMonitor()
        #if os(macOS)
        let device = inputDeviceStore?.effectiveDevice
        #endif
        let engine = try await AudioCaptureStartup.run {
            let engine = AVAudioEngine()
            #if os(macOS)
            if let device { try engine.inputNode.auAudioUnit.setDeviceID(AudioObjectID(device.id)) }
            #endif
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingWriterError.unsupportedFormat }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                monitor.observe(buffer: buffer)
                writer.submit(buffer, source: 0, hostTime: time.isHostTimeValid ? time.hostTime : 0)
            }
            do {
                engine.prepare(); try engine.start()
                return engine
            } catch { engine.inputNode.removeTap(onBus: 0); engine.stop(); throw error }
        } discard: { engine in engine.inputNode.removeTap(onBus: 0); engine.stop() }
        try await Task.sleep(for: .milliseconds(300))
        guard monitor.bufferCount > 0 else {
            engine.inputNode.removeTap(onBus: 0); engine.stop(); throw RecordingWriterError.unsupportedFormat
        }
        guard captureGeneration == generation, !isPaused else {
            engine.inputNode.removeTap(onBus: 0); engine.stop(); throw CancellationError()
        }
        audioEngine = engine; microphoneMonitor = monitor
        lastMicrophoneBufferCount = 0; lastMicrophoneGrowth = ProcessInfo.processInfo.systemUptime
        segmentCount += 1
        #if os(macOS)
        inputDescription = "\(device?.name ?? "Microphone")\(systemCapture == nil ? "" : " + system audio")"
        #else
        inputDescription = "Microphone"
        #endif
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.captureInputChanged() }
            }
    }

    @MainActor private func teardownMicrophone() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        audioEngine?.inputNode.removeTap(onBus: 0); audioEngine?.stop(); audioEngine = nil
    }

    @MainActor func captureInputChanged() {
        if isRebuildingCapture { pendingInputChange = true; return }
        recoverMicrophone(resetSilenceClock: false)
    }
    @MainActor private func recoverMicrophone(resetSilenceClock: Bool) {
        guard isRecording, !isPaused, !isRebuildingCapture else { return }
        isRebuildingCapture = true
        teardownMicrophone()
        let generation = captureGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRebuildingCapture = false
                if self.pendingInputChange {
                    self.pendingInputChange = false; self.captureInputChanged()
                }
            }
            do {
                try await self.beginMicrophoneWithRetries(generation: generation)
                self.levelMonitor?.captureRestarted(resetSilenceClock: resetSilenceClock)
            } catch {
                guard self.captureGeneration == generation, self.isRecording else { return }
                self.pauseRecording()
                self.errorMessage = "Recording paused because the microphone could not be reopened. All captured audio is preserved. \(error.localizedDescription)"
            }
        }
    }

    #if os(macOS)
    @MainActor private func recoverSystemAudio() {
        guard isRecording, !isPaused, !isRebuildingSystemAudio, let writer else { return }
        isRebuildingSystemAudio = true
        let generation = captureGeneration
        systemCapture?.deactivate(); systemCapture = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRebuildingSystemAudio = false }
            for attempt in 1...3 {
                guard self.captureGeneration == generation, !self.isPaused else { return }
                do {
                    let capture = try await AudioCaptureStartup.runAsync {
                        let capture = SystemAudioCapture(); try await capture.activate(writer: writer); return capture
                    } discard: { $0.deactivate() }
                    guard self.captureGeneration == generation, !self.isPaused else { capture.deactivate(); return }
                    self.systemCapture = capture
                    return
                } catch { try? await Task.sleep(for: .milliseconds(attempt * 300)) }
            }
            self.pauseRecording()
            self.errorMessage = "Recording paused because system audio could not be reconnected. All captured audio is preserved. Check Screen & System Audio Recording permission, then resume."
        }
    }
    #endif

    @MainActor func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        captureGeneration = UUID()
        recordingClock.pause(at: ProcessInfo.processInfo.systemUptime)
        recordingDuration = recordingClock.elapsed(at: ProcessInfo.processInfo.systemUptime).rounded(.down)
        teardownMicrophone()
        #if os(macOS)
        systemCapture?.deactivate(); systemCapture = nil
        #endif
        writer?.pause(); liveTranscriber?.stop(); sleepGuard = nil
        pendingCheckIn = nil; RecordingNotifier.shared.clearCheckIn()
    }

    @MainActor func resumeRecording() {
        guard isRecording, isPaused, !isStartingRecording, let writer else { return }
        isStartingRecording = true
        let generation = captureGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStartingRecording = false }
            do {
                #if os(iOS)
                try AudioSessionController.shared.activateRecording()
                #endif
                self.isPaused = false
                writer.resume(); self.recordingClock.resume(at: ProcessInfo.processInfo.systemUptime)
                #if os(macOS)
                if self.recordSystemAudioPreference {
                    let capture = try await AudioCaptureStartup.runAsync {
                        let capture = SystemAudioCapture(); try await capture.activate(writer: writer); return capture
                    } discard: { $0.deactivate() }
                    guard self.captureGeneration == generation else { capture.deactivate(); return }
                    self.systemCapture = capture
                }
                #endif
                try await self.beginMicrophoneWithRetries(generation: generation)
                guard self.captureGeneration == generation else { return }
                self.levelMonitor?.captureRestarted(); self.silenceRecoveryAttempts = 0
                self.sleepGuard = SleepGuard(reason: "Recording audio"); self.liveTranscriber?.start()
            } catch {
                guard self.captureGeneration == generation else { return }
                self.pauseRecording(); self.errorMessage = "Could not resume: \(error.localizedDescription)" }
        }
    }

    @MainActor @discardableResult func stopRecording(review: Bool = false) -> Recording? {
        guard isRecording, let writer, let store else { return nil }
        isRecording = false; isPaused = false; captureGeneration = UUID()
        teardownMicrophone()
        #if os(macOS)
        systemCapture?.deactivate(); systemCapture = nil
        #else
        AudioSessionController.shared.endRecordingSession()
        #endif
        timer?.invalidate(); timer = nil
        liveTranscriber?.stop(); sleepGuard = nil
        pendingCheckIn = nil; RecordingNotifier.shared.clearCheckIn()
        let date = recordingStartDate ?? Date()
        do { recordingDuration = try writer.finish() }
        catch { errorMessage = "The recording is preserved, but could not finish saving: \(error.localizedDescription)" }
        self.writer = nil
        let source = writer.url
        let format = activeFormat
        let destination = source.deletingPathExtension().appendingPathExtension(format.fileExtension)
        isFinalizingRecording = true
        Task { @MainActor [weak self, writer] in
            guard let self else { return }
            defer { self.isFinalizingRecording = false; store.activeRecordingURL = nil; _ = writer }
            var finalSource = source
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AudioCompressor.concatenateSync(segments: [source], to: destination, as: format)
                    let before = RecordingStore.audioDuration(for: source)
                    let after = RecordingStore.audioDuration(for: destination)
                    guard before > 0, abs(after - before) <= max(0.15, before * 0.0001) else {
                        throw NSError(domain: "Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "The saved duration did not match the captured audio."])
                    }
                }.value
                finalSource = destination
            } catch {
                self.errorMessage = "The full recording was saved in recoverable CAF format because compression failed: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: destination)
            }
            let finalURL = store.finalizeRecordingFile(at: finalSource)
            let recording = Recording(fileURL: finalURL, date: date, duration: RecordingStore.audioDuration(for: finalURL))
            store.insert(recording, notify: !review)
            if finalSource != source { try? FileManager.default.removeItem(at: source) }
            if review { self.recordingToReview = recording }
        }
        return nil
    }

    @MainActor private func evaluateGuardrails() {
        guard isRecording, !isPaused, let monitor = levelMonitor else { return }
        let silence = monitor.silenceDuration()
        if monitor.lastSoundTime > recoveryBaselineSoundTime { silenceRecoveryAttempts = 0 }
        if monitor.shouldAutoStop() {
            pauseRecording()
            let message = "Recording paused after \(Int(silence / 60)) minutes without sound. Resume or stop and save when ready."
            errorMessage = message; RecordingNotifier.shared.postAutoStopped(message: message)
            return
        }
        let warning = silenceWarningIntervalOverride ?? 15 * 60
        if silence >= warning, pendingCheckIn?.reason != .silence {
            pendingCheckIn = CheckInPrompt(elapsed: recordingDuration, reason: .silence)
            RecordingNotifier.shared.postCheckIn(elapsed: recordingDuration, silence: silence)
        } else if pendingCheckIn == nil, checkIn.isDue(at: recordingDuration) {
            pendingCheckIn = CheckInPrompt(elapsed: recordingDuration)
            RecordingNotifier.shared.postCheckIn(elapsed: recordingDuration)
        }
        if pendingCheckIn?.reason == .silence, silence < warning {
            pendingCheckIn = nil; RecordingNotifier.shared.clearCheckIn()
        }
        if guardrailConfig.silenceRecoveryDelay > 0, !isRebuildingCapture,
           silenceRecoveryAttempts < guardrailConfig.maxSilenceRecoveryAttempts,
           silence >= guardrailConfig.silenceRecoveryDelay * Double(silenceRecoveryAttempts + 1) {
            silenceRecoveryAttempts += 1; recoveryBaselineSoundTime = monitor.lastSoundTime
            recoverMicrophone(resetSilenceClock: false)
        }
    }
    @MainActor func acknowledgeCheckIn() {
        if pendingCheckIn?.reason == .silence {
            // An explicit response grants another full 30 minutes. New sound
            // resets the detector independently; a duration check-in never does.
            levelMonitor?.captureRestarted()
        }
        pendingCheckIn = nil
        checkIn.acknowledged(at: recordingDuration); RecordingNotifier.shared.clearCheckIn()
    }
    @MainActor func stopRecordingFromCheckIn() { stopRecording(review: true) }
    @MainActor func finishReview() {
        if let recordingToReview { store?.onRecordingAdded?(recordingToReview.id) }
        recordingToReview = nil
    }
    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let duration = self.recordingClock.elapsed(at: now).rounded(.down)
            guard duration != self.recordingDuration else { return }
            self.recordingDuration = duration
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isPaused else { return }
                if let monitor = self.microphoneMonitor {
                    if monitor.bufferCount != self.lastMicrophoneBufferCount {
                        self.lastMicrophoneBufferCount = monitor.bufferCount; self.lastMicrophoneGrowth = now
                    } else if now - self.lastMicrophoneGrowth > 3 { self.captureInputChanged() }
                }
                #if os(macOS)
                if self.systemCapture?.needsRecovery == true {
                    self.recoverSystemAudio()
                }
                #endif
                self.evaluateGuardrails()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    // MARK: - Streamed playback

    func playRecording(_ recording: Recording) {
        if isPlaying, playingRecordingID == recording.id { stopPlayback(); return }
        seekAndPlay(to: 0, recording: recording)
    }

    func seekAndPlay(to time: TimeInterval, recording: Recording) {
        guard time.isFinite else { return }
        if playingRecordingID == recording.id, audioPlayer != nil {
            seek(to: time); audioPlayer?.playImmediately(atRate: playbackRate); isPlaying = true; return
        }
        guard !CloudPlaceholder.isPlaceholderOnly(recording.fileURL) else {
            CloudPlaceholder.requestDownload(recording.fileURL)
            errorMessage = "Downloading “\(recording.displayName)” from iCloud. Try playback when the download finishes."
            return
        }
        stopPlayback()
        #if os(iOS)
        do { try AudioSessionController.shared.activatePlayback() }
        catch { errorMessage = error.localizedDescription; return }
        #endif
        // AVPlayer reads/decompresses on demand; opening an eight-hour file
        // never copies the whole recording into memory on the main thread.
        let item = AVPlayerItem(url: recording.fileURL)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        audioPlayer = player; playingRecordingID = recording.id; isPlaying = true
        playbackStatusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            guard let item, item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "Audio could not be opened."
            DispatchQueue.main.async {
                guard self?.audioPlayer?.currentItem === item else { return }
                self?.stopPlayback(); self?.errorMessage = message
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in self?.stopPlayback() }
        seek(to: time)
        player.playImmediately(atRate: playbackRate)
        startPlaybackTimer()
    }
    func seek(to time: TimeInterval) {
        guard time.isFinite, let player = audioPlayer else { return }
        let target = max(0, time)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = target
    }
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate; UserDefaults.standard.set(Double(rate), forKey: "playbackRate")
        if isPlaying { audioPlayer?.rate = rate }
    }
    func stopPlayback() {
        audioPlayer?.pause(); audioPlayer = nil
        playbackStatusObserver = nil
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
        isPlaying = false; playingRecordingID = nil; playbackTime = 0
        stopPlaybackTimer()
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer, player.timeControlStatus == .playing else { return }
            let time = player.currentTime().seconds
            if time.isFinite { self.playbackTime = time }
        }
        RunLoop.main.add(timer, forMode: .common); playbackTimer = timer
    }
    private func stopPlaybackTimer() { playbackTimer?.invalidate(); playbackTimer = nil }
}
