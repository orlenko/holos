import AVFoundation
import Foundation
import HolosCore

/// Brings meeting audio to the recording format, 48 kHz mono (docs/meeting-design.md §4.5), before it is saved or
/// transcribed.
///
/// ScreenCaptureKit already delivers 48 kHz mono, but AVAudioEngine's microphone input keeps the device's own format
/// (a stereo interface, or 96 kHz), which would take up to 4× the disk the start check budgeted. Channels are
/// averaged; another sample rate is resampled with one `AVAudioConverter` per track, whose filter state carries from
/// frame to frame. Output frames of a resampled run are timed by the samples produced since the run's first frame, so
/// they are contiguous. A frame that does not follow its track's previous one (a gap or overlap beyond
/// `FrameContinuity.tolerance`, a drop, or a new sample rate) starts a new run; what the old converter still held
/// (its look-ahead, about 15 ms, right before the gap) is left out. `flush()` returns that look-ahead when the
/// capture ends.
///
/// Not thread-safe: one consumer uses it for one capture epoch.
public final class RecordingFormatConverter {
    public static let sampleRate = 48_000.0

    private struct Run {
        let sourceRate: Double
        let converter: AVAudioConverter
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        /// Session time of the run's first output sample.
        let anchor: Double
        /// Output frames produced so far.
        var produced: Int64 = 0
        /// Where the next input frame should start.
        var expectedInput: Double
        /// A frame marked `followsDrop` produced no output yet: the next output carries the mark.
        var pendingDrop = false
    }

    private var runs: [String: Run] = [:]

    public init() {}

    /// `audio` at 48 kHz mono, or nil while the resampler holds all of it back (its filter needs more input). Frames
    /// already in the format come back unchanged.
    public func convert(_ audio: CapturedAudio) throws -> CapturedAudio? {
        let frame = audio.frame
        let mono = try Self.mono(frame)
        if frame.sampleRate == Self.sampleRate {
            runs[audio.track] = nil
            if frame.channels == 1 { return audio }
            return CapturedAudio(track: audio.track, frame: mono, followsDrop: audio.followsDrop)
        }
        var run: Run
        if let existing = runs[audio.track], existing.sourceRate == frame.sampleRate, !audio.followsDrop,
           abs(frame.startTime - existing.expectedInput) < FrameContinuity.tolerance {
            run = existing
        } else {
            run = try Self.makeRun(sourceRate: frame.sampleRate, start: frame.startTime)
            run.pendingDrop = audio.followsDrop
        }
        run.expectedInput = frame.startTime + frame.duration
        let output = try Self.resample(mono, with: run)
        let start = run.anchor + Double(run.produced) / Self.sampleRate
        run.produced += Int64(output.count)
        guard !output.isEmpty else {
            runs[audio.track] = run
            return nil
        }
        let followsDrop = run.pendingDrop
        run.pendingDrop = false
        runs[audio.track] = run
        return CapturedAudio(track: audio.track,
                             frame: try PCMFrame(samples: output, sampleRate: Self.sampleRate, channels: 1,
                                                 startTime: start),
                             followsDrop: followsDrop)
    }

    /// What each track's resampler still holds (its filter's look-ahead, about 15 ms), as one last frame per track,
    /// when the capture ends. Every track starts over afterwards.
    public func flush() throws -> [CapturedAudio] {
        defer { runs.removeAll() }
        var flushed: [CapturedAudio] = []
        for (track, run) in runs.sorted(by: { $0.key < $1.key }) {
            let samples = try Self.drain(run.converter, into: run.outputFormat, capacity: 8_192, input: nil)
            guard !samples.isEmpty else { continue }
            let start = run.anchor + Double(run.produced) / Self.sampleRate
            flushed.append(CapturedAudio(track: track,
                                         frame: try PCMFrame(samples: samples, sampleRate: Self.sampleRate,
                                                             channels: 1, startTime: start),
                                         followsDrop: run.pendingDrop))
        }
        return flushed
    }

    /// Channels averaged.
    static func mono(_ frame: PCMFrame) throws -> PCMFrame {
        guard frame.channels > 1 else { return frame }
        let channels = frame.channels
        var samples = [Float](repeating: 0, count: frame.frameCount)
        frame.samples.withUnsafeBufferPointer { source in
            for index in 0..<samples.count {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[index * channels + channel] }
                samples[index] = sum / Float(channels)
            }
        }
        return try PCMFrame(samples: samples, sampleRate: frame.sampleRate, channels: 1, startTime: frame.startTime)
    }

    private static func makeRun(sourceRate: Double, start: Double) throws -> Run {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw HolosError.unavailable("Cannot convert \(Int(sourceRate)) Hz microphone audio to 48 kHz.")
        }
        return Run(sourceRate: sourceRate, converter: converter, inputFormat: input, outputFormat: output,
                   anchor: start, expectedInput: start)
    }

    /// Feeds `frame` (mono, at the run's rate) to the run's converter and returns everything it produces now.
    private static func resample(_ frame: PCMFrame, with run: Run) throws -> [Float] {
        guard frame.frameCount > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: run.inputFormat, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let data = input.floatChannelData else {
            throw HolosError.io("Cannot allocate audio buffers to convert microphone audio.")
        }
        input.frameLength = AVAudioFrameCount(frame.frameCount)
        frame.samples.withUnsafeBufferPointer { source in
            data[0].update(from: source.baseAddress!, count: frame.frameCount)
        }
        let capacity = Int((Double(frame.frameCount) * sampleRate / run.sourceRate).rounded(.up)) + 1_024
        return try drain(run.converter, into: run.outputFormat, capacity: capacity, input: input)
    }

    /// Runs `converter` until it wants more input: with `input`, it gets that buffer once and then "no data for now",
    /// so it keeps its state for the next frame; with nil, the stream ends and it gives up what it held.
    private static func drain(_ converter: AVAudioConverter, into format: AVAudioFormat, capacity: Int,
                              input: AVAudioPCMBuffer?) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw HolosError.io("Cannot allocate audio buffers to convert microphone audio.")
        }
        let feed = SingleBufferFeed(input)
        var samples: [Float] = []
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                feed.next(status)
            }
            if status == .error {
                throw HolosError.io("Cannot convert microphone audio to 48 kHz: \(conversionError?.localizedDescription ?? "unknown error").")
            }
            if output.frameLength > 0, let converted = output.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: converted[0], count: Int(output.frameLength)))
            }
            // `.inputRanDry`: the converter used the whole frame and keeps its filter tail for the next one.
            if status != .haveData || output.frameLength == 0 { break }
        }
        return samples
    }
}

/// Hands at most one buffer to a converter, then reports no data for now (so the converter keeps its state for the
/// next frame), or the end of the stream when there is no buffer (a flush).
///
/// `@unchecked Sendable`: AVAudioConverter calls the input block synchronously, on the calling thread, inside
/// `convert(to:error:withInputFrom:)`; a feed lives for one `drain` call.
private final class SingleBufferFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private var given = false

    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .endOfStream
            return nil
        }
        guard !given else {
            status.pointee = .noDataNow
            return nil
        }
        given = true
        status.pointee = .haveData
        return buffer
    }
}
