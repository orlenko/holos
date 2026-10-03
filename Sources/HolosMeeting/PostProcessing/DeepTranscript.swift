import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers

/// The vocabulary prompt of the deep transcription pass (docs/meeting-design.md §4.16): the meeting's name, then the
/// word list's terms and the names of people the app knows, the ones this meeting's vocabulary.json used first, as
/// many as fit in Whisper's prompt budget. Pure; the token count comes from the model's tokenizer.
public enum DeepTranscriptionPrompt {
    /// WhisperKit 1.1.0 conditions on the last 111 prompt tokens only (`Constants.maxTokenContext` is 224, and a prompt
    /// keeps half of it less one), cutting the start of a longer prompt: the meeting name and the terms this meeting used
    /// would be the first lost. One token is kept spare.
    public static let tokenBudget = 110
    /// Longest term or name considered, in characters, as a meeting's vocabulary keeps them.
    static let maximumTermLength = RecognizerVocabulary.maximumLength

    public struct Prompt: Sendable, Equatable {
        /// What the model is given; empty for no prompt.
        public var text: String
        /// The terms and names it holds, in order (the meeting name not counted).
        public var terms: [String]
        /// Its token count.
        public var tokens: Int
        /// Terms and names left out for the budget.
        public var leftOut: Int
    }

    /// The terms and names in the order they are offered: those this meeting's `vocabulary` (vocabulary.json) holds,
    /// in its order, then the rest of the word list, then the rest of the names. Whitespace collapsed, blank and
    /// over-long ones dropped, each spelling once (ignoring case).
    public static func candidates(vocabulary: [String], wordList: [String], names: [String]) -> [String] {
        let offered = clean(wordList + names)
        let byKey = Dictionary(offered.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [String] = []
        for string in vocabulary {
            guard let term = WordList.cleaned(string), let known = byKey[term.lowercased()],
                  seen.insert(known.lowercased()).inserted else { continue }
            result.append(known)
        }
        for term in offered where seen.insert(term.lowercased()).inserted { result.append(term) }
        return result
    }

    /// The prompt: "<meeting name>. <term>, <term>, …." with the meeting name (when it fits alone) and then each
    /// candidate in order that still fits within `budget` tokens; a candidate that does not fit is skipped and the
    /// next, maybe shorter, one tried.
    public static func build(meetingName: String?, candidates: [String], budget: Int = tokenBudget,
                             tokenCount: (String) async throws -> Int) async throws -> Prompt {
        var name = meetingName.flatMap(WordList.cleaned)
        if let candidate = name, try await tokenCount(text(name: candidate, terms: [])) > budget { name = nil }
        var included: [String] = []
        // Each term is counted alone as it sits in the list (" Term,"), so a long list costs one short count per term
        // rather than one count of the whole prompt per term; the whole prompt is counted once at the end.
        var tokens = name == nil ? 0 : try await tokenCount(text(name: name, terms: []))
        var leftOut = 0
        for term in candidates {
            let cost = try await tokenCount(" " + term + ",")
            if tokens + cost <= budget {
                included.append(term)
                tokens += cost
            } else {
                leftOut += 1
            }
        }
        var total = try await tokenCount(text(name: name, terms: included))
        while total > budget, !included.isEmpty {
            included.removeLast()
            leftOut += 1
            total = try await tokenCount(text(name: name, terms: included))
        }
        return Prompt(text: text(name: name, terms: included), terms: included, tokens: total, leftOut: leftOut)
    }

    /// "Name. A, B, C." / "A, B, C." / "Name." / "".
    static func text(name: String?, terms: [String]) -> String {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name.hasSuffix(".") ? name : name + ".") }
        if !terms.isEmpty { parts.append(terms.joined(separator: ", ") + ".") }
        return parts.joined(separator: " ")
    }

    private static func clean(_ strings: [String]) -> [String] {
        strings.compactMap { string in
            guard let term = WordList.cleaned(string), term.count <= maximumTermLength else { return nil }
            return term
        }
    }
}

/// One segment the deep transcriber wrote, in session time, with the loudness of its audio.
public struct DeepHeardSegment: Sendable, Equatable {
    public var track: String
    public var start: Double
    public var end: Double
    public var text: String
    /// In session time; may be empty.
    public var words: [DeepTranscribedWord]
    /// RMS level of the segment's audio in dBFS (`DeepAudio.silenceDB` for digital silence).
    public var levelDB: Double

    public init(track: String, start: Double, end: Double, text: String, words: [DeepTranscribedWord] = [],
                levelDB: Double) {
        self.track = track; self.start = start; self.end = end; self.text = text; self.words = words
        self.levelDB = levelDB
    }
}

/// Audio helpers of the deep transcription pass: pieces of a long track and loudness. Pure.
public enum DeepAudio {
    public static let sampleRate = 16_000
    /// A track is given to the model in pieces of at most this long, so a long meeting never sits in memory whole.
    public static let pieceSeconds = 600.0
    /// A piece ends at the quietest moment of its last this many seconds, so no word is cut in two.
    public static let cutSearchSeconds = 30.0
    /// The window in which loudness is compared when choosing that moment.
    static let cutFrameSeconds = 0.1
    /// The level given to digital silence (and empty audio), instead of minus infinity.
    public static let silenceDB = -120.0

