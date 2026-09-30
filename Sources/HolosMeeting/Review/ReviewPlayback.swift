import Foundation

/// The review window's playback speeds (docs/meeting-design.md §5.10): 1×, 1.25×, 1.5×, and 2×, remembered across
/// windows and launches.
public enum ReviewPlaybackSpeed {
    public static let rates: [Double] = [1, 1.25, 1.5, 2]
    /// UserDefaults key; the value is one of `rates`, and anything else (or nothing) means 1×.
    public static let key = "reviewPlaybackRate"

    /// `saved` when it is one of `rates`, else 1.
    public static func rate(saved: Any?) -> Double {
        guard let number = saved as? NSNumber else { return 1 }
        let value = number.doubleValue
        return rates.contains(value) ? value : 1
    }

    public static func load(from defaults: UserDefaults) -> Double {
        rate(saved: defaults.object(forKey: key))
    }

    /// Saves `rate` when it is one of `rates`; anything else is ignored.
    public static func save(_ rate: Double, to defaults: UserDefaults) {
        guard rates.contains(rate) else { return }
        defaults.set(rate, forKey: key)
    }

    /// "1×", "1.25×", "1.5×", "2×".
    public static func title(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}

/// Where playback is in a meeting's turns and words, and where ⌘← and ⌘→ go (docs/meeting-design.md §5.10). Pure.
public enum ReviewTimeline {
    /// A word counts as reached this much before its start: a seek to a word's start lands on a millisecond, which
    /// may round just below it.
    public static let wordTolerance = 0.01
    /// ⌘← within this many seconds of a turn's start goes to the turn before it rather than back to that start.
    public static let previousGrace = 1.5
    /// ⌘→ skips turns starting within this many seconds after the play head (the turn just jumped to).
    public static let nextSkip = 0.05

    /// The turn being spoken at `time`: of the turns with start ≤ time < end, the one that started last (a reply
    /// that overlaps wins over the turn it interrupts; ties go to the later turn in the list). Nil in silence.
    public static func turnIndex(at time: Double, turns: [(start: Double, end: Double)]) -> Int? {
        var found: Int?
        for (index, turn) in turns.enumerated() where turn.start <= time && time < turn.end {
            if let current = found, turns[current].start > turn.start { continue }
            found = index
        }
        return found
    }

    /// The word being spoken at `time`: the last word (in text order) whose start is at or before it. Nil before the
    /// first word.
    public static func wordIndex(at time: Double, starts: [Double]) -> Int? {
        var found: Int?
        for (index, start) in starts.enumerated() where start <= time + wordTolerance { found = index }
        return found
    }

    /// Where ⌘→ goes: the earliest turn start after `time` (skipping starts within `nextSkip`); nil after the last.
    public static func nextTurnStart(after time: Double, starts: [Double]) -> Double? {
        starts.filter { $0.isFinite && $0 > time + nextSkip }.min()
    }

    /// Where ⌘← goes: the start of the latest turn started at `time`, or the start just before it when the play head
    /// is within `previousGrace` of that start (so pressing it again keeps going back); 0 before the first turn.
    public static func previousTurnStart(before time: Double, starts: [Double]) -> Double {
        let sorted = starts.filter(\.isFinite).sorted()
        guard let current = sorted.last(where: { $0 <= time }) else { return 0 }
        if time - current >= previousGrace { return current }
        return sorted.last { $0 < current } ?? 0
    }
}

/// Each word of a turn in the text the window shows for it, for clicking a word and tinting the one playing. Pure.
public enum ReviewWordRanges {
    /// How far past the previous word (in UTF-16 units, besides the word's own length) a word is looked for: the
    /// shown text puts at most spaces and punctuation between consecutive words.
    public static let slack = 40

    /// Each word's UTF-16 range in `text`, found in order (each after the one before), or nil for a word not found
    /// near there. Exact matches first, then ignoring case and diacritics.
    public static func ranges(of words: [String], in text: String) -> [NSRange?] {
        let shown = text as NSString
        var cursor = 0
        var ranges: [NSRange?] = []
        ranges.reserveCapacity(words.count)
        for word in words {
            let needle = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, cursor < shown.length else {
                ranges.append(nil)
                continue
            }
            let window = NSRange(location: cursor,
                                 length: min(shown.length - cursor, (needle as NSString).length + slack))
            var found = shown.range(of: needle, options: .literal, range: window)
            if found.location == NSNotFound {
                found = shown.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: window)
            }
            if found.location == NSNotFound || found.length == 0 {
                ranges.append(nil)
            } else {
                ranges.append(found)
                cursor = NSMaxRange(found)
            }
        }
        return ranges
    }

    /// The word a click on UTF-16 offset `index` plays from: the word containing it, else the last word before it
    /// (a space or a punctuation mark after a word), else the first word. Nil when no word was found in the text.
    public static func word(at index: Int, ranges: [NSRange?]) -> Int? {
        var first: Int?
        var before: Int?
        for (word, range) in ranges.enumerated() {
            guard let range else { continue }
            if first == nil { first = word }
            guard range.location <= index else { break }
            before = word
        }
        return before ?? first
    }
}

/// Whether the turn list follows playback (docs/meeting-design.md §5.10): it does, except for `resumeAfter` seconds
/// after the reader last scrolled it themselves; playing, clicking a word or a timestamp, or ⌘← / ⌘→ follow again at
/// once. Times are any monotonic clock in seconds. Pure.
public struct ReviewFollow: Sendable, Equatable {
    public static let resumeAfter: Double = 5

    /// When the reader last scrolled the turns, until following resumes.
    public private(set) var scrolledAt: Double?

    public init() {}

    /// The reader scrolled the turns (a wheel, a trackpad, or the scroller); scrolling done by the window is not this.
    public mutating func userScrolled(at now: Double) {
        scrolledAt = now
    }

    /// The reader chose where to listen (Play, a word, a timestamp, ⌘← / ⌘→): follow again now.
    public mutating func resume() {
        scrolledAt = nil
    }

    /// The list should keep the playing turn in view at `now`.
    public func isFollowing(at now: Double) -> Bool {
        guard let scrolledAt else { return true }
        // A clock that went backwards resumes rather than waits forever.
        return now < scrolledAt || now - scrolledAt >= Self.resumeAfter
    }
}

/// What VoiceOver hears while a meeting plays: only who speaks, once when the speaker changes (never every turn or
/// word, which would talk over the audio). Pure.
public struct ReviewSpeakerAnnouncer: Sendable, Equatable {
    private var last: String?

    public init() {}

    /// The announcement for `speaker` now playing (nil in silence), or nil when there is nothing new to say.
    public mutating func announcement(for speaker: String?) -> String? {
        guard let speaker else { return nil }
        guard speaker != last else { return nil }
        last = speaker
        return speaker
    }

    /// Playback stopped: the next speaker heard is announced even when it is the same one.
    public mutating func reset() {
        last = nil
    }
}
