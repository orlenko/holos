import AVFoundation
import Foundation
import HolosCore
import HolosSynthesis
import os

/// A PCM buffer read off the main actor, handed to it (only the main actor uses it after).
final class ReadPart: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// A part that could not be read, and whether it is no longer there.
private struct ReadFailure: Error {
    let reason: String
    let gone: Bool
}

/// Plays a reading while it is being made (docs/design.md "Reading section"): its parts in order from the first, each
/// after the silence the finished file puts before it, read into memory a few parts ahead and queued on a
/// `ReadingSegmentOutput`. Its timeline is the finished file's, frame for frame (`ReadingAudioFormat.silenceFrames`).
///
/// Invariants:
/// 1. Parts are queued in order, at most `window` of them queued and not yet played; nothing is queued once making has
///    finished (invariant 4) or the playback has ended. A part is queued once, unless a change of audio device lost it:
///    then it and those after it are queued again, from the start of the part being heard, paused.
/// 2. `isPlaying` means engaged: true from `play` until `pause`, `stop`, or the end, also while it waits for a part
///    that is not made yet (`isWaiting`). Run dry, the output is stopped, so its count of played frames starts again
///    from where the parts end (`base`).
/// 3. `onEnd` is called once: `.finished` once the last part has played and making has finished, `.failed` once the made parts have played
///    after making failed (or a part could not be read), `.stopped` once making was stopped; never after `stop`.
/// 5. A seek goes anywhere in what is made: what is queued is dropped, and the part holding that place is queued from
///    there. Playing or paused stays as it was. Once making has finished, the finished file takes over at that place.
/// 4. Once making has finished, what is not queued yet plays from the finished file: at the end of the parts queued
///    (the start of the next part's silence), `onHandoff` gives that place in seconds. Until `stop`, play and pause
///    only change whether the file is to play (`isPlaying`), with no error.
@MainActor
public final class PartQueuePlayback {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")
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
    /// The parts queued and not played yet, with their frames and the silence before them, and the frames of those
    /// played since `base`: what a change of audio device goes back to.
    private var unheard: [(index: Int, frames: Int64)] = []
    private var heardFrames: Int64 = 0
    /// Counts the changes of audio device and the seeks, so a part read before one is not queued after it.
    private var run = 0
    /// Where a seek lands in the part it lands in, in frames of that part, until that part is queued.
    private var landing: (index: Int, frames: Int64)?
    /// The same, while that part is queued: it is what a change of audio device goes back to.
    private var landed: (index: Int, frames: Int64)?
    /// A place asked for before the first part was read: nothing tells frames from seconds until then.
    private var pendingSeek: TimeInterval?
    /// Where the finished file is to play from: the latest place asked for while it opens.
    private(set) var handoverPlace: TimeInterval?

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
        if let handoverPlace { return handoverPlace }
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
        if next >= total {
            // All heard, and making may yet fail joining them: its outcome is the end, told, never assumed. It stays
            // loaded meanwhile (invariant 2), and the feed comes back here.
            switch feed.end {
            case .failed(let reason)?: return end(.failed("The reading could not be finished: \(reason)"))
            case .stopped?: return end(.stopped)
            case .finished?: return end(.finished)
            case nil:
                Self.log.notice("All \(total) parts heard; waiting for the reading to be finished")
                onChange?()
                return
            }
        }
        switch feed.end {
        case .failed(let reason)?:
            end(.failed("Playback stopped at part \(next + 1) of \(total): \(reason)"))
        case .stopped?:
            end(.stopped)
        case .finished?, nil:
            // Waiting for the next part (invariant 2).
            Self.log.notice("Waiting for part \(self.next + 1) of \(total); made in order: \(self.feed.madeInOrder), missing: \(self.missing)")
            onChange?()
        }
    }

    private func readAndQueue(_ part: ReadingMadePart) {
        reading = true
        let read = self.read
        let asked = run
        Task { [weak self] in
            // Read and, when that fails, looked for off the main actor: the cache can be on a drive that hangs.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ReadPart, ReadFailure> in
                do {
                    return .success(try read(part.audio))
                } catch {
                    return .failure(ReadFailure(reason: error.localizedDescription,
                                                gone: (try? ReadingOutput.exists(part.audio)) == false))
                }
            }.value
            guard let self, !self.done, !self.handingOver, asked == self.run else { return }
            self.reading = false
            switch result {
            case .success(let read):
                do {
                    try self.queue(read.buffer, silence: part.silenceBefore, index: part.index)
                } catch {
                    let reason = error.localizedDescription
                    return self.end(.failed("Part \(part.index + 1) could not be played: \(reason)"))
                }
                if let place = self.pendingSeek {
                    self.pendingSeek = nil
                    return self.seek(to: place)
                }
            case .failure(let failure):
                // Gone from the cache: the reading was published meanwhile (or making failed); its end says which.
                Self.log.notice("Part \(part.index + 1) could not be read (gone: \(failure.gone)): \(failure.reason, privacy: .public)")
                guard failure.gone else {
                    return self.end(.failed("Part \(part.index + 1) could not be read: \(failure.reason)"))
                }
                self.missing = true
            }
            self.fill()
        }
    }

    private func queue(_ whole: AVAudioPCMBuffer, silence seconds: Double, index: Int) throws {
        let rate = self.rate ?? whole.format.sampleRate
        self.rate = rate
        // A seek lands inside this part: no silence, and the audio from there.
        let lands = landing?.index == index ? landing?.frames : nil
        landed = lands.map { (index, $0) }
        landing = nil
        let silence = lands == nil ? ReadingAudioFormat.silenceFrames(seconds, rate: rate) : 0
        let buffer = try lands.map { try Self.tail(of: whole, from: $0) } ?? whole
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
        unheard.append((index, silence + Int64(buffer.frameLength)))
        Self.log.notice("Queued part \(index + 1) of \(self.feed.total ?? -1); made in order: \(self.feed.madeInOrder)")
        next += 1
        queued += 1
        if engaged { try output.play() }
        if queued == 1 { onChange?() }
    }

    /// `buffer` from frame `frames` on, at least its last frame.
    private static func tail(of buffer: AVAudioPCMBuffer, from frames: Int64) throws -> AVAudioPCMBuffer {
        guard frames > 0 else { return buffer }
        let skip = min(AVAudioFrameCount(clamping: frames), buffer.frameLength - min(1, buffer.frameLength))
        let length = buffer.frameLength - skip
        guard let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(1, length)),
              let from = buffer.floatChannelData, let to = tail.floatChannelData else {
            throw HolosError.io("The place in a part could not be found.")
        }
        tail.frameLength = length
        for channel in 0..<Int(buffer.format.channelCount) {
            to[channel].update(from: from[channel] + Int(skip), count: Int(length))
        }
        return tail
    }

    private func played() {
        guard !done, !handingOver else { return }
        queued -= 1
        if !unheard.isEmpty {
            let part = unheard.removeFirst()
            heardFrames += part.frames
            if landed?.index == part.index { landed = nil }
        }
        if queued == 0 {
            // Run dry (invariant 2): the count of played frames starts again where the parts queued end.
            output.stop()
            base += queuedFrames
            queuedFrames = 0
            heardFrames = 0
        }
        fill()
    }

    private func handOff() {
        handOff(at: Double(base + queuedFrames) / (rate ?? ReadingAudioFormat.sampleRate))
    }

    private func handOff(at place: TimeInterval) {
        handingOver = true
        handoverPlace = place
        feed.onChange = nil
        output.onInterrupted = nil
        output.stop()
        onHandoff?(place)
    }

    private func end(_ end: End) {
        stop()
        onEnd?(end)
    }

    /// The audio device changed and the engine lost what was queued: paused at the start of the part being heard, and
    /// Play queues it and the rest again (invariant 1).
    private func interrupted() {
        guard !done, !handingOver else { return }
        engaged = false
        output.stop()
        base += heardFrames
        heardFrames = 0
        queuedFrames = 0
        next = unheard.first?.index ?? next
        // The part a seek landed in goes back to that place, which `base` already is.
        let back = landed.flatMap { $0.index == next ? $0 : nil }
        dropQueued()
        landing = back
        onChange?()
    }

    private func dropQueued() {
        unheard = []
        queued = 0
        missing = false
        reading = false
        landing = nil
        landed = nil
        run += 1
    }

    /// Invariant 5.
    public func seek(to time: TimeInterval) {
        guard !done else { return }
        if handingOver {
            handoverPlace = time
            onChange?()
            return
        }
        guard let rate else {
            pendingSeek = time
            return
        }
        // Once it is made its parts go: the finished file has every place.
        if case .finished? = feed.end { return handOff(at: time) }
        let made = feed.madeInOrder
        let target = Int64(max(0, time) * rate)
        var start: Int64 = 0
        var found: (index: Int, audio: Int64)?
        for index in 0..<made {
            guard let part = feed.parts[index] else { break }
            let audio = start + ReadingAudioFormat.silenceFrames(part.silenceBefore, rate: rate)
            let end = audio + Int64((part.duration * rate).rounded())
            found = (index, audio)
            if target < end { break }
            start = end
        }
        guard let found else { return }
        output.stop()
        dropQueued()
        queuedFrames = 0
        heardFrames = 0
        next = found.index
        // A place in the silence before a part is that part's start.
        let frames = max(0, target - found.audio)
        base = found.audio + frames
        landing = (found.index, frames)
        fill()
        onChange?()
    }
}

extension PartQueuePlayback: @MainActor ReadingPlayback {
    public var isPlaying: Bool { engaged }

}
