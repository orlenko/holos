import CoreAudio
import HolosAudio
import Testing

// The built-in microphone is found by its transport type and input streams (docs/meeting-design.md §4.12). Only the
// pure classification is tested: the default suite never looks up real CoreAudio devices.

@Test func builtInClassification() {
    #expect(BuiltInMicrophone.isBuiltInInput(transportType: kAudioDeviceTransportTypeBuiltIn, inputStreamCount: 1))
    #expect(!BuiltInMicrophone.isBuiltInInput(transportType: kAudioDeviceTransportTypeUSB, inputStreamCount: 1))
    #expect(!BuiltInMicrophone.isBuiltInInput(transportType: kAudioDeviceTransportTypeBuiltIn, inputStreamCount: 0))
    #expect(!BuiltInMicrophone.isBuiltInInput(transportType: kAudioDeviceTransportTypeBluetooth, inputStreamCount: 1))
}
