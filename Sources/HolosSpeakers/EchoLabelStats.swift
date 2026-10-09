import Foundation
import HolosCore

/// What the evidence requirement of the word rule (`AcousticEchoMask.isEcho`, `wordRuleVersion` 2,
/// docs/meeting-design.md §5.11) changes in one call's labels, against the rule before it
/// (`AcousticEchoMask.countingEveryLocalFrame()`): counts only, for `voiceislocal session echo-label-stats`. It holds
/// no transcript text, names or word times, so it can be printed and shared.
public struct EchoLabelStats: Sendable, Equatable, Encodable {
    /// Effective words of the microphone track's segments.
    public var microphoneWords = 0
    /// Of them, the words the mask judges as the labels do: not dropped by the text filter, not edited in Review, with
    /// measured times inside the mask.
    public var judgedWords = 0
    /// Judged words counted as the microphone's own speech (not echo) under the rule before, and under the rule now.
    public var localBefore = 0
    public var localAfter = 0
    /// Judged words the new rule moves from the microphone to echo, and from echo to the microphone (none expected:
    /// the evidence requirement only takes local frames away; counted to show it).
    public var localToEcho = 0
    public var echoToLocal = 0
    /// Words counted as the microphone's own whose surroundings the echo dominates (`echoDominated`), before and now:
    /// echo kept as the user's, mostly.
    public var localInEchoBefore = 0
    public var localInEchoAfter = 0
    /// Microphone rows shown (`SpeakerProjection.shownTurns`, short interjections joined or hidden as Review shows
    /// them), and those of them with no speaker ("Unknown"), before and now; nil without speaker labels.
    public var microphoneRowsBefore: Int?
    public var microphoneRowsAfter: Int?
    public var unknownRowsBefore: Int?
    public var unknownRowsAfter: Int?
    /// Microphone turns whose words shown differ between the two rules (one shown only under one counts too); nil
    /// without speaker labels.
    public var turnsChanged: Int?

    public init() {}

    /// Half the window around a word in which `echoDominated` counts frames.
    public static let surroundingSeconds = 0.5
    /// Echo frames at least this many times the local ones around a word: its surroundings are echo.
    public static let echoDominance = 3

