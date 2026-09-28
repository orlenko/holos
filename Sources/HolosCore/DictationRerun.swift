import Foundation

/// Settings › History and privacy › "Keep the audio of dictations (for Run Again)" (UserDefaults `historyKeepAudio`,
/// on when never set), and how the audio is kept (docs/design.md "Dictation audio and Run Again").
public enum HistoryAudio {
    public static let defaultsKey = "historyKeepAudio"
    /// AAC, mono, 16 kHz: speech needs no more, and the recognizer resamples to 16 kHz itself.
    public static let sampleRate = 16_000.0
    public static let bitRate = 32_000

    /// The saved choice (`UserDefaults.object(forKey:)`), or on.
    public static func keeps(_ saved: Any?) -> Bool { (saved as? Bool) ?? true }

    /// "12.4 MB".
    public static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// Settings' line under the checkbox: what the kept audio takes on disk.
    public static func usageText(bytes: Int64?, keeps: Bool) -> String {
        switch bytes {
        case nil: "Checking the space the audio takes…"
        case 0?: keeps ? "No dictation audio is kept yet." : "No dictation audio is kept."
        case let bytes?: "Dictation audio uses \(sizeText(bytes)) on this Mac."
            + (keeps ? " Each file is deleted with its dictation." : " New dictations keep no audio.")
        }
    }
}

/// The text steps live dictation applies to what the recognizer heard, in order: filler removal, learned corrections,
/// then Apple Intelligence's fix, chunk by chunk as the words are committed and the rest on release. Run Again feeds it
/// a saved dictation's recognizer results so the text comes out as live dictation would write it now. The fix is
/// injected (`fixer`), so tests run it with a closure; nil runs without it.
public struct DictationTextPipeline: Sendable {
    public var language: String
    public var removeFillers: Bool
    public var corrections: CorrectionList
    /// Apple Intelligence's fix; nil when it is off or cannot be used.
    public var fixer: TranscriptFixer?

    public init(language: String, removeFillers: Bool, corrections: CorrectionList, fixer: TranscriptFixer? = nil) {
        self.language = language
        self.removeFillers = removeFillers
        self.corrections = corrections
        self.fixer = fixer
    }

    /// What each step produced.
    public struct Output: Sendable, Equatable {
        /// The recognizer's text (its results joined as live dictation joins them).
        public var heard: String
        /// After filler removal.
        public var withoutFillers: String
        /// After learned corrections: what dictation writes without Apple Intelligence's fix.
        public var corrected: String
        /// The text as written: after Apple Intelligence's fix (`corrected` when it is off or changed nothing).
        public var written: String
        /// Phrases the corrections replaced.
        public var corrections: Int
        /// Whether the fix ran.
        public var aiFixed: Bool
        /// Words Apple Intelligence's fix changed.
        public var aiChangedWords: Int
        /// Each chunk's fix outcome, in order.
        public var aiOutcomes: [TranscriptFixer.Outcome]

        public var fillersRemoved: Bool { WordDiff.normalized(withoutFillers) != WordDiff.normalized(heard) }
    }

    /// The recognizer's results as live dictation joins them (`DictationStatus.transcript`): each trimmed, empty ones
    /// left out, one space between.
    public static func transcript(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Filler removal (when on), as live dictation applies it to the final text.
    public func withoutFillers(_ text: String) -> String {
        removeFillers ? FillerWords.remove(from: text, language: language) : text
    }

    /// Filler removal and corrections as live dictation applies them to the words committed so far, holding back a
    /// trailing comma or phrase start that later words may still change.
    public func cleanedForStreaming(_ text: String) -> String {
        corrections.applyWithholdingPartialMatch(
            to: removeFillers ? FillerWords.removeWithholdingTrailingComma(from: text, language: language) : text)
    }

    /// Runs the steps on the recognizer's results (`segments`, in order). With the fix, each result is taken as
    /// committed in turn, as dictation writing into a field streams it (the last one too: the recognizer commits it
    /// when it finishes, before the result), and each new part, cleaned as streaming cleans it, is fixed as a chunk;
    /// what streaming held back (a trailing comma, the start of a correction) is fixed on release, as `isFinal`.
    /// Live dictation joins chunks queued while the model is busy, which depends on timing, so its fix may differ.
    public func run(segments: [String]) async -> Output {
        let heard = Self.transcript(segments)
        let withoutFillers = withoutFillers(heard).trimmingCharacters(in: .whitespacesAndNewlines)
        let (corrected, count) = corrections.applyCounting(to: withoutFillers)
        var output = Output(heard: heard, withoutFillers: withoutFillers, corrected: corrected, written: corrected,
                            corrections: count, aiFixed: false, aiChangedWords: 0, aiOutcomes: [])
        guard let fixer, !corrected.isEmpty else { return output }
        output.aiFixed = true
        // Streaming: what the pipeline was handed (as recognized) and what it wrote (as fixed).
        var submitted = ""
        var written = ""
        var streaming = true
        for count in stride(from: 1, through: segments.count, by: 1) {
            let streamed = cleanedForStreaming(Self.transcript(Array(segments.prefix(count))))
            guard streamed.hasPrefix(submitted) else {
                // The recognizer revised committed text: dictation stops streaming there.
                streaming = false
                break
            }
            let chunk = String(streamed.dropFirst(submitted.count))
            guard !chunk.isEmpty else { continue }
            let result = await fixer.fix(chunk, isFinal: false)
            output.aiOutcomes.append(result.outcome)
            submitted += chunk
            written += result.text
        }
        let unwritten = corrected.hasPrefix(submitted) ? String(corrected.dropFirst(submitted.count)) : nil
        var fixedRest: String?
        if streaming, let rest = unwritten, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = await fixer.fix(rest, isFinal: true)
            output.aiOutcomes.append(result.outcome)
            fixedRest = result.text
        }
        let attempted = unwritten.map { AIFixUnwritten.attempted($0, fixedRest: fixedRest, failedWrite: nil) }
        let changed = written != submitted || (attempted ?? "") != (unwritten ?? "")
        let end = DictationRecord.endText(recognized: corrected, fixChanged: changed, fixedWritten: written,
                                          rest: attempted)
        output.written = end.text.trimmingCharacters(in: .whitespacesAndNewlines)
        output.aiChangedWords = end.aiChangedWords
        return output
    }
}

