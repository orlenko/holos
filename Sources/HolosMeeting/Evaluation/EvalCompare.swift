import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// eval/compare/<run>/report.json.
public struct CompareReport: Codable, Sendable, Equatable {
    public struct TrackReport: Codable, Sendable, Equatable {
        public var track: String
        /// The raw comparison: every word difference but case and punctuation counts.
        public var score: EvalScore
        /// Word passages per group (case/punctuation-only passages included).
        public var groups: [String: Int]
        /// Segments where the cloud text is much shorter than the local one (the model may have cut its answer).
        public var warnings: [String]
        /// The normalized comparison (nil in a raw one, or a report made before it existed).
        public var normalized: EvalScore?
        public var normalization: NormalizationCounts?

        public init(track: String, score: EvalScore, groups: [String: Int], warnings: [String],
                    normalized: EvalScore? = nil, normalization: NormalizationCounts? = nil) {
            self.track = track; self.score = score; self.groups = groups; self.warnings = warnings
            self.normalized = normalized; self.normalization = normalization
        }

        /// More of the track's local words were left out as echo of the system track than were kept: what is left
        /// is little and mostly what the echo filter missed, so its WER says little about recognition.
        public var mostlyEcho: Bool { score.echoLocalWords > score.localWords }

        /// The score the report leads with: the normalized one when there is one.
        public var headline: EvalScore { normalized ?? score }
    }

    /// The local transcript compared.
    public struct LocalVersion: Codable, Sendable, Equatable {
        /// "current" (the session's current transcript) or a local run ID (`voiceislocal eval local`).
        public var source: String
        public var languages: [String]
        /// Where the recognizer's vocabulary came from: "vocabulary.json" (what the meeting was recorded with),
        /// "current" (the word list, people's names, and correction words when the local run started), or "none".
        public var vocabulary: String
        public var vocabularyCount: Int
        public var madeAt: Date?

        public init(source: String, languages: [String], vocabulary: String, vocabularyCount: Int, madeAt: Date?) {
            self.source = source; self.languages = languages; self.vocabulary = vocabulary
            self.vocabularyCount = vocabularyCount; self.madeAt = madeAt
        }
    }

    public static let currentSchemaVersion = 2

    public var schemaVersion = CompareReport.currentSchemaVersion
    public var sessionID: String
    public var run: String
    public var model: String
    /// The local transcript revision compared.
    public var transcriptID: String
    public var createdAt: Date
    public var total: EvalScore
    public var tracks: [TrackReport]
    /// Every passage, by track then time. Case/punctuation-only passages are listed too.
    public var passages: [EvalPassage]
    /// "normalized" (the default) or "raw" (nil in a report made before there was a choice: raw).
    public var mode: String?
    public var normalizedTotal: EvalScore?
    public var normalizationTotal: NormalizationCounts?
    /// Vocabulary terms the cloud text has, with the local transcript's hits and misses (nil before there were any).
    public var terms: [TermStat]?
    /// Terms looked for that the cloud text never has.
    public var termsNotHeard: Int?
    public var local: LocalVersion?

    public init(sessionID: String, run: String, model: String, transcriptID: String, createdAt: Date,
                total: EvalScore, tracks: [TrackReport], passages: [EvalPassage], mode: String? = nil,
                normalizedTotal: EvalScore? = nil, normalizationTotal: NormalizationCounts? = nil,
                terms: [TermStat]? = nil, termsNotHeard: Int? = nil, local: LocalVersion? = nil) {
        self.sessionID = sessionID; self.run = run; self.model = model; self.transcriptID = transcriptID
        self.createdAt = createdAt; self.total = total; self.tracks = tracks; self.passages = passages
        self.mode = mode; self.normalizedTotal = normalizedTotal; self.normalizationTotal = normalizationTotal
        self.terms = terms; self.termsNotHeard = termsNotHeard; self.local = local
    }

    public var isNormalized: Bool { mode == "normalized" }
    /// A comparison of the session's current transcript (what review and apply work on).
    public var isOfCurrentTranscript: Bool { (local?.source ?? "current") == "current" }
}

