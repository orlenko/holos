import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// Keeps a meeting's speaker labels when a word-fix revision replaces the transcript without changing its segments
/// or audio. The immutable speaker run is copied to the new transcript with its word spans mapped by time, then the
/// effective edit journal is replayed on that run. Nothing is guessed from names or transcript text.
enum SpeakerTranscriptRetarget {
    @TaskLocal static var beforePublishHead: (@Sendable () throws -> Void)?
    @TaskLocal static var afterPublishHead: (@Sendable () -> Void)?

    struct Plan {
        var run: DiarizationRun
        var edits: [SpeakerEdit]
        var recognition: RecognitionResult?
        var voiceData: SessionVoiceData?
    }

    /// A complete replacement for the current head, or nil when there is no usable head to preserve.
    static func plan(session: URL, from snapshot: SpeakerSessionSnapshot, to transcript: Transcript,
                     now: Date = Date()) throws -> Plan? {
        guard let oldRun = snapshot.run, let projection = snapshot.projection,
              oldRun.transcriptID == snapshot.transcript.id else { return nil }
        guard snapshot.journal.isComplete else {
            throw HolosError.invalidInput("The speaker edits cannot all be read, so the labels cannot be kept.")
        }
        let mapping = try Mapping(from: snapshot.transcript, to: transcript)
        var run = oldRun
        run.id = UUID().uuidString
        run.createdAt = now
        run.transcriptID = transcript.id
        run.turns = try oldRun.turns.map { turn in
            var moved = turn
            moved.spans = try mapping.spans(turn.spans, turnID: turn.id)
            let timing = try mapping.timing(of: moved.spans, turnID: turn.id)
            moved.start = timing.start
            moved.end = timing.end
            moved.timing = timing.quality
            return moved
        }
        run.droppedWords = oldRun.droppedWords.compactMap { dropped in
            let spans = mapping.spansAllowingEmpty(dropped.spans)
            return spans.isEmpty ? nil : DroppedWords(spans: spans, reason: dropped.reason)
        }

        let effective = Set(projection.appliedEditIDs)
        var view = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil,
                                          profileNames: [:])
        var edits: [SpeakerEdit] = []
        for old in snapshot.journal.edits where old.baseRunID == oldRun.id && effective.contains(old.id) {
            let action = try mapping.action(old.action)
            let expected = view.fingerprint(for: action)
            let staleBefore = view.staleEdits.count
            view = view.applying(action, editID: old.id)
            guard view.appliedEditIDs.contains(old.id), view.staleEdits.count == staleBefore else {
                throw HolosError.invalidInput("A speaker edit cannot be kept across this word change.")
            }
            edits.append(SpeakerEdit(id: old.id, baseRunID: run.id, at: old.at, source: "carry", action: action,
                                     expected: expected, batchID: old.batchID))
        }

