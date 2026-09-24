import Foundation
import HolosCore
import Testing
@testable import HolosAudio

// docs/meeting-design.md §4.5: meeting audio is saved as 48 kHz mono, whatever the microphone delivers.

/// `count` contiguous frames of `seconds` each, every channel at a constant value (`values[channel]`).
private func converterFrames(rate: Double, values: [Float], count: Int, seconds: Double = 0.1,
                             from start: Double = 0) throws -> [CapturedAudio] {
    let frames = Int((seconds * rate).rounded())
    return try (0..<count).map { index in
        var samples: [Float] = []
        samples.reserveCapacity(frames * values.count)
        for _ in 0..<frames { samples += values }
        let frame = try PCMFrame(samples: samples, sampleRate: rate, channels: values.count,
                                 startTime: start + Double(index * frames) / rate)
        return CapturedAudio(track: "mic", frame: frame)
    }
}

private func convertAll(_ input: [CapturedAudio], with converter: RecordingFormatConverter) throws -> [CapturedAudio] {
    try input.compactMap { try converter.convert($0) }
}

@Test func recordingFormatPassesThrough48kMono() throws {
    let converter = RecordingFormatConverter()
    let input = try converterFrames(rate: 48_000, values: [0.25], count: 3)
    let output = try convertAll(input, with: converter)
    #expect(output.map(\.frame.samples) == input.map(\.frame.samples))
    #expect(output.map(\.frame.startTime) == input.map(\.frame.startTime))
}

@Test func recordingFormatAveragesChannels() throws {
    let converter = RecordingFormatConverter()
    let output = try convertAll(try converterFrames(rate: 48_000, values: [0.5, 0.25], count: 2), with: converter)
    #expect(output.allSatisfy { $0.frame.channels == 1 && $0.frame.sampleRate == 48_000 })
    #expect(output.allSatisfy { $0.frame.samples.allSatisfy { abs($0 - 0.375) < 1e-6 } })
    #expect(output.map(\.frame.frameCount) == [4_800, 4_800])
}

@Test(arguments: [96_000.0, 44_100.0, 16_000.0])
func recordingFormatResamplesToContiguous48kMono(rate: Double) throws {
    let converter = RecordingFormatConverter()
    // 3 s of a stereo device.
    var output = try convertAll(try converterFrames(rate: rate, values: [0.4, 0.2], count: 30), with: converter)
    let held = 144_000 - output.map(\.frame.frameCount).reduce(0, +)
    #expect(held >= 0 && held < 1_440, "The resampler holds back at most its look-ahead (\(held) frames).")
    // The capture ended: the look-ahead comes out as the last frame.
    output += try converter.flush()
    #expect(try converter.flush().isEmpty)
    #expect(output.allSatisfy { $0.frame.channels == 1 && $0.frame.sampleRate == 48_000 })
    let total = output.map(\.frame.frameCount).reduce(0, +)
    #expect(abs(total - 144_000) <= 2, "\(total) frames for 3 s at \(rate) Hz.")
    // Timed by the samples produced: every frame starts where the previous one ended.
    for (previous, next) in zip(output, output.dropFirst()) {
        #expect(abs(next.frame.startTime - (previous.frame.startTime + previous.frame.duration)) < 1e-9)
    }
    #expect(output.first?.frame.startTime == 0)
    // The level survives the channel average and the resampler (away from the filter's start).
    let middle = output[output.count / 2].frame.samples
    #expect(middle.allSatisfy { abs($0 - 0.3) < 0.01 })
}

@Test func recordingFormatRestartsAtAGapAndCarriesDrops() throws {
    let converter = RecordingFormatConverter()
    let first = try convertAll(try converterFrames(rate: 44_100, values: [0.1], count: 10), with: converter)
    var later = try converterFrames(rate: 44_100, values: [0.1], count: 10, from: 5)
    later[0] = CapturedAudio(track: later[0].track, frame: later[0].frame, followsDrop: true)
    let second = try convertAll(later, with: converter)
    let firstEnd = try #require(first.last).frame
    #expect(firstEnd.startTime + firstEnd.duration <= 1.0 + 1e-9)
    let resumed = try #require(second.first)
    #expect(abs(resumed.frame.startTime - 5) < 1e-9, "A gap re-anchors the output at the frame's own time.")
    #expect(resumed.followsDrop, "The first output after a drop keeps the mark.")
    #expect(second.dropFirst().allSatisfy { !$0.followsDrop })
}

@Test func recordingFormatKeepsTracksApart() throws {
    let converter = RecordingFormatConverter()
    let mic = try converterFrames(rate: 44_100, values: [0.2], count: 5)
    let system = try converterFrames(rate: 48_000, values: [0.3], count: 5).map {
        CapturedAudio(track: "system", frame: $0.frame)
    }
    var output: [CapturedAudio] = []
    for (a, b) in zip(mic, system) {
        if let converted = try converter.convert(a) { output.append(converted) }
        if let converted = try converter.convert(b) { output.append(converted) }
    }
    let micOut = output.filter { $0.track == "mic" }
    for (previous, next) in zip(micOut, micOut.dropFirst()) {
        #expect(abs(next.frame.startTime - (previous.frame.startTime + previous.frame.duration)) < 1e-9)
    }
    #expect(output.filter { $0.track == "system" }.map(\.frame.samples) == system.map(\.frame.samples))
}
