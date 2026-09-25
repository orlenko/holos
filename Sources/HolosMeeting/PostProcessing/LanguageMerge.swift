import Foundation
import HolosCore

/// Merges one transcription of a meeting per language into one transcript, choosing the language passage by passage
/// (docs/meeting-design.md §4.14). Pure: no file IO, and the language identification is passed in, so it is tested
/// with synthetic transcripts.
///
/// The rule, validated on a 3 h 43 min bilingual (French and English) meeting against Otter:
/// 1. Each track is merged on its own. Its words are grouped into fixed windows of `windowSeconds` (3 s) of session
///    time from 0, each word by its middle ((start + end) / 2). A segment without timed words moves as one unit, by
///    the middle of its time range.
/// 2. In a window where only one language has words, that language is the window's choice. Where several do, each
///    scores the mean confidence of its words there (words without a confidence left out; 0 when none has one) plus
///    the probability that its text there is in its own language, among the candidate languages (`Scorer`); the
///    highest score wins, and a tie goes to the language listed first.
/// 3. Smoothing: over the windows with words, in time order, the language changes only where `switchWindows` (2)
///    consecutive windows choose the same new language; it changes at the first of them. The track starts in the
///    language of the first such run (the first window's own choice when there is none), so a lone first window does
///    not set it either. Windows without words do not break a run; they carry the previous choice (and keep nothing).
/// 4. A window keeps the words of its language only (none when that language has no words in it). Kept words stay
///    in their own segments: a segment all of whose words are kept is kept whole (same ID, text, and words); a run
///    of kept words from part of a segment becomes a segment of its own, cut from the text at the words' UTF-16
///    offsets. Every segment carries the language it was transcribed in.
///
/// Where two windows of different languages meet, the same spoken word may be kept twice or not at all (each
/// recognizer times it a little differently); the validation's error rates include that.
public enum LanguageMerge {
    public struct Parameters: Sendable, Equatable {
        /// Words are grouped into windows of this many seconds of session time.
        public var windowSeconds: Double
        /// A switch to another language needs this many consecutive windows with words that choose it (1: none).
        public var switchWindows: Int

        public init(windowSeconds: Double = 3, switchWindows: Int = 2) {
            self.windowSeconds = windowSeconds; self.switchWindows = switchWindows
        }

        /// 3 s windows, a switch after 2 agreeing windows.
        public static let v1 = Parameters()
    }

    /// One language's transcription of the whole meeting (every track).
    public struct Candidate: Sendable, Equatable {
        /// A locale identifier, "fr-CA".
        public var language: String
        public var segments: [TranscriptSegment]

        public init(language: String, segments: [TranscriptSegment]) {
            self.language = language; self.segments = segments
        }
    }

    /// The probability, between 0 and 1, that `text` is in each of `languages` (locale identifiers, the candidates'
    /// languages in order), telling only those languages apart. Called only with text that has words.
    public typealias Scorer = (_ text: String, _ languages: [String]) -> [String: Double]

    /// What the merge chose, for the post-processing record and the event journal. Counts only; never text.
    public struct Summary: Sendable, Equatable {
        /// Windows with words in some language, over every track.
        public var windows: Int
        /// Windows whose chosen language is each language.
        public var windowsByLanguage: [String: Int]
        /// Changes of language between one window with words and the next, over every track.
        public var switches: Int
        /// Words kept in each language.
        public var wordsByLanguage: [String: Int]

        public init(windows: Int = 0, windowsByLanguage: [String: Int] = [:], switches: Int = 0,
                    wordsByLanguage: [String: Int] = [:]) {
            self.windows = windows; self.windowsByLanguage = windowsByLanguage; self.switches = switches
            self.wordsByLanguage = wordsByLanguage
        }
    }

    public struct Result: Sendable, Equatable {
        /// The kept segments, in (start, track) order, each with its `language`.
        public var segments: [TranscriptSegment]
        public var summary: Summary
    }

