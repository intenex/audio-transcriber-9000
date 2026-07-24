import AVFoundation
import XCTest
@testable import AudioTranscriber

/// Offline stitching of recorder segments (device-change recovery) and the
/// input-selection policy.
final class SegmentStitchTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StitchTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Writes a mono AAC segment of `seconds` at `sampleRate` containing a sine
    /// tone. Writer scoped so the container finalizes (DEVELOPMENT.md).
    private func makeSegment(name: String, seconds: Double, sampleRate: Double) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = sinf(Float(i) * 0.03) * 0.4
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testStitchesSameRateSegments() throws {
        let a = try makeSegment(name: "a.seg0.m4a", seconds: 2.0, sampleRate: 48_000)
        let b = try makeSegment(name: "a.seg1.m4a", seconds: 3.0, sampleRate: 48_000)
        let out = tempDir.appendingPathComponent("a.m4a")

        try AudioCompressor.concatenateSync(segments: [a, b], to: out, as: .aacCompact)

        let duration = RecordingStore.audioDuration(for: out)
        XCTAssertEqual(duration, 5.0, accuracy: 0.25, "2s + 3s segments must stitch to ~5s")
    }

    /// The real-world case: AirPods HFP mic (24 kHz) → built-in mic (48 kHz).
    func testStitchesMixedSampleRateSegments() throws {
        let airpods = try makeSegment(name: "b.seg0.m4a", seconds: 2.0, sampleRate: 24_000)
        let builtin = try makeSegment(name: "b.seg1.m4a", seconds: 2.0, sampleRate: 48_000)
        let out = tempDir.appendingPathComponent("b.m4a")

        try AudioCompressor.concatenateSync(segments: [airpods, builtin], to: out, as: .aacCompact)

        let duration = RecordingStore.audioDuration(for: out)
        XCTAssertEqual(duration, 4.0, accuracy: 0.25,
                       "mixed-rate segments must keep their combined duration")
        // Output follows the first segment's rate.
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000, accuracy: 1)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }

    func testStitchToWav() throws {
        let a = try makeSegment(name: "c.seg0.m4a", seconds: 1.0, sampleRate: 48_000)
        let b = try makeSegment(name: "c.seg1.m4a", seconds: 1.0, sampleRate: 48_000)
        let out = tempDir.appendingPathComponent("c.wav")

        try AudioCompressor.concatenateSync(segments: [a, b], to: out, as: .wav)

        XCTAssertEqual(RecordingStore.audioDuration(for: out), 2.0, accuracy: 0.25)
    }

    func testSingleSegmentStitchIsIdentityShaped() throws {
        let a = try makeSegment(name: "d.seg0.m4a", seconds: 2.0, sampleRate: 48_000)
        let out = tempDir.appendingPathComponent("d.m4a")
        try AudioCompressor.concatenateSync(segments: [a], to: out, as: .aacHigh)
        XCTAssertEqual(RecordingStore.audioDuration(for: out), 2.0, accuracy: 0.25)
    }

    // MARK: - Input selection policy

    #if os(macOS)
    func testEffectiveDeviceResolution() {
        let builtin = AudioInputDevice(id: 1, uid: "builtin", name: "MacBook Pro Microphone")
        let airpods = AudioInputDevice(id: 2, uid: "airpods", name: "AirPods Pro")
        let devices = [builtin, airpods]

        // Automatic follows the system default.
        XCTAssertEqual(AudioInputDeviceStore.resolveEffective(
            devices: devices, selectedUID: nil, systemDefault: airpods), airpods)
        // A pinned, connected device wins over the default.
        XCTAssertEqual(AudioInputDeviceStore.resolveEffective(
            devices: devices, selectedUID: "builtin", systemDefault: airpods), builtin)
        // A pinned but DISCONNECTED device falls back to the default.
        XCTAssertEqual(AudioInputDeviceStore.resolveEffective(
            devices: [builtin], selectedUID: "airpods", systemDefault: builtin), builtin)
        // No devices at all.
        XCTAssertNil(AudioInputDeviceStore.resolveEffective(
            devices: [], selectedUID: "airpods", systemDefault: nil))
    }
    #endif
}
