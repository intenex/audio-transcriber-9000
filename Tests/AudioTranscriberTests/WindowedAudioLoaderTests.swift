import AVFoundation
import XCTest
import FluidAudio
@testable import AudioTranscriber

final class WindowedAudioLoaderTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test_recording.wav")
    }

    /// Write a small synthetic WAV (sine wave) and return its URL.
    private func makeWav(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testResamples48kMonoToExpectedLength() throws {
        let url = try makeWav(seconds: 2, sampleRate: 48_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        // Use a sub-second window to force many windows through one converter.
        let samples = try WindowedAudioLoader.load16kMono(from: url, windowSeconds: 0.25)
        XCTAssertEqual(Double(samples.count), 2 * 16_000, accuracy: 16_000 * 0.01)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.05, "sine RMS should survive resampling")
    }

    func testStereoMixdown() throws {
        let url = try makeWav(seconds: 1, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try WindowedAudioLoader.load16kMono(from: url, windowSeconds: 0.3)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 16_000 * 0.02)
    }

    func testAlreadY16kMonoPassthrough() throws {
        let url = try makeWav(seconds: 1, sampleRate: 16_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try WindowedAudioLoader.load16kMono(from: url, windowSeconds: 0.5)
        XCTAssertEqual(samples.count, 16_000)
    }

    func testEssentiallyEmptyFileThrows() throws {
        let url = try makeWav(seconds: 0.2, sampleRate: 48_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        // 0.2s < 0.5s minimum
        XCTAssertThrowsError(try WindowedAudioLoader.load16kMono(from: url))
    }

    /// The windowed loader must produce essentially the same signal as
    /// FluidAudio's single-shot loader (which the engine used previously) —
    /// same length and near-identical energy on the real fixture.
    func testMatchesFluidAudioLoaderOnFixture() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureURL.path))
        let ours = try WindowedAudioLoader.load16kMono(from: fixtureURL)
        let theirs = try AudioConverter().resampleAudioFile(fixtureURL)

        XCTAssertEqual(Double(ours.count), Double(theirs.count),
                       accuracy: Double(theirs.count) * 0.005, "length within 0.5%")

        func rms(_ x: [Float]) -> Float {
            sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)))
        }
        let ourRMS = rms(ours)
        let theirRMS = rms(theirs)
        XCTAssertEqual(ourRMS, theirRMS, accuracy: max(0.001, theirRMS * 0.1), "energy within 10%")
    }
}
