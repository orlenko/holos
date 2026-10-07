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
    /// Test hook: called once head.json names the new run, before anything after it; throwing is a failure after the
    /// rename (a folder sync).
    @TaskLocal static var afterHeadWritten: (@Sendable () throws -> Void)?

    struct Plan {
        var run: DiarizationRun
        var edits: [SpeakerEdit]
        var recognition: RecognitionResult?
        var voiceData: SessionVoiceData?
    }

    /// A complete replacement for the current head, or nil when there is no usable head to preserve.
    ///
    /// `move`: the word change is a Review word edit (or its undo) that moved these words and no others. Words are then
    /// mapped by index, not by time: every other word keeps its exact owner, and the replacement words take the owner of
    /// the words they replace (one turn). Recognizer timings of neighbouring words can overlap across speakers, so
    /// mapping an edit's words by time could give an untouched word to another turn as well.
    ///
    /// `undo`: `move` takes an edit back (`SessionWordEdit.restore`), whose mark is in the transcript it is made from;
    /// otherwise an edit's mark is in the new one.
    static func plan(session: URL, from snapshot: SpeakerSessionSnapshot, to transcript: Transcript,
                     move: ReviewWordMove? = nil, undo: Bool = false, now: Date = Date()) throws -> Plan? {
        guard let oldRun = snapshot.run, let projection = snapshot.projection,
              oldRun.transcriptID == snapshot.transcript.id else { return nil }
        guard snapshot.journal.isComplete else {
            throw HolosError.invalidInput("The speaker edits cannot all be read, so the labels cannot be kept.")
        }
        // Mapped by the words each automatic fix replaced (`heardWords`): counts that are wrong but add up would move
        // words between speakers, so they are checked against the unfixed revision first, when it can be read.
        if move == nil {
            try checkFixCounts(snapshot.transcript, session: session)
            try checkFixCounts(transcript, session: session)
        }
        let mapping = try move.map { try Mapping(from: snapshot.transcript, to: transcript, move: $0, undo: undo) }
            ?? Mapping(from: snapshot.transcript, to: transcript)
        // Every word a move replaces belongs to the same turns (an edit is refused otherwise), so each replacement word
        // takes exactly those turns. Checked here for every path that maps by a move, a recovery reading it from the
        // event log included: a damaged one would give words to turns that never held them.
        if let move, !TranscriptWordEdit.sameOwners(move.replaced, segmentID: move.segmentID,
                                                    turns: projection.turns.map(\.spans)) {
            throw TranscriptWordEdit.overlappingTurns
        }
        var run = oldRun
        run.id = UUID().uuidString
        // The same labelling, on other words: what was learned from the run before still holds (`labelling`).
        run.labelling = oldRun.labelling ?? oldRun.id
        run.createdAt = now
        run.transcriptID = transcript.id
        run.turns = try oldRun.turns.map { turn in
            var moved = turn
            moved.spans = try mapping.spans(turn.spans, turnID: turn.id)
            let timing = try mapping.timing(of: moved.spans, turnID: turn.id)
            // Words of the same times: the same audio, and the times the labelling gave it stay.
            if mapping.sameTimes(turn.spans, moved.spans) { return moved }
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
        try afterHeadWritten?()
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

    /// Maps spans through the same provenance model used for a saved speaker run. Kept separate from file planning
    /// so callers that already own the two revisions can validate a word change without touching session state.
    static func retargetedSpans(_ spans: [WordSpan], from old: Transcript, to new: Transcript) throws -> [WordSpan] {
        try Mapping(from: old, to: new).spans(spans, turnID: "transcript")
    }

    /// Every old word whose provenance a new word covers. A collapsed replacement can consume words from several
    /// speaker turns; keeping only its single nearest owner would leave the other turns with no span to retarget.
    private static func ownerCoverage(from oldSegment: TranscriptSegment, to newSegment: TranscriptSegment,
                                      commonBase: Bool) throws -> [[Int]] {
        let old = WordTiming.effectiveWords(of: oldSegment)
        let new = WordTiming.effectiveWords(of: newSegment)
        guard !old.isEmpty || new.isEmpty else {
            throw HolosError.invalidInput("The fixed transcript added words to an empty segment.")
        }
        guard !new.isEmpty else { return [] }
        if !old.allSatisfy(\.estimated), !new.allSatisfy(\.estimated) {
            let primary = try owners(from: oldSegment, to: newSegment, commonBase: commonBase)
            return new.indices.map { index in
                let covered = old.indices.filter { oldIndex in
                    max(0, min(old[oldIndex].end, new[index].end) - max(old[oldIndex].start, new[index].start)) > 0
                }
                return covered.isEmpty ? [primary[index]] : covered
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
            let covered = oldOrigins.words.indices.filter { overlap(oldOrigins.words[$0], word) > 0 }
            guard !covered.isEmpty else {
                throw HolosError.invalidInput("The fixed transcript's words cannot be mapped to the speaker labels.")
            }
            return covered
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
            case .correction, .term, .liveCorrection, .reviewEdit:
                // A damaged count is refused below (nil), never multiplied.
                originalCount = fix.heardWordCount() ?? 0
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

    /// Refuses (as damaged) a fixed `transcript` whose automatic fixes' recorded word counts do not lie over what they
    /// matched in its unfixed revision (`WordFixes.originalWordRanges`, `heardFits`). Nothing is checked when the
    /// revision cannot be read, or for a segment with an older fix (no recorded count: counted by its spaces, as before).
    private static func checkFixCounts(_ transcript: Transcript, session: URL) throws {
        let automatic = { (fix: TranscriptWordFix) in fix.kind == .correction || fix.kind == .term }
        guard let baseID = transcript.fixedFrom,
              transcript.segments.contains(where: { ($0.fixes ?? []).contains(where: automatic) }),
              let base = try? SessionFiles.transcript(id: baseID, session: session),
              !TranscriptWordEdit.hasRepeatedSegmentIDs(base) else { return }
        let baseSegments = Dictionary(base.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for segment in transcript.segments {
            let fixes = segment.fixes ?? []
            guard fixes.contains(where: automatic),
                  !fixes.contains(where: { automatic($0) && $0.heardWords == nil }),
                  let baseSegment = baseSegments[segment.id] else { continue }
            let ranges = WordFixes.originalWordRanges(fixes: fixes, currentWords: WordTiming.effectiveWords(of: segment),
                                                      originalWords: WordTiming.effectiveWords(of: baseSegment),
                                                      originalText: Array(baseSegment.text.utf16))
            guard !ranges.isEmpty else {
                throw HolosError.invalidInput("The transcript's word fixes do not match the transcript they were fixed "
                                              + "from, so speaker labels cannot be kept.")
            }
        }
    }

    private struct Mapping {
        /// The most replaced × replacement word pairs a word move may map (`init(from:to:move:)`): a million, far more
        /// than any edit of one turn's words.
        static let maximumMovePairs = 1_000_000

        struct Segment {
            var old: [EffectiveWord]
            var new: [EffectiveWord]
            /// Each new word's old word provenance. A word that collapses a phrase may cover several old words,
            /// possibly in adjacent language pieces.
            var owners: [[WordRef]]
        }

        var segments: [String: Segment]
        var order: [String]

        init(from old: Transcript, to new: Transcript) throws {
            // Read from disk: a segment whose words or marks cannot be trusted (`TranscriptWordEdit.isDamaged`) is never
            // mapped (combining language pieces offsets their marks, which a damaged one could overflow), nor a
            // transcript with a segment ID used twice.
            guard !TranscriptWordEdit.hasRepeatedSegmentIDs(old), !TranscriptWordEdit.hasRepeatedSegmentIDs(new),
                  !old.segments.contains(where: TranscriptWordEdit.isDamaged),
                  !new.segments.contains(where: TranscriptWordEdit.isDamaged) else {
                throw HolosError.invalidInput("The transcript's words or word fixes are damaged, so speaker labels "
                                              + "cannot be kept.")
            }
            let oldBase = old.liveCorrectedFrom ?? old.fixedFrom ?? old.id
            let newBase = new.liveCorrectedFrom ?? new.fixedFrom ?? new.id
            let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var mapped: [String: Segment] = [:]
            var groups: [[TranscriptSegment]] = []
            for segment in new.segments {
                if let last = groups.indices.last,
                   Self.pieceFamily(groups[last][0].id) == Self.pieceFamily(segment.id),
                   groups[last][0].track == segment.track {
                    groups[last].append(segment)
                } else {
                    groups.append([segment])
                }
            }
            for group in groups {
                let before = try group.map { segment -> TranscriptSegment in
                    guard let found = oldSegments[segment.id] else {
                        throw HolosError.invalidInput(
                            "The fixed transcript changed its segments, so speaker labels cannot be kept.")
                    }
                    return found
                }
                if try Self.mapIndividually(before: before, after: group,
                                            commonBase: oldBase == newBase, into: &mapped) {
                    continue
                }
                let oldCombined = Self.combined(before)
                let newCombined = Self.combined(group)
                let coverage = try SpeakerTranscriptRetarget.ownerCoverage(
                    from: oldCombined.segment, to: newCombined.segment, commonBase: oldBase == newBase)
                guard coverage.count == newCombined.refs.count else {
                    throw HolosError.invalidInput("The fixed transcript changed its segments, so speaker labels cannot be kept.")
                }
                var offset = 0
                for (beforeSegment, afterSegment) in zip(before, group) {
                    let oldWords = WordTiming.effectiveWords(of: beforeSegment)
                    let newWords = WordTiming.effectiveWords(of: afterSegment)
                    let owners = coverage[offset..<(offset + newWords.count)].map { indices in
                        indices.map { oldCombined.refs[$0] }
                    }
                    mapped[afterSegment.id] = Segment(old: oldWords, new: newWords, owners: owners)
                    offset += newWords.count
                }
            }
            guard Set(mapped.keys) == Set(oldSegments.keys) else {
                throw HolosError.invalidInput("The fixed transcript changed its segments, so speaker labels cannot be kept.")
            }
            segments = mapped
            order = new.segments.map(\.id)
        }

        /// A Review word edit's (or its undo's) mapping: in `move`'s segment, words before the replaced ones keep their
        /// index, words after shift by the change in count, and each replacement word is owned by every replaced word;
        /// every other segment keeps its words as they are.
        init(from old: Transcript, to new: Transcript, move: ReviewWordMove, undo: Bool) throws {
            let changed = HolosError.invalidInput("The edited transcript does not match the speaker labels' words.")
            let oldSegments = Dictionary(old.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The move names a segment both revisions have (one naming none would be ignored, its numbers unchecked),
            // and no segment ID is there twice (a damaged transcript: which one the move means cannot be told).
            guard Set(oldSegments.keys) == Set(new.segments.map(\.id)), old.segments.count == new.segments.count,
                  oldSegments.count == old.segments.count, oldSegments[move.segmentID] != nil,
                  move.replaced.lowerBound == move.replacement.lowerBound, move.replaced.lowerBound >= 0 else {
                throw changed
            }
            var mapped: [String: Segment] = [:]
            for segment in new.segments {
                guard let before = oldSegments[segment.id] else { throw changed }
                let oldWords = WordTiming.effectiveWords(of: before)
                let newWords = WordTiming.effectiveWords(of: segment)
                let ref = { (word: Int) in WordRef(segmentID: segment.id, word: word) }
                let owners: [[WordRef]]
                if segment.id == move.segmentID {
                    // Both ranges within their words before any count is used (a move read from a damaged journal
                    // can hold any numbers), then compared without adding, so nothing can overflow. Neither is ever
                    // empty (an edit, and its undo, replace words by words): an empty one would leave words with no
                    // owner, hidden from every turn.
                    guard !move.replaced.isEmpty, !move.replacement.isEmpty,
                          move.replaced.upperBound <= oldWords.count, move.replacement.upperBound <= newWords.count,
                          newWords.count - move.replacement.count == oldWords.count - move.replaced.count else {
                        throw changed
                    }
                    // Each replacement word is owned by every replaced word: an edit replaces a few words of one turn,
                    // so far fewer than `maximumMovePairs`; a move read from a damaged journal with more would take
                    // hours to map, and is refused as damaged.
                    let pairs = move.replaced.count.multipliedReportingOverflow(by: move.replacement.count)
                    guard !pairs.overflow, pairs.partialValue <= Self.maximumMovePairs else { throw changed }
                    // Every word outside the move reads the same in both revisions: a move whose numbers point
                    // elsewhere (damaged) would give the words around it to the wrong turns.
                    guard oldWords[..<move.replaced.lowerBound].map(\.text)
                            == newWords[..<move.replacement.lowerBound].map(\.text),
                          oldWords[move.replaced.upperBound...].map(\.text)
                            == newWords[move.replacement.upperBound...].map(\.text) else {
                        throw changed
                    }
                    // And the edit is where the move says: a Review edit leaves its mark over exactly its new words,
                    // and its undo (`undo`) takes back one over exactly the words it replaces. Repeated text ("go go
                    // go") can read the same around another place; the mark cannot, and an older mark elsewhere never
                    // stands in for it (each direction is checked on its own side).
                    func marked(_ fixes: [TranscriptWordFix]?, _ range: Range<Int>) -> Bool {
                        (fixes ?? []).contains {
                            $0.kind == .reviewEdit && $0.first == range.lowerBound && $0.end == range.upperBound
                        }
                    }
                    guard undo ? marked(before.fixes, move.replaced) : marked(segment.fixes, move.replacement) else {
                        throw changed
                    }
                    let replacedRefs = move.replaced.map(ref)
                    owners = newWords.indices.map { index in
                        if index < move.replacement.lowerBound { return [ref(index)] }
                        if index < move.replacement.upperBound { return replacedRefs }
                        return [ref(index - move.replacement.count + move.replaced.count)]
                    }
                } else {
                    // Every other segment is as it was.
                    guard newWords.map(\.text) == oldWords.map(\.text) else { throw changed }
                    owners = newWords.indices.map { [ref($0)] }
                }
                mapped[segment.id] = Segment(old: oldWords, new: newWords, owners: owners)
            }
            segments = mapped
            order = new.segments.map(\.id)
        }

        /// True when every piece maps in its own word space. A cross-piece correction deliberately makes the
        /// surviving piece's provenance larger than that piece's old word count; that falls through to the combined
        /// language-family mapping.
        private static func mapIndividually(before: [TranscriptSegment], after: [TranscriptSegment],
                                            commonBase: Bool, into mapped: inout [String: Segment]) throws -> Bool {
            var additions: [String: Segment] = [:]
            for (oldSegment, newSegment) in zip(before, after) {
                let oldWords = WordTiming.effectiveWords(of: oldSegment)
                let newWords = WordTiming.effectiveWords(of: newSegment)
                guard oldWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite }),
                      newWords.allSatisfy({ $0.start.isFinite && $0.end.isFinite }) else {
                    throw HolosError.invalidInput(
                        "The transcript has unusable word timing, so speaker labels cannot be kept.")
                }
                if before.count > 1, commonBase {
                    let oldBase = try SpeakerTranscriptRetarget.origins(of: oldSegment).baseWords
                    let newBase = try SpeakerTranscriptRetarget.origins(of: newSegment).baseWords
                    if oldBase != newBase { return false }
                }
                let coverage = try SpeakerTranscriptRetarget.ownerCoverage(
                    from: oldSegment, to: newSegment, commonBase: commonBase)
                additions[newSegment.id] = Segment(
                    old: oldWords, new: newWords,
                    owners: coverage.map { indices in
                        indices.map { WordRef(segmentID: oldSegment.id, word: $0) }
                    })
            }
            mapped.merge(additions, uniquingKeysWith: { _, new in new })
            return true
        }

        private static func pieceFamily(_ id: String) -> String {
            guard let slash = id.lastIndex(of: "/"), Int(id[id.index(after: slash)...]) != nil else { return id }
            return String(id[..<slash])
        }

        private static func combined(_ pieces: [TranscriptSegment])
            -> (segment: TranscriptSegment, refs: [WordRef]) {
            var refs: [WordRef] = []
            var text: [String] = []
            var fixes: [TranscriptWordFix] = []
            var offset = 0
            for piece in pieces {
                let words = WordTiming.effectiveWords(of: piece)
                refs += words.indices.map { WordRef(segmentID: piece.id, word: $0) }
                text += words.map { _ in "word" }
                fixes += (piece.fixes ?? []).map {
                    TranscriptWordFix(first: $0.first + offset, end: $0.end + offset,
                                      heard: $0.heard, kind: $0.kind, heardWords: $0.heardWords, deleted: $0.deleted)
                }
                offset += words.count
            }
            return (TranscriptSegment(start: 0, end: Double(max(1, refs.count)),
                                      text: text.joined(separator: " "), fixes: fixes), refs)
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
            for segmentID in order {
                guard let segment = segments[segmentID] else { continue }
                let indices = segment.owners.indices.filter { index in
                    segment.owners[index].contains { owner in
                        spans.contains { span in
                            span.segmentID == owner.segmentID && span.first <= owner.word && owner.word < span.end
                        }
                    }
                }
                for index in indices {
                    if let last = result.last, last.segmentID == segmentID, last.end == index {
                        result[result.count - 1].end = index + 1
                    } else {
                        result.append(WordSpan(segmentID: segmentID, first: index, end: index + 1))
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

        /// Whether `old` spans (of the old revision) and `new` spans (their mapping) name words of the same times, one
        /// for one: the turn's audio is unchanged, so it keeps its own times (a labelling may time a turn otherwise
        /// than by its words; a voice learned from it was learned from those). False for a span outside its segment.
        func sameTimes(_ old: [WordSpan], _ new: [WordSpan]) -> Bool {
            func words(_ spans: [WordSpan], old: Bool) -> [EffectiveWord]? {
                var words: [EffectiveWord] = []
                for span in spans {
                    guard let segment = segments[span.segmentID] else { return nil }
                    let side = old ? segment.old : segment.new
                    guard span.first >= 0, span.first < span.end, span.end <= side.count else { return nil }
                    words += side[span.first..<span.end]
                }
                return words
            }
            guard let before = words(old, old: true), let after = words(new, old: false),
                  before.count == after.count else { return false }
            return zip(before, after).allSatisfy {
                $0.start == $1.start && $0.end == $1.end && $0.estimated == $1.estimated
            }
        }

        func action(_ action: SpeakerEditAction) throws -> SpeakerEditAction {
            switch action {
            case .splitTurn(let turnID, let at):
                let candidates = order.flatMap { segmentID -> [(WordRef, [WordRef])] in
                    guard let segment = segments[segmentID] else { return [] }
                    return segment.owners.indices.map {
                        (WordRef(segmentID: segmentID, word: $0), segment.owners[$0])
                    }
                }
                let exact = candidates.first { $0.1.contains(at) }
                let later = candidates.first { candidate in
                    candidate.1.contains { $0.segmentID == at.segmentID && $0.word > at.word }
                }
                guard let moved = (exact ?? later)?.0 else {
                    throw HolosError.invalidInput("A split speaker turn cannot be kept across this word change.")
                }
                return .splitTurn(turnID: turnID, at: moved)
            default:
                return action
            }
        }
    }
}
