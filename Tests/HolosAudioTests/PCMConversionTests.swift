import AVFoundation
import HolosCore
import Testing
@testable import HolosAudio

@Test func stereoConversionPreservesChannelsAndTiming() throws {
    let frame = try PCMFrame(samples: [0.25, -0.25, 0.5, -0.5], sampleRate: 48000, channels: 2, startTime: 7.5)
    let buffer = try PCMConversion.makeBuffer(frame)
    let roundTrip = try PCMConversion.copy(buffer, startTime: frame.startTime)
    #expect(roundTrip.samples == frame.samples)
    #expect(roundTrip.channels == 2)
    #expect(roundTrip.startTime == 7.5)
    #expect(roundTrip.frameCount == 2)
}

@Test func readOnlyCallbackBufferIsCopiedIntoOwnedSamples() throws {
    let original = try PCMFrame(samples: [0.2, -0.2, 0.7, -0.7], sampleRate: 48000,
                                channels: 2, startTime: 3.25)
    let mutable = try PCMConversion.makeBuffer(original)
    let readOnly = AVReadOnlyAudioPCMBuffer(copying: mutable)
    let result = try PCMConversion.copy(readOnly, startTime: original.startTime)
    mutable.floatChannelData?[0][0] = 0
    #expect(result.samples == original.samples)
    #expect(result.channels == original.channels)
    #expect(result.startTime == original.startTime)
}

@Test func microphoneTimelineIgnoresHostClockJitter() {
    var timeline = MicrophoneTimeline(sampleRate: 48000)
    // Host times from a real tap: buffer 3 arrives 4.3 µs early relative to the previous buffer's end.
    let host = [11065.032509, 11065.132509, 11065.232510, 11065.332506, 11065.432506]
    var previousEnd: Double?
    for (index, hostSeconds) in host.enumerated() {
        let start = timeline.startTime(hostSeconds: hostSeconds, sampleTime: Int64(index * 4800))
        if let previousEnd { #expect(abs(start - previousEnd) < 0.000_001) }
        previousEnd = start + 0.1
    }
}