extension WordDiff {
    /// One place where `old` and `new` differ: the words of `old` replaced (empty when words were added) and the words
    /// of `new` that replace them (empty when words were removed), as they are written in each.
    public struct Change: Codable, Sendable, Equatable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// The places where `new` differs from `old`, word by word (without case and surrounding punctuation), in order.
    public static func changes(from old: String, to new: String) -> [Change] {
        let a = words(in: old)
        let b = words(in: new)
        let matches = lcsMatches(a.map { key(old[$0]) }, b.map { key(new[$0]) })
        let pairsA = matches.a.sorted()
        let pairsB = matches.b.sorted()
        var changes: [Change] = []
        func text(_ ranges: ArraySlice<Range<String.Index>>, in source: String) -> String {
            guard let first = ranges.first, let last = ranges.last else { return "" }
            return String(source[first.lowerBound..<last.upperBound])
        }
        var i = 0, j = 0
        for (matchA, matchB) in Array(zip(pairsA, pairsB)) + [(a.count, b.count)] {
            if i < matchA || j < matchB {
                changes.append(Change(from: text(a[i..<matchA], in: old), to: text(b[j..<matchB], in: new)))
            }
            i = matchA + 1
            j = matchB + 1
        }
        return changes
    }

    /// "“a boon to” → “Ubuntu”; removed “um”; added “the”".
    public static func describe(_ changes: [Change], limit: Int = 6) -> String {
        let shown = changes.prefix(limit).map { change -> String in
            if change.from.isEmpty { return "added “\(change.to)”" }
            if change.to.isEmpty { return "removed “\(change.from)”" }
            return "“\(change.from)” → “\(change.to)”"
        }
        let more = changes.count > limit ? "; \(changes.count - limit) more" : ""
        return shown.joined(separator: "; ") + more
    }
}

/// Run Again's comparison of a saved dictation with what the current settings make of its audio (docs/design.md
/// "Dictation audio and Run Again"): as heard then and now, as written then and now, what each step did now, and
/// which steps did something different from then. `voiceislocal history rerun --json` prints it.
public struct DictationRerunReport: Codable, Sendable, Equatable {
    public enum Step: String, Codable, Sendable, CaseIterable {
        case recognizer, fillers, corrections, aiFix

        public var title: String {
            switch self {
            case .recognizer: "Recognizer"
            case .fillers: "Filler removal"
            case .corrections: "Corrections"
            case .aiFix: "Apple Intelligence"
            }
        }
    }

    /// Then against now.
    public struct Comparison: Codable, Sendable, Equatable {
        public var then: String
        public var now: String
        /// The words differ (case and punctuation aside).
        public var changed: Bool
        public var changes: [WordDiff.Change]

        public init(then: String, now: String) {
            self.then = then
            self.now = now
            changed = WordDiff.normalized(then) != WordDiff.normalized(now)
            changes = changed ? WordDiff.changes(from: then, to: now) : []
        }
    }

    /// What one step did in this run.
    public struct StepResult: Codable, Sendable, Equatable {
        public var step: Step
        /// Whether the step ran (fillers and the fix can be off).
        public var enabled: Bool
        public var input: String
        public var output: String
        /// The step changed the words it was given.
        public var changed: Bool
        public var changes: [WordDiff.Change]
        /// "off", "unavailable: …", or the fix's outcomes; nil otherwise.
        public var note: String?