    /// Where to end a piece of `samples` (more than `pieceSeconds` remain after it): the middle of the quietest
    /// `cutFrameSeconds` frame from `searchFrom` on. Ties keep the earliest frame.
    public static func quietestCut(_ samples: [Float], searchFrom: Int) -> Int {
        let frame = Int(cutFrameSeconds * Double(sampleRate))
        let lower = max(0, min(searchFrom, samples.count))
        guard samples.count - lower >= frame else { return samples.count }
        var best = (energy: Double.infinity, start: lower)
        var start = lower
        while start + frame <= samples.count {
            var energy = 0.0
            for index in start..<(start + frame) { energy += Double(samples[index] * samples[index]) }
            if energy < best.energy { best = (energy, start) }
            start += frame
        }
        return best.start + frame / 2
    }

    /// RMS level of `samples` in dBFS; `silenceDB` for digital silence or no samples.
    public static func levelDB(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return silenceDB }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return silenceDB }
        return max(silenceDB, 20 * log10(rms))
    }

    /// The level of `samples` (a piece) between `start` and `end` seconds of it (at least one cut frame long,
    /// centered on the span when it is shorter).
    public static func levelDB(_ samples: [Float], from start: Double, to end: Double) -> Double {
        guard start.isFinite, end.isFinite else { return silenceDB }
        let minimum = cutFrameSeconds
        var lower = start, upper = max(end, start)
        if upper - lower < minimum {
            let middle = (lower + upper) / 2
            lower = middle - minimum / 2
            upper = middle + minimum / 2
        }
        let first = max(0, min(samples.count, Int((lower * Double(sampleRate)).rounded(.down))))
        let last = max(first, min(samples.count, Int((upper * Double(sampleRate)).rounded(.up))))
        return levelDB(samples[first..<last])
    }

    /// The deep transcriber's segments of one piece (times from the piece's start, which is `pieceStart` seconds into
    /// the render of `track`) in session time, through the render's time map (`RenderTimeMap.sessionTime`), with the
    /// level of each segment's audio. Segments without text are left out.
    public static func sessionSegments(_ segments: [DeepTranscribedSegment], piece: [Float], pieceStart: Double,
                                       track: String, timeMap: [RenderSpan]) -> [DeepHeardSegment] {
        func session(_ time: Double) -> Double { RenderTimeMap.sessionTime(pieceStart + time, map: timeMap) }
        return segments.compactMap { segment in
            let words = segment.words.filter { $0.start.isFinite && $0.end.isFinite }
            let hasText = !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || words.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard hasText, segment.start.isFinite, segment.end.isFinite else { return nil }
            let start = words.first.map { min($0.start, segment.start) } ?? segment.start
            let end = words.last.map { max($0.end, segment.end) } ?? segment.end
            let mapped = words.map { word in
                DeepTranscribedWord(text: word.text, start: session(word.start), end: max(session(word.start),
                                                                                         session(word.end)),
                                    probability: word.probability)
            }
            let sessionStart = session(start)
            return DeepHeardSegment(track: track, start: sessionStart, end: max(sessionStart, session(end)),
                                    text: segment.text, words: mapped,
                                    levelDB: levelDB(piece, from: start, to: end))
        }
    }

    /// A transcript segment for `heard`: its words' texts joined as the model spaced them (punctuation the model
    /// wrote as a word of its own joins the word before it), each a `TimedWord` at its UTF-16 offset in the text; a
    /// segment without word timings keeps its text, untimed. Nil when there is no text.
    public static func transcriptSegment(_ heard: DeepHeardSegment) -> TranscriptSegment? {
        var text = ""
        var words: [TimedWord] = []
        for word in heard.words {
            let raw = word.text
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let spaced = raw.first.map { $0.isWhitespace } ?? false
            if !spaced, var last = words.last, trimmed.unicodeScalars.allSatisfy(isPunctuation) {
                // "Hello" "," → "Hello,"
                text += trimmed
                last.text += trimmed
                last.utf16Length += trimmed.utf16.count
                last.end = max(last.end, word.end)
                words[words.count - 1] = last
                continue
            }
            if !text.isEmpty, spaced { text += " " }
            let offset = text.utf16.count
            text += trimmed
            words.append(TimedWord(text: trimmed, start: word.start, end: max(word.start, word.end),
                                   utf16Offset: offset, utf16Length: trimmed.utf16.count,
                                   confidence: word.probability))
        }
        if words.isEmpty {
            let plain = heard.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !plain.isEmpty else { return nil }
            return TranscriptSegment(start: heard.start, end: heard.end, text: plain, track: heard.track)
        }
        return TranscriptSegment(start: words.first?.start ?? heard.start,
                                 end: max(words.last?.end ?? heard.end, words.first?.start ?? heard.start),
                                 text: text, words: words, track: heard.track)
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }
}

