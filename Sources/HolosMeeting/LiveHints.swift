import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// A correction made against one finalized phrase in the live transcript. The phrase ID is the quick path; its
/// track, word range, words, and times are durable evidence for the final transcript, whose replay may use another ID.
public struct LiveHint: Codable, Sendable, Equatable, Identifiable {
    public enum Action: Codable, Sendable, Equatable {
        case replaceText(String)
        case nameSpeaker(String)
    }

    public var schemaVersion = 1
    public var id: String
    public var at: Date
    public var segmentID: String
    public var track: String
    public var firstWord: Int
    public var endWord: Int
    public var start: Double
    public var end: Double
    public var heard: String
    public var action: Action
    /// Correction-list rules this live edit actually added. Nil is an older hint that did not record ownership;
    /// treating it as none keeps an identical rule that may have predated the edit.
    public var learned: [Correction]?

    public init(id: String = UUID().uuidString, at: Date = Date(), segmentID: String, track: String,
                firstWord: Int, endWord: Int, start: Double, end: Double, heard: String, action: Action,
                learned: [Correction]? = nil) {
        self.id = id; self.at = at; self.segmentID = segmentID; self.track = track
        self.firstWord = firstWord; self.endWord = endWord; self.start = start; self.end = end
        self.heard = heard; self.action = action; self.learned = learned
    }
}

/// The small, atomically replaced sidecar the app may write while the recorder owns the session journal.
public struct LiveHintFile: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sessionID: String
    public var hints: [LiveHint]
    /// True once post-processing has taken the final snapshot. Optional keeps schema 1 files written by an older
    /// build readable; nil means open.
    public var sealed: Bool?

    public init(sessionID: String, hints: [LiveHint] = [], sealed: Bool = false) {
        self.sessionID = sessionID; self.hints = hints; self.sealed = sealed
    }
}

public enum LiveHintStore {
    public static let maximumHints = 5_000
    private static let maximumLearnedCorrections = 2_000
    private static let maximumBytes = 8 << 20

    /// Missing means no hints. A newer file is refused; a copied file must name this session.
    public static func read(session: URL) throws -> LiveHintFile {
        let manifest = try SessionArchive.readManifest(at: session)
        guard let data = try AtomicFile.readIfPresent(SessionPaths.liveHints(session), maxBytes: maximumBytes) else {
            return LiveHintFile(sessionID: manifest.id)
        }
        let file = try decode(data)
        guard file.sessionID == manifest.id else {
            throw HolosError.invalidInput("live-hints.json belongs to another session.")
        }
        guard file.hints.count <= maximumHints else {
            throw HolosError.invalidInput("live-hints.json has too many corrections.")
        }
        for hint in file.hints { try validate(hint) }
        return file
    }

    /// Adds one hint under a lock beside the sidecar, preserving a hint another app instance saved meanwhile.
    public static func append(_ hint: LiveHint, session: URL) throws {
        try validate(hint)
        let url = SessionPaths.liveHints(session)
        try CorrectionList.withFileLock(for: url) {
            var file = try read(session: session)
            guard file.sealed != true else {
                throw HolosError.unavailable("This meeting is no longer accepting live corrections.")
            }
            guard file.hints.count < maximumHints else {
                throw HolosError.invalidInput("This meeting already has too many live corrections.")
            }
            file.hints.append(hint)
            let data = try HolosJSON.encoder().encode(file)
            guard data.count <= maximumBytes else {
                throw HolosError.invalidInput("This meeting already has too much live correction data.")
            }
            try AtomicFile.write(data, to: url)
        }
    }

