import AVFAudio
import Foundation
import HolosCore

/// The Speed setting for a natural voice. Pocket TTS has no speed control, so the speech is time-stretched after it
/// is made (`TimeStretch`, pitch kept). The factor is the one the Reading section's slider shows (the inverse of
/// `ReadingSpeed.rate(for:)`), continued linearly for `--rate` values outside the slider, within 0.5×–2×.
public enum NaturalSpeechSpeed {
    public static let range: ClosedRange<Double> = 0.5...2.0

    public static func factor(rate: Float?) -> Double {
        guard let rate, rate.isFinite else { return 1 }
        let normal = Double(ReadingSpeed.normalRate)
        let value = Double(rate)
        let speed: Double
        if value < normal {
            speed = 1 - (normal - value) / (normal - Double(ReadingSpeed.slowRate))
                * (ReadingSpeed.standard - ReadingSpeed.range.lowerBound)
        } else {
            speed = 1 + (value - normal) / (Double(ReadingSpeed.fastRate) - normal)
                * (ReadingSpeed.range.upperBound - ReadingSpeed.standard)
        }
        return min(range.upperBound, max(range.lowerBound, speed))
    }
}

/// Changes the speed of mono speech without changing its pitch: `AVAudioUnitTimePitch`, rendered offline.
public enum TimeStretch {
    public static func apply(_ samples: [Float], sampleRate: Double, rate: Double) throws -> [Float] {
        guard rate.isFinite, rate > 0, abs(rate - 1) > 0.001, !samples.isEmpty else { return samples }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw HolosError.io("Could not prepare the speech for its speed change.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(pitch)
        try engine.connectNode(player, to: pitch, format: format)
        try engine.connectNode(pitch, to: engine.mainMixerNode, format: format)
        let chunk: AVAudioFrameCount = 4_096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input, completionHandler: nil)
        try player.playAudio()
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw HolosError.io("Could not prepare the speech for its speed change.")
        }
        // The time-pitch unit delays its output by its latency: that much more is rendered, and dropped from the start.
        let latency = Int((pitch.latency * sampleRate).rounded())
        let wanted = Int((Double(samples.count) / rate).rounded()) + latency
        var result: [Float] = []
        result.reserveCapacity(wanted)
        while result.count < wanted {
            let frames = AVAudioFrameCount(min(Int(chunk), wanted - result.count))
            switch try engine.renderOffline(frames, to: output) {
            case .success:
                let channel = output.floatChannelData![0]
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw HolosError.io("The speech could not be sped up or slowed down.")
            @unknown default:
                throw HolosError.io("The speech could not be sped up or slowed down.")
            }
        }
        return Array(result.dropFirst(min(latency, result.count)))
    }
}
