import HolosAudio
import HolosCore

/// What one capture epoch records, from the input devices present when it starts (decision 9, §4.12).
struct EpochPlan: Sendable, Equatable {
    static let builtInMicrophoneUnavailable = BuiltInMicrophone.unavailableMessage
    static let noMicrophone = "No microphone is connected. Connect one and try again."

    /// The epoch's `CaptureRequest.source`: `.system` for a call epoch without the microphone.
    var source: AudioSource
    /// The tracks the epoch records.
    var tracks: [String]
    /// The input device the microphone track records, for status.json.
    var microphoneName: String?
    /// A microphone-and-system epoch records system audio alone because the microphone it would record is the
    /// built-in one and the lid is closed; it restarts with the microphone when the lid opens.
    var microphoneOffWithLidClosed = false

    /// Microphone only: the selected microphone; nil when the built-in one is selected and gone, or when the device
    /// it records is the built-in microphone and the lid is closed — selected explicitly, or as the system default
    /// input (Macs with Apple silicon or a T2 chip disconnect it in hardware then, and the device may stay listed
    /// while recording silence). Microphone and system: the selected input (the system default), or system audio
    /// alone when the Mac has no input device, or when the selected input is the built-in microphone and the lid is
    /// closed (`microphoneOffWithLidClosed`, by the same rule as microphone only).
    static func make(_ options: RecordingOptions, devices: InputDevices, lidOpen: Bool = true) -> EpochPlan? {
        let microphone = options.microphone == .builtIn ? devices.builtIn : devices.systemDefault
        switch options.source {
        case .microphone:
            // Nothing to record: the selected microphone (built-in, or the system default input) is gone.
            guard let microphone else { return nil }
            if !lidOpen, isBuiltIn(microphone, in: devices) { return nil }
            return EpochPlan(source: .microphone, tracks: ["mic"], microphoneName: microphone.name)
        case .microphoneAndSystem:
            if !lidOpen, options.microphone == .builtIn || microphone.map({ isBuiltIn($0, in: devices) }) == true {
                return EpochPlan(source: .system, tracks: ["system"], microphoneName: nil,
                                 microphoneOffWithLidClosed: true)
            }
            guard let microphone else { return EpochPlan(source: .system, tracks: ["system"], microphoneName: nil) }
            return EpochPlan(source: .microphoneAndSystem, tracks: ["mic", "system"], microphoneName: microphone.name)
        case .system:
            return EpochPlan(source: .system, tracks: ["system"], microphoneName: nil)
        }
    }

    /// Why `make` returned nil: no input device at all for a capture that follows the system default, otherwise
    /// the built-in microphone being gone or off with the lid closed.
    static func unavailableMessage(_ options: RecordingOptions, devices: InputDevices) -> String {
        options.microphone == .systemDefault && devices.systemDefault == nil
            ? noMicrophone : builtInMicrophoneUnavailable
    }

    /// The device is the built-in microphone: the same CoreAudio device, or the same stable UID.
    private static func isBuiltIn(_ device: InputDevice, in devices: InputDevices) -> Bool {
        guard let builtIn = devices.builtIn else { return false }
        return device.id == builtIn.id || device.uid == builtIn.uid
    }
}
