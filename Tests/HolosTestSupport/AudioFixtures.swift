import AVFAudio
import Foundation

/// Audio files for tests. Rendering speech (text to speech) stays with `NativeSpeechRenderer` in HolosSynthesis;
/// this reads what it rendered back as samples, which needs AVFAudio only.
public enum AudioFixtures {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// A mono Float32 CAF of `frames` samples of constant `value`.
    public static func writeCAF(at url: URL, frames: Int = 64, sampleRate: Double = 48_000,
                                value: Float = 0.1) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData else { throw Failure(description: "Test audio allocation failed.") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { samples[0][index] = value }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        try file?.write(from: buffer)
        file = nil
    }

    /// The whole audio file at `url` (a rendered speech fixture, say) as 16 kHz mono Float32 samples.
    public static func mono16k(_ url: URL) throws -> [Float] {
        let input = try AVAudioFile(forReading: url)
        guard let whole = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                           frameCapacity: AVAudioFrameCount(input.length)) else {
            throw Failure(description: "Cannot allocate a buffer for \(url.lastPathComponent).")
        }
        try input.read(into: whole)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw Failure(description: "Cannot convert \(url.lastPathComponent) to 16 kHz mono.")
        }
        let capacity = AVAudioFrameCount((Double(whole.frameLength) * 16_000 / input.processingFormat.sampleRate)
            .rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure(description: "Cannot allocate the 16 kHz buffer.")
        }
        // The converter calls the input block synchronously inside `convert`: first the whole file, then end of stream.
        final class Delivery { var pending: AVAudioPCMBuffer? }
        let delivery = Delivery()
        delivery.pending = whole
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            let next = delivery.pending
            delivery.pending = nil
            inputStatus.pointee = next == nil ? .endOfStream : .haveData
            return next
        }
        if let conversionError { throw conversionError }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw Failure(description: "Converting \(url.lastPathComponent) failed.")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
