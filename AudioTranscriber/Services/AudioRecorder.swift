import AVFoundation
import AVFAudio
import Foundation
import Observation

/// Records audio via AVAudioEngine and plays recordings back. Library state
/// (the recordings list, import, delete, persistence) lives in RecordingStore.
@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    var isPlaying = false
    var playingRecordingID: UUID? = nil
    var recordingDuration: TimeInterval = 0
    var playbackTime: Double = 0.0
    var playbackRate: Float = Float(UserDefaults.standard.object(forKey: "playbackRate") as? Double ?? 1.0)
    var errorMessage: String? = nil

    private weak var store: RecordingStore?
    /// Live transcript preview sink (optional; fed from the tap callback).
    var liveTranscriber: LiveTranscriber? = nil
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var currentRecordingURL: URL?
    private var recordingStartDate: Date?
    private var sleepGuard: SleepGuard? = nil

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

        let format = RecordingFormat.selected
        let filename = "recording_\(dateString()).\(format.fileExtension)"
        // Record into the device-local spool; the file moves into the library
        // only after the container is finalized at stop (sync safety).
        let url = SpoolLocation.url(fileName: filename)
        currentRecordingURL = url
        store.activeRecordingURL = url
        NSLog("[AudioRecorder] Starting recording to: \(url.path)")

        // Use a detached task to avoid blocking the main thread.
        // AVAudioEngine.inputNode triggers a TCC check via coreaudiod that deadlocks
        // if called synchronously on the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.initAndStartEngine(url: url)
        }
    }

    @MainActor
    private func initAndStartEngine(url: URL) async {
        NSLog("[AudioRecorder] initAndStartEngine called")
        do {
            // Run blocking audio hardware init off the main thread
            let (engine, file) = try await Task.detached(priority: .userInitiated) {
                NSLog("[AudioRecorder] Creating AVAudioEngine on background thread...")
                let engine = AVAudioEngine()
                let inputNode = engine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                NSLog("[AudioRecorder] Input format: \(inputFormat)")

                // Write compressed AAC (or 16-bit WAV) while keeping the tap in the
                // native input format. The AVAudioFile's processingFormat is pinned
                // to the tap format via commonFormat:, so encoding happens internally
                // — no AVAudioConverter in the tap callback (which historically crashed).
                let format = RecordingFormat.selected
                let file: AVAudioFile
                if inputFormat.commonFormat == .pcmFormatFloat32 {
                    file = try AVAudioFile(forWriting: url,
                                           settings: format.fileSettings(for: inputFormat),
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false)
                } else {
                    // Unexpected tap format — fall back to writing the native format.
                    file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
                }

                var firstWriteError: Error? = nil
                var didAttemptFirstWrite = false
                let live = self.liveTranscriber
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    do {
                        try file.write(from: buffer)
                    } catch {
                        if !didAttemptFirstWrite { firstWriteError = error }
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

                NSLog("[AudioRecorder] AVAudioEngine started on background thread")
                return (engine, file)
            }.value

            // Update state on main thread
            self.audioEngine = engine
            self.audioFile = file
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
        }
    }

    @MainActor
    @discardableResult
    func stopRecording() -> Recording? {
        guard isRecording, let url = currentRecordingURL else { return nil }

        var writtenFrames: AVAudioFramePosition = 0
        var sampleRate: Double = 0
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let file = audioFile {
                writtenFrames = file.length
                sampleRate = file.processingFormat.sampleRate
            }
            audioEngine = nil
            audioFile = nil
        }

        stopTimer()
        isRecording = false
        sleepGuard = nil
        liveTranscriber?.stop()
        #if os(iOS)
        AudioSessionController.shared.endRecordingSession()
        #endif

        // Authoritative duration = frames actually written; wall-clock as fallback.
        let fileDuration = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
        let wallClock = recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let duration = fileDuration > 0 ? fileDuration : wallClock
        let date = recordingStartDate ?? Date()

        // The container is finalized (audioFile released above) — move the
        // completed file from the spool into the library.
        store?.activeRecordingURL = nil
        let finalURL = store?.finalizeRecordingFile(at: url) ?? url
        let recording = Recording(fileURL: finalURL, date: date, duration: duration)

        store?.insert(recording)
        return recording
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

            // WAV's 32-bit header caps files at 4 GB — check every ~10s.
            // Compressed (m4a) recordings have no such limit.
            tick += 1
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
