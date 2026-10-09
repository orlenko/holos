import AVFAudio
import AudioToolbox
import Foundation
import HolosCore

/// Mono float samples written as an audio file, a piece at a time: 16-bit PCM in .wav and .caf, AAC (64 kbit/s) in
/// .m4a.
///
/// Invariants:
/// 1. `frames` advances only when a whole `append` has been written: it counts the samples of the appends that
///    succeeded, silence included.
/// 2. Once an append fails or `close()` is called, the writer is done: every later `append` (or `appendSilence`)
///    throws, and the file is the caller's to discard or keep as it is.
/// 3. `close()` finishes the file once; calling it again does nothing.
public final class NaturalSpeechFileWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let sampleRate: Double
    /// The frames written so far (invariant 1).
    public private(set) var frames: Int64 = 0
    /// Whether the writer is done (invariant 2).
    private var done = false
    /// Whether `close()` has run (invariant 3).
    private var closed = false

    public init(url: URL, sampleRate: Double) throws {
        let fileExtension = url.pathExtension.lowercased()
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
        switch fileExtension {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 64_000
            settings[AVAudioFileTypeKey] = kAudioFileM4AType
        case "wav", "caf":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVAudioFileTypeKey] = fileExtension == "wav" ? kAudioFileWAVEType : kAudioFileCAFType
        default:
            throw HolosError.invalidInput("Unsupported speech output format .\(fileExtension); use wav, caf, or m4a.")
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw HolosError.io("Could not prepare the speech file.")
        }
        self.format = format
        self.sampleRate = sampleRate
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ samples: [Float]) throws {
        guard !done else { throw HolosError.io("The speech file is already finished.") }
        // Invariant 2: a write that fails ends the writer, whatever part of `samples` reached the file.
        done = true
        let chunk = 65_536
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw HolosError.io("Could not prepare the speech file.")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
        frames += Int64(samples.count)
        done = false
    }

    public func appendSilence(seconds: Double) throws {
        var remaining = Int((seconds * sampleRate).rounded())
        while remaining > 0 {
            let count = min(remaining, 65_536)
            try append([Float](repeating: 0, count: count))
            remaining -= count
        }
    }

    /// Finishes the file (an AAC file's last packets are written here); the writer takes no more samples.
    public func close() {
        guard !closed else { return }
        closed = true
        done = true
        file.close()
    }
}

/// A whole file of mono float samples (see `NaturalSpeechFileWriter`).
public enum NaturalSpeechFile {
    public static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let writer = try NaturalSpeechFileWriter(url: url, sampleRate: sampleRate)
        try writer.append(samples)
        writer.close()
    }
}

/// A render's file, written off the main actor: each paragraph is time-stretched to the render's speed
/// (`TimeStretch`) and appended here, then the pause after it.
///
/// Invariants:
/// 1. One writer per sink, used only on this actor; `add` calls run one at a time, in the order they are awaited.
/// 2. `close` finishes the file and returns the frames written; after it every `add` throws (the writer's invariant 2).
actor NaturalSpeechSink {
    private let writer: NaturalSpeechFileWriter
    private let sampleRate: Double

    private init(writer: NaturalSpeechFileWriter, sampleRate: Double) {
        self.writer = writer
        self.sampleRate = sampleRate
    }

    /// Creates the file at `url`, off the main actor; fails when `output` (where it will be published) already exists.
    static func open(_ url: URL, refusing output: URL, sampleRate: Double) async throws -> NaturalSpeechSink {
        try await Task.detached(priority: .userInitiated) {
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw HolosError.invalidInput("Speech output already exists: \(output.path)")
            }
            return NaturalSpeechSink(writer: try NaturalSpeechFileWriter(url: url, sampleRate: sampleRate),
                                     sampleRate: sampleRate)
        }.value
    }

    func add(_ samples: [Float], rate: Double, pauseAfter: Double) throws {
        try writer.append(TimeStretch.apply(samples, sampleRate: sampleRate, rate: rate))
        try writer.appendSilence(seconds: pauseAfter)
    }

    func close() -> Int64 {
        writer.close()
        return writer.frames
    }
}
