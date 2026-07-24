#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

enum SystemAudioCaptureError: LocalizedError {
    case unsupported
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "System audio capture requires macOS 14.4 or later."
        case .tapCreationFailed(let status):
            return "Couldn't tap system audio (error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
        case .aggregateCreationFailed(let status):
            return "Couldn't combine the microphone with system audio (error \(status))."
        }
    }
}

/// Captures everything the Mac plays (calls, videos, meetings) alongside the
/// microphone: a global Core Audio process tap is combined with the selected
/// mic in a private aggregate device, which the recording engine then uses as
/// its input. Output-device switches (speakers ⇄ AirPods) don't interrupt a
/// global tap — it captures the system mix regardless of where it's routed.
///
/// First use triggers the system-audio recording permission prompt
/// (NSAudioCaptureUsageDescription). All failures are recoverable: the caller
/// degrades to mic-only capture.
final class SystemAudioCapture {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Creates the global tap + aggregate. Returns the aggregate's device ID,
    /// ready to be set as an AVAudioEngine input via AUAudioUnit.deviceID.
    /// The mic is the aggregate's clock master; the tap drift-compensates.
    func activate(micUID: String) throws -> AudioObjectID {
        guard #available(macOS 14.4, *) else { throw SystemAudioCaptureError.unsupported }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = tapUUID
        description.name = "Audio Transcriber 9000 System Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Transcriber 9000 Capture",
            kAudioAggregateDeviceUIDKey: "com.audiortranscriber.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            deactivate()
            throw SystemAudioCaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = newAggregateID
        return newAggregateID
    }

    func deactivate() {
        guard #available(macOS 14.2, *) else { return }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        deactivate()
    }
}
#endif
