import AVFoundation
import XCTest
@testable import AudioTranscriber

/// The platform-neutral import API (the Mac NSOpenPanel flow and the iOS
/// fileImporter both funnel into importAudioFiles(urls:compress:)).
@MainActor
final class ImportURLsTests: XCTestCase {
    private var tempDir: URL!
    private var sourceDir: URL!
    private var store: RecordingStore!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        sourceDir = tempDir.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ImportTests-\(UUID().uuidString)")!
        store = RecordingStore(storageDirectory: tempDir, defaults: defaults)
        store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRealWav(_ name: String, seconds: Double = 1.0) throws -> URL {
        let url = sourceDir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3
        }
        try file.write(from: buffer)
        return url
    }

    func testImportCopyKeepsFormatAndSource() async throws {
        let wav = try makeRealWav("meeting.wav")
        await store.importAudioFiles(urls: [wav], compress: false).value

        XCTAssertEqual(store.recordings.count, 1)
        let imported = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(imported.fileURL.pathExtension, "wav")
        XCTAssertTrue(imported.fileURL.path.hasPrefix(tempDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "source untouched")
        XCTAssertEqual(imported.duration, 1.0, accuracy: 0.3)
    }

    func testImportCompressProducesM4A() async throws {
        let wav = try makeRealWav("big.wav")
        await store.importAudioFiles(urls: [wav], compress: true).value

        let imported = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(imported.fileURL.pathExtension, "m4a")
        XCTAssertEqual(imported.duration, 1.0, accuracy: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "source untouched")
    }

    func testCompressFlagIgnoredForAlreadyCompressedSources() async throws {
        // An .mp3-named copy of arbitrary data big enough to import.
        let mp3 = sourceDir.appendingPathComponent("song.mp3")
        try Data(count: 8192).write(to: mp3)
        await store.importAudioFiles(urls: [mp3], compress: true).value

        let imported = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(imported.fileURL.pathExtension, "mp3", "mp3 is copied as-is, never transcoded")
    }

    func testPolicyResolution() {
        XCTAssertEqual(store.resolveImportCompressionPolicy(), .ask)
        defaults.set("always", forKey: "importCompression")
        XCTAssertEqual(store.resolveImportCompressionPolicy(), .always)
        defaults.set("never", forKey: "importCompression")
        XCTAssertEqual(store.resolveImportCompressionPolicy(), .never)
    }

    func testEstimateCountsOnlyCompressibles() throws {
        let wav = try makeRealWav("a.wav", seconds: 2)
        let mp3 = sourceDir.appendingPathComponent("b.mp3")
        try Data(count: 8192).write(to: mp3)

        let estimate = store.importCompressionEstimate(for: [wav, mp3])
        XCTAssertEqual(estimate.compressibleCount, 1)
        XCTAssertGreaterThan(estimate.originalBytes, 300_000)   // 2s Float32 48k ≈ 384KB
        XCTAssertGreaterThan(estimate.compressedBytes, 0)
        XCTAssertLessThan(estimate.compressedBytes, estimate.originalBytes)
    }
}
