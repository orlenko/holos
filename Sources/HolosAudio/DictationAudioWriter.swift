import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import os

/// Writes one dictation's microphone audio, the frames the recognizer was given, to the history's partial audio file
/// (`DictationHistoryStore.partialAudioURL(for:)`): AAC, mono, 16 kHz, about 32 kbit/s, 0600 in the private audio
/// folder (docs/design.md "Dictation audio and Run Again"). Frames are converted and encoded on a queue of its own, so
/// the capture path only hands them over. The file is made on the first frame, so a dictation that heard nothing
/// leaves none; `finish` closes it for the history to rename and link, `discard` deletes it. Nothing is logged but
/// failures, never audio or text.
public final class DictationAudioWriter: DictationAudioRecording, @unchecked Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "history")
    public let url: URL
    private let store: DictationHistoryStore
    private let queue = DispatchQueue(label: "ca.orlenko.holos.dictation-audio", qos: .utility)
    // Confined to `queue`:
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false
    private var ended = false

    /// The writer for dictation `id`'s audio in `store`.
    public init(store: DictationHistoryStore, id: UUID) {
        self.store = store
        url = store.partialAudioURL(for: id)
    }

    /// The file's format: AAC, mono, `HistoryAudio.sampleRate`, `HistoryAudio.bitRate`.
    public static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: HistoryAudio.sampleRate, AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: HistoryAudio.bitRate]
    }

    /// Queues a frame the recognizer was given (Float32, interleaved, any rate and channel count).
    public func append(_ frame: PCMFrame) {
        queue.async { [self] in
            guard !ended, !failed, frame.frameCount > 0 else { return }
            do {
                try write(frame)
            } catch {
                Self.log.error("Dictation audio could not be written: \(error.localizedDescription, privacy: .public)")
                failed = true
            }
        }
    }

    public func finish() -> DictationHistoryStore.FinishedAudio? {
        queue.sync { [self] in
            guard !ended else { return nil }
            ended = true
            if !failed, file != nil {
                do {
                    try flushConverter()
                } catch {
                    Self.log.error("Dictation audio could not be finished: \(error.localizedDescription, privacy: .public)")
                    failed = true
                }
            }
            file?.close()
            let wrote = file != nil
            file = nil
            converter = nil
            let seconds = Double(framesWritten) / HistoryAudio.sampleRate
            guard wrote, !failed, seconds > 0 else {
                if wrote { try? DictationHistoryStore.removeAudioFile(url) }
                return nil
            }
            return DictationHistoryStore.FinishedAudio(partial: url, seconds: seconds)
        }
    }

    public func discard() {
        queue.sync { [self] in
            ended = true
            file?.close()
            let wrote = file != nil
            file = nil
            converter = nil
            if wrote { try? DictationHistoryStore.removeAudioFile(url) }
        }
    }

    // MARK: - On the queue

    private func write(_ frame: PCMFrame) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.sampleRate,
                                         channels: AVAudioChannelCount(frame.channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let channels = buffer.floatChannelData else {
            throw HolosError.invalidInput("Unsupported audio frame.")
        }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        for channel in 0..<frame.channels {
            for index in 0..<frame.frameCount {
                channels[channel][index] = frame.samples[index * frame.channels + channel]
            }
        }
        let file = try openFile()
        if let inputFormat, inputFormat != format {
            // The input changed (another microphone): what the old converter holds is written first.
            try flushConverter()
        }
        if converter == nil || inputFormat != format {
            guard let made = AVAudioConverter(from: format, to: file.processingFormat) else {
                throw HolosError.invalidInput("No converter for this audio format.")
            }
            made.downmix = true
            converter = made
            inputFormat = format
        }
        try convert(buffer, endOfStream: false)
    }

    private func openFile() throws -> AVAudioFile {
        if let file { return file }
        try store.prepareAudioFolder()
        try DictationHistoryStore.removeAudioFile(url)
        let made = try AVAudioFile(forWriting: url, settings: Self.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard chmod(url.path, 0o600) == 0 else {
            made.close()
            try? DictationHistoryStore.removeAudioFile(url)
            throw HolosError.io("Cannot make the dictation audio private: \(String(cString: strerror(errno))).")
        }
        file = made
        return made
    }

    /// Converts `input` (nil: drains what the converter holds) and writes what comes out.
    private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool) throws {
        guard let converter, let file else { return }
        let output = file.processingFormat
        let ratio = output.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 4_096
        var given = false
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw HolosError.io("Cannot allocate an audio buffer.")
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, status in
                if let input, !given {
                    given = true
                    status.pointee = .haveData
                    return input
                }
                status.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw error ?? HolosError.io("The audio could not be converted.") }
            if buffer.frameLength > 0 {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            }
            // Full output buffers mean more may be waiting; otherwise the input is used up (or the stream ended).
            if status == .haveData, buffer.frameLength == buffer.frameCapacity { continue }
            return
        }
    }

    private func flushConverter() throws {
        guard converter != nil else { return }
        try convert(nil, endOfStream: true)
        converter = nil
        inputFormat = nil
    }
}

/// A saved dictation's audio as the frames live dictation gives the recognizer: Float32, in 0.1 s pieces on a
/// timeline starting at 0.
public enum DictationAudioFile {
    public static func frames(of url: URL, pieceSeconds: Double = 0.1) throws -> [PCMFrame] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let step = AVAudioFrameCount(max(1, (rate * pieceSeconds).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) else {
            throw HolosError.io("Cannot allocate an audio buffer.")
        }
        var frames: [PCMFrame] = []
        var position = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: step)
            guard buffer.frameLength > 0 else { break }
            frames.append(try PCMConversion.copy(buffer, startTime: Double(position) / rate))
            position += Int(buffer.frameLength)
        }
        return frames
    }

    /// How long the file plays, in seconds.
    public static func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
