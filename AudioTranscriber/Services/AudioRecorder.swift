import AppKit
import AVFoundation
import AVFAudio
import Foundation
import Observation

@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    var isPlaying = false
    var playingRecordingID: UUID? = nil
    var recordingDuration: TimeInterval = 0
    var playbackTime: Double = 0.0
    var recordings: [Recording] = []
    var errorMessage: String? = nil

    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var currentRecordingURL: URL?
    private var recordingStartDate: Date?

    var storageDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "storageDirectory"),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AudioTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Public

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

    func startRecording() {
        guard !isRecording else { return }

        let filename = "recording_\(dateString()).wav"
        let url = storageDirectory.appendingPathComponent(filename)
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

                // Write in the native input format — whisperX resamples automatically.
                // Using a custom format with AVAudioConverter + AVAudioFile causes internal
                // CoreAudio assertion failures (ExtAudioFile::WriteInputProc) when the
                // buffer format doesn't match the file's processingFormat.
                let file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)

                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    try? file.write(from: buffer)
                }

                engine.prepare()
                try engine.start()
                NSLog("[AudioRecorder] AVAudioEngine started on background thread")
                return (engine, file)
            }.value

            // Update state on main thread
            self.audioEngine = engine
            self.audioFile = file
            self.isRecording = true
            self.recordingDuration = 0
            self.recordingStartDate = Date()
            self.startTimer()
            NSLog("[AudioRecorder] Recording state updated")
        } catch {
            NSLog("[AudioRecorder] Failed: \(error)")
            self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func stopRecording() -> Recording? {
        guard isRecording, let url = currentRecordingURL else { return nil }

        // Stop AVAudioEngine-based recording
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            audioFile = nil
        }
        // Stop legacy AVAudioRecorder-based recording
        audioRecorder?.stop()

        stopTimer()
        isRecording = false

        let duration = recordingDuration
        let date = recordingStartDate ?? Date()
        let recording = Recording(fileURL: url, date: date, duration: duration)

        recordings.insert(recording, at: 0)
        saveRecordings()
        return recording
    }

    func playRecording(_ recording: Recording) {
        if isPlaying, playingRecordingID == recording.id {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.delegate = self
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

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingRecordingID = nil
        stopPlaybackTimer()
        playbackTime = 0.0
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        if let markdownURL = recording.transcriptionURL {
            try? FileManager.default.removeItem(at: markdownURL)
        }
        // Delete sidecar files (summary, chat, segments)
        let summaryURL = recording.fileURL.deletingPathExtension().appendingPathExtension("summary.json")
        let chatURL = recording.fileURL.deletingPathExtension().appendingPathExtension("chat.json")
        let segmentsURL = recording.fileURL.deletingPathExtension().appendingPathExtension("segments.json")
        try? FileManager.default.removeItem(at: summaryURL)
        try? FileManager.default.removeItem(at: chatURL)
        try? FileManager.default.removeItem(at: segmentsURL)

        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    func showInFinder(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
    }

    func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .audio, .wav, .mp3, .mpeg4Audio, .aiff,
        ]
        panel.message = "Select audio files to import for transcription"

        guard panel.runModal() == .OK else { return }

        for sourceURL in panel.urls {
            let filename = sourceURL.lastPathComponent
            let destURL = storageDirectory.appendingPathComponent(filename)

            // Avoid overwriting — add suffix if needed
            let finalURL = uniqueURL(for: destURL)

            do {
                try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                let duration = audioDuration(for: finalURL)
                let recording = Recording(fileURL: finalURL, date: Date(), duration: duration)
                recordings.insert(recording, at: 0)
            } catch {
                errorMessage = "Failed to import \(filename): \(error.localizedDescription)"
            }
        }
        saveRecordings()
    }

    func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: "recordings"),
              let saved = try? JSONDecoder().decode([Recording].self, from: data) else {
            return
        }
        // Filter out recordings whose files no longer exist
        recordings = saved.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    // MARK: - Private

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingDuration += 0.1
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

    func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: "recordings")
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem)_\(counter).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func audioDuration(for url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playingRecordingID = nil
        stopPlaybackTimer()
        playbackTime = 0.0
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            errorMessage = "Recording finished unsuccessfully."
            isRecording = false
            stopTimer()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        errorMessage = "Recording encode error: \(error?.localizedDescription ?? "unknown")"
        isRecording = false
        stopTimer()
    }
}
