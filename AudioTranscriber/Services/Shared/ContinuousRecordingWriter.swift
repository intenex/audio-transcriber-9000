import Accelerate
import AVFoundation
import Foundation
import Darwin

/// The clock counts captured time through a pause, and never resets on a prompt.
struct RecordingClock {
    private var started: TimeInterval?
    private var accumulated: TimeInterval = 0
    mutating func start(at time: TimeInterval) { accumulated = 0; started = time }
    mutating func pause(at time: TimeInterval) { accumulated = elapsed(at: time); started = nil }
    mutating func resume(at time: TimeInterval) { guard started == nil else { return }; started = time }
    func elapsed(at time: TimeInterval) -> TimeInterval { accumulated + (started.map { max(0, time - $0) } ?? 0) }
    static func display(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < Double(Int.max) else { return "--:--" }
        let value = Int(max(0, seconds).rounded(.down))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Fixed-capacity timeline: both sources contribute to the same frame range.
/// A missing microphone cannot stall or discard the system-audio source.
struct RecordingTimelineMixer {
    private var samples: [Float]
    private(set) var nextFrame: Int64 = 0
    var capacity: Int { samples.count }
    init(capacity: Int) { samples = .init(repeating: 0, count: max(1, capacity)) }
    mutating func add(_ input: [Float], at start: Int64) throws {
        guard start + Int64(input.count) <= nextFrame + Int64(capacity) else {
            NSLog("[RecordingWriter] timeline overflow: start=%lld count=%d written=%lld capacity=%d", start, input.count, nextFrame, capacity)
            throw RecordingWriterError.overrun
        }
        // A small overlap can come from resampling rounding; a genuinely late
        // callback must be visible rather than quietly replacing it with silence.
        if start >= 0, nextFrame - start > 2_400 { throw RecordingWriterError.lateAudio }
        var offset = Int(min(Int64(input.count), max(0, nextFrame - start)))
        samples.withUnsafeMutableBufferPointer { destination in
            input.withUnsafeBufferPointer { source in
                while offset < input.count {
                    let slot = Int((start + Int64(offset)) % Int64(destination.count))
                    let count = min(input.count - offset, destination.count - slot)
                    vDSP_vadd(destination.baseAddress! + slot, 1, source.baseAddress! + offset, 1,
                              destination.baseAddress! + slot, 1, vDSP_Length(count))
                    offset += count
                }
            }
        }
    }
    mutating func clearPending() { samples = .init(repeating: 0, count: capacity) }
    mutating func take(_ count: Int) -> [Float] {
        precondition(count >= 0 && count <= capacity)
        var result = [Float](repeating: 0, count: count)
        if count > 0 {
            var lower: Float = -1, upper: Float = 1
            let firstFrame = nextFrame
            samples.withUnsafeMutableBufferPointer { source in
                result.withUnsafeMutableBufferPointer { destination in
                    var offset = 0
                    while offset < count {
                        let slot = Int((firstFrame + Int64(offset)) % Int64(source.count))
                        let length = min(count - offset, source.count - slot)
                        vDSP_vclip(source.baseAddress! + slot, 1, &lower, &upper,
                                   destination.baseAddress! + offset, 1, vDSP_Length(length))
                        vDSP_vclr(source.baseAddress! + slot, 1, vDSP_Length(length))
                        offset += length
                    }
                }
            }
        }
        nextFrame += Int64(count)
        return result
    }
}

enum RecordingWriterError: LocalizedError {
    case overrun, lateAudio, diskSpace, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .overrun: return "Audio arrived faster than it could be saved. Recording has been paused; the captured audio is preserved."
        case .lateAudio: return "An audio device fell behind the recording clock. Recording has been paused to prevent further missing audio. Resume when ready."
        case .diskSpace: return "Storage is almost full. Recording has been paused; the captured audio is preserved."
        case .unsupportedFormat: return "The audio device provided an unsupported format."
        }
    }
}

/// CAF permits an unknown-length data chunk (-1). Unlike an open M4A, every
/// complete PCM frame is readable after a process kill, without a final index.
/// 48 kHz / 16 bit mono uses 346 MB/hour, with constant working memory.
final class RecoverablePCMFile {
    private let handle: FileHandle
    private var closed = false
    init(url: URL, sampleRate: Double) throws {
        var header = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "caff".utf8); bytes(UInt16(1)); bytes(UInt16(0))
        header.append(contentsOf: "desc".utf8); bytes(Int64(32))
        bytes(sampleRate.bitPattern)
        header.append(contentsOf: "lpcm".utf8)
        bytes(UInt32(2)) // CAF signed integer, little endian (CAF flags, not ASBD flags).
        bytes(UInt32(2)); bytes(UInt32(1)); bytes(UInt32(1)); bytes(UInt32(16))
        header.append(contentsOf: "data".utf8); bytes(Int64(-1)); bytes(UInt32(0))
        // Publish only after the ownership lock exists. Another store must not
        // mistake the new header for an abandoned recording between create/lock.
        let opening = url.deletingLastPathComponent().appendingPathComponent(".opening-\(UUID())")
        try header.write(to: opening, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: opening) }
        handle = try FileHandle(forWritingTo: opening)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw RecordingWriterError.overrun }
        try handle.seekToEnd()
        try FileManager.default.moveItem(at: opening, to: url)
    }
    static func isLocked(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
    func append(_ samples: [Float]) throws {
        var scale: Float = 32767
        var scaled = [Float](repeating: 0, count: samples.count)
        var pcm = [Int16](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &scale, &scaled, 1, vDSP_Length(samples.count))
        vDSP_vfix16(scaled, 1, &pcm, 1, vDSP_Length(samples.count))
        try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }
    func synchronize() throws { try handle.synchronize() }
    func close() throws {
        guard !closed else { return }
        try handle.synchronize(); try handle.close(); closed = true
    }
    deinit { try? close() }
}