    /// The stats of one call: its transcript, its mask, and, when it has speaker labels, the run and the edit journal
    /// they are shown with (the views are made without recognition or people's names, which change no word).
    ///
    /// A word is judged as `SpeakerProjection` judges it (`EchoFilter.acousticEchoSpans`): every effective word of a
    /// segment of the "mic" track, except words the run's text filter dropped, words edited in Review, words with
    /// estimated times, and words the mask cannot judge (times that are not numbers, or past its last frame).
    public static func compare(transcript: Transcript, mask: AcousticEchoMask, run: DiarizationRun? = nil,
                               edits: [SpeakerEdit] = []) -> EchoLabelStats {
        let before = mask.countingEveryLocalFrame()
        var stats = EchoLabelStats()
        var excluded = EchoFilter.reviewEditedWords(in: transcript)
        if let run, !run.droppedWords.isEmpty {
            var counts: [String: Int] = [:]
            for segment in transcript.segments where counts[segment.id] == nil {
                counts[segment.id] = WordTiming.effectiveWords(of: segment).count
            }
            for span in run.droppedWords.flatMap(\.spans) {
                // Spans come from files: bounded by the segment's words before being walked.
                guard let count = counts[span.segmentID] else { continue }
                let first = max(0, span.first)
                let end = min(count, span.end)
                guard first < end else { continue }
                for word in first..<end { excluded.insert(WordRef(segmentID: span.segmentID, word: word)) }
            }
        }
        for segment in SpeakerAlignment.trackSegments(transcript.segments, track: EchoFilter.microphoneTrack,
                                                      includeUntracked: false) {
            for (index, word) in WordTiming.effectiveWords(of: segment).enumerated() {
                stats.microphoneWords += 1
                guard !excluded.contains(WordRef(segmentID: segment.id, word: index)), !word.estimated,
                      let echoBefore = before.isEcho(start: word.start, end: word.end),
                      let echoAfter = mask.isEcho(start: word.start, end: word.end) else { continue }
                stats.judgedWords += 1
                let dominated = echoDominated(mask, start: word.start, end: word.end)
                if !echoBefore {
                    stats.localBefore += 1
                    if dominated { stats.localInEchoBefore += 1 }
                }
                if !echoAfter {
                    stats.localAfter += 1
                    if dominated { stats.localInEchoAfter += 1 }
                }
                if !echoBefore && echoAfter { stats.localToEcho += 1 }
                if echoBefore && !echoAfter { stats.echoToLocal += 1 }
            }
        }
        if let run {
            let views = [before, mask].map { mask in
                SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: nil,
                                       profileNames: [:], acousticEcho: mask)
            }
            let rows = views.map { view in
                view.shownTurns(includingHidden: false).filter { $0.track == EchoFilter.microphoneTrack }
            }
            stats.microphoneRowsBefore = rows[0].count
            stats.microphoneRowsAfter = rows[1].count
            stats.unknownRowsBefore = rows[0].filter { $0.speakerID == nil }.count
            stats.unknownRowsAfter = rows[1].filter { $0.speakerID == nil }.count
            let spans = views.map { view in
                Dictionary(view.turns.filter { $0.track == EchoFilter.microphoneTrack }.map { ($0.id, $0.spans) },
                           uniquingKeysWith: { first, _ in first })
            }
            stats.turnsChanged = Set(spans[0].keys).union(spans[1].keys).filter { spans[0][$0] != spans[1][$0] }.count
        }
        return stats
    }

    /// Whether the echo dominates around a word: within `surroundingSeconds` of its middle, echo frames are at least
    /// `echoDominance` times the local ones (and there is echo). The frame classes as the analysis gave them.
    static func echoDominated(_ mask: AcousticEchoMask, start: Double, end: Double) -> Bool {
        let middle = (start + end) / 2
        let first = mask.firstFrame(centredAtOrAfter: middle - surroundingSeconds)
        let last = mask.firstFrame(centredAtOrAfter: middle + surroundingSeconds)
        var echo = 0
        var local = 0
        for frame in first..<max(first, last) {
            switch mask.frameClass(frame) {
            case .silence: continue
            case .echo: echo += 1
            case .local: local += 1
            }
        }
        return echo > 0 && echo >= echoDominance * local
    }

    /// Adds `other`'s counts (a total over sessions); an optional count is added when both have it, else kept from
    /// the one that has it.
    public mutating func add(_ other: EchoLabelStats) {
        microphoneWords += other.microphoneWords
        judgedWords += other.judgedWords
        localBefore += other.localBefore
        localAfter += other.localAfter
        localToEcho += other.localToEcho
        echoToLocal += other.echoToLocal
        localInEchoBefore += other.localInEchoBefore
        localInEchoAfter += other.localInEchoAfter
        func sum(_ left: Int?, _ right: Int?) -> Int? {
            guard let left else { return right }
            return left + (right ?? 0)
        }
        microphoneRowsBefore = sum(microphoneRowsBefore, other.microphoneRowsBefore)
        microphoneRowsAfter = sum(microphoneRowsAfter, other.microphoneRowsAfter)
        unknownRowsBefore = sum(unknownRowsBefore, other.unknownRowsBefore)
        unknownRowsAfter = sum(unknownRowsAfter, other.unknownRowsAfter)
        turnsChanged = sum(turnsChanged, other.turnsChanged)
    }

    /// One line of counts: "mic words 1200, judged 1100; user's 400 -> 340 (local->echo 60, echo->local 0); in echo
    /// 90 -> 35; mic rows 120 -> 104, unknown 30 -> 18; turns changed 22".
    public var line: String {
        var text = "mic words \(microphoneWords), judged \(judgedWords); user's \(localBefore) -> \(localAfter) "
            + "(local->echo \(localToEcho), echo->local \(echoToLocal)); in echo \(localInEchoBefore) -> "
            + "\(localInEchoAfter)"
        if let microphoneRowsBefore, let microphoneRowsAfter, let unknownRowsBefore, let unknownRowsAfter {
            text += "; mic rows \(microphoneRowsBefore) -> \(microphoneRowsAfter), unknown \(unknownRowsBefore) -> "
                + "\(unknownRowsAfter)"
        }
        if let turnsChanged { text += "; turns changed \(turnsChanged)" }
        return text
    }
}
