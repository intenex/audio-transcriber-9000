import AppKit
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

        let filename = "recording_\(dateString()).wav"
        let url = store.storageDirectory.appendingPathComponent(filename)
        currentRecordingURL = url
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

                // Write 16-bit PCM (half the size of Float32) while keeping the tap
                // in the native input format. The AVAudioFile's processingFormat is
                // pinned to the tap format via commonFormat:, so ExtAudioFile performs
                // the Float32→Int16 conversion internally — no AVAudioConverter in the
                // tap callback (which historically crashed).
                let file: AVAudioFile
                if inputFormat.commonFormat == .pcmFormatFloat32 {
                    var settings = inputFormat.settings
                    settings[AVFormatIDKey] = kAudioFormatLinearPCM
                    settings[AVLinearPCMBitDepthKey] = 16
                    settings[AVLinearPCMIsFloatKey] = false
                    settings[AVLinearPCMIsBigEndianKey] = false
                    settings[AVLinearPCMIsNonInterleaved] = false
                    file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false)
                } else {
                    // Unexpected tap format — fall back to writing the native format.
                    file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
                }

                var firstWriteError: Error? = nil
                var didAttemptFirstWrite = false
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    do {
                        try file.write(from: buffer)
                    } catch {
                        if !didAttemptFirstWrite { firstWriteError = error }
                    }
                    didAttemptFirstWrite = true
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
            NSLog("[AudioRecorder] Recording state updated")
        } catch {
            NSLog("[AudioRecorder] Failed: \(error)")
            self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
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

        // Authoritative duration = frames actually written; wall-clock as fallback.
        let fileDuration = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
        let wallClock = recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let duration = fileDuration > 0 ? fileDuration : wallClock
        let date = recordingStartDate ?? Date()
        let recording = Recording(fileURL: url, date: date, duration: duration)

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

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartDate else { return }
            // Wall-clock, not accumulation — immune to timer drift on long recordings.
            self.recordingDuration = Date().timeIntervalSince(start)
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