/// Only this serial queue converts, mixes and writes. Capture callbacks copy a
/// bounded buffer, then return; no encoding, file I/O or unbounded Task backlog.
final class ContinuousRecordingWriter: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    let url: URL
    private let queue = DispatchQueue(label: "AudioTranscriber.recording-writer", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 32)
    private let file: RecoverablePCMFile
    private var mixer = RecordingTimelineMixer(capacity: 48_000 * 3)
    private var timer: DispatchSourceTimer?
    private var origin = ProcessInfo.processInfo.systemUptime
    private var paused = false
    private var finished = false
    private var lastSync: TimeInterval = 0
    private var converters: [Int: AVAudioConverter] = [:]
    private var failed = false
    private let monitor: RecordingLevelMonitor
    private let onError: @Sendable (String) -> Void
    private let preview: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    init(url: URL, monitor: RecordingLevelMonitor,
         preview: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
         onError: @escaping @Sendable (String) -> Void) throws {
        self.url = url; self.monitor = monitor; self.preview = preview; self.onError = onError
        file = try RecoverablePCMFile(url: url, sampleRate: Self.sampleRate)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func submit(_ buffer: AVAudioPCMBuffer, source: Int, hostTime: UInt64 = 0) {
        guard pending.wait(timeout: .now()) == .success else {
            NSLog("[RecordingWriter] pending audio queue capacity exceeded (source %d)", source)
            onError(RecordingWriterError.overrun.localizedDescription); return
        }
        guard buffer.frameLength > 0, buffer.frameLength <= 65_536,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            pending.signal(); return
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in src.indices {
            guard let from = src[i].mData, let to = dst[i].mData else { continue }
            memcpy(to, from, Int(src[i].mDataByteSize))
        }
        let time = hostTime == 0
            ? ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
            : AVAudioTime.seconds(forHostTime: hostTime)
        queue.async { [self] in
            defer { pending.signal() }
            guard !paused, !finished, !failed else { return }
            do {
                let converter: AVAudioConverter
                if let existing = converters[source], existing.inputFormat == copy.format { converter = existing }
                else {
                    guard let created = AVAudioConverter(from: copy.format, to: outputFormat) else {
                        throw RecordingWriterError.unsupportedFormat
                    }
                    converter = created; converters[source] = created
                }
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * Self.sampleRate / copy.format.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    throw RecordingWriterError.unsupportedFormat
                }
                var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return copy
                }
                if let error { throw error }
                let frame = Int64(((time - origin) * Self.sampleRate).rounded())
                let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
                try mixer.add(samples, at: frame)
            } catch { fail(error) }
        }
    }

    private func tick() {
        guard !paused, !finished, !failed else { return }
        do {
            // Hold one second for Bluetooth input latency and independently scheduled callbacks.
            try flush(until: ProcessInfo.processInfo.systemUptime - 1.0)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSync >= 5 {
                try file.synchronize(); lastSync = now
                if let free = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
                   free < 128 * 1024 * 1024 { throw RecordingWriterError.diskSpace }
            }
        } catch { fail(error) }
    }
    private func flush(until time: TimeInterval) throws {
        let end = max(mixer.nextFrame, Int64(max(0, time - origin) * Self.sampleRate))
        while mixer.nextFrame < end {
            let values = mixer.take(Int(min(4_800, end - mixer.nextFrame)))
            try file.append(values)
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(values.count))!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(from: values, count: values.count)
            monitor.observe(buffer: buffer)
            preview?(buffer)
        }
    }
    private func fail(_ error: Error) {
        guard !failed else { return }; failed = true
        try? file.synchronize()
        onError(error.localizedDescription)
    }
    func pause() { queue.sync { try? flush(until: ProcessInfo.processInfo.systemUptime); paused = true; try? file.synchronize() } }
    func resume() { queue.sync { origin = ProcessInfo.processInfo.systemUptime - Double(mixer.nextFrame) / Self.sampleRate; mixer.clearPending(); paused = false; failed = false; converters = [:] } }
    func finish() throws -> TimeInterval {
        try queue.sync {
            timer?.cancel(); timer = nil
            if !paused && !failed { try flush(until: ProcessInfo.processInfo.systemUptime) }
            finished = true
            try file.synchronize() // Keep the ownership lock through final compression.
            return Double(mixer.nextFrame) / Self.sampleRate
        }
    }
    var duration: TimeInterval { queue.sync { Double(mixer.nextFrame) / Self.sampleRate } }
    deinit { timer?.cancel() }
}