    /// Records which global correction rules an already-saved hint actually added. This follows `append` because
    /// the timed edit is useful even when learning fails. A crash between the two writes conservatively leaves nil,
    /// so a later edit will keep rather than delete a possibly pre-existing rule.
    public static func recordLearned(_ learned: [Correction], for hintID: String, session: URL) throws {
        let url = SessionPaths.liveHints(session)
        try CorrectionList.withFileLock(for: url) {
            var file = try read(session: session)
            guard let index = file.hints.lastIndex(where: { $0.id == hintID }) else {
                throw HolosError.invalidInput("That live correction is no longer in this meeting.")
            }
            file.hints[index].learned = learned
            try validate(file.hints[index])
            let data = try HolosJSON.encoder().encode(file)
            guard data.count <= maximumBytes else {
                throw HolosError.invalidInput("This meeting already has too much live correction data.")
            }
            try AtomicFile.write(data, to: url)
        }
    }

    /// Atomically takes the final set of hints and prevents later appends. Whichever operation gets the sidecar lock
    /// first wins: a correction is either in this returned snapshot or is refused, never reported saved but omitted.
    public static func sealAndRead(session: URL) throws -> LiveHintFile {
        let url = SessionPaths.liveHints(session)
        return try CorrectionList.withFileLock(for: url) {
            var file = try read(session: session)
            if file.sealed != true {
                file.sealed = true
                let data = try HolosJSON.encoder().encode(file)
                guard data.count <= maximumBytes else {
                    throw HolosError.invalidInput("This meeting already has too much live correction data.")
                }
                try AtomicFile.write(data, to: url)
            }
            return file
        }
    }

    private struct VersionProbe: Decodable { var schemaVersion: Int? }

    private static func decode(_ data: Data) throws -> LiveHintFile {
        if let version = (try? HolosJSON.decoder().decode(VersionProbe.self, from: data))?.schemaVersion {
            if version > 1 {
                throw HolosError.unavailable("live-hints.json was written by a newer version of Voice is Local; update Voice is Local to read it.")
            }
            if version < 1 { throw HolosError.invalidInput("live-hints.json has an unsupported schema version.") }
        }
        do { return try HolosJSON.decoder().decode(LiveHintFile.self, from: data) } catch {
            throw HolosError.invalidInput("live-hints.json is damaged or was not written by Voice is Local.")
        }
    }

    private static func validate(_ hint: LiveHint) throws {
        guard hint.schemaVersion == 1, SessionArchive.validToken(hint.id),
              SessionArchive.validToken(hint.segmentID), SessionArchive.validToken(hint.track),
              hint.track.utf8.count <= 128,
              hint.firstWord >= 0, hint.firstWord < hint.endWord,
              hint.start.isFinite, hint.end.isFinite, hint.start >= 0, hint.start <= hint.end,
              hint.heard.contains(where: { !$0.isWhitespace }) else {
            throw HolosError.invalidInput("That live correction is not valid.")
        }
        let value: String = switch hint.action {
        case .replaceText(let text), .nameSpeaker(let text): text
        }
        guard value.contains(where: { !$0.isWhitespace }), value.utf8.count <= 16_384,
              hint.heard.utf8.count <= 16_384 else {
            throw HolosError.invalidInput("That live correction is empty or too long.")
        }
        if case .replaceText(let text) = hint.action,
           !text.contains(where: { $0.isLetter || $0.isNumber }) {
            throw HolosError.invalidInput("A live text correction must contain a word or number.")
        }
        guard let learned = hint.learned else { return }
        guard learned.count <= maximumLearnedCorrections,
              learned.allSatisfy({ correction in
                  correction.heard.contains(where: { !$0.isWhitespace })
                      && correction.meant.contains(where: { !$0.isWhitespace })
                      && correction.heard != correction.meant
                      && correction.heard.utf8.count <= 16_384
                      && correction.meant.utf8.count <= 16_384
              }) else {
            throw HolosError.invalidInput("That live correction has invalid learned rules.")
        }
    }
}

/// Reconciles live hints with the final transcript. IDs win when their recorded words still agree; otherwise nearby
/// same-track words win, so replay and language segmentation may replace IDs without matching a distant occurrence.
public enum LiveHints {
    private static let maximumReplayMatchGap = 1.0