/// `voiceislocal eval compare` (docs/reference-evaluation.md, "Cloud reference").
public enum EvalCompare {
    /// Every local word of `track` in the transcript, in time order, split at whitespace, with echo marked as the
    /// exports drop it (`EchoFilter` with the meeting's alignment settings: only calls filter echo).
    ///
    /// Segments without a track belong to `untrackedOwner` only (the run's first track), so they are never counted
    /// twice. A word that is only punctuation joins the word before it.
    public static func localTokens(_ transcript: Transcript, track: String, parameters: AlignmentParameters,
                                   untrackedOwner: String? = nil) -> [EvalToken] {
        let echo = Set(EchoFilter.echoSpans(transcript: transcript, parameters: parameters).flatMap { span in
            (span.first..<max(span.first, span.end)).map { WordRef(segmentID: span.segmentID, word: $0) }
        })
        let untracked = (untrackedOwner ?? track) == track
        let segments = transcript.segments.enumerated()
            .filter { $0.element.track == track || ($0.element.track == nil && untracked) }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        var tokens: [EvalToken] = []
        for segment in segments {
            let words = WordTiming.effectiveWords(of: segment)
            let isEcho = words.indices.map { echo.contains(WordRef(segmentID: segment.id, word: $0)) }
            tokens += segmentTokens(words: words, text: segment.text, isEcho: isEcho)
        }
        // Stable, by start: overlapping segments interleave their words.
        return tokens.enumerated()
            .sorted { (($0.element.start ?? 0), $0.offset) < (($1.element.start ?? 0), $1.offset) }
            .map(\.element)
    }

    /// The words of one transcript segment, cut from its full text by `EvalText.pieces` (as the cloud text is), each
    /// with the time of the recognizer's words it overlaps and marked as echo when they all are. A word that
    /// overlaps none (text the recognizer gave no timing for) takes the time of the word before it (or after).
    /// When the words do not lie in order in the text (an edited segment), the words themselves are written out
    /// and cut instead.
    static func segmentTokens(words: [EffectiveWord], text: String, isEcho: [Bool]) -> [EvalToken] {
        guard !words.isEmpty else { return [] }
        var source = text
        var spans = words.map { (start: $0.utf16Offset, end: $0.utf16Offset + $0.utf16Length) }
        if !wordsLieInText(words, text) {
            source = ""
            spans = []
            for word in words {
                if let last = source.last, let first = word.text.first,
                   !(EvalText.isUnspacedScript(last) && EvalText.isUnspacedScript(first)) {
                    source += " "
                }
                let start = source.utf16.count
                source += word.text
                spans.append((start, source.utf16.count))
            }
        }
        var tokens: [EvalToken] = []
        var first = 0
        for (position, piece) in EvalText.pieces(source).enumerated() {
            while first < spans.count, spans[first].end <= piece.utf16Start { first += 1 }
            var chosen: [Int] = []
            var index = first
            while index < spans.count, spans[index].start < piece.utf16End {
                if spans[index].end > piece.utf16Start { chosen.append(index) }
                index += 1
            }
            if chosen.isEmpty { chosen = [first > 0 ? first - 1 : min(first, words.count - 1)] }
            let echo = chosen.allSatisfy { $0 < isEcho.count && isEcho[$0] }
            tokens.append(EvalToken(text: piece.text, start: words[chosen[0]].start,
                                    end: words[chosen[chosen.count - 1]].end, echo: echo,
                                    spaceBefore: position == 0 || piece.spaceBefore))
        }
        return tokens
    }

    /// Whether each word's UTF-16 range lies in `text`, after the one before, and holds the word.
    static func wordsLieInText(_ words: [EffectiveWord], _ text: String) -> Bool {
        let units = text.utf16
        var previousEnd = 0
        for word in words {
            guard word.utf16Offset >= previousEnd, word.utf16Length >= 0,
                  word.utf16Offset + word.utf16Length <= units.count else { return false }
            let lower = units.index(units.startIndex, offsetBy: word.utf16Offset)
            let upper = units.index(lower, offsetBy: word.utf16Length)
            guard let inText = String(units[lower..<upper]),
                  inText.trimmingCharacters(in: .whitespacesAndNewlines)
                    == word.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            previousEnd = word.utf16Offset + word.utf16Length
        }
        return true
    }

    /// Which local transcript to compare.
    public enum LocalChoice: Sendable, Equatable {
        /// The session's current transcript.
        case current
        /// A finished `voiceislocal eval local` run.
        case candidate(LocalRunRecord)
    }

