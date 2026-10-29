import AVFoundation
import Foundation
import HolosCore
import HolosSynthesis

/// A PCM buffer read off the main actor, handed to it (only the main actor uses it after).
final class ReadPart: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Plays a reading while it is being made (docs/design.md "Reading section"): its parts in order from the first, each
/// after the silence the finished file puts before it, read into memory a few parts ahead and queued on a
/// `ReadingSegmentOutput`. Its timeline is the finished file's, frame for frame (`ReadingAudioFormat.silenceFrames`).
///
/// Invariants:
/// 1. Parts are queued in order, each once, at most `window` of them queued and not yet played; nothing is queued
///    once making has finished (invariant 4) or the playback has ended.
/// 2. `isPlaying` means engaged: true from `play` until `pause`, `stop`, or the end, also while it waits for a part
///    that is not made yet (`isWaiting`). Run dry, the output is stopped, so its count of played frames starts again
///    from where the parts end (`base`).
/// 3. `onEnd` is called once: `.finished` once the last part has played, `.failed` once the made parts have played
///    after making failed (or a part could not be read), `.stopped` once making was stopped; never after `stop`.
/// 4. Once making has finished, what is not queued yet plays from the finished file: at the end of the parts queued
///    (the start of the next part's silence), `onHandoff` gives that place in seconds. Until `stop`, play and pause
///    only change whether the file is to play (`isPlaying`), with no error.
@MainActor
public final class PartQueuePlayback {
    public enum End: Equatable, Sendable {
        case finished
        case failed(String)
        case stopped
    }

    /// How many parts are read into memory and queued ahead of the one playing.
    nonisolated static let window = 2

    private let feed: ReadingPartFeed
    private let output: any ReadingSegmentOutput
    private let read: @Sendable (URL) throws -> ReadPart
    /// The next part to queue.
    private(set) var next = 0
    /// Parts queued and not played yet.
    private var queued = 0
    private var engaged = false
    /// A part is being read.
    private var reading = false
    /// The part `next` was not found where it was made: wait for making to end (it was published, or it failed).
    private var missing = false
    private var done = false
    /// Handed over (invariant 4): the finished file is being opened.
    private var handingOver = false
    /// The parts' rate, from the first read.
    private var rate: Double?
    /// The timeline frame where the output's count of played frames starts (invariant 2), and the frames queued since.
    private var base: Int64 = 0
    private var queuedFrames: Int64 = 0

    var onEnd: ((End) -> Void)?
    var onHandoff: ((TimeInterval) -> Void)?
    /// It started or stopped waiting for a part.
    var onChange: (() -> Void)?

    init(feed: ReadingPartFeed, output: any ReadingSegmentOutput,
         read: @escaping @Sendable (URL) throws -> ReadPart = PartQueuePlayback.readPart) {
        self.feed = feed
        self.output = output
        self.read = read
        feed.onChange = { [weak self] in self?.fill() }
        output.onInterrupted = { [weak self] in self?.interrupted() }
    }

