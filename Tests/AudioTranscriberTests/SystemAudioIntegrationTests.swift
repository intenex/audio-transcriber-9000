#if os(macOS)
import AVFoundation
import CoreAudio
import XCTest
@testable import AudioTranscriber

/// Requires both the ordinary integration gate and a separate explicit system
/// audio gate; never surprises an unattended unit run with a permission sheet.
@MainActor
final class SystemAudioIntegrationTests: XCTestCase {
    func testSystemOutputCapturedDirectlyWithoutAnyMicrophone() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled && FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-system-audio-tests"), "system audio gate not present")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SystemAudio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toneURL = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: toneURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 4)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 48_000) * 0.12 }
            try file.write(from: buffer)
        }
        let destination = directory.appendingPathComponent("captured.caf")
        let writer = try ContinuousRecordingWriter(url: destination, monitor: RecordingLevelMonitor()) { message in XCTFail(message) }
        let capture = SystemAudioCapture()
        defer { capture.deactivate() }
        try await capture.activate(writer: writer)
        let player = try AVAudioPlayer(contentsOf: toneURL)
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .seconds(5))
        capture.deactivate()
        let duration = try writer.finish()
        XCTAssertGreaterThan(duration, 4)
        let file = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
        var audibleFrames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_800, file.length - file.framePosition)))
            if AudioLevel.levels(of: buffer).rmsDB > -40 { audibleFrames += Int(buffer.frameLength) }
        }
        XCTAssertGreaterThan(audibleFrames, 48_000 * 3, "System output must be captured directly: this test never opens a microphone")
    }
    func testAirPodsSpeakerSwitchesKeepSystemAudioWithoutMicrophone() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled && FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-route-switch-tests"), "explicit route switch gate not present")
        try await verifyRouteSwitches(matching: "AirPods")
    }

    func testVirtualSpeakerSwitchesKeepSystemAudioWithoutMicrophone() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled && FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-virtual-route-tests"), "explicit virtual route gate not present")
        try await verifyRouteSwitches(matching: "ZoomAudioDevice")
    }

    private func verifyRouteSwitches(matching alternateName: String) async throws {
        func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        var devicesAddress = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        XCTAssertEqual(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size), noErr)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices), noErr)
        func name(_ id: AudioObjectID) -> String {
            var address = property(kAudioObjectPropertyName), name: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
            return name as String
        }
        let headphones = try XCTUnwrap(devices.first { name($0).contains(alternateName) }, "Connect \(alternateName) to run this gate")
        let speakers = try XCTUnwrap(devices.first { name($0).contains("Speakers") })
        var outputAddress = property(kAudioHardwarePropertyDefaultOutputDevice)
        var original = AudioObjectID(0), outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &outputSize, &original), noErr)
        func route(_ id: AudioObjectID) throws {
            var id = id
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, outputSize, &id)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        defer { try? route(original) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RouteSwitch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toneURL = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: toneURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 30)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 48_000) * 0.12 }
            try file.write(from: buffer)
        }
        try route(speakers)
        let destination = directory.appendingPathComponent("captured.caf")
        let writer = try ContinuousRecordingWriter(url: destination, monitor: RecordingLevelMonitor()) { XCTFail($0) }
        let capture = SystemAudioCapture()
        defer { capture.deactivate() }
        try await capture.activate(writer: writer)
        let player = try AVAudioPlayer(contentsOf: toneURL)
        XCTAssertTrue(player.play())
        defer { player.stop() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        var windows: [(String, Double, Double)] = []
        for device in [speakers, headphones, speakers, headphones] {
            try route(device)
            let start = writer.duration
            try await Task.sleep(for: .seconds(5))
            print("SOURCE \(name(device)): elapsed=\(ProcessInfo.processInfo.systemUptime - startedAt) playback=\(player.currentTime)")
            windows.append((name(device), start + 2, writer.duration))
        }
        player.stop(); capture.deactivate()
        _ = try writer.finish()
        let file = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        var audible = Array(repeating: 0.0, count: windows.count)
        var longestGap = 0.0, gap = 0.0
        while file.framePosition < file.length {
            let time = Double(file.framePosition) / 48_000
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(480, file.length - file.framePosition)))
            let sound = AudioLevel.levels(of: buffer).rmsDB > -40
            if time > 2 && time < Double(file.length) / 48_000 - 1 {
                if sound && gap > 0.05 { print("GAP ending at \(time): \(gap)s") }
                gap = sound ? 0 : gap + 0.01; longestGap = max(longestGap, gap)
            }
            for i in windows.indices where time >= windows[i].1 && time < windows[i].2 {
                if sound { audible[i] += Double(buffer.frameLength) / 48_000 }
            }
        }
        for i in windows.indices {
            print("ROUTE \(windows[i].0): \(audible[i]) seconds captured of \(windows[i].2 - windows[i].1)")
            XCTAssertGreaterThan(audible[i], windows[i].2 - windows[i].1 - 0.3)
        }
        print("ROUTE longest capture gap: \(longestGap)s")
        XCTAssertLessThan(longestGap, 0.5, "switches must not create a prolonged hole in directly captured system output")
    }

    func testBothSourcesStayLiveForOneMinute() async throws {
        try XCTSkipUnless(IntegrationGate.isEnabled && FileManager.default.fileExists(atPath: "/tmp/audiotranscriber-system-audio-tests"), "system audio gate not present")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BothSources-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder()
        let previous = recorder.recordSystemAudioPreference
        recorder.recordSystemAudioPreference = true
        defer { recorder.recordSystemAudioPreference = previous }
        let store = RecordingStore(storageDirectory: directory, defaults: UserDefaults(suiteName: "BothSources-\(UUID())")!)
        recorder.attach(store: store)
        let previousPreview = UserDefaults.standard.object(forKey: "liveTranscriptionPreview")
        UserDefaults.standard.set(true, forKey: "liveTranscriptionPreview")
        defer {
            if let previousPreview { UserDefaults.standard.set(previousPreview, forKey: "liveTranscriptionPreview") }
            else { UserDefaults.standard.removeObject(forKey: "liveTranscriptionPreview") }
        }
        recorder.liveTranscriber = LiveTranscriber()
        recorder.startRecording()
        for _ in 0..<200 {
            if recorder.isRecording || recorder.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(recorder.isRecording, recorder.errorMessage ?? "capture did not start")
        guard recorder.isRecording else { return }
        for _ in 0..<65 {
            try await Task.sleep(for: .seconds(1))
            if recorder.isPaused || recorder.errorMessage != nil { break }
        }
        XCTAssertNil(recorder.errorMessage)
        XCTAssertFalse(recorder.isPaused)
        XCTAssertGreaterThanOrEqual(recorder.recordingDuration, 64)
        recorder.stopRecording()
        for _ in 0..<100 {
            if !recorder.isFinalizingRecording { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertGreaterThan(store.recordings.first?.duration ?? 0, 64)
    }

}
#endif