    public struct TextOutcome: Sendable, Equatable {
        public var transcript: Transcript
        public var applied: Int
        public var alreadyApplied: Int
        public var unmatched: Int
    }

    struct Match: Sendable, Equatable {
        var segment: Int
        var words: Range<Int>
        var start: Double
        var end: Double
    }

    /// What a repeated edit originally corrected. The hint being saved contains the text currently on screen (so its
    /// timed chain remains A→B→C); learning should replace the global A→B rule with A→C.
    public static func originalHeard(for hint: LiveHint, among hints: [LiveHint]) -> String {
        hints.first { candidate in
            guard case .replaceText = candidate.action else { return false }
            return candidate.segmentID == hint.segmentID && candidate.track == hint.track
                && candidate.firstWord == hint.firstWord && candidate.endWord == hint.endWord
        }?.heard ?? hint.heard
    }

    /// Rules the last text edit of this same timed phrase actually added. Older hints did not record this field;
    /// returning none for them avoids claiming and later deleting a rule that may have existed beforehand.
    public static func learnedCorrections(for hint: LiveHint, among hints: [LiveHint]) -> [Correction] {
        hints.last { candidate in
            guard case .replaceText = candidate.action else { return false }
            return candidate.segmentID == hint.segmentID && candidate.track == hint.track
                && candidate.firstWord == hint.firstWord && candidate.endWord == hint.endWord
        }?.learned ?? []
    }

    public static func applyingText(_ hints: [LiveHint], to transcript: Transcript,
                                    now: Date = Date()) -> TextOutcome {
        var result = transcript
        var applied = 0, already = 0, unmatched = 0
        // Re-editing one live piece records what the user saw each time (A→B, then B→C). Collapse that chain to
        // A→C before making provenance, rather than stacking overlapping word-fix marks.
        struct TextHint {
            var hint: LiveHint
            /// Every state the live phrase had before its final edit, in edit order.
            var heard: [String]
        }
        var textHints: [TextHint] = []
        var positions: [String: Int] = [:]
        for hint in hints {
            guard case .replaceText = hint.action else { continue }
            let key = "\(hint.segmentID):\(hint.firstWord):\(hint.endWord)"
            if let index = positions[key] {
                textHints[index].heard.append(hint.heard)
                textHints[index].hint.action = hint.action
            } else {
                positions[key] = textHints.count
                textHints.append(TextHint(hint: hint, heard: [hint.heard]))
            }
        }
        for edit in textHints {
            let hint = edit.hint
            guard case .replaceText(let replacement) = hint.action else { continue }
            if let found = match(hint, in: result, text: replacement),
               let range = characterRange(found.words, matching: replacement,
                                          in: result.segments[found.segment]),
               text(in: range, of: result.segments[found.segment]) == replacement {
                let segment = result.segments[found.segment]
                guard var working = WordFixes.Working(segment, preservingExistingFixes: true) else {
                    unmatched += 1
                    continue
                }
                // Replay may independently produce the text the person requested. It still needs live provenance:
                // without the mark, the automatic word-fix stage can replace the person's explicit choice. Replace
                // an overlapping older mark, but keep the replay's text and word timings exactly as they are.
                working.marks.removeAll { $0.range.overlaps(range) }
                working.marks.append(.init(range: range, heard: hint.heard, kind: .liveCorrection))
                working.marks.sort { $0.range.lowerBound < $1.range.lowerBound }
                let marked = WordFixes.finished(working, segment: segment)
                if marked != segment {
                    result.segments[found.segment] = marked
                    applied += 1
                } else {
                    already += 1
                }
                continue
            }
            // Recovery may already contain an intermediate state (A→B→C replayed from B). Prefer the most
            // recent heard form, but keep the first form as the single collapsed mark's provenance.
            let found = edit.heard.reversed().lazy.compactMap { heard in
                match(hint, in: result, text: heard).map { (match: $0, heard: heard) }
            }.first
            if let found,
               let working = WordFixes.Working(result.segments[found.match.segment], preservingExistingFixes: true),
               let range = characterRange(found.match.words, matching: found.heard,
                                          in: result.segments[found.match.segment]) {
                let changed = WordFixes.applying([
                    .init(range: range, text: replacement, kind: .liveCorrection, heard: hint.heard),
                ], to: working)
                let segment = WordFixes.finished(changed, segment: result.segments[found.match.segment])
                if segment != result.segments[found.match.segment] {
                    result.segments[found.match.segment] = segment
                    applied += 1
                } else {
                    unmatched += 1
                }
            } else {
                unmatched += 1
            }
        }
        if applied > 0 {
            result.id = UUID().uuidString
            result.createdAt = now
            result.liveCorrectedFrom = transcript.liveCorrectedFrom ?? transcript.id
        }
        return TextOutcome(transcript: result, applied: applied, alreadyApplied: already, unmatched: unmatched)
    }

