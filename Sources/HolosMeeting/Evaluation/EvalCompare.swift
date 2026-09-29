import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// eval/compare/<run>/report.json.
public struct CompareReport: Codable, Sendable, Equatable {
    public struct TrackReport: Codable, Sendable, Equatable {
        public var track: String
        public var score: EvalScore
        /// Word passages per group (case/punctuation-only passages included).
        public var groups: [String: Int]
        /// Segments where the cloud text is much shorter than the local one (the model may have cut its answer).
        public var warnings: [String]
    }

    public var schemaVersion = 1
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

    /// Compares the current transcript with the run's cloud tracks, segment by segment.
    public static func compare(session: URL, run: CloudRunRecord, now: Date = Date()) throws -> CompareReport {
        guard let transcript = try SessionFiles.currentTranscript(session: session) else {
            throw HolosError.invalidInput("This session has no transcript to compare.")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
        let parameters = meeting.map(SpeakerAnalysis.alignmentParameters(meeting:)) ?? .v1
        var total = EvalScore()
        var tracks: [CompareReport.TrackReport] = []
        var passages: [EvalPassage] = []
        for plan in run.tracks {
            guard let cloud = try EvalStore.read(CloudTrackResult.self,
                                                 from: EvalPaths.trackResult(run.id, track: plan.track, in: session))
            else { throw HolosError.incomplete("Run \(run.id) has no stitched \(plan.track) track.") }
            let local = localTokens(transcript, track: plan.track, parameters: parameters,
                                    untrackedOwner: run.tracks.first?.track)
            let compared = compareTrack(track: plan.track, local: local, cloud: cloud)
            total.add(compared.report.score)
            tracks.append(compared.report)
            passages += compared.passages
        }
        return CompareReport(sessionID: manifest.id, run: run.id, model: run.model, transcriptID: transcript.id,
                             createdAt: now, total: total, tracks: tracks, passages: passages)
    }

    /// Edits on each side of a segment boundary that are aligned again together (`repairBoundaries`).
    static let boundaryEdits = 6

    /// One track: each cloud segment is aligned with the local words that start in its window, from where its
    /// own audio begins (after any overlap) to where the next one's begins (the first and last windows are open).
    /// A word said across a cut can fall in one window locally and in the other in the cloud text, so the edits
    /// around each boundary are aligned again across it before the whole track is scored.
    static func compareTrack(track: String, local: [EvalToken], cloud: CloudTrackResult)
        -> (report: CompareReport.TrackReport, passages: [EvalPassage]) {
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
                                             start: trackStart, end: trackEnd)
        for index in result.passages.indices { result.passages[index].id = "\(track)-\(index + 1)" }
        var groups: [String: Int] = [:]
        for passage in result.passages { groups[passage.group.rawValue, default: 0] += 1 }
        return (CompareReport.TrackReport(track: track, score: result.score, groups: groups, warnings: warnings),
                result.passages)
    }

    private static func shifted(_ op: AlignmentOp, local: Int, cloud: Int) -> AlignmentOp {
        switch op {
        case .match(let i, let j, let exact): .match(i + local, j + cloud, exact: exact)
        case .substitute(let i, let j): .substitute(i + local, j + cloud)
        case .localOnly(let i): .localOnly(i + local)
        case .cloudOnly(let j): .cloudOnly(j + cloud)
        }
    }

