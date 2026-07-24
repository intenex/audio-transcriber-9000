#if os(macOS)
import CoreAudio
import Foundation
import Observation

/// A physical (or virtual) audio input device as seen by Core Audio.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Enumerates input devices, tracks the system default, and holds the user's
/// preference ("Automatic" = follow the system default). The recorder observes
/// `onEffectiveInputChanged` to rebuild its capture chain mid-recording when
/// the effective device changes (AirPods connecting, a mic unplugged, …).
@Observable @MainActor
final class AudioInputDeviceStore {
    static let preferenceKey = "preferredInputDeviceUID"

    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemDefault: AudioInputDevice? = nil

    /// nil = Automatic (follow the system default input).
    var selectedUID: String? {
        didSet {
            guard oldValue != selectedUID else { return }
            if let selectedUID {
                defaults.set(selectedUID, forKey: Self.preferenceKey)
            } else {
                defaults.removeObject(forKey: Self.preferenceKey)
            }
            notifyIfEffectiveChanged()
        }
    }

    /// Fired (on the main actor) whenever the device that WOULD be captured
    /// from changes — selection changes, default changes in Automatic mode,
    /// or a manually pinned device (dis)appearing.
    var onEffectiveInputChanged: (() -> Void)? = nil

    private let defaults: UserDefaults
    private var lastNotifiedUID: String? = nil
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedUID = defaults.string(forKey: Self.preferenceKey)
        refresh()
        lastNotifiedUID = effectiveDevice?.uid
        installListeners()
    }

    /// The device recording would actually use right now. A pinned device
    /// that's currently disconnected falls back to the system default.
    var effectiveDevice: AudioInputDevice? {
        Self.resolveEffective(devices: devices, selectedUID: selectedUID, systemDefault: systemDefault)
    }

    var isUsingFallback: Bool {
        guard let selectedUID else { return false }
        return !devices.contains { $0.uid == selectedUID }
    }

    /// Pure selection policy (unit-tested without Core Audio).
    nonisolated static func resolveEffective(devices: [AudioInputDevice],
                                             selectedUID: String?,
                                             systemDefault: AudioInputDevice?) -> AudioInputDevice? {
        if let selectedUID, let pinned = devices.first(where: { $0.uid == selectedUID }) {
            return pinned
        }
        return systemDefault
    }

    func refresh() {
        devices = Self.listInputDevices()
        systemDefault = Self.defaultInputDevice()
    }

    private func notifyIfEffectiveChanged() {
        let current = effectiveDevice?.uid
        guard current != lastNotifiedUID else { return }
        lastNotifiedUID = current
        onEffectiveInputChanged?()
    }

    // MARK: - Core Audio listeners

    private func installListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refresh()
                    self.notifyIfEffectiveChanged()
                }
            }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            listenerBlocks.append((address, block))
        }
    }

    // MARK: - Core Audio queries

    nonisolated static func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    nonisolated static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: deviceID, uid: uid, name: name)
    }

    private nonisolated static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPointer) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func stringProperty(_ deviceID: AudioDeviceID,
                                                   selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}
#endif
