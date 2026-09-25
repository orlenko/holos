import Foundation
import HolosCore

/// Microphone echo of system audio in calls (docs/meeting-design.md §5.11, PR11). When the laptop speakers play a
/// call, the microphone hears the other people too, so speech recognition writes their words twice: on the system
/// track and, a moment later, on the microphone track. The filter finds the microphone copies; `SpeakerRunBuilder`
/// leaves them out of every turn and lists them in `DiarizationRun.droppedWords` with reason `echo`.
public enum EchoFilter {
    /// `DroppedWords.reason` of microphone echo.
    public static let reason = "echo"
    /// The track whose words can be echo.
    static let microphoneTrack = "mic"
    /// The track they echo.
    static let systemTrack = "system"
    /// A diarized microphone cluster with at least this share of its words dropped as echo is echo itself: it is not
    /// listed as a speaker, and its remaining words become unknown speaker.
    public static let echoClusterShare = 0.6
    /// How far a microphone word may start before its system counterpart and still be echo: timing jitter between
    /// the two tracks' recognized words. Echo itself can only follow the system audio.
    public static let echoLeadToleranceSeconds = 0.25
    /// A pause longer than this between two matched words ends the run they would extend: they belong to separate
    /// utterances, not to one phrase the microphone heard back. Without it, the same short word said on both
    /// tracks minutes apart ("yes" … "yes" … "yes") would add up to a run and be dropped, which is exactly what
    /// `echoMinRunWords` exists to prevent.
    public static let echoRunGapSeconds = 2.0

