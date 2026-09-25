import CoreAudio
import Foundation

/// Where the Mac plays sound: the system default output device (docs/meeting-design.md §5.11, PR11). A call played on
/// the laptop speakers reaches the microphone, so other people's words are transcribed twice; the start panel, the
/// recorder (`echoRisk`), and `holos record start` warn about it.
public struct OutputRoute: Sendable, Equatable {
    /// The device name shown to the user, e.g. "MacBook Pro Speakers".
    public var name: String
    /// The laptop's own speakers, not headphones, a display, or an external device.
    public var isBuiltInSpeakers: Bool

    public init(name: String, isBuiltInSpeakers: Bool) {
        self.name = name; self.isBuiltInSpeakers = isBuiltInSpeakers
    }

    /// The warning shown while a call's microphone may pick up the laptop speakers.
    public static let echoRiskMessage = "The laptop speakers are playing the call, so other people's voices also "
        + "reach your microphone. Headphones give a cleaner transcript."

    /// Default output device: transport built-in and data source 'ispk' → speakers; 'hdpn' → headphones.
    /// Nil when there is no default output device. Reads CoreAudio properties only (no permission is needed).
    public static func current() -> OutputRoute? {
        guard let id = defaultOutputID() else { return nil }
        let transport = uint32(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        let dataSource = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        let name = string(id, kAudioObjectPropertyName) ?? string(id, kAudioDevicePropertyDeviceUID) ?? "Output"
        return OutputRoute(name: name, isBuiltInSpeakers: classify(transportType: transport, dataSource: dataSource))
    }

    /// Pure classification used by `current()`, for tests: only a built-in device whose output data source is the
    /// internal speakers ('ispk') counts. Headphones on the built-in jack ('hdpn'), a built-in device without a data
    /// source, and every external device (USB, Bluetooth, HDMI, AirPlay, aggregate) do not.
    public static func classify(transportType: UInt32, dataSource: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && dataSource == internalSpeakers
    }

    /// 'ispk', the internal-speaker data source of built-in output devices.
    static let internalSpeakers: UInt32 = 0x6973_706B
    /// 'hdpn', headphones on the built-in jack.
    static let headphones: UInt32 = 0x6864_706E

    // MARK: - CoreAudio

    private static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputID() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// A UInt32 property, or nil when the device does not have it.
    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = propertyAddress(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
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