        public init(step: Step, enabled: Bool, input: String, output: String, note: String? = nil) {
            self.step = step
            self.enabled = enabled
            self.input = input
            self.output = output
            changed = WordDiff.normalized(input) != WordDiff.normalized(output)
            changes = changed ? WordDiff.changes(from: input, to: output) : []
            self.note = note
        }

        /// "Corrections: “a boon to” → “Ubuntu”", "Filler removal: off".
        public var summary: String {
            let what: String = switch step {
            case .recognizer:
                changed ? "heard differently from then: " + WordDiff.describe(changes) : "heard the same words as then"
            case .fillers:
                !enabled ? "off" : changed ? WordDiff.describe(changes) : "nothing removed"
            case .corrections:
                changed ? WordDiff.describe(changes) : "nothing replaced"
            case .aiFix:
                !enabled ? (note ?? "off") : changed ? WordDiff.describe(changes) : "no change"
            }
            return "\(step.title): \(what)"
        }
    }

    public var id: UUID
    public var date: Date
    public var app: String?
    public var languageThen: String
    public var languageNow: String
    public var audioSeconds: Double?
    public var heard: Comparison
    public var written: Comparison
    /// This run's steps, in order: the recognizer (then's heard text as its input), fillers, corrections, the fix.
    public var steps: [StepResult]
    /// The steps that did something different from then: the recognizer heard other words; filler removal removed
    /// fillers where it did not then (or the reverse), in the words heard now or replayed on the words heard then; the
    /// corrections replaced a different number of phrases, now or replayed on the words heard then (or, when nothing
    /// else explains it, other words); Apple Intelligence changed a different number of words (or other words, when
    /// nothing else explains a change in the text).
    public var changedBy: [Step]
    /// The text as written differs from then.
    public var changed: Bool
    /// What the steps changed now, as History counts it.
    public var fixes: DictationRecord.Fixes

    /// Compares `record` with `output`, this run of `pipeline` on its audio. `aiNote` says why the fix did not run
    /// ("off", "unavailable: …"), when it did not.
    public init(record: DictationRecord, output: DictationTextPipeline.Output, pipeline: DictationTextPipeline,
                aiNote: String? = nil) {
        id = record.id
        date = record.date
        app = record.app
        languageThen = record.language
        languageNow = pipeline.language
        audioSeconds = record.audio?.seconds
        heard = Comparison(then: record.heard, now: output.heard)
        written = Comparison(then: record.text, now: output.written)
        changed = written.changed
        fixes = DictationRecord.Fixes(fillersRemoved: output.fillersRemoved, corrections: output.corrections,
                                      aiChangedWords: output.aiChangedWords)
        let outcomes = output.aiOutcomes.map(\.rawValue)
        steps = [
            StepResult(step: .recognizer, enabled: true, input: record.heard, output: output.heard),
            StepResult(step: .fillers, enabled: pipeline.removeFillers, input: output.heard,
                       output: output.withoutFillers, note: pipeline.removeFillers ? nil : "off"),
            StepResult(step: .corrections, enabled: true, input: output.withoutFillers, output: output.corrected,
                       note: "\(output.corrections) replaced"),
            StepResult(step: .aiFix, enabled: output.aiFixed, input: output.corrected, output: output.written,
                       note: output.aiFixed ? (outcomes.isEmpty ? "nothing to fix" : outcomes.joined(separator: ", "))
                                            : (aiNote ?? "off")),
        ]
        changedBy = Self.changedBy(record: record, output: output, pipeline: pipeline, heardChanged: heard.changed,
                                   writtenChanged: written.changed)
    }

    static func changedBy(record: DictationRecord, output: DictationTextPipeline.Output,
                          pipeline: DictationTextPipeline, heardChanged: Bool, writtenChanged: Bool) -> [Step] {
        var steps: [Step] = []
        if heardChanged { steps.append(.recognizer) }
        // Filler removal and the corrections replayed on the words heard then, so a recognizer change does not count
        // against them.
        let heardThen = record.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFillers = pipeline.withoutFillers(heardThen).trimmingCharacters(in: .whitespacesAndNewlines)
        let fillersOnThen = pipeline.removeFillers
            && WordDiff.normalized(withoutFillers) != WordDiff.normalized(heardThen)
        if fillersOnThen != record.fixes.fillersRemoved || output.fillersRemoved != record.fixes.fillersRemoved {
            steps.append(.fillers)
        }
        let (corrected, count) = pipeline.corrections.applyCounting(to: withoutFillers)
        // Without then's fix the text written then is what fillers and corrections made of the words heard.
        let otherWords = record.fixes.aiChangedWords == 0 && !heardChanged && !steps.contains(.fillers)
            && WordDiff.normalized(corrected) != WordDiff.normalized(record.text)
        if count != record.fixes.corrections || output.corrections != record.fixes.corrections || otherWords {
            steps.append(.corrections)
        }
        if output.aiChangedWords != record.fixes.aiChangedWords
            || (writtenChanged && steps.isEmpty && output.aiChangedWords > 0) {
            steps.append(.aiFix)
        }
        return steps
    }
}