        var recognition = snapshot.recognition
        recognition?.runID = run.id
        recognition?.createdAt = now
        var voiceData = try? SessionSpeakerStore.readVoiceData(runID: oldRun.id, session: session)
        voiceData?.runID = run.id
        voiceData?.createdAt = now
        return Plan(run: run, edits: edits, recognition: recognition, voiceData: voiceData)
    }

    /// Writes everything that may safely be orphaned before the transcript pointer changes. The head is published
    /// separately, after the new transcript is current.
    static func stage(_ plan: Plan, session: URL) throws {
        try SessionSpeakerStore.writeRun(plan.run, session: session)
        try SessionSpeakerStore.appendEdits(plan.edits, session: session)
        if let recognition = plan.recognition {
            try SessionSpeakerStore.writeRecognition(recognition, session: session)
        }
        if let voiceData = plan.voiceData {
            try SessionSpeakerStore.writeVoiceData(voiceData, session: session)
        }
    }

    static func publishHead(_ plan: Plan, session: URL, now: Date = Date()) throws {
        try beforePublishHead?()
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: plan.run.id, updatedAt: now), session: session)
        afterPublishHead?()
    }

    /// New-word ownership in the old word space. Recognizer timings are stable across a word fix, but estimated
    /// timings are redistributed when the number of words changes. Those use each fix's original-word provenance;
    /// comparing text is ambiguous when the replacement also occurs beside it ("one two" -> "two two").
    static func owners(from oldSegment: TranscriptSegment, to newSegment: TranscriptSegment,
                       commonBase: Bool) throws -> [Int] {
        let old = WordTiming.effectiveWords(of: oldSegment)
        let new = WordTiming.effectiveWords(of: newSegment)
        guard !old.isEmpty || new.isEmpty else {
            throw HolosError.invalidInput("The fixed transcript added words to an empty segment.")
        }
        guard !new.isEmpty else { return [] }
        if !old.allSatisfy(\.estimated), !new.allSatisfy(\.estimated) {
            return new.map { word in
                let middle = (word.start + word.end) / 2
                return old.indices.max { left, right in
                    score(old[left], for: word, middle: middle, index: left)
                        < score(old[right], for: word, middle: middle, index: right)
                } ?? 0
            }
        }
        guard commonBase else {
            throw HolosError.invalidInput("The fixed transcript's words cannot be mapped to the speaker labels.")
        }

        let oldOrigins = try origins(of: oldSegment)
        let newOrigins = try origins(of: newSegment)
        guard oldOrigins.baseWords == newOrigins.baseWords else {
            throw HolosError.invalidInput("The fixed transcript's words cannot be mapped to the speaker labels.")
        }
        return try newOrigins.words.map { word in
            guard let owner = oldOrigins.words.indices.max(by: { left, right in
                originScore(oldOrigins.words[left], for: word, index: left)
                    < originScore(oldOrigins.words[right], for: word, index: right)
            }), overlap(oldOrigins.words[owner], word) > 0 else {
                throw HolosError.invalidInput("The fixed transcript's words cannot be mapped to the speaker labels.")
            }
            return owner
        }
    }

    private struct Origin {
        var start: Double
        var end: Double
    }

    /// Every effective word's interval in the unfixed segment's word space. Automatic marks say how many original
    /// words their replacement consumed; a Review-revert mark already contains those original words again.
    private static func origins(of segment: TranscriptSegment) throws -> (words: [Origin], baseWords: Int) {
        let count = WordTiming.effectiveWords(of: segment).count
        let fixes = (segment.fixes ?? []).sorted { ($0.first, $0.end) < ($1.first, $1.end) }
        var result: [Origin] = []
        var current = 0
        var original = 0
        func appendUnchanged(_ amount: Int) {
            for offset in 0..<amount {
                result.append(Origin(start: Double(original + offset), end: Double(original + offset + 1)))
            }
        }
        for fix in fixes {
            guard fix.first >= current, fix.first < fix.end, fix.end <= count else {
                throw HolosError.invalidInput("The fixed transcript's word provenance is invalid.")
            }
            let unchanged = fix.first - current
            appendUnchanged(unchanged)
            current += unchanged
            original += unchanged

            let replacementCount = fix.end - fix.first
            let originalCount: Int
            switch fix.kind {
            case .correction, .term, .liveCorrection:
                originalCount = WordFixes.tokens(of: Array(fix.heard.utf16)).count
            case .reviewRevert:
                originalCount = replacementCount
            default:
                throw HolosError.invalidInput("The fixed transcript has unknown word-fix provenance.")
            }
            guard originalCount > 0 else {
                throw HolosError.invalidInput("The fixed transcript's word provenance is invalid.")
            }
            for offset in 0..<replacementCount {
                result.append(Origin(
                    start: Double(original) + Double(offset * originalCount) / Double(replacementCount),
                    end: Double(original) + Double((offset + 1) * originalCount) / Double(replacementCount)))
            }
            current = fix.end
            original += originalCount
        }
        appendUnchanged(count - current)
        original += count - current
        guard result.count == count else {
            throw HolosError.invalidInput("The fixed transcript's word provenance is invalid.")
        }
        return (result, original)
    }

    private static func overlap(_ left: Origin, _ right: Origin) -> Double {
        max(0, min(left.end, right.end) - max(left.start, right.start))
    }

    private static func originScore(_ old: Origin, for new: Origin, index: Int) -> (Double, Double, Int) {
        let distance = abs((old.start + old.end) / 2 - (new.start + new.end) / 2)
        return (overlap(old, new), -distance, -index)
    }

    private static func score(_ old: EffectiveWord, for new: EffectiveWord, middle: Double, index: Int)
        -> (Double, Double, Int) {
        let overlap = max(0, min(old.end, new.end) - max(old.start, new.start))
        let distance = abs((old.start + old.end) / 2 - middle)
        return (overlap, -distance, -index)
    }

    private struct Mapping {
        struct Segment {
            var old: [EffectiveWord]
            var new: [EffectiveWord]
            /// New word index -> old word index.
            var owner: [Int]
        }

        var segments: [String: Segment]

        init(from old: Transcript, to new: Transcript) throws {
            let oldBase = old.liveCorrectedFrom ?? old.fixedFrom ?? old.id
            let newBase = new.liveCorrectedFrom ?? new.fixedFrom ?? new.id
            let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var mapped: [String: Segment] = [:]
            for segment in new.segments {
                guard let before = oldSegments[segment.id] else {
                    throw HolosError.invalidInput("The fixed transcript changed its segments, so speaker labels cannot be kept.")
                }
                let oldWords = WordTiming.effectiveWords(of: before)
                let newWords = WordTiming.effectiveWords(of: segment)
                guard oldWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite }),
                      newWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite }) else {
                    throw HolosError.invalidInput("The transcript has unusable word timing, so speaker labels cannot be kept.")
                }
                let owner = try SpeakerTranscriptRetarget.owners(from: before, to: segment,
                                                                 commonBase: oldBase == newBase)
                mapped[segment.id] = Segment(old: oldWords, new: newWords, owner: owner)
            }
            guard Set(mapped.keys) == Set(oldSegments.keys) else {
                throw HolosError.invalidInput("The fixed transcript changed its segments, so speaker labels cannot be kept.")
            }
            segments = mapped
        }

        func spans(_ spans: [WordSpan], turnID: String) throws -> [WordSpan] {
            let result = spansAllowingEmpty(spans)
            guard !result.isEmpty else {
                throw HolosError.invalidInput("Speaker labels cannot be kept across this word change (turn \(turnID)).")
            }
            return result
        }

        func spansAllowingEmpty(_ spans: [WordSpan]) -> [WordSpan] {
            var result: [WordSpan] = []
            for span in spans {
                guard let segment = segments[span.segmentID] else { continue }
                let indices = segment.owner.indices.filter { span.first <= segment.owner[$0] && segment.owner[$0] < span.end }
                for index in indices {
                    if let last = result.last, last.segmentID == span.segmentID, last.end == index {
                        result[result.count - 1].end = index + 1
                    } else {
                        result.append(WordSpan(segmentID: span.segmentID, first: index, end: index + 1))
                    }
                }
            }
            return result
        }

        func timing(of spans: [WordSpan], turnID: String) throws
            -> (start: Double, end: Double, quality: WordTimingQuality) {
            var words: [EffectiveWord] = []
            for span in spans {
                guard let segment = segments[span.segmentID], span.first >= 0, span.first < span.end,
                      span.end <= segment.new.count else {
                    throw HolosError.invalidInput("Speaker labels cannot be kept across this word change (turn \(turnID)).")
                }
                words += segment.new[span.first..<span.end]
            }
            guard let first = words.first else {
                throw HolosError.invalidInput("Speaker labels cannot be kept across this word change (turn \(turnID)).")
            }
            let estimated = words.filter(\.estimated).count
            let quality: WordTimingQuality = estimated == 0 ? .measured : estimated == words.count ? .estimated : .mixed
            return (words.map(\.start).min() ?? first.start, words.map(\.end).max() ?? first.end, quality)
        }

        func action(_ action: SpeakerEditAction) throws -> SpeakerEditAction {
            switch action {
            case .splitTurn(let turnID, let at):
                guard let segment = segments[at.segmentID] else {
                    throw HolosError.invalidInput("A split speaker turn no longer refers to this transcript.")
                }
                let index = segment.owner.firstIndex(of: at.word)
                    ?? segment.owner.firstIndex(where: { $0 > at.word })
                guard let index else {
                    throw HolosError.invalidInput("A split speaker turn cannot be kept across this word change.")
                }
                return .splitTurn(turnID: turnID, at: WordRef(segmentID: at.segmentID, word: index))
            default:
                return action
            }
        }
    }
}
