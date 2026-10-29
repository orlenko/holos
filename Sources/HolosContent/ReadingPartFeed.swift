import Foundation
import HolosSynthesis

/// A part of a reading being made, rendered and checked: what playing the reading before it is finished needs
/// (`ReadingPipeline.render`'s `partMade`).
public struct ReadingMadePart: Sendable, Equatable {
    /// Counted from 0.
    public let index: Int
    /// How many parts the reading has.
    public let total: Int
    /// Its PCM file in the reading's cache. The pipeline removes it once the finished file is published.
    public let audio: URL
    public let duration: Double
    /// The silence before it in the finished file (`ReadingAudioFormat.silenceBefore`).
    public let silenceBefore: Double

    public init(index: Int, total: Int, audio: URL, duration: Double, silenceBefore: Double) {
        self.index = index
        self.total = total
        self.audio = audio
        self.duration = duration
        self.silenceBefore = silenceBefore
    }

    /// Part `part` of a manifest whose cache is `directory`.
    init(_ part: ReadingPart, of total: Int, in directory: URL) {
        self.init(index: part.index, total: total, audio: directory.appendingPathComponent(part.relativeAudioPath),
                  duration: part.duration ?? 0,
                  silenceBefore: ReadingAudioFormat.silenceBefore(part: part.index, startsSection: part.startsSection))
    }
}

/// The parts of one reading as they are made, so it can play before it is finished (docs/design.md "Reading
/// section").
///
/// Invariants:
/// 1. `parts` only grows: a part is added once, by its index; one added again is ignored. All share one `total`.
/// 2. `end` is set once, and nothing is added after it.
/// 3. `onChange` is called after every change, and only then.
@MainActor
public final class ReadingPartFeed {
    /// How making the reading ended.
    public enum End: Equatable, Sendable {
        /// Every part is made and the finished file is published.
        case finished
        /// Making it failed: what to tell (a sentence).
        case failed(String)
        /// Making it was stopped.
        case stopped
    }

    public private(set) var parts: [Int: ReadingMadePart] = [:]
    /// How many parts the reading has; nil until the first is made.
    public private(set) var total: Int?
    public private(set) var end: End?
    /// A part was added, or making ended.
    public var onChange: (() -> Void)?

    public init() {}

    /// Invariants 1 and 2.
    public func add(_ part: ReadingMadePart) {
        guard end == nil, parts[part.index] == nil, total == nil || total == part.total else { return }
        parts[part.index] = part
        total = part.total
        onChange?()
    }

    /// Invariant 2.
    public func finish(_ end: End) {
        guard self.end == nil else { return }
        self.end = end
        onChange?()
    }

    /// How many parts are made from the first on, with none missing between them: those that can play in order.
    public var madeInOrder: Int {
        var count = 0
        while parts[count] != nil { count += 1 }
        return count
    }

    /// Every part is made.
    public var isComplete: Bool { total.map { madeInOrder == $0 } ?? false }

    /// The length of the parts made in order, with the silence before each, as in the finished file.
    public var madeDuration: Double {
        (0..<madeInOrder).reduce(0) { sum, index in
            sum + (parts[index].map { $0.silenceBefore + $0.duration } ?? 0)
        }
    }
}
