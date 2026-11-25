import Foundation
import HolosCore

/// Microphone echo of system audio in calls (docs/meeting/online-calls-echo.md §5.11). When the laptop speakers play a
/// call, the microphone hears the other people too, so speech recognition writes their words twice: on the system
/// track and, a moment later, on the microphone track. The filter finds the microphone copies; `SpeakerRunBuilder`
/// leaves them out of every turn and lists them in `DiarizationRun.droppedWords` with reason `echo`.
public enum EchoFilter {
    /// `DroppedWords.reason` of microphone echo.
    public static let reason = "echo"
    /// The track whose words can be echo.
    public static let microphoneTrack = "mic"
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
    /// At most this many unmatched words on each track inside an echoed phrase ("alpha" against "beta", "keep one"
    /// against "keepone") may be bridged when the matched words on both sides reach `echoMinRunWords + 1`.
    public static let echoMaxBridgeWords = 2
    /// The echo window used when a segment-level acoustic check compares against system speech.
    static let defaultEchoWindowSeconds = 1.0

    /// Microphone spans to drop: runs of at least `echoMinRunWords` consecutive mic words whose normalized
    /// text (lowercased, letters and digits only) equals, in order, consecutive system words, each mic word
    /// starting at most echoWindowSeconds after its system counterpart and at most `echoLeadToleranceSeconds`
    /// before it.
    ///
    /// The window is one-sided (a deviation from the "±echoWindowSeconds" of docs/meeting/online-calls-echo.md §5.11): echo
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
        // Words the person edited in Review were read and confirmed: never echo, and they break an echo run as a word
        // the call did not say would (they stay in the sequence, matching nothing), so an edit never hides the words
        // around it either: correcting "write" to "right" beside the call's "that sounds right", or "rarely" to
        // "really" in "I rarely think so" beside its "I think so", leaves the microphone's words as judged before.
        let edited = reviewEditedWords(in: transcript)
        // An edited word breaks runs even when it has no letters or digits ("…"), which other words do not.
        let micMatchable = mic.indices.filter {
            mic[$0].isMatchable || (edited.contains(mic[$0].ref) && mic[$0].start.isFinite)
        }
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
            guard !edited.contains(word.ref), let list = byText[word.key] else { return [] }
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
        var backward = candidates.map { [Int](repeating: 0, count: $0.count) }
        var next: [Int: Int] = [:]
        for i in candidates.indices.reversed() {
            var current: [Int: Int] = [:]
            let leadsOn = i + 1 < candidates.count && micTogether(i, i + 1)
            for (slot, j) in candidates[i].enumerated() {
                var length = 1
                if leadsOn, let after = next[j + 1], systemTogether(j, j + 1) { length = after + 1 }
                backward[i][slot] = length
                current[j] = length
                if forward[i][slot] + length - 1 >= minimumRun { droppedMatchable[i] = true }
            }
            next = current
        }

        // A 1–2 word disagreement between the two tracks' recognizers inside an echoed phrase ("we should alpha now"
        // on the microphone against "we should beta now" on the system track, or "so we keep one" against "so we
        // keepone") is still one echo run when both tracks advance by 1…echoMaxBridgeWords matchable
        // words within echoRunGapSeconds, the bridged words on the two tracks share no normalized word (a missed word
        // is an insertion or deletion, not a substitution, and still breaks the run), none of the bridged microphone
        // words was edited in Review, each bridged microphone word lies within the echo window of a bridged system
        // word, and the matched words on both sides together reach at least max(minimumRun, minimumRun + 1).
        let bridgeMinimum = max(minimumRun, minimumRun + 1)
        let leadWindow = min(window, echoLeadToleranceSeconds)
        for i1 in candidates.indices {
            for dm in 1...echoMaxBridgeWords {
                let i2 = i1 + dm + 1
                guard i2 < candidates.count,
                      !droppedMatchable[i1] || !droppedMatchable[i1 + 1]
                          || !droppedMatchable[i2 - 1] || !droppedMatchable[i2],
                      (i1..<i2).allSatisfy({ micTogether($0, $0 + 1) }),
                      ((i1 + 1)..<i2).allSatisfy({ !edited.contains(mic[micMatchable[$0]].ref) }) else { continue }
                for (slot1, j1) in candidates[i1].enumerated() {
                    let f = forward[i1][slot1]
                    guard f > 0 else { continue }
                    for ds in 1...echoMaxBridgeWords {
                        let j2 = j1 + ds + 1
                        guard let slot2 = candidates[i2].firstIndex(of: j2) else { continue }
                        let b = backward[i2][slot2]
                        guard f + b >= bridgeMinimum,
                              (j1..<j2).allSatisfy({ systemTogether($0, $0 + 1) }) else { continue }
                        let disjoint = ((i1 + 1)..<i2).allSatisfy { im in
                            let micKey = mic[micMatchable[im]].key
                            return ((j1 + 1)..<j2).allSatisfy { js in
                                system[systemMatchable[js]].key != micKey
                            }
                        }
                        guard disjoint else { continue }
                        let timed = ((i1 + 1)..<i2).allSatisfy { im in
                            let start = mic[micMatchable[im]].start
                            let low = start - window - timeEpsilon
                            let high = start + leadWindow + timeEpsilon
                            return ((j1 + 1)..<j2).contains { js in
                                let sysStart = system[systemMatchable[js]].start
                                return sysStart >= low && sysStart <= high
                            }
                        }
                        guard timed else { continue }
                        for k in (i1 - f + 1)...(i2 + b - 1) { droppedMatchable[k] = true }
                    }
                }
            }
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
        for index in mic.indices where dropped[index] && !edited.contains(mic[index].ref) {
            let ref = mic[index].ref
            if let lastSpan = spans.last, lastSpan.segmentID == ref.segmentID, lastSpan.end == ref.word {
                spans[spans.count - 1].end += 1
            } else {
                spans.append(WordSpan(segmentID: ref.segmentID, first: ref.word, end: ref.word + 1))
            }
        }
        return spans
    }

