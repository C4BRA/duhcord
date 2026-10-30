import CoreAudio
import Foundation

/// A microphone or speaker Core Audio can see. The UID is what we save; the name is what we show.
public struct AudioDevice: Equatable, Sendable {
    public var uid: String
    public var name: String
    public var input: Bool
    public var output: Bool
}

/// Microphones and speakers, shared by the app (the device menu) and the voice helper (opening one).
public enum AudioDevices {
    public static var defaultInputName: String? { name(of: kAudioHardwarePropertyDefaultInputDevice) }
    public static var defaultOutputName: String? { name(of: kAudioHardwarePropertyDefaultOutputDevice) }

    /// The device for a saved ID, or nil when it's missing or isn't a device ID we would save.
    public static func deviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid = VoiceAudioSettings.uid(uid) else { return nil }
        let name = uid as CFString
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: name) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    /// The name of a chosen device, for the connection details. Nil when that device is gone.
    public static func name(forUID uid: String?) -> String? {
        guard let device = deviceID(forUID: uid) else { return nil }
        return string(kAudioObjectPropertyName, device: device).map(displayName)
    }

    /// Microphones when `input` is true, speakers otherwise. Asked when a menu opens, not on a timer.
    public static func devices(input: Bool) -> [AudioDevice] {
        devices().filter { input ? $0.input : $0.output }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(describe)
    }

    private static func describe(_ device: AudioDeviceID) -> AudioDevice? {
        guard let uid = string(kAudioDevicePropertyDeviceUID, device: device),
              let clean = VoiceAudioSettings.uid(uid),
              let rawName = string(kAudioObjectPropertyName, device: device) else { return nil }
        let input = hasStreams(device, scope: kAudioObjectPropertyScopeInput)
        let output = hasStreams(device, scope: kAudioObjectPropertyScopeOutput)
        guard input || output else { return nil }
        return AudioDevice(uid: clean, name: displayName(rawName), input: input, output: output)
    }

    /// Menu text only: drop control characters, and keep a hostile name from stretching the menu.
    private static func displayName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 128 { name = String(name.prefix(128)) }
        return name.isEmpty ? "Audio Device" : name
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func name(of selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return string(kAudioObjectPropertyName, device: device).map(displayName)
    }

    private static func string(_ selector: AudioObjectPropertySelector, device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