/// The guards of the deep transcription pass against Whisper's known failures (docs/meeting-design.md §4.16). Pure.
public enum DeepTranscriptGuards {
    /// A segment whose audio is quieter than this (RMS, dBFS) is near silence. Speech on both tracks measured well
    /// above it, while capture gaps are digital silence and quiet rooms sit below it (§4.16 has the measurements).
    public static let silenceThresholdDB = -50.0
    /// How far around a segment the recorded transcript's words are looked for.
    public static let referencePaddingSeconds = 0.5
    /// This many consecutive identical segments on one track are a repetition loop; the first one is kept.
    public static let repeatRunLength = 3
    /// Segments of a loop follow each other: one that starts more than this after the one before it ended (the same
    /// short answer said again minutes later, other speech between) starts a new run.
    public static let repeatGapSeconds = 5.0

    public struct Result: Sendable, Equatable {
        public var kept: [DeepHeardSegment]
        /// Segments over near-silent audio where the recorded transcript has no words ("Thank you." in a gap).
        public var droppedSilent: Int
        /// Repeats past the first of a run of `repeatRunLength` or more identical segments.
        public var droppedRepeats: Int
    }

    /// Drops, per track, each segment that is both over near-silent audio (`silenceThresholdDB`) and where the
    /// recorded transcript (`reference`, nil when there is none) has no word within `referencePaddingSeconds`; then
    /// each repeat past the first in a run of at least `repeatRunLength` consecutive segments with the same text
    /// (compared lowercased, letters and digits only), each starting within
    /// `repeatGapSeconds` of the one before. The rest keep their order.
    public static func apply(_ segments: [DeepHeardSegment], reference: [TranscriptSegment]?,
                             silenceThresholdDB: Double = silenceThresholdDB) -> Result {
        let heard = ReferenceWords(reference ?? [])
        var droppedSilent = 0
        let audible = segments.filter { segment in
            let silent = segment.levelDB < silenceThresholdDB
                && !heard.hasWord(track: segment.track, from: segment.start - referencePaddingSeconds,
                                  to: segment.end + referencePaddingSeconds)
            if silent { droppedSilent += 1 }
            return !silent
        }
        var drop = Set<Int>()
        var byTrack: [String: [Int]] = [:]
        for index in audible.indices { byTrack[audible[index].track, default: []].append(index) }
        for indices in byTrack.values {
            let ordered = indices.sorted { (audible[$0].start, $0) < (audible[$1].start, $1) }
            var runStart = 0
            while runStart < ordered.count {
                let key = normalized(audible[ordered[runStart]].text)
                var runEnd = runStart + 1
                while runEnd < ordered.count, !key.isEmpty, normalized(audible[ordered[runEnd]].text) == key,
                      audible[ordered[runEnd]].start - audible[ordered[runEnd - 1]].end <= repeatGapSeconds {
                    runEnd += 1
                }
                if !key.isEmpty, runEnd - runStart >= repeatRunLength {
                    for position in (runStart + 1)..<runEnd { drop.insert(ordered[position]) }
                }
                runStart = runEnd
            }
        }
        let kept = audible.indices.filter { !drop.contains($0) }.map { audible[$0] }
        return Result(kept: kept, droppedSilent: droppedSilent, droppedRepeats: drop.count)
    }

    /// Lowercased letters and digits, words separated by one space.
    static func normalized(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            cleaned.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// The recorded transcript's word spans per track (a segment without timed words counts as one span), to ask
    /// whether any lies within an interval.
    private struct ReferenceWords {
        private struct Spans {
            var starts: [Double] = []
            /// The latest end among the spans up to each index (spans sorted by start).
            var reach: [Double] = []
        }

        private var tracks: [String: Spans] = [:]
        private var untracked = Spans()

        init(_ segments: [TranscriptSegment]) {
            var raw: [String?: [(Double, Double)]] = [:]
            for segment in segments {
                let words = WordTiming.effectiveWords(of: segment)
                let spans: [(Double, Double)] = words.isEmpty
                    ? [(segment.start, segment.end)]
                    : words.map { ($0.start, $0.end) }
                guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                raw[segment.track, default: []].append(contentsOf: spans.filter { $0.0.isFinite && $0.1.isFinite })
            }
            for (track, spans) in raw {
                let sorted = spans.sorted { $0.0 < $1.0 }
                var built = Spans()
                var reach = -Double.infinity
                for (start, end) in sorted {
                    reach = max(reach, end)
                    built.starts.append(start)
                    built.reach.append(reach)
                }
                if let track { tracks[track] = built } else { untracked = built }
            }
        }

        /// Whether a span of `track` (or of a segment without a track) overlaps [from, to].
        func hasWord(track: String, from: Double, to: Double) -> Bool {
            [tracks[track], untracked].contains { spans in
                guard let spans, !spans.starts.isEmpty else { return false }
                // The last span starting at or before `to`.
                var low = 0, high = spans.starts.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans.starts[middle] <= to { low = middle + 1 } else { high = middle }
                }
                return low > 0 && spans.reach[low - 1] >= from
            }
        }
    }
}