    /// The words under a `reviewEdit` fix (edited in Review, docs/meeting/review-window.md §5.10): neither echo filter drops
    /// or hides them.
    public static func reviewEditedWords(in transcript: Transcript) -> Set<WordRef> {
        var refs = Set<WordRef>()
        for segment in transcript.segments {
            let fixes = (segment.fixes ?? []).filter { $0.kind == .reviewEdit }
            guard !fixes.isEmpty else { continue }
            // Fixes come from files: only a mark within the segment's words counts (a damaged one, past them or
            // backwards, exempts nothing), and the marks are merged first, so each word is taken once however many
            // marks repeat it.
            let count = WordTiming.effectiveWords(of: segment).count
            let ranges = fixes.filter { $0.first >= 0 && $0.first < $0.end && $0.end <= count }
                .map { $0.first..<$0.end }.sorted { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            for range in merged {
                for word in range { refs.insert(WordRef(segmentID: segment.id, word: word)) }
            }
        }
        return refs
    }

    /// Microphone spans the acoustic echo mask flags (`SpeakerProjection` hides them; stored runs never list them):
    /// every effective word of the segments whose track is exactly "mic" for which
    /// `AcousticEchoMask.isEcho(start:end:)` is true, plus any unedited 1–2 word remnant overlapping system speech (or
    /// punctuation beside echo) inside a microphone segment at least `echoClusterShare` of whose words are already echo,
    /// except the words in `excluding` (those the text filter already dropped or the user edited in Review). A word the
    /// mask cannot judge is kept: times that are not numbers, past its last frame, or estimated (a segment without word
    /// timing spreads its words evenly, so their times say nothing about which sound they were).
    /// Spans cover consecutive flagged words of one segment, in microphone word order.
    public static func acousticEchoSpans(transcript: Transcript, mask: AcousticEchoMask,
                                         excluding: Set<WordRef> = []) -> [WordSpan] {
        let edited = reviewEditedWords(in: transcript)
        let systemWords = SpeakerAlignment.trackSegments(transcript.segments, track: systemTrack,
                                                         includeUntracked: false)
            .flatMap { WordTiming.effectiveWords(of: $0) }
            .filter { $0.start.isFinite && $0.end.isFinite }
        func overlapsSystem(_ word: EffectiveWord) -> Bool {
            guard word.start.isFinite, word.end.isFinite else { return false }
            let low = word.start - defaultEchoWindowSeconds - timeEpsilon
            let high = max(word.start, word.end) + echoLeadToleranceSeconds + timeEpsilon
            return systemWords.contains { max($0.start, $0.end) >= low && $0.start <= high }
        }

        var spans: [WordSpan] = []
        for segment in SpeakerAlignment.trackSegments(transcript.segments, track: microphoneTrack,
                                                      includeUntracked: false) {
            let effective = WordTiming.effectiveWords(of: segment)
            guard !effective.isEmpty else { continue }
            var echo = [Bool](repeating: false, count: effective.count)
            for (index, word) in effective.enumerated() {
                let ref = WordRef(segmentID: segment.id, word: index)
                if excluding.contains(ref) {
                    echo[index] = !edited.contains(ref)
                } else if !word.estimated, mask.isEcho(start: word.start, end: word.end) == true {
                    echo[index] = true
                }
            }
            let echoCount = echo.filter { $0 }.count
            if Double(echoCount) >= echoClusterShare * Double(effective.count) - timeEpsilon {
                var index = 0
                while index < effective.count {
                    guard !echo[index] else { index += 1; continue }
                    var end = index
                    while end < effective.count, !echo[end] { end += 1 }
                    let indices = index..<end
                    let unedited = indices.allSatisfy { !edited.contains(WordRef(segmentID: segment.id, word: $0)) }
                        && indices.allSatisfy { !effective[$0].estimated }
                    if unedited {
                        let matchable = indices.filter { !normalized(effective[$0].text).isEmpty }
                        if matchable.count <= echoMaxBridgeWords,
                           matchable.allSatisfy({ overlapsSystem(effective[$0]) }) {
                            for position in indices { echo[position] = true }
                        }
                    }
                    index = end
                }
            }
            for index in effective.indices where echo[index] {
                let ref = WordRef(segmentID: segment.id, word: index)
                guard !excluding.contains(ref) else { continue }
                if let last = spans.last, last.segmentID == ref.segmentID, last.end == ref.word {
                    spans[spans.count - 1].end += 1
                } else {
                    spans.append(WordSpan(segmentID: ref.segmentID, first: ref.word, end: ref.word + 1))
                }
            }
        }
        return spans
    }

    /// Every word position `spans` cover (also the live transcript's, `LiveTranscript`).
    public static func words(in spans: [WordSpan]) -> Set<WordRef> {
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
