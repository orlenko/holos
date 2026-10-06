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
    /// Correction-list rules this version of the live edit confirms.
    public var learned: [Correction]?
    /// Rules this hint first introduced to the correction list. Historical ownership is retained so reconciliation
    /// can remove a managed rule only after no latest live edit still confirms it.
    public var owned: [Correction]?
    /// Unrelated correction-list rules this live edit displaced. They remain an unmanaged baseline to restore after
    /// the last conflicting live rule is released.
    public var displaced: [Correction]?

    public init(id: String = UUID().uuidString, at: Date = Date(), segmentID: String, track: String,
                firstWord: Int, endWord: Int, start: Double, end: Double, heard: String, action: Action,
                learned: [Correction]? = nil, owned: [Correction]? = nil, displaced: [Correction]? = nil) {
        self.id = id; self.at = at; self.segmentID = segmentID; self.track = track
        self.firstWord = firstWord; self.endWord = endWord; self.start = start; self.end = end
        self.heard = heard; self.action = action
        self.learned = learned; self.owned = owned; self.displaced = displaced
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

    /// Adds one hint under a lock beside the sidecar, preserving a hint another app instance saved meanwhile, and
    /// returns the exact saved snapshot so its caller need not wait for a polling reader to observe the edit.
    @discardableResult
    public static func append(_ hint: LiveHint, session: URL) throws -> LiveHintFile {
        try validate(hint)
        let url = SessionPaths.liveHints(session)
        return try CorrectionList.withFileLock(for: url) {
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
            return file
        }
    }

    /// Records the rules an already-saved hint confirms, newly manages, and displaced. This follows `append` because
    /// the timed edit is useful even when learning fails. A crash between the two writes leaves the metadata nil,
    /// conservatively claiming neither ownership nor a possibly pre-existing rule.
    public static func recordLearning(_ learned: [Correction], owned: [Correction], displaced: [Correction],
                                      for hintID: String, session: URL) throws {
        let url = SessionPaths.liveHints(session)
        try CorrectionList.withFileLock(for: url) {
            var file = try read(session: session)
            guard let index = file.hints.lastIndex(where: { $0.id == hintID }) else {
                throw HolosError.invalidInput("That live correction is no longer in this meeting.")
            }
            file.hints[index].learned = learned
            file.hints[index].owned = owned
            file.hints[index].displaced = displaced
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
        for rules in [hint.learned, hint.owned, hint.displaced].compactMap({ $0 }) {
            guard rules.count <= maximumLearnedCorrections,
                  rules.allSatisfy({ correction in
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
}

/// Reconciles live hints with the final transcript. IDs win when their recorded words still agree; otherwise nearby
/// same-track words win, so replay and language segmentation may replace IDs without matching a distant occurrence.
public enum LiveHints {
    private static let maximumReplayMatchGap = 1.0

    public struct SpeakerActionPlan: Sendable, Equatable {
        public var actions: [SpeakerEditAction]
        public var unmatched: Int

        public init(actions: [SpeakerEditAction] = [], unmatched: Int = 0) {
            self.actions = actions; self.unmatched = unmatched
        }
    }

    public struct CorrectionLearningState: Sendable, Equatable {
        public var previous: [Correction]
        public var other: [Correction]
        public var managed: [Correction]
        public var preexisting: [Correction]

        public init(previous: [Correction] = [], other: [Correction] = [], managed: [Correction] = [],
                    preexisting: [Correction] = []) {
            self.previous = previous; self.other = other
            self.managed = managed; self.preexisting = preexisting
        }
    }

    public struct TextOutcome: Sendable, Equatable {
        public var transcript: Transcript
        public var applied: Int
        public var alreadyApplied: Int
        public var unmatched: Int
    }

    struct Match: Sendable, Equatable {
        struct Part: Sendable, Equatable {
            var segment: Int
            var words: Range<Int>
            var tokenCount: Int
        }

        var parts: [Part]
        var start: Double
        var end: Double

        var segment: Int { parts[0].segment }
        var words: Range<Int> { parts[0].words }
    }

    private struct LocatedMatch {
        var match: Match
        var exactID: Bool
        var overlap: Double
        var distance: Double

        func isPreferred(over other: LocatedMatch) -> Bool {
            (exactID ? 1 : 0, overlap, -distance, -match.start)
                > (other.exactID ? 1 : 0, other.overlap, -other.distance, -other.match.start)
        }
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

    /// The global-learning state before another edit of `hint`: what its prior version confirmed, what every other
    /// latest phrase still confirms, every rule historical live edits may remove, and unrelated rules they displaced.
    /// Hints from the first ownership build stored owned rules in `learned`; a missing `owned` field treats those
    /// rules as both facts.
    public static func correctionLearningState(for hint: LiveHint, among hints: [LiveHint])
        -> CorrectionLearningState {
        struct Latest {
            var index: Int
            var learned: [Correction]
        }
        let target = phraseKey(hint)
        var latest: [String: Latest] = [:]
        var managed: [Correction] = []
        for (index, candidate) in hints.enumerated() {
            guard case .replaceText = candidate.action else { continue }
            if let learned = candidate.learned {
                latest[phraseKey(candidate)] = Latest(index: index, learned: learned)
            }
            managed += candidate.owned ?? candidate.learned ?? []
        }
        managed = unique(managed)
        let managedSet = Set(managed)
        var preexisting: [Correction] = []
        for candidate in hints {
            guard case .replaceText = candidate.action else { continue }
            preexisting += candidate.displaced ?? []
            preexisting += (candidate.learned ?? []).filter { !managedSet.contains($0) }
        }
        preexisting = uniqueKeepingLast(preexisting)
        let previous = latest[target]?.learned ?? []
        let other = latest.filter { $0.key != target }.values.sorted { $0.index < $1.index }.flatMap(\.learned)
        return CorrectionLearningState(previous: previous, other: other,
                                       managed: managed, preexisting: preexisting)
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
            let replacementFound: (found: LocatedMatch, range: Range<Int>?)?
            replacementFound = locatedMatch(hint, in: result, text: replacement).flatMap { found in
                if found.match.parts.count > 1 {
                    return displayedText(of: found.match, matching: replacement, in: result)
                        == collapsedWhitespace(replacement)
                        ? (found: found, range: nil) : nil
                }
                return characterRange(found.match.words, matching: replacement,
                                      in: result.segments[found.match.segment]).flatMap { range in
                    text(in: range, of: result.segments[found.match.segment]) == replacement
                        ? (found: found, range: Optional(range)) : nil
                }
            }
            // Recovery may already contain an intermediate state (A→B→C replayed from B). Prefer the most
            // recent heard form when locations tie, but let the strongest location win across all recorded forms.
            var heardFound: (found: LocatedMatch, heard: String)?
            for heard in edit.heard.reversed() {
                guard let found = locatedMatch(hint, in: result, text: heard) else { continue }
                if let current = heardFound, !found.isPreferred(over: current.found) { continue }
                heardFound = (found, heard)
            }
            // A replacement elsewhere near the recorded time is not proof that this edit was applied. The exact
            // segment/range (or otherwise stronger timed location) still containing heard text must be changed.
            let heardIsStronger: Bool
            if let heardFound, let replacementFound {
                heardIsStronger = heardFound.found.isPreferred(over: replacementFound.found)
            } else {
                heardIsStronger = false
            }
            if let replacementFound, !heardIsStronger {
                let found = replacementFound.found.match
                if found.parts.count > 1 {
                    guard let marked = applyingAcrossSegments(found, replacement: replacement,
                                                              matchedText: replacement,
                                                              provenance: replacement, to: result,
                                                              markingOnly: true) else {
                        unmatched += 1
                        continue
                    }
                    if marked != result {
                        result = marked
                        applied += 1
                    } else {
                        already += 1
                    }
                    continue
                }
                guard let range = replacementFound.range else {
                    unmatched += 1
                    continue
                }
                let segment = result.segments[found.segment]
                guard var working = WordFixes.Working(segment, preservingExistingFixes: true) else {
                    unmatched += 1
                    continue
                }
                if working.marks.contains(where: { $0.range == range && $0.kind == .liveCorrection }) {
                    already += 1
                    continue
                }
                // Replay may independently produce the text the person requested. It still needs live provenance:
                // without the mark, the automatic word-fix stage can replace the person's explicit choice. Replace
                // an overlapping older mark, but keep the replay's text and word timings exactly as they are.
                working.marks.removeAll { $0.range.overlaps(range) }
                working.marks.append(.init(range: range, heard: replacement, kind: .liveCorrection,
                                           heardWords: wordsTouched(range, in: segment)))
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
            // The hint history retains the original heard form for review and learning. The transcript mark records
            // the form actually matched in this replay, so speaker retargeting maps from that revision's word span.
            if let heardFound, heardFound.found.match.parts.count > 1 {
                if let changed = applyingAcrossSegments(heardFound.found.match, replacement: replacement,
                                                        matchedText: heardFound.heard,
                                                        provenance: heardFound.heard, to: result,
                                                        markingOnly: false), changed != result {
                    result = changed
                    applied += 1
                } else {
                    unmatched += 1
                }
            } else if let heardFound,
               let working = WordFixes.Working(result.segments[heardFound.found.match.segment],
                                               preservingExistingFixes: true),
               let range = characterRange(heardFound.found.match.words, matching: heardFound.heard,
                                          in: result.segments[heardFound.found.match.segment]) {
                let changed = WordFixes.applying([
                    .init(range: range, text: replacement, kind: .liveCorrection, heard: heardFound.heard,
                          heardWords: wordsTouched(range, in: result.segments[heardFound.found.match.segment])),
                ], to: working)
                let segment = WordFixes.finished(changed,
                                                 segment: result.segments[heardFound.found.match.segment])
                if segment != result.segments[heardFound.found.match.segment] {
                    result.segments[heardFound.found.match.segment] = segment
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
        speakerActionPlan(hints, projection: projection, transcript: transcript).actions
    }

    /// Speaker renames together with the number of name hints that could not be mapped to a labelled turn.
    public static func speakerActionPlan(_ hints: [LiveHint], projection: SpeakerProjection,
                                         transcript: Transcript) -> SpeakerActionPlan {
        var names: [String: String] = [:]
        var order: [String] = []
        var unmatched = 0
        for hint in hints {
            guard case .nameSpeaker(let rawName) = hint.action else { continue }
            guard let name = SpeakerEditor.cleanName(rawName) else {
                unmatched += 1
                continue
            }
            let found = match(hint, in: transcript, text: hint.heard)
            let refs: Set<WordRef> = found.map { item in
                Set(item.parts.flatMap { part in
                    part.words.map { WordRef(segmentID: transcript.segments[part.segment].id, word: $0) }
                })
            } ?? []
            let candidates = projection.turns.filter { $0.track == hint.track && $0.speakerID != nil }
            let turn = candidates.max { left, right in
                turnScore(left, refs: refs, hint: hint) < turnScore(right, refs: refs, hint: hint)
            }
            guard let turn, let speakerID = turn.speakerID else {
                unmatched += 1
                continue
            }
            let score = turnScore(turn, refs: refs, hint: hint)
            guard score.0 > 0 || score.1 > 0 else {
                unmatched += 1
                continue
            }
            if names[speakerID] == nil { order.append(speakerID) }
            names[speakerID] = name
        }
        var actions: [SpeakerEditAction] = []
        for id in order {
            if let name = names[id] { actions.append(.rename(speakerID: id, name: name)) }
        }
        return SpeakerActionPlan(actions: actions, unmatched: unmatched)
    }

    static func match(_ hint: LiveHint, in transcript: Transcript, text: String) -> Match? {
        locatedMatch(hint, in: transcript, text: text)?.match
    }

    private static func locatedMatch(_ hint: LiveHint, in transcript: Transcript,
                                     text: String) -> LocatedMatch? {
        let wanted = tokens(text)
        guard !wanted.isEmpty else { return nil }
        var candidates: [LocatedMatch] = []
        struct Location {
            var segment: Int
            var word: Int
            var token: String
            var start: Double
            var end: Double
        }
        var locations: [Location] = []
        for (segmentIndex, segment) in transcript.segments.enumerated()
            where (segment.track ?? "mic") == hint.track {
            let words = WordTiming.effectiveWords(of: segment)
            locations += words.enumerated().compactMap { index, word in
                let token = normalized(word.text)
                return token.isEmpty ? nil : Location(segment: segmentIndex, word: index, token: token,
                                                       start: word.start, end: word.end)
            }
        }
        guard locations.count >= wanted.count else { return nil }
        for first in 0...(locations.count - wanted.count) {
            let matched = Array(locations[first..<(first + wanted.count)])
            guard matched.map(\.token) == wanted else { continue }
            var parts: [Match.Part] = []
            var crossesDistantBoundary = false
            var previousLocation: Location?
            for location in matched {
                if let last = parts.last, last.segment == location.segment {
                    parts[parts.count - 1].words = last.words.lowerBound..<(location.word + 1)
                    parts[parts.count - 1].tokenCount += 1
                } else {
                    if let previous = previousLocation, previous.segment != location.segment,
                       max(0, location.start - previous.end) > maximumReplayMatchGap {
                        crossesDistantBoundary = true
                    }
                    parts.append(.init(segment: location.segment, words: location.word..<(location.word + 1),
                                       tokenCount: 1))
                }
                previousLocation = location
            }
            guard !crossesDistantBoundary,
                  let firstLocation = matched.first, let lastLocation = matched.last else { continue }
            let start = firstLocation.start
            let end = lastLocation.end
            let overlap = max(0, min(end, hint.end) - max(start, hint.start))
            let distance = abs((start + end) / 2 - (hint.start + hint.end) / 2)
            let exactID = parts.count == 1
                && transcript.segments[parts[0].segment].id == hint.segmentID
                && parts[0].words == hint.firstWord..<hint.endWord
            let gap = max(0, max(hint.start - end, start - hint.end))
            guard exactID || gap <= maximumReplayMatchGap else { continue }
            candidates.append(LocatedMatch(match: Match(parts: parts, start: start, end: end),
                                           exactID: exactID, overlap: overlap, distance: distance))
        }
        return candidates.max { $1.isPreferred(over: $0) }
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

    /// How many of `segment`'s words `range` touches: the words a live correction there replaces, recorded as its
    /// `heardWords`.
    private static func wordsTouched(_ range: Range<Int>, in segment: TranscriptSegment) -> Int {
        WordTiming.effectiveWords(of: segment).filter { word in
            (word.utf16Offset..<(word.utf16Offset + word.utf16Length)).overlaps(range)
        }.count
    }

    private static func applyingAcrossSegments(_ match: Match, replacement: String, matchedText: String,
                                               provenance: String,
                                               to transcript: Transcript,
                                               markingOnly: Bool) -> Transcript? {
        guard match.parts.count > 1 else { return nil }
        let weights = match.parts.map(\.tokenCount)
        let replacements = divided(replacement, weights: weights)
        var provenances = divided(provenance, weights: weights)
        guard let ranges = characterRanges(of: match, matching: matchedText, in: transcript),
              replacements.count == match.parts.count,
              provenances.count == match.parts.count else { return nil }
        // How many words each piece replaces, carried with its provenance (`heardWords`: never counted by the spaces
        // in what was heard, which text without spaces between its words does not show).
        var consumed = match.parts.indices.map { index in
            wordsTouched(ranges[index], in: transcript.segments[match.parts[index].segment])
        }
        // An empty replacement deletes a whole language piece, which has no resulting word on which to keep a fix
        // mark. Carry that piece's provenance into the next surviving replacement (or the last one for a trailing
        // deletion), so speaker retargeting can still see every consumed word in the combined piece family.
        var carried: [String] = []
        var carriedWords = 0
        for index in replacements.indices {
            if replacements[index].isEmpty {
                if !provenances[index].isEmpty { carried.append(provenances[index]) }
                carriedWords += consumed[index]
                provenances[index] = ""
                consumed[index] = 0
            } else if !carried.isEmpty || carriedWords > 0 {
                provenances[index] = (carried + [provenances[index]]).filter { !$0.isEmpty }.joined(separator: " ")
                consumed[index] += carriedWords
                carried = []
                carriedWords = 0
            }
        }
        if !carried.isEmpty || carriedWords > 0, let last = replacements.lastIndex(where: { !$0.isEmpty }) {
            provenances[last] = ([provenances[last]] + carried).filter { !$0.isEmpty }.joined(separator: " ")
            consumed[last] += carriedWords
        }
        var result = transcript
        for index in match.parts.indices {
            let part = match.parts[index]
            let segment = result.segments[part.segment]
            let range = ranges[index]
            guard var working = WordFixes.Working(segment, preservingExistingFixes: true) else {
                return nil
            }
            let heard = provenances[index].isEmpty ? text(in: range, of: segment) : provenances[index]
            if markingOnly {
                guard collapsedWhitespace(text(in: range, of: segment))
                    == collapsedWhitespace(replacements[index]) else { return nil }
                if working.marks.contains(where: { $0.range == range && $0.kind == .liveCorrection }) {
                    continue
                }
                working.marks.removeAll { $0.range.overlaps(range) }
                if !replacements[index].isEmpty {
                    working.marks.append(.init(range: range, heard: heard, kind: .liveCorrection,
                                               heardWords: consumed[index]))
                    working.marks.sort { $0.range.lowerBound < $1.range.lowerBound }
                }
            } else {
                working.marks.removeAll { $0.range.overlaps(range) }
                working = WordFixes.applying([
                    .init(range: range, text: replacements[index], kind: .liveCorrection, heard: heard,
                          heardWords: consumed[index]),
                ], to: working)
            }
            result.segments[part.segment] = WordFixes.finished(working, segment: segment)
        }
        return result
    }

    /// Divides a phrase among the matched segment pieces without splitting a token. When the replacement has fewer
    /// tokens than pieces, later pieces are deleted; the complete live edit still contains at least one token.
    private static func divided(_ phrase: String, weights: [Int]) -> [String] {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        let spoken = words.indices.filter { !normalized(words[$0]).isEmpty }
        guard !weights.isEmpty, weights.allSatisfy({ $0 > 0 }) else { return [] }
        var result: [String] = []
        var word = 0
        var spokenWord = 0
        var weight = 0
        let totalWeight = weights.reduce(0, +)
        for index in weights.indices {
            weight += weights[index]
            let ideal = index == weights.count - 1
                ? spoken.count
                : Int((Double(spoken.count * weight) / Double(totalWeight)).rounded())
            let minimum = spoken.count >= weights.count ? spokenWord + 1 : spokenWord
            let remainingMinimum = spoken.count >= weights.count ? weights.count - index - 1 : 0
            let bounded = min(spoken.count - remainingMinimum, max(minimum, ideal))
            let nextWord = bounded < spoken.count ? spoken[bounded] : words.count
            result.append(words[word..<nextWord].joined(separator: " "))
            word = nextWord
            spokenWord = bounded
        }
        return result
    }

    private static func displayedText(of match: Match, matching displayed: String,
                                      in transcript: Transcript) -> String? {
        guard let ranges = characterRanges(of: match, matching: displayed, in: transcript) else { return nil }
        let pieces = match.parts.indices.map { index in
            text(in: ranges[index], of: transcript.segments[match.parts[index].segment])
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
    }

    /// The actual text owned by each matched segment piece. An internal language boundary can leave untimed or
    /// punctuation-only words after the last spoken word of one piece ("one two — — " / "three"). Those marks
    /// belong to that piece, regardless of how many whitespace-separated tokens the original displayed phrase had.
    private static func characterRanges(of match: Match, matching displayed: String,
                                        in transcript: Transcript) -> [Range<Int>]? {
        let displayed = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        var ranges: [Range<Int>] = []
        for index in match.parts.indices {
            let part = match.parts[index]
            let segment = transcript.segments[part.segment]
            guard let base = characterRange(part.words, matching: "", in: segment) else { return nil }
            let includeLeadingMarks = index > 0 || displayed.first.map(isBoundaryMark) == true
            let includeTrailingMarks = index < match.parts.count - 1
                || displayed.last.map(isBoundaryMark) == true
            ranges.append(expandingBoundaryMarks(in: segment.text, around: base,
                                                 leading: includeLeadingMarks,
                                                 trailing: includeTrailingMarks))
        }
        return ranges
    }

    private static func expandingBoundaryMarks(in value: String, around range: Range<Int>,
                                               leading: Bool, trailing: Bool) -> Range<Int> {
        let utf16 = value.utf16
        let lowerUTF16 = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let upperUTF16 = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard var lower = String.Index(lowerUTF16, within: value),
              var upper = String.Index(upperUTF16, within: value) else { return range }
        if leading {
            var candidate = lower
            var hasMark = false
            while candidate > value.startIndex {
                let previous = value.index(before: candidate)
                let character = value[previous]
                guard character.isWhitespace || isBoundaryMark(character) else { break }
                hasMark = hasMark || isBoundaryMark(character)
                candidate = previous
            }
            if hasMark {
                while candidate < lower, value[candidate].isWhitespace {
                    candidate = value.index(after: candidate)
                }
                lower = candidate
            }
        }
        if trailing {
            var candidate = upper
            var hasMark = false
            while candidate < value.endIndex {
                let character = value[candidate]
                guard character.isWhitespace || isBoundaryMark(character) else { break }
                hasMark = hasMark || isBoundaryMark(character)
                candidate = value.index(after: candidate)
            }
            if hasMark {
                while candidate > upper {
                    let previous = value.index(before: candidate)
                    guard value[previous].isWhitespace else { break }
                    candidate = previous
                }
                upper = candidate
            }
        }
        return lower.utf16Offset(in: value)..<upper.utf16Offset(in: value)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    private static func phraseKey(_ hint: LiveHint) -> String {
        "\(hint.segmentID):\(hint.track):\(hint.firstWord):\(hint.endWord)"
    }

    private static func unique(_ corrections: [Correction]) -> [Correction] {
        var seen: Set<Correction> = []
        return corrections.filter { seen.insert($0).inserted }
    }

    private static func uniqueKeepingLast(_ corrections: [Correction]) -> [Correction] {
        var seen: Set<Correction> = []
        return corrections.reversed().filter { seen.insert($0).inserted }.reversed()
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
    }
}