    /// Refuses a local run that did not transcribe the very audio the cloud run sent, track by track: the same chunk
    /// list, and the same bytes (a chunk file replaced without its manifest entry keeps the list's fingerprint). A
    /// cloud run made before its bytes' digest was recorded is checked against the audio as it is now, as the review
    /// page checks it, and so is the local run; one that has no digest of a segment's samples either cannot be
    /// checked, and is refused.
    static func checkSameAudio(_ record: LocalRunRecord, _ run: CloudRunRecord, session: URL,
                               manifest: SessionManifest) throws {
        let newRun = "make a new local run with voiceislocal eval local"
        for plan in run.tracks {
            try Task.checkCancellation()
            guard let track = record.tracks.first(where: { $0.track == plan.track }) else {
                throw HolosError.invalidInput("Local run \(record.id) has no \(plan.track) track, which run "
                    + "\(run.id) has.")
            }
            guard track.audioFingerprint == plan.audioFingerprint, let local = track.contentSHA256 else {
                throw HolosError.invalidInput("Local run \(record.id) and run \(run.id) used different "
                    + "\(plan.track) audio; \(newRun).")
            }
            if let cloud = plan.contentSHA256 {
                guard cloud == local else {
                    throw HolosError.invalidInput("Local run \(record.id) and run \(run.id) used different "
                        + "\(plan.track) audio; \(newRun).")
                }
                continue
            }
            let recorded = plan.segments.map(\.audioSHA256)
            guard !recorded.contains(nil) else {
                throw HolosError.invalidInput("Run \(run.id) is older than the check that its \(plan.track) audio is "
                    + "the local run's and kept no digest of it, so it cannot be compared with local run "
                    + "\(record.id); make a new cloud run, or compare the current transcript.")
            }
            guard try !AudioDeletedRecord.isDeleted(session: session, sessionID: manifest.id) else {
                throw HolosError.invalidInput("Run \(run.id) is older than the check that its \(plan.track) audio is "
                    + "the local run's, and this session's audio was deleted, so it cannot be checked.")
            }
            guard try EvalLocal.contentDigest(session: session, manifest: manifest, track: plan.track) == local else {
                throw HolosError.invalidInput("The \(plan.track) audio changed since local run \(record.id); "
                    + "\(newRun).")
            }
            let render = EvalPaths.work(run.id, in: session)
                .appendingPathComponent("compare-\(plan.track)-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: render) }
            let rendered = try EvalAudio.render(session: session, manifest: manifest, track: plan.track, to: render)
            let samplesMatch = try EvalAudio.segmentDigests(
                of: render, ranges: plan.segments.map { ($0.startFrame, $0.endFrame) }).map(Optional.some) == recorded
            guard rendered.frameCount == plan.frameCount, rendered.timeMap.map(EvalSpan.init) == plan.timeMap,
                  samplesMatch else {
                throw HolosError.invalidInput("The \(plan.track) audio changed since run \(run.id); it cannot be "
                    + "compared with local run \(record.id).")
            }
        }
    }

    /// Compares a local transcript (the current one, or a local candidate) with the run's cloud tracks, segment by
    /// segment. `normalize` (the default) also scores the normalized comparison and marks formatting-only passages;
    /// `terms` are counted in the cloud text with the local transcript's hits (under the normalized comparison, or by
    /// key in a raw one).
    public static func compare(session: URL, run: CloudRunRecord, local choice: LocalChoice = .current,
                               normalize: Bool = true, terms: [EvalTerms.Term] = [],
                               now: Date = Date()) throws -> CompareReport {
        let manifest = try SessionArchive.readManifest(at: session)
        let transcript: Transcript
        let version: CompareReport.LocalVersion
        switch choice {
        case .current:
            guard let current = try SessionFiles.currentTranscript(session: session) else {
                throw HolosError.invalidInput("This session has no transcript to compare.")
            }
            transcript = current
            let recorded = (try? TranscriptRebuilder.sessionVocabulary(session)) ?? []
            version = CompareReport.LocalVersion(source: "current", languages: current.languages ?? [current.locale],
                                                 vocabulary: "vocabulary.json", vocabularyCount: recorded.count,
                                                 madeAt: current.createdAt)
        case .candidate(let record):
            try checkSameAudio(record, run, session: session, manifest: manifest)
            transcript = try EvalLocal.transcript(of: record, in: session)
            version = CompareReport.LocalVersion(source: record.id, languages: record.languages,
                                                 vocabulary: record.vocabularySource,
                                                 vocabularyCount: record.vocabulary.count, madeAt: record.completedAt)
        }
        let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
        // Fillers of the languages the local transcript was made in (none for a language other than English or French).
        let fillers = EvalNormalization.fillers(languages: version.languages)
        let parameters = meeting.map(SpeakerAnalysis.alignmentParameters(meeting:)) ?? .v1
        var total = EvalScore()
        var normalizedTotal = EvalScore()
        var normalizationTotal = NormalizationCounts()
        var tracks: [CompareReport.TrackReport] = []
        var passages: [EvalPassage] = []
        var termTracks: [EvalTerms.Track] = []
        for plan in run.tracks {
            guard let cloud = try EvalStore.read(CloudTrackResult.self,
                                                 from: EvalPaths.trackResult(run.id, track: plan.track, in: session))
            else { throw HolosError.incomplete("Run \(run.id) has no stitched \(plan.track) track.") }
            let local = localTokens(transcript, track: plan.track, parameters: parameters,
                                    untrackedOwner: run.tracks.first?.track)
            var compared = compareTrack(track: plan.track, local: local, cloud: cloud, fillers: fillers)
            if !normalize {
                compared.report.normalized = nil
                compared.report.normalization = nil
                for index in compared.passages.indices { compared.passages[index].formattingOnly = false }
            }
            total.add(compared.report.score)
            if let normalized = compared.report.normalized { normalizedTotal.add(normalized) }
            if let counts = compared.report.normalization { normalizationTotal.add(counts) }
            tracks.append(compared.report)
            passages += compared.passages
            termTracks.append(compared.termTrack(plan.track, normalized: normalize))
        }
        let termStats = EvalTerms.count(terms, tracks: termTracks, normalized: normalize)
        return CompareReport(sessionID: manifest.id, run: run.id, model: run.model, transcriptID: transcript.id,
                             createdAt: now, total: total, tracks: tracks, passages: passages,
                             mode: normalize ? "normalized" : "raw",
                             normalizedTotal: normalize ? normalizedTotal : nil,
                             normalizationTotal: normalize ? normalizationTotal : nil,
                             terms: termStats, termsNotHeard: terms.count - termStats.count, local: version)
    }

    /// Operations on each side of a segment boundary that are always aligned again together (`repairBoundaries`).
    static let boundaryEdits = 6

    /// One track: each cloud segment is aligned with the local words that start in its window, from where its
    /// own audio begins (after any overlap) to where the next one's begins (the first and last windows are open).
    /// A word said across a cut can fall in one window locally and in the other in the cloud text, so the edits
    /// around each boundary are aligned again across it before the whole track is scored.
    struct TrackComparison {
        var report: CompareReport.TrackReport
        var passages: [EvalPassage]
        /// The track's cloud words, and per word whether and where the local transcript has it (`WindowComparison`).
        var cloud: [EvalToken]
        var window: WindowComparison
        /// Per local word: echo, which may stand between a term's words.
        var localEcho: [Bool]
        /// Per local word and per cloud word: a filler, which the normalized comparison leaves out between a term's
        /// words (the raw comparison reads it as a word).
        var localFillers: [Bool]
        var cloudFillers: [Bool]

        /// The track for the Terms section: by key, or under the normalized comparison.
        func termTrack(_ name: String, normalized: Bool) -> EvalTerms.Track {
            EvalTerms.Track(track: name, words: cloud.map(\.text),
                            covered: normalized ? window.cloudEquivalent : window.cloudMatched,
                            spans: normalized ? window.cloudEquivalentSpans : window.cloudMatchedSpans,
                            ignorable: normalized ? zip(localEcho, localFillers).map { $0 || $1 } : localEcho,
                            skipped: normalized ? cloudFillers : [])
        }
    }

    static func compareTrack(track: String, local: [EvalToken], cloud: CloudTrackResult,
                             fillers: Set<String> = EvalNormalization.allFillers) -> TrackComparison {
        var warnings: [String] = []
        let segments = cloud.segments
        let starts = segments.map { $0.sessionStart + $0.overlapSeconds }
        var allCloud: [EvalToken] = []
        var ops: [AlignmentOp] = []
        var boundaries: [Int] = []
        var cursor = 0
        for (position, segment) in segments.enumerated() {
            let windowEnd = position + 1 < segments.count ? starts[position + 1] : .infinity
            let first = cursor
            while cursor < local.count, (local[cursor].start ?? -.infinity) < windowEnd { cursor += 1 }
            let localWindow = Array(local[first..<cursor])
            let cloudWindow = cloudTokens(segment)
            let cloudOffset = allCloud.count
            allCloud += cloudWindow
            let windowOps = EvalAlignment.align(localWindow.map(\.text), cloudWindow.map(\.text))
            let windowScore = WindowComparer.evaluate(track: track, ops: windowOps, local: localWindow,
                                                      cloud: cloudWindow, start: 0, end: 0).score
            if windowScore.localWords >= 40, Double(windowScore.cloudWords) < 0.5 * Double(windowScore.localWords) {
                warnings.append("Segment \(segment.index + 1) (\(TimeLabel.clock(starts[position]))): cloud has "
                    + "\(windowScore.cloudWords) words, local \(windowScore.localWords); the model may have cut "
                    + "its answer short.")
            }
            if position > 0 { boundaries.append(ops.count) }
            ops += windowOps.map { shifted($0, local: first, cloud: cloudOffset) }
        }
        ops = repairBoundaries(ops, at: boundaries, local: local, cloud: allCloud)
        let trackStart = min(segments.first?.sessionStart ?? 0, local.first?.start ?? 0)
        let trackEnd = max(segments.last?.sessionEnd ?? 0, local.last?.end ?? 0)
        var result = WindowComparer.evaluate(track: track, ops: ops, local: local, cloud: allCloud,
                                             start: trackStart, end: trackEnd, fillers: fillers)
        for index in result.passages.indices { result.passages[index].id = "\(track)-\(index + 1)" }
        var groups: [String: Int] = [:]
        for passage in result.passages { groups[passage.group.rawValue, default: 0] += 1 }
        return TrackComparison(
            report: CompareReport.TrackReport(track: track, score: result.score, groups: groups, warnings: warnings,
                                              normalized: result.normalized, normalization: result.normalization),
            passages: result.passages, cloud: allCloud, window: result,
            localEcho: local.map(\.echo),
            localFillers: EvalNormalization.fillerFlags(local.map(\.text), fillers: fillers),
            cloudFillers: EvalNormalization.fillerFlags(allCloud.map(\.text), fillers: fillers))
    }

    private static func shifted(_ op: AlignmentOp, local: Int, cloud: Int) -> AlignmentOp {
        switch op {
        case .match(let i, let j, let exact): .match(i + local, j + cloud, exact: exact)
        case .substitute(let i, let j): .substitute(i + local, j + cloud)
        case .localOnly(let i): .localOnly(i + local)
        case .cloudOnly(let j): .cloudOnly(j + cloud)
        }
    }

    /// Consecutive matched words that bound a boundary repair: the alignment is taken as right beyond them.
    static let boundaryAnchor = 3

    /// Most operations a boundary repair reaches on each side of the cut, and most it aligns at once, so the
    /// alignment's memory stays small (`EvalAlignment.align`).
    static let boundaryReach = 500
    static let boundaryRegionLimit = 2000

    /// Around each boundary (an index into `ops`), at least `boundaryEdits` operations on each side, matches included,
    /// and then more until the stretch is bounded on each side by `boundaryAnchor` matched words in a row (or the
    /// track's edge, or `boundaryReach`), are aligned again as one stretch. So a word, or a whole run of words
    /// (coarse local timing), that one side put before the cut and the other after it becomes matches ("that that |
    /// works" against "that | that works"; "we need to ship this change today | okay" against "| we need to ship this
    /// change today okay"). Stretches that touch are aligned together (a merged stretch stops at
    /// `boundaryRegionLimit`); a stretch without an edit is left alone. Realigning never adds edits (the alignment is
    /// minimum-edit).
    static func repairBoundaries(_ ops: [AlignmentOp], at boundaries: [Int], local: [EvalToken],
                                 cloud: [EvalToken]) -> [AlignmentOp] {
        func anchored(_ range: Range<Int>) -> Bool {
            range.lowerBound >= 0 && range.upperBound <= ops.count && ops[range].allSatisfy(isMatch)
        }
        var regions: [Range<Int>] = []
        for boundary in Set(boundaries).sorted() where boundary > 0 && boundary < ops.count {
            var low = max(0, boundary - boundaryEdits)
            while low > 0, boundary - low < boundaryReach, !anchored((low - boundaryAnchor)..<low) { low -= 1 }
            var high = min(ops.count, boundary + boundaryEdits)
            while high < ops.count, high - boundary < boundaryReach, !anchored(high..<(high + boundaryAnchor)) {
                high += 1
            }
            if let last = regions.last, last.upperBound >= low {
                // Merged with the stretch before, up to the limit; past it, this one starts where that one ends.
                if max(last.upperBound, high) - last.lowerBound <= boundaryRegionLimit {
                    regions[regions.count - 1] = last.lowerBound..<max(last.upperBound, high)
                } else if high > last.upperBound {
                    regions.append(last.upperBound..<high)
                }
            } else {
                regions.append(low..<high)
            }
        }
        var result = ops
        // From the last region back, so each replacement leaves the positions of the earlier ones as they were.
        for range in regions.reversed() where result[range].contains(where: { !isMatch($0) }) {
            let low = range.lowerBound, high = range.upperBound
            let region = result[low..<high]
            let localIndices = region.compactMap(WindowComparer.localIndex)
            let cloudIndices = region.compactMap(WindowComparer.cloudIndex)
            let realigned = EvalAlignment.align(localIndices.map { local[$0].text }, cloudIndices.map { cloud[$0].text })
                .map { op -> AlignmentOp in
                    switch op {
                    case .match(let i, let j, let exact): .match(localIndices[i], cloudIndices[j], exact: exact)
                    case .substitute(let i, let j): .substitute(localIndices[i], cloudIndices[j])
                    case .localOnly(let i): .localOnly(localIndices[i])
                    case .cloudOnly(let j): .cloudOnly(cloudIndices[j])
                    }
                }
            result.replaceSubrange(low..<high, with: realigned)
        }
        return result
    }

    private static func isMatch(_ op: AlignmentOp) -> Bool {
        if case .match = op { return true }
        return false
    }

    /// A segment's stitched words; with the timestamp pass, each takes the time of the whisper-1 word it aligns with.
    /// Words are cut as the local ones are (`EvalText.pieces`), and each whisper-1 word is cut the same way (its
    /// pieces share its time).
    static func cloudTokens(_ segment: CloudTrackResult.Segment) -> [EvalToken] {
        var tokens = CloudSegmentation.spacedWords(text: segment.text, words: segment.words).enumerated()
            .map { EvalToken(text: $0.element.text, spaceBefore: $0.offset == 0 || $0.element.spaceBefore) }
        guard let timed = segment.timedWords, !timed.isEmpty, !tokens.isEmpty else { return tokens }
        let timedPieces = timed.flatMap { word in EvalText.tokens(word.word).map { ($0, word.start, word.end) } }
        for op in EvalAlignment.align(tokens.map(\.text), timedPieces.map(\.0)) {
            if case .match(let i, let j, _) = op {
                tokens[i].start = timedPieces[j].1
                tokens[i].end = timedPieces[j].2
            } else if case .substitute(let i, let j) = op {
                tokens[i].start = timedPieces[j].1
                tokens[i].end = timedPieces[j].2
            }
        }
        return tokens
    }

    /// Writes report.json and report.md into eval/compare/<run>/ (a local candidate's into eval/compare/<run>/<local
    /// run>/), replacing an older report.
    @discardableResult
    public static func write(_ report: CompareReport, session: URL) throws -> (markdown: URL, json: URL) {
        let candidate = report.isOfCurrentTranscript ? nil : report.local?.source
        if let candidate { try EvalStore.checkRunID(candidate) }
        let folder = EvalPaths.compare(report.run, local: candidate, in: session)
        let json = folder.appendingPathComponent("report.json")
        let markdown = folder.appendingPathComponent("report.md")
        try EvalStore.write(report, to: json)
        try EvalStore.writeData(Data(self.markdown(report).utf8), to: markdown)
        return (markdown, json)
    }

    /// Reads eval/compare/<run>/report.json (the comparison of the current transcript).
    public static func readReport(run: String, session: URL) throws -> CompareReport? {
        try EvalStore.checkRunID(run)
        return try EvalStore.read(CompareReport.self,
                                  from: EvalPaths.compare(run, in: session).appendingPathComponent("report.json"))
    }

    /// Whether a report of the current transcript `transcriptID` can be reused as it is: one made before the
    /// normalized comparison (schema 1) cannot mark formatting-only passages.
    public static func isCurrent(_ report: CompareReport?, transcriptID: String?) -> Bool {
        guard let report else { return false }
        return report.transcriptID == transcriptID && report.schemaVersion >= CompareReport.currentSchemaVersion
            && report.isOfCurrentTranscript
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f %%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }

    /// "the current transcript (vocabulary.json: 12 strings)", "local run local-… (en-CA; current vocabulary: 40
    /// strings)".
    static func localDescription(_ report: CompareReport) -> String {
        guard let local = report.local else { return "transcript \(report.transcriptID)" }
        let vocabulary = local.vocabulary == "none" ? "no vocabulary"
            : "\(local.vocabulary == "current" ? "vocabulary as of the run" : local.vocabulary): "
                + "\(local.vocabularyCount) strings"
        if local.source == "current" {
            return "the current transcript \(report.transcriptID) (\(vocabulary))"
        }
        return "local run \(local.source) (\(local.languages.joined(separator: ", ")); \(vocabulary))"
    }

    /// Why a track's WER says little: shown next to it in the summary and the report.
    static func echoNote(_ track: CompareReport.TrackReport) -> String {
        "unreliable: mostly echo (\(track.score.echoLocalWords) local words were echo of the system track, "
            + "\(track.score.localWords) kept)"
    }

    public static func summaryLines(_ report: CompareReport) -> [String] {
        var lines = ["Run \(report.run) (\(report.model)) against \(localDescription(report)), "
            + (report.isNormalized ? "normalized:" : "raw:")]
        for track in report.tracks {
            let s = track.headline
            var line = "  \(track.track): \(s.localWords) local words, \(s.cloudWords) cloud words; "
                + "WER \(percent(s.werAgainstLocal)) against local, \(percent(s.werAgainstCloud)) against cloud; "
                + "\(s.substitutions) changed, \(s.localOnly) only local, \(s.cloudOnly) only cloud"
            if track.normalized != nil {
                line += " (raw WER \(percent(track.score.werAgainstLocal)), \(percent(track.score.werAgainstCloud)))"
            }
            lines.append(line)
            if track.mostlyEcho { lines.append("  \(track.track) is \(echoNote(track)).") }
            for warning in track.warnings { lines.append("  Note: \(warning)") }
        }
        let words = report.passages.filter { $0.group != .caseOrPunctuation }
        let formatting = words.filter(\.formattingOnly).count
        lines.append("\(words.count - formatting) passages differ in words"
            + (report.isNormalized ? " (\(formatting) more only in numbers, fillers, or compounds)" : "")
            + "; \(report.passages.count - words.count) only in case or punctuation.")
        if let terms = report.terms, !terms.isEmpty {
            let misses = terms.reduce(0) { $0 + $1.misses }, heard = terms.reduce(0) { $0 + $1.cloud }
            lines.append("Terms: \(heard - misses) of \(heard) found where the cloud has them; most missed: "
                + terms.prefix(5).filter { $0.misses > 0 }.map { "\($0.term) \($0.misses)/\($0.cloud)" }
                    .joined(separator: ", "))
        }
        return lines
    }

    /// report.md: the scores, the terms, then the passages by group with their times.
    public static func markdown(_ report: CompareReport) -> String {
        var out = "# Local and cloud transcripts compared\n\n"
        out += "Run `\(report.run)` (\(report.model)) against \(escape(localDescription(report))).\n\n"
        out += "Neither transcript is taken as the truth: WER is given against each. Passages where they differ are "
        out += "listed by kind; review them with `voiceislocal eval review`.\n\n"
        if report.isNormalized {
            out += "**WER** is normalized: a number written in digits on one side and in words on the other "
            out += "(\"3\"/\"three\", \"1st\"/\"first\", \"+30\"/\"plus 30\", \"30%\"/\"thirty percent\"), a filler "
            out += "(um, uh, er, erm, hmm, mm, ah, euh, heu, bah, hein) on either side, a compound written as one "
            out += "word or as two or three (\"TestFlight\"/\"test flight\"), and case or punctuation are not "
            out += "errors; fillers are left out of the word counts. **Raw WER** counts every word difference but "
            out += "case and punctuation.\n\n"
            out += "| Track | Local words | Cloud words | Changed | Only local | Only cloud | WER vs local | "
            out += "WER vs cloud | Raw WER vs local | Raw WER vs cloud | Fillers local / cloud | Numbers | "
            out += "Compounds | Echo words left out |\n"
            out += "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
            let all = CompareReport.TrackReport(track: "All", score: report.total, groups: [:], warnings: [],
                                                normalized: report.normalizedTotal,
                                                normalization: report.normalizationTotal)
            for track in report.tracks + [all] {
                let s = track.headline, raw = track.score, counts = track.normalization ?? NormalizationCounts()
                let name = track.track + (track.mostlyEcho ? " ⚠︎ unreliable: mostly echo" : "")
                out += "| \(name) | \(s.localWords) | \(s.cloudWords) | \(s.substitutions) | \(s.localOnly) | "
                out += "\(s.cloudOnly) | \(percent(s.werAgainstLocal)) | \(percent(s.werAgainstCloud)) | "
                out += "\(percent(raw.werAgainstLocal)) | \(percent(raw.werAgainstCloud)) | "
                out += "\(counts.fillersLocal) / \(counts.fillersCloud) | \(counts.numbers) | \(counts.compounds) | "
                out += "\(raw.echoLocalWords) |\n"
            }
        } else {
            out += "**Raw comparison** (`--raw`): every word difference but case and punctuation counts.\n\n"
            out += "| Track | Local words | Cloud words | Changed | Only local | Only cloud | Case/punct. only | "
            out += "WER vs local | WER vs cloud | Echo words left out |\n"
            out += "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
            for track in report.tracks + [CompareReport.TrackReport(track: "All", score: report.total, groups: [:],
                                                                     warnings: [])] {
                let s = track.score
                let name = track.track + (track.mostlyEcho ? " ⚠︎ unreliable: mostly echo" : "")
                out += "| \(name) | \(s.localWords) | \(s.cloudWords) | \(s.substitutions) | \(s.localOnly) | "
                out += "\(s.cloudOnly) | \(s.caseOrPunctuationOnly) | \(percent(s.werAgainstLocal)) | "
                out += "\(percent(s.werAgainstCloud)) | \(s.echoLocalWords) |\n"
            }
        }
        var notes = report.tracks.filter(\.mostlyEcho).map { track in
            "\(track.track) is \(echoNote(track)): the echo filter left out more of its words than it kept, so "
                + "what is left is mostly what the filter missed, and its WER says little about recognition."
        }
        notes += report.tracks.flatMap { track in track.warnings.map { "\(track.track): \($0)" } }
        if !notes.isEmpty {
            out += "\n" + notes.map { "- \(escape($0))" }.joined(separator: "\n") + "\n"
        }
        if let terms = report.terms {
            out += "\n## Terms\n\n"
            out += "Each word-list term and each correction's meant phrase, where the cloud text has it (echo left "
            out += "out): whether the local transcript has the same words at the aligned position"
            out += report.isNormalized ? " (under the normalized comparison)" : ""
            out += ". Sorted by misses. Per track, hits of the cloud's count: the microphone's count depends on the "
            out += "echo left out, which differs from one local transcript to another.\n\n"
            if terms.isEmpty {
                out += "The cloud text has none of the \(report.termsNotHeard ?? 0) terms.\n"
            } else {
                let names = report.tracks.map(\.track)
                out += "| Term | Source | In cloud | Local hits | Local misses |"
                out += names.map { " \($0) |" }.joined() + "\n"
                out += "| --- | --- | ---: | ---: | ---: |" + String(repeating: " ---: |", count: names.count) + "\n"
                for term in terms {
                    let source = term.source == .wordList ? "word list" : "correction"
                    out += "| \(escape(term.term)) | \(source) | \(term.cloud) | \(term.hits) | \(term.misses) |"
                    for name in names {
                        let count = term.tracks.first { $0.track == name }
                        out += count.map { " \($0.hits)/\($0.cloud) |" } ?? " – |"
                    }
                    out += "\n"
                }
                if let unheard = report.termsNotHeard, unheard > 0 {
                    out += "\n\(unheard) more terms are not in the cloud text.\n"
                }
            }
        }
        for group in PassageGroup.allCases {
            let items = report.passages.filter { $0.group == group && !$0.formattingOnly }
            guard !items.isEmpty else { continue }
            out += "\n## \(group.title) (\(items.count))\n\n"
            out += passageTable(items)
        }
        let formatting = report.passages.filter(\.formattingOnly)
        if !formatting.isEmpty {
            out += "\n## Formatting only: numbers, fillers, compounds (\(formatting.count))\n\n"
            out += "The same words under the normalized comparison; hidden on the review page unless shown.\n\n"
            out += passageTable(formatting)
        }
        return out
    }

    private static func passageTable(_ items: [EvalPassage]) -> String {
        var out = "| Time | Track | Local | Cloud |\n| --- | --- | --- | --- |\n"
        for passage in items {
            out += "| \(TimeLabel.clock(passage.start)) | \(passage.track) | "
            out += cell(passage.local, before: passage.before, after: passage.after) + " | "
            out += cell(passage.cloud, before: passage.cloudBefore, after: passage.cloudAfter) + " |\n"
        }
        return out
    }

    private static func cell(_ text: String, before: String, after: String) -> String {
        let shown = text.isEmpty ? "—" : "**\(escape(text))**"
        return (before.isEmpty ? "" : "…\(escape(before)) ") + shown + (after.isEmpty ? "" : " \(escape(after))…")
    }

    /// Transcript text as literal Markdown: Markdown punctuation is backslash-escaped and "<", ">", "&" become
    /// entities, so no link, image, or HTML in a transcript is ever active in a preview.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\\", "|", "*", "_", "[", "]", "(", ")", "!", "`", "#", "~": out += "\\\(character)"
            case "\n", "\r": out += " "
            default: out.append(character)
            }
        }
        return out
    }
}

public enum TimeLabel {
    /// "h:mm:ss" or "m:ss".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
