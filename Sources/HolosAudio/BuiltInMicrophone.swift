import CoreAudio
import Foundation

/// A CoreAudio input device.
public struct InputDevice: Sendable, Equatable {
    /// The CoreAudio `AudioDeviceID`.
    public let id: UInt32
    /// `kAudioDevicePropertyDeviceUID`: stable across launches.
    public let uid: String
    /// The name shown to the user, e.g. "MacBook Pro Microphone".
    public let name: String

    public init(id: UInt32, uid: String, name: String) {
        self.id = id; self.uid = uid; self.name = name
    }
}

/// The input devices a meeting can record (docs/meeting-design.md §4.12).
public struct InputDevices: Sendable, Equatable {
    /// nil when absent (e.g. lid closed in clamshell mode).
    public var builtIn: InputDevice?
    /// nil when the Mac has no input device.
    public var systemDefault: InputDevice?

    public init(builtIn: InputDevice?, systemDefault: InputDevice?) {
        self.builtIn = builtIn; self.systemDefault = systemDefault
    }
}

/// Finds the built-in microphone and the system default input (decision 9: in-person meetings record the built-in
/// microphone, calls the system default input).
public enum BuiltInMicrophone {
    /// The built-in input (transport type built-in, with input streams) and the system default input, looked up now.
    public static func devices() -> InputDevices {
        var builtIn: InputDevice?
        for id in deviceIDs() {
            guard let transport = transportType(id), isBuiltInInput(transportType: transport,
                                                                     inputStreamCount: inputStreamCount(id)),
                  let device = device(id) else { continue }
            builtIn = device
            break
        }
        var systemDefault: InputDevice?
        if let id = defaultInputID(), inputStreamCount(id) > 0 { systemDefault = device(id) }
        return InputDevices(builtIn: builtIn, systemDefault: systemDefault)
    }

    /// Pure classification used by `devices()`, for tests.
    public static func isBuiltInInput(transportType: UInt32, inputStreamCount: Int) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && inputStreamCount > 0
    }

    // MARK: - CoreAudio

    private static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func defaultInputID() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func transportType(_ id: AudioObjectID) -> UInt32? {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func inputStreamCount(_ id: AudioObjectID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func device(_ id: AudioObjectID) -> InputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return InputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    /// A CFString property; CoreAudio returns it retained.
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
