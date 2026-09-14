#if os(macOS)
import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKit supplies the application mix independently of the selected
/// speaker/headphone device. Only an audio output is registered: screen frames
/// are neither delivered to this app nor stored in the recording.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: ContinuousRecordingWriter?
    private let queue = DispatchQueue(label: "AudioTranscriber.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var interrupted = false
    var needsRecovery: Bool { lock.lock(); defer { lock.unlock() }; return interrupted }
    static let isSupported = true // Audio capture is available on every supported Mac (14+).

    func activate(writer: ContinuousRecordingWriter) async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard let display = content.displays.first else {
                throw NSError(domain: "SystemAudioCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Connect a display to start system audio capture."])
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(seconds: 60, preferredTimescale: 1)
            config.queueDepth = 3; config.showsCursor = false
            config.capturesAudio = true; config.sampleRate = 48_000; config.channelCount = 2
            config.excludesCurrentProcessAudio = false
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream
            queue.sync { self.writer = writer }
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            deactivate()
            if error is CancellationError { throw error }
            throw NSError(domain: "SystemAudioCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "System audio could not start. Enable Audio Transcriber 9000 in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. \(error.localizedDescription)"])
        }
    }

    func deactivate() {
        let previous = stream; stream = nil
        queue.sync { self.writer = nil }
        previous?.stopCapture(completionHandler: { _ in })
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); interrupted = true; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let writer, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = sampleBuffer.numSamples
        guard count > 0, count <= 65_536,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
            frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        let seconds = sampleBuffer.presentationTimeStamp.seconds
        writer.submit(pcm, source: 1,
                      hostTime: seconds.isFinite && seconds > 0 ? AVAudioTime.hostTime(forSeconds: seconds) : 0)
    }
}
#endif
