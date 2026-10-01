import Foundation
import HolosCore
import HolosStorage
import os

/// What the word-fix stage uses outside the session folder (docs/design.md "Meeting word fixes"): the learned
/// corrections, the word list, and Apple's on-device model. `none` (the default everywhere in HolosMeeting) fixes
/// nothing and records nothing; the command-line tool passes the user's files and the model, and tests pass their own.
public struct WordFixDependencies: Sendable {
    /// Apple's on-device model for a meeting in a language, or why it cannot be used.
    public enum Model: Sendable {
        case available(TranscriptFixer.Model)
        /// Why not: Apple Intelligence's fix is off in Settings, or the model cannot be used for that language.
        case unavailable(String)
    }

    /// The learned corrections (corrections.json).
    public var corrections: @Sendable () throws -> CorrectionList
    /// The word list (words.json), for its "often heard as" phrases.
    public var wordList: @Sendable () throws -> WordList
    /// The model for a meeting in `language` (a locale identifier).
    public var model: @Sendable (_ language: String) -> Model
    /// The time limit of one question to the model: a meeting's places are asked one after another in the background,
    /// so it is longer than dictation's chunk limit, which the first question's model load would not fit.
    public var timeout: Duration

    public init(corrections: @escaping @Sendable () throws -> CorrectionList,
                wordList: @escaping @Sendable () throws -> WordList,
                model: @escaping @Sendable (_ language: String) -> Model,
                timeout: Duration = .seconds(10)) {
        self.corrections = corrections; self.wordList = wordList; self.model = model; self.timeout = timeout
    }

    /// No corrections, no word list, no model: the stage does nothing.
    public static let none = WordFixDependencies(corrections: { CorrectionList() }, wordList: { WordList() },
                                                 model: { _ in .unavailable("No model was given.") })
}

/// Stage 1c of the post-processor, `wordFixes` (docs/design.md "Meeting word fixes"), after the languages stage and
/// before the speakers, so speakers are labelled on the fixed text: the learned corrections are applied to every
/// segment as dictation applies them (whole words and phrases, any case, a sentence's capital carried over), then each
/// place where the word list's "often heard as" phrase of a term was written is put to Apple's on-device model
/// (`HeardAsJudge`), which may replace exactly that place by the term and nothing else. A replaced phrase takes the
/// time span of the words it replaced (`WordFixes`). The result is a new revision (`Transcript.fixedFrom` names the one
/// it was fixed from, which is kept), journaled (`wordsFixed`) and made current; each change is marked
/// (`TranscriptSegment.fixes`) so the review shows it.
///
/// Fixes are always made from the unfixed transcript, so a run with the same corrections and terms keeps the current
/// transcript ("already fixed") and a run after they changed replaces it. Nothing is recorded when there are no
/// corrections and no "often heard as" phrases and the transcript was never fixed. Like the languages stage, it never
/// replaces a transcript whose speaker labels were edited, unless asked for by name with `force` (`voiceislocal
/// session fix-words --force`, names carry over when speakers are labelled again). Without the model (Apple
/// Intelligence's fix off in Settings, or unavailable) only the corrections are applied, and a transcript whose terms
/// the model chose before is kept as it is. Cancellation publishes nothing.
enum WordFixStage {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    struct Request {
        var session: URL
        var manifest: SessionManifest
        /// The current transcript, as the languages stage left it.
        var transcript: Transcript
        var lease: ProcessingLease
        /// Asked for by name (`voiceislocal session fix-words`, `PostProcessingOptions.fixWords`).
        var requested: Bool
        /// `PostProcessingOptions.force`: with `requested`, it lets the stage replace a transcript whose speaker labels
        /// were edited.
        var force: Bool
    }

    struct Outcome {
        /// The transcript the later stages use.
        var transcript: Transcript
        /// For the final record's message: "Fixed 12 misheard words."
        var note: String?
        /// Why the stage did not do what it would have; makes the post-processing partial.
        var problem: String?
    }

    static let editedHead = "Speaker labels were edited, so misheard words were not fixed again. To fix them and "
        + "label speakers again (names carry over), run voiceislocal session fix-words with --force."
    /// At most this many places are put to the model in one run; the rest stay as written.
    static let maximumQuestions = 500
    /// After this many questions in a row without an answer in time, no more are asked in that run.
    static let maximumTimeoutsInARow = 3

    /// Test hook: while set (a task-local value), called with the writer and speaker locks held, after the last
    /// edited-labels check and before the fixed transcript is journaled and saved.
    @TaskLocal static var whilePublishing: (@Sendable () -> Void)? = nil