    /// The whole part file, as floats (its processing format).
    nonisolated static let readPart: @Sendable (URL) throws -> ReadPart = { url in
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw HolosError.io("The part \(url.lastPathComponent) is too long to play.")
        }
        try file.read(into: buffer)
        return ReadPart(buffer)
    }

    public var isWaiting: Bool { engaged && queued == 0 && !done }

    /// Every part is made, so the length is the finished file's.
    public var isDurationFinal: Bool { feed.isComplete }

    public func play() -> Bool {
        guard !done else { return false }
        engaged = true
        if handingOver {
            onChange?()
            return true
        }
        if queued > 0 {
            do { try output.play() } catch { return false }
        }
        fill()
        onChange?()
        return true
    }

    public func pause() {
        engaged = false
        if !handingOver { output.pause() }
        onChange?()
    }

    public func stop() {
        engaged = false
        done = true
        feed.onChange = nil
        output.onInterrupted = nil
        output.stop()
    }

    public var currentTime: TimeInterval {
        guard let rate else { return 0 }
        return Double(base + min(output.playedFrames, queuedFrames)) / rate
    }

    public var duration: TimeInterval { feed.madeDuration }

    /// Queues what can be queued (invariant 1), or ends, hands off, or waits once nothing is left to queue.
    private func fill() {
        guard !done, !handingOver, !reading else { return }
        let total = feed.total ?? Int.max
        if case .finished? = feed.end, next < total {
            // Invariant 4: the rest comes from the finished file once the parts queued have played.
            if queued == 0 { handOff() }
            return
        }
        if !missing, next < feed.madeInOrder, queued < Self.window, let part = feed.parts[next] {
            return readAndQueue(part)
        }
        guard queued == 0 else { return }
        if next >= total { return end(.finished) }
        switch feed.end {
        case .failed(let reason)?:
            end(.failed("Playback stopped at part \(next + 1) of \(total): \(reason)"))
        case .stopped?:
            end(.stopped)
        case .finished?, nil:
            // Waiting for the next part (invariant 2).
            onChange?()
        }
    }

    private func readAndQueue(_ part: ReadingMadePart) {
        reading = true
        let read = self.read
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try read(part.audio) } }.value
            guard let self, !self.done, !self.handingOver else { return }
            self.reading = false
            switch result {
            case .success(let read):
                do {
                    try self.queue(read.buffer, silence: part.silenceBefore)
                } catch {
                    let reason = error.localizedDescription
                    return self.end(.failed("Part \(part.index + 1) could not be played: \(reason)"))
                }
            case .failure(let error):
                // Gone from the cache: the reading was published meanwhile (or making failed); its end says which.
                guard (try? ReadingOutput.exists(part.audio)) == false else {
                    return self.end(.failed("Part \(part.index + 1) could not be read: \(error.localizedDescription)"))
                }
                self.missing = true
            }
            self.fill()
        }
    }

    private func queue(_ buffer: AVAudioPCMBuffer, silence seconds: Double) throws {
        let rate = self.rate ?? buffer.format.sampleRate
        self.rate = rate
        let silence = ReadingAudioFormat.silenceFrames(seconds, rate: rate)
        if silence > 0 {
            guard let gap = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(silence)) else {
                throw HolosError.io("The silence before a part could not be made.")
            }
            gap.frameLength = AVAudioFrameCount(silence)
            for channel in 0..<Int(gap.format.channelCount) {
                gap.floatChannelData?[channel].update(repeating: 0, count: Int(silence))
            }
            try output.schedule(gap) {}
        }
        try output.schedule(buffer) { [weak self] in self?.played() }
        queuedFrames += silence + Int64(buffer.frameLength)
        next += 1
        queued += 1
        if engaged { try output.play() }
        if queued == 1 { onChange?() }
    }

    private func played() {
        guard !done, !handingOver else { return }
        queued -= 1
        if queued == 0 {
            // Run dry (invariant 2): the count of played frames starts again where the parts queued end.
            output.stop()
            base += queuedFrames
            queuedFrames = 0
        }
        fill()
    }

    private func handOff() {
        let place = Double(base + queuedFrames) / (rate ?? ReadingAudioFormat.sampleRate)
        handingOver = true
        feed.onChange = nil
        output.onInterrupted = nil
        output.stop()
        onHandoff?(place)
    }

    private func end(_ end: End) {
        stop()
        onEnd?(end)
    }

    /// The audio device changed and the engine stopped: paused where it was, what is queued kept for Play.
    private func interrupted() {
        guard !done, !handingOver, engaged else { return }
        engaged = false
        output.pause()
        onChange?()
    }
}

extension PartQueuePlayback: @MainActor ReadingPlayback {
    public var isPlaying: Bool { engaged }

    /// Not offered while the reading is being made.
    public func seek(to time: TimeInterval) {}
}