    /// Speaker renames in hint order. Several phrases assigned to the same machine speaker collapse to its last name.
    public static func speakerActions(_ hints: [LiveHint], projection: SpeakerProjection,
                                      transcript: Transcript) -> [SpeakerEditAction] {
        var names: [String: String] = [:]
        var order: [String] = []
        for hint in hints {
            guard case .nameSpeaker(let rawName) = hint.action,
                  let name = SpeakerEditor.cleanName(rawName) else { continue }
            let found = match(hint, in: transcript, text: hint.heard)
            let refs: Set<WordRef> = found.map { item in
                Set(item.words.map { WordRef(segmentID: transcript.segments[item.segment].id, word: $0) })
            } ?? []
            let candidates = projection.turns.filter { $0.track == hint.track && $0.speakerID != nil }
            let turn = candidates.max { left, right in
                turnScore(left, refs: refs, hint: hint) < turnScore(right, refs: refs, hint: hint)
            }
            guard let turn, let speakerID = turn.speakerID else { continue }
            let score = turnScore(turn, refs: refs, hint: hint)
            guard score.0 > 0 || score.1 > 0 else { continue }
            if names[speakerID] == nil { order.append(speakerID) }
            names[speakerID] = name
        }
        return order.compactMap { id in names[id].map { .rename(speakerID: id, name: $0) } }
    }

    static func match(_ hint: LiveHint, in transcript: Transcript, text: String) -> Match? {
        let wanted = tokens(text)
        guard !wanted.isEmpty else { return nil }
        var candidates: [(match: Match, exactID: Bool, overlap: Double, distance: Double)] = []
        for (segmentIndex, segment) in transcript.segments.enumerated() where (segment.track ?? "mic") == hint.track {
            let words = WordTiming.effectiveWords(of: segment)
            let comparable: [(word: Int, token: String)] = words.enumerated().compactMap { index, word in
                let token = normalized(word.text)
                return token.isEmpty ? nil : (index, token)
            }
            guard comparable.count >= wanted.count else { continue }
            for first in 0...(comparable.count - wanted.count) {
                let matched = comparable[first..<(first + wanted.count)]
                guard matched.map(\.token) == wanted,
                      let firstWord = matched.first?.word,
                      let lastWord = matched.last?.word else { continue }
                let range = firstWord..<(lastWord + 1)
                let start = words[range.lowerBound].start
                let end = words[range.upperBound - 1].end
                let overlap = max(0, min(end, hint.end) - max(start, hint.start))
                let distance = abs((start + end) / 2 - (hint.start + hint.end) / 2)
                let exactID = segment.id == hint.segmentID && range == hint.firstWord..<hint.endWord
                let gap = max(0, max(hint.start - end, start - hint.end))
                guard exactID || gap <= maximumReplayMatchGap else { continue }
                candidates.append((Match(segment: segmentIndex, words: range, start: start, end: end), exactID,
                                   overlap, distance))
            }
        }
        return candidates.max {
            ($0.exactID ? 1 : 0, $0.overlap, -$0.distance, -$0.match.start)
                < ($1.exactID ? 1 : 0, $1.overlap, -$1.distance, -$1.match.start)
        }?.match
    }