    /// At each boundary (an index into `ops`), the run of edits just before it and just after it (at most
    /// `boundaryEdits` on each side) is aligned again as one stretch, so "word" missing at the end of one window
    /// and extra at the start of the next becomes a match.
    static func repairBoundaries(_ ops: [AlignmentOp], at boundaries: [Int], local: [EvalToken],
                                 cloud: [EvalToken]) -> [AlignmentOp] {
        var result = ops
        for boundary in boundaries.reversed() {
            var low = boundary
            while low > 0, boundary - low < boundaryEdits, !isMatch(result[low - 1]) { low -= 1 }
            var high = boundary
            while high < result.count, high - boundary < boundaryEdits, !isMatch(result[high]) { high += 1 }
            guard low < boundary, high > boundary else { continue }
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

    /// Writes report.json and report.md into eval/compare/<run>/, replacing an older report.
    @discardableResult
    public static func write(_ report: CompareReport, session: URL) throws -> (markdown: URL, json: URL) {
        let folder = EvalPaths.compare(report.run, in: session)
        let json = folder.appendingPathComponent("report.json")
        let markdown = folder.appendingPathComponent("report.md")
        try EvalStore.write(report, to: json)
        try EvalStore.writeData(Data(self.markdown(report).utf8), to: markdown)
        return (markdown, json)
    }

    /// Reads eval/compare/<run>/report.json.
    public static func readReport(run: String, session: URL) throws -> CompareReport? {
        try EvalStore.checkRunID(run)
        return try EvalStore.read(CompareReport.self,
                                  from: EvalPaths.compare(run, in: session).appendingPathComponent("report.json"))
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f %%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }

    public static func summaryLines(_ report: CompareReport) -> [String] {
        var lines = ["Run \(report.run) (\(report.model)) against transcript \(report.transcriptID):"]
        for track in report.tracks {
            let s = track.score
            lines.append("  \(track.track): \(s.localWords) local words, \(s.cloudWords) cloud words; "
                + "WER \(percent(s.werAgainstLocal)) against local, \(percent(s.werAgainstCloud)) against cloud; "
                + "\(s.substitutions) changed, \(s.localOnly) only local, \(s.cloudOnly) only cloud")
            for warning in track.warnings { lines.append("  Note: \(warning)") }
        }
        let wordPassages = report.passages.filter { $0.group != .caseOrPunctuation }.count
        lines.append("\(wordPassages) passages differ in words; "
            + "\(report.passages.count - wordPassages) only in case or punctuation.")
        return lines
    }

    /// report.md: the scores, then the passages by group with their times.
    public static func markdown(_ report: CompareReport) -> String {
        var out = "# Local and cloud transcripts compared\n\n"
        out += "Run `\(report.run)` (\(report.model)), local transcript `\(report.transcriptID)`.\n\n"
        out += "Neither transcript is taken as the truth: WER is given against each. Passages where they differ are "
        out += "listed by kind; review them with `voiceislocal eval review`.\n\n"
        out += "| Track | Local words | Cloud words | Changed | Only local | Only cloud | Case/punct. only | "
        out += "WER vs local | WER vs cloud | Echo words left out |\n"
        out += "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        for track in report.tracks + [CompareReport.TrackReport(track: "All", score: report.total, groups: [:],
                                                                 warnings: [])] {
            let s = track.score
            out += "| \(track.track) | \(s.localWords) | \(s.cloudWords) | \(s.substitutions) | \(s.localOnly) | "
            out += "\(s.cloudOnly) | \(s.caseOrPunctuationOnly) | \(percent(s.werAgainstLocal)) | "
            out += "\(percent(s.werAgainstCloud)) | \(s.echoLocalWords) |\n"
        }
        let warnings = report.tracks.flatMap { track in track.warnings.map { "\(track.track): \($0)" } }
        if !warnings.isEmpty {
            out += "\n" + warnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        for group in PassageGroup.allCases {
            let items = report.passages.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            out += "\n## \(group.title) (\(items.count))\n\n"
            out += "| Time | Track | Local | Cloud |\n| --- | --- | --- | --- |\n"
            for passage in items {
                out += "| \(TimeLabel.clock(passage.start)) | \(passage.track) | "
                out += cell(passage.local, before: passage.before, after: passage.after) + " | "
                out += cell(passage.cloud, before: passage.cloudBefore, after: passage.cloudAfter) + " |\n"
            }
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
