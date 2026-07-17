import AVFoundation
import XCTest
@testable import AudioTranscriber

final class RecordingFormatTests: XCTestCase {

    private var input48kMono: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    func testDefaultIsCompressedHighQuality() {
        // No stored preference → AAC high
        XCTAssertEqual(RecordingFormat(rawValue: "nonsense") ?? .aacHigh, .aacHigh)
        XCTAssertEqual(RecordingFormat.aacHigh.fileExtension, "m4a")
        XCTAssertEqual(RecordingFormat.wav.fileExtension, "wav")
    }

    func testAACSettings() {
        let settings = RecordingFormat.aacHigh.fileSettings(for: input48kMono)
        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? UInt32, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testAACNeverUpsamplesButCapsAt48k() {
        let hiRes = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 1, interleaved: false)!
        XCTAssertEqual(RecordingFormat.aacHigh.fileSettings(for: hiRes)[AVSampleRateKey] as? Double, 48_000)
        let lowRes = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        XCTAssertEqual(RecordingFormat.aacHigh.fileSettings(for: lowRes)[AVSampleRateKey] as? Double, 24_000)
    }

    func testWavSettings() {
        let settings = RecordingFormat.wav.fileSettings(for: input48kMono)
        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
    }

    /// The exact write path the recorder uses: Float32 tap buffers into an
    /// AVAudioFile with AAC settings and commonFormat pinned to Float32.
    func testAACWritePathProducesPlayableM4A() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-write-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let inputFormat = input48kMono
        // Scope the writer: AVAudioFile finalizes the m4a container on deinit
        // (the recorder does the same by nil-ing audioFile before inserting).
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url,
                                       settings: RecordingFormat.aacHigh.fileSettings(for: inputFormat),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)

            // 3 seconds of 440Hz sine in tap-sized chunks
            let chunkFrames: AVAudioFrameCount = 4096
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames)!
            var written = 0
            var phase: Float = 0
            while written < 3 * 48_000 {
                let frames = min(Int(chunkFrames), 3 * 48_000 - written)
                buffer.frameLength = AVAudioFrameCount(frames)
                let data = buffer.floatChannelData![0]
                for i in 0..<frames {
                    data[i] = sinf(phase) * 0.4
                    phase += 2 * .pi * 440 / 48_000
                }
                try file.write(from: buffer)
                written += frames
            }
        }

        // Reopen and verify duration + that the transcription loader can read it.
        let duration = RecordingStore.audioDuration(for: url)
        XCTAssertEqual(duration, 3.0, accuracy: 0.2)
        let samples = try WindowedAudioLoader.load16kMono(from: url)
        XCTAssertEqual(Double(samples.count), 3 * 16_000, accuracy: 16_000 * 0.2)

        // And it's dramatically smaller than the PCM equivalent (576 KB Float32).
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertLessThan(size, 100_000, "3s at 96kbps should be ~36KB, got \(size)")
        XCTAssertGreaterThan(size, 10_000)
    }
}

@MainActor
final class CompressInPlaceTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "CompressTests-\(UUID().uuidString)")!)
        store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRealWav(_ name: String, seconds: Double) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.4
        }
        try file.write(from: buffer)
        return url
    }

    func testCompressInPlaceSwapsFileAndKeepsSidecars() async throws {
        let wav = try makeRealWav("session.wav", seconds: 3)
        var recording = Recording(fileURL: wav, date: .now,
                                  duration: RecordingStore.audioDuration(for: wav))
        recording.status = .done
        // Sidecar next to the wav — must remain valid after the swap
        try "# transcript".write(to: recording.markdownURL, atomically: true, encoding: .utf8)
        store.insert(recording)

        await store.compressAudio(recording)

        let updated = store.recording(with: recording.id)
        XCTAssertEqual(updated?.fileURL.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated!.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "original wav removed")
        // Same stem → sidecars still resolve
        XCTAssertEqual(updated?.markdownURL.lastPathComponent, "session.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated!.markdownURL.path))
        XCTAssertEqual(updated?.duration ?? 0, 3.0, accuracy: 0.3)
        XCTAssertNil(store.errorMessage)
    }

    /// The exact reported bug: manifest carried a stale legacy duration (~2x
    /// the file's real length), which made the duration check abort a
    /// perfectly good conversion. Verification must use the source file's
    /// actual duration, and succeed despite the bad manifest value.
    func testCompressSucceedsDespiteStaleManifestDuration() async throws {
        let wav = try makeRealWav("stale.wav", seconds: 3)
        // Manifest lies: claims 6s for a 3s file (like 14720s vs 7629s).
        let recording = Recording(fileURL: wav, date: .now, duration: 6.0)
        store.insert(recording)

        await store.compressAudio(recording)

        XCTAssertNil(store.errorMessage, "compression must not abort on stale manifest duration")
        let updated = store.recording(with: recording.id)
        XCTAssertEqual(updated?.fileURL.pathExtension, "m4a")
        XCTAssertEqual(updated?.duration ?? 0, 3.0, accuracy: 0.3, "duration healed to reality")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }

    func testLoadHealsStaleDurations() throws {
        let wav = try makeRealWav("drift.wav", seconds: 3)
        var recording = Recording(fileURL: wav, date: .now, duration: 3)
        recording.duration = 5.8   // stale legacy value
        store.insert(recording)
        store.saveNow()

        let store2 = RecordingStore(storageDirectory: tempDir,
                                    defaults: UserDefaults(suiteName: "CompressTests-heal-\(UUID().uuidString)")!)
        store2.load()
        XCTAssertEqual(store2.recording(with: recording.id)?.duration ?? 0, 3.0, accuracy: 0.3)
    }

    func testCompressSkipsAlreadyCompressed() async throws {
        let wav = try makeRealWav("keep.wav", seconds: 1)
        // Manually rename to .m4a extension category by making a compressed copy first
        var recording = Recording(fileURL: wav, date: .now, duration: 1)
        recording.fileURL = wav.deletingPathExtension().appendingPathExtension("m4a")
        store.insert(recording)
        await store.compressAudio(recording)   // should no-op: not a compressible extension
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }
}
