import CoreAudio
@testable import HolosAudio
import Testing

// Whether the laptop speakers play the call (docs/meeting-design.md §5.11, PR11). Only the pure classification is
// tested: the default suite never looks up real CoreAudio devices.

/// A four-character CoreAudio code, e.g. "ispk".
private func code(_ text: String) -> UInt32 {
    text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

@Test func builtInSpeakersClassification() {
    #expect(OutputRoute.classify(transportType: code("bltn"), dataSource: code("ispk")))
    #expect(!OutputRoute.classify(transportType: code("bltn"), dataSource: code("hdpn")))
    #expect(!OutputRoute.classify(transportType: kAudioDeviceTransportTypeUSB, dataSource: nil))
}

@Test func onlyTheBuiltInSpeakersCount() {
    #expect(code("bltn") == kAudioDeviceTransportTypeBuiltIn)
    #expect(OutputRoute.internalSpeakers == code("ispk"))
    #expect(OutputRoute.headphones == code("hdpn"))
    // A built-in device that does not say what it plays through is not assumed to be the speakers.
    #expect(!OutputRoute.classify(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: nil))
    // External devices never count, whatever data source they report.
    for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                      kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeHDMI,
                      kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay,
                      kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual] {
        #expect(!OutputRoute.classify(transportType: transport, dataSource: code("ispk")))
    }
}

@Test func echoRiskMessageIsTheDesignText() {
    let design = """
        The laptop speakers are playing the call, so other people's voices also reach your microphone. \
        Headphones give a cleaner transcript.
        """
    #expect(OutputRoute.echoRiskMessage == design)
}