    /// Microphone spans to drop: runs of at least `echoMinRunWords` consecutive mic words whose normalized
    /// text (lowercased, letters and digits only) equals, in order, consecutive system words, each mic word
    /// starting at most echoWindowSeconds after its system counterpart and at most `echoLeadToleranceSeconds`
    /// before it.
    ///
    /// The window is one-sided (a deviation from the "±echoWindowSeconds" of docs/meeting-design.md §5.11): echo
    /// reaches the microphone after the system audio plays. A microphone phrase clearly ahead of the same words in
    /// the system audio is the user speaking while the far end sends their voice back into the call, and it stays
    /// with the user.
    ///
    /// Details:
    /// - No spans when `echoWindowSeconds` is nil, negative, or not finite. A run needs at least
    ///   `max(1, echoMinRunWords)` words (3 in `AlignmentParameters.v1`, so a lone "yes" or "okay" is kept, R34).
    /// - Consecutive matches extend one run only while both tracks stay inside `echoRunGapSeconds`: matches
    ///   further apart than that are separate utterances and each starts a new run, so isolated words repeated
    ///   over a call never add up to one.
    /// - Words are the effective words (`WordTiming`) of the segments whose track is exactly "mic" or "system", in
    ///   alignment order (segments by start, then their words). A word's time is its start.
    /// - A word whose normalized text is empty (punctuation) or whose start is not a number takes no part in matching
    ///   and does not break a run; such a microphone word between two dropped words is dropped too.
    /// - Spans cover consecutive dropped words of one segment, in microphone word order.
    public static func echoSpans(transcript: Transcript, parameters: AlignmentParameters) -> [WordSpan] {
        guard let window = parameters.echoWindowSeconds, window.isFinite, window >= 0 else { return [] }
        let minimumRun = max(1, parameters.echoMinRunWords)
        let mic = words(transcript.segments, track: microphoneTrack)
        let system = words(transcript.segments, track: systemTrack)
        let micMatchable = mic.indices.filter { mic[$0].isMatchable }
        let systemMatchable = system.indices.filter { system[$0].isMatchable }
        guard !micMatchable.isEmpty, !systemMatchable.isEmpty else { return [] }

        // System words by text, each list by start, holding positions in `systemMatchable`.
        var byText: [String: [(start: Double, position: Int)]] = [:]
        for (position, index) in systemMatchable.enumerated() {
            byText[system[index].key, default: []].append((system[index].start, position))
        }
        for key in byText.keys {
            byText[key]?.sort { ($0.start, $0.position) < ($1.start, $1.position) }
        }

        // For each matchable microphone word: the system positions it may echo.
        let candidates: [[Int]] = micMatchable.map { index in
            let word = mic[index]
            guard let list = byText[word.key] else { return [] }
            let low = word.start - window - timeEpsilon
            let high = word.start + min(window, echoLeadToleranceSeconds) + timeEpsilon
            var first = 0
            var last = list.count
            while first < last {
                let middle = (first + last) / 2
                if list[middle].start < low { first = middle + 1 } else { last = middle }
            }
            var found: [Int] = []
            while first < list.count, list[first].start <= high {
                found.append(list[first].position)
                first += 1
            }
            return found
        }

        // A pair (mic i, system j) lies on a diagonal of consecutive matches; its length is the matches before it
        // (forward) plus the matches after it (backward), counting the pair once.
        /// Whether the matchable microphone words at `positions` follow each other closely enough to be one phrase.
        let micTogether = { (earlier: Int, later: Int) -> Bool in
            mic[micMatchable[later]].start - mic[micMatchable[earlier]].start <= echoRunGapSeconds + timeEpsilon
        }
        /// The same for the system words a run is matched against.
        let systemTogether = { (earlier: Int, later: Int) -> Bool in
            guard earlier >= 0, later < systemMatchable.count else { return false }
            return system[systemMatchable[later]].start - system[systemMatchable[earlier]].start
                <= echoRunGapSeconds + timeEpsilon
        }
        var forward = candidates.map { [Int](repeating: 0, count: $0.count) }
        var previous: [Int: Int] = [:]
        for i in candidates.indices {
            var current: [Int: Int] = [:]
            let followsOn = i > 0 && micTogether(i - 1, i)
            for (slot, j) in candidates[i].enumerated() {
                var length = 1
                if followsOn, let before = previous[j - 1], systemTogether(j - 1, j) { length = before + 1 }
                forward[i][slot] = length
                current[j] = length
            }
            previous = current
        }
        var droppedMatchable = [Bool](repeating: false, count: candidates.count)
        var next: [Int: Int] = [:]
        for i in candidates.indices.reversed() {
            var current: [Int: Int] = [:]
            let leadsOn = i + 1 < candidates.count && micTogether(i, i + 1)
            for (slot, j) in candidates[i].enumerated() {
                var length = 1
                if leadsOn, let after = next[j + 1], systemTogether(j, j + 1) { length = after + 1 }
                current[j] = length
                if forward[i][slot] + length - 1 >= minimumRun { droppedMatchable[i] = true }
            }
            next = current
        }

        var dropped = [Bool](repeating: false, count: mic.count)
        for (position, index) in micMatchable.enumerated() where droppedMatchable[position] {
            dropped[index] = true
        }
        // Punctuation, and words whose start is not a number, go with the echo around them.
        var droppedBefore = [Bool](repeating: false, count: mic.count)
        var last = false
        for index in mic.indices {
            droppedBefore[index] = last
            if mic[index].isMatchable { last = dropped[index] }
        }
        var after = false
        for index in mic.indices.reversed() {
            if mic[index].isMatchable {
                after = dropped[index]
            } else if after && droppedBefore[index] {
                dropped[index] = true
            }
        }

        var spans: [WordSpan] = []
        for index in mic.indices where dropped[index] {
            let ref = mic[index].ref
            if let lastSpan = spans.last, lastSpan.segmentID == ref.segmentID, lastSpan.end == ref.word {
                spans[spans.count - 1].end += 1
            } else {
                spans.append(WordSpan(segmentID: ref.segmentID, first: ref.word, end: ref.word + 1))
            }
        }
        return spans
    }

    /// Every word position `spans` cover.
    static func words(in spans: [WordSpan]) -> Set<WordRef> {
        var refs = Set<WordRef>()
        for span in spans where span.first < span.end {
            for word in span.first..<span.end { refs.insert(WordRef(segmentID: span.segmentID, word: word)) }
        }
        return refs
    }

    /// Lowercased letters and digits of `text`: "Vote," and "vote" match, "don't" becomes "dont".
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// One effective word of a track.
    private struct Word {
        let ref: WordRef
        let start: Double
        let key: String

        var isMatchable: Bool { !key.isEmpty && start.isFinite }
    }

    /// The words of the segments whose track is exactly `track`, in alignment order.
    private static func words(_ segments: [TranscriptSegment], track: String) -> [Word] {
        var words: [Word] = []
        for segment in SpeakerAlignment.trackSegments(segments, track: track, includeUntracked: false) {
            for (index, word) in WordTiming.effectiveWords(of: segment).enumerated() {
                words.append(Word(ref: WordRef(segmentID: segment.id, word: index), start: word.start,
                                  key: normalized(word.text)))
            }
        }
        return words
    }
}