    /// Merges `candidates` (in preference order: the first wins a tie) as the type's rules say. With one candidate,
    /// every word is kept. Candidates with the same language are not told apart by `scorer`; callers pass distinct
    /// languages.
    public static func merge(_ candidates: [Candidate], parameters: Parameters = .v1,
                             scorer: Scorer) -> Result {
        let languages = candidates.map(\.language)
        let windowSeconds = parameters.windowSeconds.isFinite && parameters.windowSeconds > 0
            ? parameters.windowSeconds : Parameters.v1.windowSeconds

        // Units (a timed word, or a whole untimed segment) by track, then window, then candidate.
        var tracks: [String?: [Int: [[Unit]]]] = [:]
        let empty = [[Unit]](repeating: [], count: candidates.count)
        for (candidateIndex, candidate) in candidates.enumerated() {
            for (segmentIndex, segment) in candidate.segments.enumerated() {
                for unit in units(of: segment, candidate: candidateIndex, segmentIndex: segmentIndex) {
                    let window = windowIndex(unit.middle, windowSeconds: windowSeconds)
                    tracks[segment.track, default: [:]][window, default: empty][candidateIndex].append(unit)
                }
            }
        }

        var summary = Summary()
        var kept: [Unit] = []
        for track in tracks.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            guard let windows = tracks[track] else { continue }
            let order = windows.keys.sorted()
            let raw = order.map { choose(windows[$0] ?? [], languages: languages, scorer: scorer) }
            let chosen = smooth(raw, switchWindows: parameters.switchWindows)
            for (position, window) in order.enumerated() {
                let candidate = chosen[position]
                let language = languages[candidate]
                summary.windows += 1
                summary.windowsByLanguage[language, default: 0] += 1
                if position > 0, chosen[position - 1] != candidate { summary.switches += 1 }
                let units = windows[window]?[candidate] ?? []
                summary.wordsByLanguage[language, default: 0] += units.reduce(0) { $0 + $1.wordCount }
                kept += units
            }
        }
        return Result(segments: segments(from: kept, candidates: candidates), summary: summary)
    }

    /// The smoothed choice per window with words (rule 3), from each window's own choice, as indexes into the
    /// candidates.
    static func smooth(_ raw: [Int], switchWindows: Int) -> [Int] {
        guard let first = raw.first else { return [] }
        let needed = max(1, switchWindows)
        /// Whether the `needed` windows from `index` on all choose what `index` does.
        func agreeing(_ index: Int) -> Bool {
            index + needed <= raw.count && raw[index..<(index + needed)].allSatisfy { $0 == raw[index] }
        }
        var current = raw.indices.first(where: agreeing).map { raw[$0] } ?? first
        var result: [Int] = []
        result.reserveCapacity(raw.count)
        for index in raw.indices {
            if raw[index] != current, agreeing(index) { current = raw[index] }
            result.append(current)
        }
        return result
    }

    // MARK: - Private

    /// One timed word of a segment, or a whole segment without timed words.
    private struct Unit {
        var candidate: Int
        var segment: Int
        /// The word's index in the segment's `words`; nil for a whole untimed segment.
        var word: Int?
        var middle: Double
        var text: String
        var confidence: Double?
        var wordCount: Int
    }

    private static func units(of segment: TranscriptSegment, candidate: Int, segmentIndex: Int) -> [Unit] {
        let segmentMiddle = (segment.start + segment.end) / 2
        guard !segment.words.isEmpty else {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let count = text.split(whereSeparator: { $0.isWhitespace }).count
            return [Unit(candidate: candidate, segment: segmentIndex, word: nil, middle: segmentMiddle, text: text,
                         confidence: nil, wordCount: count)]
        }
        return segment.words.enumerated().map { index, word in
            let middle = (word.start + word.end) / 2
            let confidence = word.confidence.flatMap { $0.isFinite ? $0 : nil }
            return Unit(candidate: candidate, segment: segmentIndex, word: index,
                        middle: middle.isFinite ? middle : segmentMiddle,
                        text: word.text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: confidence,
                        wordCount: 1)
        }
    }

    /// The window holding session time `time`; times that are not numbers, or beyond any meeting, clamp so the
    /// conversion never traps.
    private static func windowIndex(_ time: Double, windowSeconds: Double) -> Int {
        let position = (time / windowSeconds).rounded(.down)
        guard position.isFinite else { return 0 }
        return Int(min(max(position, -1e15), 1e15))
    }

    /// Rule 2: the candidate a window chooses on its own. `perCandidate[c]` are candidate c's units there; at least
    /// one is non-empty.
    private static func choose(_ perCandidate: [[Unit]], languages: [String], scorer: Scorer) -> Int {
        let present = perCandidate.indices.filter { !perCandidate[$0].isEmpty }
        guard present.count > 1 else { return present.first ?? 0 }
        var best = present[0]
        var bestScore = -Double.infinity
        for candidate in present {
            let units = perCandidate[candidate]
            let confidences = units.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            let text = units.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            var probability = 0.0
            if !text.isEmpty, let value = scorer(text, languages)[languages[candidate]], value.isFinite {
                probability = min(1, max(0, value))
            }
            let score = confidence + probability
            // Strictly higher: a tie keeps the language listed first.
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }

    /// Rule 4: the kept units as segments, in (start, track) order, with unique IDs.
    private static func segments(from kept: [Unit], candidates: [Candidate]) -> [TranscriptSegment] {
        struct Key: Hashable {
            var candidate: Int
            var segment: Int
        }
        var wholes: Set<Key> = []
        var words: [Key: [Int]] = [:]
        for unit in kept {
            let key = Key(candidate: unit.candidate, segment: unit.segment)
            if let word = unit.word { words[key, default: []].append(word) } else { wholes.insert(key) }
        }
        /// A kept piece and where it came from, for a deterministic order.
        struct Piece {
            var key: Key
            var first: Int
            var segment: TranscriptSegment
        }
        var pieces: [Piece] = []
        for key in wholes {
            var segment = candidates[key.candidate].segments[key.segment]
            segment.language = candidates[key.candidate].language
            pieces.append(Piece(key: key, first: 0, segment: segment))
        }
        for (key, indexes) in words {
            let source = candidates[key.candidate].segments[key.segment]
            let language = candidates[key.candidate].language
            let sorted = Array(Set(indexes)).sorted()
            var runStart = 0
            for position in sorted.indices {
                let isLast = position == sorted.count - 1
                if !isLast, sorted[position + 1] == sorted[position] + 1 { continue }
                let first = sorted[runStart]
                let end = sorted[position] + 1
                pieces.append(Piece(key: key, first: first,
                                    segment: piece(of: source, first: first, end: end, language: language)))
                runStart = position + 1
            }
        }
        pieces.sort { left, right in
            let a = left.segment, b = right.segment
            if a.start != b.start { return a.start < b.start }
            if (a.track ?? "") != (b.track ?? "") { return (a.track ?? "") < (b.track ?? "") }
            return (left.key.candidate, left.key.segment, left.first) < (right.key.candidate, right.key.segment,
                                                                         right.first)
        }
        var used = Set<String>()
        return pieces.map { piece in
            var segment = piece.segment
            segment.id = unique(segment.id, language: segment.language ?? "", used: &used)
            return segment
        }
    }

    /// Words `[first, end)` of `source`: the segment itself when that is all of them, else a segment cut from its
    /// text at the words' UTF-16 offsets (the text before the first word goes with a cut that starts the segment, the
    /// text after the last with one that ends it), with its words' offsets rebased. When the offsets do not fit the
    /// text, the words' own texts joined with spaces.
    static func piece(of source: TranscriptSegment, first: Int, end: Int, language: String) -> TranscriptSegment {
        var segment = source
        segment.language = language
        let words = source.words
        guard first > 0 || end < words.count else { return segment }
        segment.id = "\(source.id)/\(first)"
        segment.start = first == 0 ? source.start : words[first].start
        segment.end = end == words.count ? source.end : words[end - 1].end
        if !(segment.start <= segment.end) { segment.end = segment.start }
        let utf16 = Array(source.text.utf16)
        let lower = first == 0 ? 0 : words[first].utf16Offset
        let upper = end == words.count ? utf16.count : words[end].utf16Offset
        if offsetsFit(words, first: first, end: end, lower: lower, upper: upper, utf16: utf16) {
            segment.text = String(decoding: utf16[lower..<upper], as: UTF16.self)
            segment.words = words[first..<end].map { word in
                var rebased = word
                rebased.utf16Offset -= lower
                return rebased
            }
            return segment
        }
        var text = ""
        var rebased: [TimedWord] = []
        for word in words[first..<end] {
            let spelled = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { text += " " }
            var moved = word
            moved.utf16Offset = text.utf16.count
            moved.utf16Length = spelled.utf16.count
            text += spelled
            rebased.append(moved)
        }
        segment.text = text
        segment.words = rebased
        return segment
    }

    /// Whether the cut `[lower, upper)` lies within the text on scalar boundaries, and the offsets of words
    /// `first..<end` lie within it in order.
    private static func offsetsFit(_ words: [TimedWord], first: Int, end: Int, lower: Int, upper: Int,
                                   utf16: [UInt16]) -> Bool {
        guard lower >= 0, lower <= upper, upper <= utf16.count,
              isScalarBoundary(lower, utf16), isScalarBoundary(upper, utf16) else { return false }
        var previous = lower
        for index in first..<end {
            let offset = words[index].utf16Offset
            guard offset >= previous, offset <= upper else { return false }
            previous = offset
        }
        return true
    }

    private static func isScalarBoundary(_ offset: Int, _ utf16: [UInt16]) -> Bool {
        guard offset > 0, offset < utf16.count else { return true }
        return !(UTF16.isLeadSurrogate(utf16[offset - 1]) && UTF16.isTrailSurrogate(utf16[offset]))
    }

    /// `id`, or when it is taken, `id/<language>`, then `id/<language>/2`, … .
    private static func unique(_ id: String, language: String, used: inout Set<String>) -> String {
        if used.insert(id).inserted { return id }
        let base = "\(id)/\(language)"
        if used.insert(base).inserted { return base }
        var counter = 2
        while !used.insert("\(base)/\(counter)").inserted { counter += 1 }
        return "\(base)/\(counter)"
    }
}
