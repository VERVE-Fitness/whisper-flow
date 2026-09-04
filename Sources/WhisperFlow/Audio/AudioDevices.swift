import Foundation
import CoreAudio
import AudioToolbox

/// One capture-capable audio device as CoreAudio reports it.
struct AudioInputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    /// Stable across reboots and re-pairing (unlike `id`, which is a runtime
    /// handle). This is what a user's saved choice is keyed on.
    let uid: String
    let name: String
    let transportType: UInt32

    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Which microphone Whisper Flow records from.
///
/// Default is the Mac's built-in microphone, NOT the system default input.
/// Reason: when AirPods (or any Bluetooth headset) are connected, macOS makes
/// them the default input, and opening a Bluetooth microphone forces the
/// headset from the high-quality A2DP profile down to the Hands-Free Profile.
/// That switch takes 1-3 seconds (during which the input delivers silence or
/// changes format under us), degrades the mic to narrowband phone-call audio
/// that Parakeet transcribes noticeably worse, and drops music/calls on the
/// AirPods to phone quality for the duration. The laptop mic has none of
/// those problems and is within a metre of the speaker anyway.
enum InputDeviceSelection: Equatable {
    /// The Mac's built-in microphone (falls back to system default if this
    /// Mac has none, e.g. a Mac mini with no mic).
    case builtIn
    /// Whatever macOS currently has as the default input (follows AirPods).
    case systemDefault
    /// A specific device by its CoreAudio UID.
    case device(uid: String)

    private static let defaultsKey = "inputDeviceSelection"

    static var saved: InputDeviceSelection {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .builtIn }
            switch raw {
            case "builtIn": return .builtIn
            case "systemDefault": return .systemDefault
            default:
                if raw.hasPrefix("device:") { return .device(uid: String(raw.dropFirst("device:".count))) }
                return .builtIn
            }
        }
        set {
            let raw: String
            switch newValue {
            case .builtIn: raw = "builtIn"
            case .systemDefault: raw = "systemDefault"
            case .device(let uid): raw = "device:" + uid
            }
            UserDefaults.standard.set(raw, forKey: defaultsKey)
        }
    }
}

/// Thin CoreAudio HAL wrapper: enumerate input devices, find the built-in
/// mic, read the current default input. All synchronous property reads; safe
/// to call from any thread.
enum AudioDevices {
    static func allInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { describe($0) }.filter { hasInputStreams($0.id) }
    }

    static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name,
                                transportType: uint32Property(id, kAudioDevicePropertyTransportType) ?? 0)
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return describe(id)
    }

    static func builtInMicrophone() -> AudioInputDevice? {
        allInputDevices().first { $0.isBuiltIn }
    }

    /// Resolve a selection to a concrete device, with the fallbacks the
    /// selection's doc comment promises. Returns nil only when the machine
    /// has no input device at all.
    static func resolve(_ selection: InputDeviceSelection) -> (device: AudioInputDevice?, followsSystemDefault: Bool) {
        switch selection {
        case .systemDefault:
            return (defaultInputDevice(), true)
        case .builtIn:
            if let mic = builtInMicrophone() { return (mic, false) }
            return (defaultInputDevice(), true)
        case .device(let uid):
            if let dev = allInputDevices().first(where: { $0.uid == uid }) { return (dev, false) }
            // Saved device unplugged/unpaired: behave like the default choice
            // rather than failing the dictation.
            if let mic = builtInMicrophone() { return (mic, false) }
            return (defaultInputDevice(), true)
        }
    }

    // MARK: - Property helpers

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func uint32Property(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