/// `voiceislocal history rerun --all --json`: each dictation's Run Again in brief, for judging a change to corrections
/// or the fix on the dictations kept.
public struct DictationRerunBatch: Codable, Sendable, Equatable {
    public struct Settings: Codable, Sendable, Equatable {
        /// The language every dictation was run in; nil when each ran in its own.
        public var language: String?
        public var removeFillers: Bool
        public var aiFix: Bool
        /// Why the fix could not run, when it was asked for.
        public var aiFixUnavailable: String?
        public var corrections: Int

        public init(language: String?, removeFillers: Bool, aiFix: Bool, aiFixUnavailable: String?,
                    corrections: Int) {
            self.language = language
            self.removeFillers = removeFillers
            self.aiFix = aiFix
            self.aiFixUnavailable = aiFixUnavailable
            self.corrections = corrections
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var id: UUID
        public var date: Date
        public var app: String?
        /// Nil when the dictation was not run (`skipped`, `error`).
        public var changed: Bool?
        public var changedBy: [DictationRerunReport.Step]
        public var writtenThen: String
        public var writtenNow: String?
        public var changes: [WordDiff.Change]
        /// Why it was not run ("no audio kept").
        public var skipped: String?
        public var error: String?

        public init(report: DictationRerunReport) {
            id = report.id
            date = report.date
            app = report.app
            changed = report.changed
            changedBy = report.changedBy
            writtenThen = report.written.then
            writtenNow = report.written.now
            changes = report.written.changes
        }

        public init(record: DictationRecord, skipped: String? = nil, error: String? = nil) {
            id = record.id
            date = record.date
            app = record.app
            changed = nil
            changedBy = []
            writtenThen = record.text
            writtenNow = nil
            changes = []
            self.skipped = skipped
            self.error = error
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var dictations: Int
        public var rerun: Int
        public var changed: Int
        public var skipped: Int
        public var failed: Int
        /// How many dictations each step behaved differently in.
        public var byStep: [String: Int]
    }

    public var settings: Settings
    public var dictations: [Item]
    public var summary: Summary

    public init(settings: Settings, dictations: [Item]) {
        self.settings = settings
        self.dictations = dictations
        var byStep: [String: Int] = [:]
        for step in DictationRerunReport.Step.allCases {
            byStep[step.rawValue] = dictations.count { $0.changedBy.contains(step) }
        }
        summary = Summary(dictations: dictations.count, rerun: dictations.count { $0.changed != nil },
                          changed: dictations.count { $0.changed == true },
                          skipped: dictations.count { $0.skipped != nil }, failed: dictations.count { $0.error != nil },
                          byStep: byStep)
    }
}

/// Which dictation `voiceislocal history rerun <id|latest>` means.
public enum HistoryLookup {
    /// `key` is "latest" (the newest dictation), a dictation's ID, or the start of one (at least 4 characters, any
    /// case) that only one dictation has. `records` are oldest first, as stored.
    public static func find(_ key: String, in records: [DictationRecord]) throws -> DictationRecord {
        let key = key.trimmingCharacters(in: .whitespaces)
        if key.lowercased() == "latest" {
            // Dates have one-second precision; the file order (append order) breaks ties.
            guard let newest = records.enumerated().max(by: { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date < rhs.element.date : lhs.offset < rhs.offset
            }) else {
                throw HolosError.invalidInput("No dictations in the history.")
            }
            return newest.element
        }
        guard key.count >= 4 else {
            throw HolosError.invalidInput("Give a dictation's ID (at least its first 4 characters) or latest.")
        }
        let matches = records.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        guard let first = matches.first else {
            throw HolosError.invalidInput("No dictation in the history has the ID \(key).")
        }
        guard matches.count == 1 else {
            throw HolosError.invalidInput("\(matches.count) dictations have an ID starting with \(key); give more of it.")
        }
        return first
    }
}

/// `--since 7d`: how far back, in minutes, hours, days, or weeks ("90m", "12h", "7d", "2w").
public enum HistorySince {
    public static func interval(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let value = Double(text.dropLast()), value.isFinite, value > 0 else { return nil }
        let seconds: Double? = switch unit {
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        case "w": 604_800
        default: nil
        }
        return seconds.map { $0 * value }
    }
}