    /// Runs the stage and records its outcome. Throws only `CancellationError`: every other failure is recorded and
    /// the current transcript kept.
    static func run(_ request: Request, dependencies: WordFixDependencies,
                    recorder: StageRecorder) async throws -> Outcome {
        let current = request.transcript
        let unchanged = Outcome(transcript: current)
        let corrections: CorrectionList
        let terms: CorrectionList
        do {
            corrections = try dependencies.corrections()
            // As a correction list, so places are found as corrections are (whole words, any case) and a phrase
            // heard for two terms counts once.
            terms = CorrectionList(entries: try dependencies.wordList().heardAsPairs)
        } catch {
            let started = recorder.begin(.wordFixes, message: "Fixing misheard words…")
            let message = "Kept the transcript as it was: \(error.localizedDescription)"
            recorder.end(.wordFixes, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        guard !corrections.entries.isEmpty || !terms.entries.isEmpty || current.fixedFrom != nil || request.requested
        else { return unchanged }
        let started = recorder.begin(.wordFixes, message: "Fixing misheard words…")
        try Task.checkCancellation()

        // Always from the transcript before any fix, so fixes never stack.
        let base: Transcript
        if let id = current.fixedFrom {
            do {
                base = try SessionFiles.transcript(id: id, session: request.session)
            } catch {
                let message = "Kept the transcript as it was: the transcript its words were fixed from cannot be read: "
                    + error.localizedDescription
                recorder.end(.wordFixes, .failed, message, since: started)
                return Outcome(transcript: current, problem: message)
            }
        } else {
            base = current
        }

        let journal = recorder.journal
        let computed = try await fix(base, title: request.manifest.name, corrections: corrections, terms: terms,
                                     dependencies: dependencies) { fraction in
            journal.progress(PostProcessingProgress(stage: .wordFixes, fraction: fraction,
                                                    message: "Checking words the recognizer may have misheard…"))
        }
        // Without the model, the terms it chose before are kept rather than undone.
        if let unavailable = computed.unavailable, WordFixes.Counts(current).terms > 0 {
            let message = "Kept the words fixed before: Apple Intelligence cannot check the word list's "
                + "often-heard-as phrases now (\(unavailable))."
            recorder.end(.wordFixes, .skipped, message, since: started)
            return Outcome(transcript: current)
        }
        let fixed = computed.transcript
        let segments = fixed.segments
        let counts = computed.counts
        let asked = computed.asked
        let detail = computed.notes.isEmpty ? nil : computed.notes.joined(separator: " ")
        if counts.total == 0, current.fixedFrom == nil {
            recorder.end(.wordFixes, .succeeded, ["No misheard words to fix.", detail].compactMap { $0 }
                .joined(separator: " "), since: started)
            return unchanged
        }
        if current.fixedFrom == base.id, current.segments == segments {
            let message = "The words were already fixed (\(summary(counts)))."
            recorder.end(.wordFixes, .succeeded, [message, detail].compactMap { $0 }.joined(separator: " "),
                         since: started)
            return Outcome(transcript: current, note: counts.total == 0 ? nil : note(counts))
        }
        if let problem = editedHeadProblem(request) {
            recorder.end(.wordFixes, .skipped, problem, since: started)
            return Outcome(transcript: current, problem: problem)
        }
        let details = [
            "transcriptID": fixed.id, "base": base.id, "corrections": String(counts.corrections),
            "terms": String(counts.terms), "asked": String(asked),
        ]
        do {
            if let problem = try await publish(fixed, details: details, request: request) {
                recorder.end(.wordFixes, .skipped, problem, since: started)
                return Outcome(transcript: current, problem: problem)
            }
        } catch let error where !(error is CancellationError) {
            let message = "Kept the transcript as it was: the fixed transcript could not be saved: "
                + error.localizedDescription
            recorder.end(.wordFixes, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        log.notice("Session \(request.manifest.id, privacy: .public): fixed \(counts.corrections, privacy: .public) corrections and \(counts.terms, privacy: .public) terms (\(asked, privacy: .public) asked)")
        let message = counts.total == 0 ? "No misheard words to fix; the earlier fixes were undone."
            : "Fixed \(summary(counts))."
        recorder.end(.wordFixes, .succeeded, [message, detail].compactMap { $0 }.joined(separator: " "),
                     since: started)
        return Outcome(transcript: fixed, note: counts.total == 0 ? nil : note(counts))
    }

    /// What `fix` made of a transcript.
    struct Computed {
        /// A new revision (`fixedFrom` the transcript given) with the fixes made and marked.
        var transcript: Transcript
        var counts: WordFixes.Counts
        /// Places put to the model.
        var asked: Int
        /// What the messages add: places not checked, and why.
        var notes: [String]
        /// Why the model could not be asked about some place (it was not), when it could not.
        var unavailable: String?
    }

    /// Fixes `base` (a transcript none of whose words were fixed) without saving anything: the learned corrections
    /// everywhere, then each place where a phrase of `terms` (heard → term pairs) was written, outside what the
    /// corrections changed, put to the model with the passage around it (its segment, and for a short segment the ends
    /// of the segments before and after it in time, any track: `HeardAsJudge.context`) and `title`; at most
    /// `maximumQuestions`, one after another, none once `maximumTimeoutsInARow` went unanswered in a row. `progress`
    /// gets the share of places asked. Throws only `CancellationError`. The stage publishes the result; an evaluation
    /// candidate can use it as is.
    static func fix(_ base: Transcript, title: String, corrections: CorrectionList, terms: CorrectionList,
                    dependencies: WordFixDependencies,
                    progress: (Double) -> Void = { _ in }) async throws -> Computed {
        // The corrections, everywhere.
        var working: [WordFixes.Working?] = base.segments.map { segment in
            WordFixes.Working(segment).map { WordFixes.applying(WordFixes.corrections(in: $0, list: corrections), to: $0) }
        }
        // The places where a term's "often heard as" phrase was written, outside what the corrections changed.
        struct Place {
            var segment: Int
            var match: CorrectionList.Match
        }
        var places: [Place] = []
        for (index, item) in working.enumerated() {
            guard let item else { continue }
            for match in terms.matches(in: item.text) {
                let range = match.range.location..<(match.range.location + match.range.length)
                guard !item.marks.contains(where: { $0.range.overlaps(range) }) else { continue }
                places.append(Place(segment: index, match: match))
            }
        }
        var notes: [String] = []
        var asked = 0
        var unavailable: String?
        if !places.isEmpty {
            // Asked once per language the places are in.
            var models: [String: WordFixDependencies.Model] = [:]
            func model(for segment: Int) -> WordFixDependencies.Model {
                let language = base.segments[segment].language ?? base.locale
                if let known = models[language] { return known }
                let found = dependencies.model(language)
                models[language] = found
                return found
            }
            var accepted: [Int: [WordFixes.Replacement]] = [:]
            // The passage around a place: the segments before and after it in time, whatever their track.
            let order = base.segments.indices.sorted {
                (base.segments[$0].start, base.segments[$0].track ?? "")
                    < (base.segments[$1].start, base.segments[$1].track ?? "")
            }
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let total = min(places.count, maximumQuestions)
            var timedOut = 0
            var timedOutInARow = 0
            var stoppedAt: Int?
            for (number, place) in places.prefix(maximumQuestions).enumerated() {
                try Task.checkCancellation()
                // A model that stops answering would hold the meeting's post-processing for every place left.
                if timedOutInARow >= maximumTimeoutsInARow {
                    stoppedAt = number
                    break
                }
                let ask: TranscriptFixer.Model
                switch model(for: place.segment) {
                case .available(let found): ask = found
                case .unavailable(let why):
                    unavailable = why
                    continue
                }
                guard let item = working[place.segment] else { continue }
                progress(Double(asked) / Double(total))
                let at = position[place.segment] ?? 0
                let previous = at > 0 ? working[order[at - 1]]?.text : nil
                let next = at + 1 < order.count ? working[order[at + 1]]?.text : nil
                let range = place.match.range.location..<(place.match.range.location + place.match.range.length)
                let context = HeardAsJudge.context(of: range, in: item.text, previous: previous, next: next)
                let question = HeardAsJudge.Question(title: title, before: context.before, heard: place.match.heard,
                                                     after: context.after, term: place.match.correction.meant)
                asked += 1
                let answer = await HeardAsJudge.ask(question, model: ask, timeout: dependencies.timeout)
                try Task.checkCancellation()
                timedOutInARow = answer == .timedOut ? timedOutInARow + 1 : 0
                switch answer {
                case .term:
                    accepted[place.segment, default: []].append(
                        // The term as saved ("iPhone"), never with a sentence's capital ("IPhone").
                        WordFixes.Replacement(range: range, text: place.match.correction.meant, kind: .term))
                case .keep, .failed:
                    break
                case .timedOut:
                    timedOut += 1
                }
            }
            if let stoppedAt {
                notes.append("Apple Intelligence stopped answering, so the last \(total - stoppedAt) "
                    + "\(total - stoppedAt == 1 ? "place was" : "places were") not checked.")
            }
            if let unavailable {
                notes.append("The word list's often-heard-as phrases were not checked: \(unavailable).")
            }
            if places.count > maximumQuestions {
                notes.append("\(places.count - maximumQuestions) places past the first \(maximumQuestions) were not "
                    + "checked.")
            }
            if timedOut > 0 {
                notes.append("Apple Intelligence did not answer in time for \(timedOut) "
                    + "\(timedOut == 1 ? "place" : "places"), which stay as written.")
            }
            for (segment, replacements) in accepted {
                working[segment] = working[segment].map { WordFixes.applying(replacements, to: $0) }
            }
        }
        try Task.checkCancellation()
        let segments = base.segments.indices.map { index in
            working[index].map { WordFixes.finished($0, segment: base.segments[index]) } ?? base.segments[index]
        }
        let fixed = Transcript(source: base.source, locale: base.locale, backend: base.backend, segments: segments,
                               languages: base.languages, fixedFrom: base.id)
        return Computed(transcript: fixed, counts: WordFixes.Counts(fixed), asked: asked, notes: notes,
                        unavailable: unavailable)
    }

    /// "12 misheard words: 9 by corrections, 3 word-list terms"
    static func summary(_ counts: WordFixes.Counts) -> String {
        let words = counts.total == 1 ? "1 misheard word" : "\(counts.total) misheard words"
        var parts: [String] = []
        if counts.corrections > 0 { parts.append("\(counts.corrections) by corrections") }
        if counts.terms > 0 {
            parts.append(counts.terms == 1 ? "1 word-list term" : "\(counts.terms) word-list terms")
        }
        return parts.isEmpty ? words : "\(words): " + parts.joined(separator: ", ")
    }

    /// The final record's note: "Fixed 12 misheard words."
    static func note(_ counts: WordFixes.Counts) -> String {
        counts.total == 1 ? "Fixed 1 misheard word." : "Fixed \(counts.total) misheard words."
    }

    // MARK: - Publication

    /// Why the transcript must not be replaced now: its speaker labels were edited and the request does not replace
    /// edited labels (`force` with the stage asked for by name). Nil when it may be.
    private static func editedHeadProblem(_ request: Request) -> String? {
        do {
            guard let head = try SpeakerAnalysis.headState(session: request.session, transcript: request.transcript),
                  head.needsForce(request.force && request.requested) else { return nil }
            return editedHead
        } catch {
            return "Cannot read the current speaker labels, so the transcript was kept: \(error.localizedDescription)"
        }
    }

    /// Under the writer lock and then the speaker lock (as the languages stage publishes), checks once more that the
    /// speaker labels were not edited, then journals `wordsFixed` (before the save, so a fixed current transcript is
    /// always explained) and makes the fixed transcript current. A cancellation seen with both locks held publishes
    /// nothing.
    private static func publish(_ fixed: Transcript, details: [String: String], request: Request) async throws -> String? {
        let archive = try SessionArchive.openForMaintenance(at: request.session, lease: request.lease)
        do {
            let problem = try await SessionArchive.withSpeakerLockAsync(at: request.session) { () async throws -> String? in
                if let problem = editedHeadProblem(request) { return problem }
                whilePublishing?()
                try Task.checkCancellation()
                try await archive.recordEvent(kind: MeetingEventKind.wordsFixed, details: details)
                try await archive.saveTranscript(fixed, writeLegacyExports: false)
                return nil
            }
            await archive.releaseLock()
            return problem
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    // MARK: - Lineage

    /// The transcript `transcriptID` was fixed from, following `wordsFixed` events back to one that was not fixed;
    /// `transcriptID` itself when it was not. Every bookkeeping that names transcripts by ID (a merge's languages, a
    /// rebuild) asks about that one, since a fixed transcript stands for it.
    static func unfixedID(_ transcriptID: String, events: [ArchiveEvent]) -> String {
        var id = transcriptID
        var seen: Set<String> = [id]
        while let base = events.last(where: {
            $0.kind == MeetingEventKind.wordsFixed && $0.details["transcriptID"] == id
        })?.details["base"], !base.isEmpty, seen.insert(base).inserted {
            id = base
        }
        return id
    }
}