    /// The word range, expanded to the exact displayed phrase when it also contains untimed punctuation. Speech can
    /// give "Hello." a timed word range covering only "Hello"; replacing just that range with "Hi." would otherwise
    /// leave the old period behind and produce "Hi..". Requiring the displayed phrase to contain the timed range
    /// keeps repeated text elsewhere in the segment out of the match.
    private static func characterRange(_ words: Range<Int>, matching displayed: String,
                                       in segment: TranscriptSegment) -> Range<Int>? {
        let effective = WordTiming.effectiveWords(of: segment)
        guard !words.isEmpty, words.lowerBound >= 0, words.upperBound <= effective.count else { return nil }
        let first = effective[words.lowerBound]
        let last = effective[words.upperBound - 1]
        let range = first.utf16Offset..<(last.utf16Offset + last.utf16Length)
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
              range.upperBound <= segment.text.utf16.count else { return nil }
        let displayed = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = displayed.utf16.count
        guard length >= range.count, length <= segment.text.utf16.count else { return range }
        let firstStart = max(0, range.upperBound - length)
        let lastStart = min(range.lowerBound, segment.text.utf16.count - length)
        guard firstStart <= lastStart else { return range }
        let source = segment.text as NSString
        for start in firstStart...lastStart {
            let candidate = source.substring(with: NSRange(location: start, length: length))
            if candidate.compare(displayed, options: [.caseInsensitive]) == .orderedSame {
                return start..<(start + length)
            }
        }
        // A replay may keep the words but choose different untimed punctuation ("Hello." → "Hello!"). The hint's
        // boundary punctuation still says that punctuation was part of the editable phrase, so replace whatever
        // non-word marks the replay put directly against that boundary.
        let utf16 = segment.text.utf16
        let lowerUTF16 = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let upperUTF16 = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard displayed.first.map(isBoundaryMark) == true || displayed.last.map(isBoundaryMark) == true,
              let lower = String.Index(lowerUTF16, within: segment.text),
              let upper = String.Index(upperUTF16, within: segment.text) else { return range }
        var expandedLower = lower
        var expandedUpper = upper
        if displayed.first.map(isBoundaryMark) == true {
            while expandedLower > segment.text.startIndex {
                let previous = segment.text.index(before: expandedLower)
                guard isBoundaryMark(segment.text[previous]) else { break }
                expandedLower = previous
            }
        }
        if displayed.last.map(isBoundaryMark) == true {
            while expandedUpper < segment.text.endIndex,
                  isBoundaryMark(segment.text[expandedUpper]) {
                expandedUpper = segment.text.index(after: expandedUpper)
            }
        }
        return expandedLower.utf16Offset(in: segment.text)..<expandedUpper.utf16Offset(in: segment.text)
    }

    private static func isBoundaryMark(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && !character.isWhitespace
    }

    private static func text(in range: Range<Int>, of segment: TranscriptSegment) -> String {
        String(decoding: Array(segment.text.utf16)[range], as: UTF16.self)
    }

    private static func turnScore(_ turn: ProjectedTurn, refs: Set<WordRef>, hint: LiveHint)
        -> (Int, Double, Double) {
        let words = turn.spans.reduce(0) { count, span in
            count + (span.first..<span.end).filter { refs.contains(WordRef(segmentID: span.segmentID, word: $0)) }.count
        }
        let overlap = max(0, min(turn.end, hint.end) - max(turn.start, hint.start))
        let distance = abs((turn.start + turn.end) / 2 - (hint.start + hint.end) / 2)
        return (words, overlap, -distance)
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
    }
}
