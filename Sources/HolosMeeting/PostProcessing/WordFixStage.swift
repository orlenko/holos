import Foundation
import HolosCore
import HolosSpeakers
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

/// Stage 1d of the post-processor, `wordFixes` (docs/design.md "Meeting word fixes"), after languages and live text
/// corrections and before the speakers, so speakers are labelled on the fixed text: learned corrections apply to every
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
/// replaces a transcript whose speaker labels were edited automatically. When asked for by name, it maps the current
/// run and its effective edits onto the new word positions; `force` instead labels speakers again. Without the model (Apple
/// Intelligence's fix off in Settings, or unavailable) only the corrections are applied, and a transcript whose terms
/// the model chose before is kept as it is. Cancellation publishes nothing.
enum WordFixStage {
    private struct IncompletePublication: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

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
        /// A fixed revision displaced when late live hints were rebased onto its unfixed base. Its accepted term and
        /// Review-revert decisions can be carried across the retry.
        var priorFixed: Transcript? = nil
    }

    struct Outcome {
        /// The transcript the later stages use.
        var transcript: Transcript
        /// For the final record's message: "Fixed 12 misheard words."
        var note: String?
        /// Why the stage did not do what it would have; makes the post-processing partial.
        var problem: String?
        /// The current speaker labels were mapped onto this new transcript, so later stages need not label again.
        var labelsPreserved = false
        /// The transcript became current but its staged speaker head did not. Later stages must not relabel over the
        /// old head, which is still the only published copy of the person's turn edits.
        var speakerHeadIncomplete = false
    }

    static let editedHead = "Speaker labels were edited, so misheard words were not fixed again. To fix them and "
        + "label speakers again (names carry over), run voiceislocal session fix-words with --force."
    static let reviewRevert = "Words changed back in Review were kept. Run voiceislocal session fix-words to check "
        + "them again."
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
        guard !corrections.entries.isEmpty || !terms.entries.isEmpty || current.fixedFrom != nil
            || request.priorFixed != nil || request.requested
        else { return unchanged }
        let started = recorder.begin(.wordFixes, message: "Fixing misheard words…")
        try Task.checkCancellation()

        // Review reverts are explicit rejections of automatic replacements. Ordinary post-processing (including
        // Label Speakers) keeps them; the named command is the deliberate way to check all words again.
        if !request.requested, current.segments.contains(where: {
            ($0.fixes ?? []).contains { $0.kind == .reviewRevert }
        }) {
            do {
                let repaired = try await repairPreservedHeadIfNeeded(current, request: request)
                recorder.end(.wordFixes, .skipped, reviewRevert, since: started)
                return Outcome(transcript: current, labelsPreserved: repaired)
            } catch let error where !(error is CancellationError) {
                let problem = "The reverted words were saved, but publication was incomplete: the speaker head "
                    + "could not be published: \(error.localizedDescription)"
                recorder.end(.wordFixes, .failed, problem, since: started)
                return Outcome(transcript: current, problem: problem, speakerHeadIncomplete: true)
            }
        }

        // Do not spend model work on a result that cannot be published. This is checked again after the work and
        // under the publication locks because the labels can still be edited while the model is running.
        if let problem = editedHeadProblem(request), !request.requested {
            recorder.end(.wordFixes, .skipped, problem, since: started)
            return Outcome(transcript: current, problem: problem)
        }

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
                                     dependencies: dependencies, preservingTermsFrom: request.priorFixed) { fraction in
            journal.progress(PostProcessingProgress(stage: .wordFixes, fraction: fraction,
                                                    message: "Checking words the recognizer may have misheard…"))
        }
        // An incomplete rerun cannot tell a prior rejection from a place it never decided: keep the current revision
        // rather than silently undoing a term the model chose before.
        if WordFixes.Counts(current).terms > 0, !computed.termChecksComplete {
            let message: String
            let detail: String?
            if let unavailable = computed.unavailable {
                message = "Kept the words fixed before: Apple Intelligence cannot check the word list's "
                    + "often-heard-as phrases now (\(unavailable))."
                detail = nil
            } else {
                message = "Kept the words fixed before: Apple Intelligence did not finish checking the word list's "
                    + "often-heard-as phrases."
                detail = computed.notes.isEmpty ? nil : computed.notes.joined(separator: " ")
            }
            recorder.end(.wordFixes, .skipped, [message, detail].compactMap { $0 }.joined(separator: " "),
                         since: started)
            return Outcome(transcript: current)
        }
        let fixed = computed.transcript
        let segments = fixed.segments
        let counts = computed.counts
        let asked = computed.asked
        let detail = computed.notes.isEmpty ? nil : computed.notes.joined(separator: " ")
        let keptReviewReverts = segments.contains { segment in
            (segment.fixes ?? []).contains { $0.kind == .reviewRevert }
        }
        if counts.total == 0, current.fixedFrom == nil, segments == current.segments {
            recorder.end(.wordFixes, .succeeded, ["No misheard words to fix.", detail].compactMap { $0 }
                .joined(separator: " "), since: started)
            return unchanged
        }
        if current.fixedFrom == base.id, current.segments == segments {
            let message = "The words were already fixed (\(summary(counts)))."
            do {
                let repaired = request.force ? false
                    : try await repairPreservedHeadIfNeeded(current, request: request)
                recorder.end(.wordFixes, .succeeded, [message, detail].compactMap { $0 }.joined(separator: " "),
                             since: started)
                return Outcome(transcript: current, note: counts.total == 0 ? nil : note(counts),
                               labelsPreserved: repaired)
            } catch let error where !(error is CancellationError) {
                let problem = "The fixed words were saved, but publication was incomplete: the speaker head "
                    + "could not be published: \(error.localizedDescription)"
                recorder.end(.wordFixes, .failed, problem, since: started)
                return Outcome(transcript: current, problem: problem, speakerHeadIncomplete: true)
            }
        }
        if let problem = editedHeadProblem(request), !request.requested {
            recorder.end(.wordFixes, .skipped, problem, since: started)
            return Outcome(transcript: current, problem: problem)
        }
        let details = [
            "transcriptID": fixed.id, "base": base.id, "corrections": String(counts.corrections),
            "terms": String(counts.terms), "asked": String(asked),
        ]
        let message = keptReviewReverts ? reviewRevert
            : counts.total == 0 ? "No misheard words to fix; the earlier fixes were undone."
            : "Fixed \(summary(counts))."
        do {
            let publication = try await publish(fixed, details: details, request: request)
            if let problem = publication.problem {
                recorder.end(.wordFixes, .skipped, problem, since: started)
                return Outcome(transcript: current, problem: problem)
            }
            recorder.end(.wordFixes, .succeeded, [message, detail].compactMap { $0 }.joined(separator: " "),
                         since: started)
            log.notice("Session \(request.manifest.id, privacy: .public): fixed \(counts.corrections, privacy: .public) corrections and \(counts.terms, privacy: .public) terms (\(asked, privacy: .public) asked)")
            return Outcome(transcript: fixed, note: counts.total == 0 ? nil : note(counts),
                           labelsPreserved: publication.labelsPreserved)
        } catch let error where !(error is CancellationError) {
            let incomplete = error is IncompletePublication
            let message = (incomplete ? "The fixed words were saved, but publication was incomplete: "
                : "Kept the transcript as it was: the fixed transcript could not be saved: ") + error.localizedDescription
            recorder.end(.wordFixes, .failed, message, since: started)
            return Outcome(transcript: incomplete ? fixed : current, problem: message,
                           speakerHeadIncomplete: incomplete)
        }
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
        /// Every often-heard-as place was decided by the model (`.term` or `.keep`). False for unavailable models,
        /// failures, timeouts, or places left past a timeout streak or the per-run question limit.
        var termChecksComplete: Bool
    }

    private struct AcceptedTerm {
        var segmentID: String
        var heard: String
        var visible: String
        var location: FixLocation
    }

    private struct RevertedFix {
        var segmentID: String
        /// The automatic replacement the person rejected.
        var rejected: String
        /// The recognizer text restored in Review and expected in the new base.
        var visible: String
        var location: FixLocation
    }

    private struct PriorFix {
        var segmentID: String
        var heard: String
        var visible: String
        var kind: TranscriptWordFixKind
        var location: FixLocation
    }

    private struct FixLocation {
        var midpoint: Double
        var tolerance: Double
        /// Position in the segment's word order. Unlike estimated times, this is not redistributed when an untimed
        /// segment gains or loses words elsewhere.
        var wordMidpoint: Double
        var wordTolerance: Double
        var estimated: Bool
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
                    preservingTermsFrom priorFixed: Transcript? = nil,
                    progress: (Double) -> Void = { _ in }) async throws -> Computed {
        var working: [WordFixes.Working?] = base.segments.map {
            WordFixes.Working($0, preservingExistingFixes: true)
        }
        // A late live-hint rebase deliberately starts from the unfixed revision, which would otherwise discard a
        // correction the person changed back in Review. Restore those marks at the same timed text before applying
        // automatic rules; the ordinary overlap rule then keeps each rejected replacement out. A live correction
        // over the same words wins because the restored recognizer text is no longer present there.
        preserveReviewReverts(from: priorFixed, in: base, working: &working)
        // The corrections, everywhere outside live corrections and preserved Review reverts.
        for index in working.indices {
            working[index] = working[index].map {
                WordFixes.applying(WordFixes.corrections(in: $0, list: corrections), to: $0)
            }
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
        // A late live-hint retry starts again from the earlier fixed revision's base. Carry its accepted term
        // decisions at the same timed locations into that new base before asking the model. A live correction that
        // overlaps one of them leaves no matching place, so the direct edit wins.
        var accepted: [Int: [WordFixes.Replacement]] = [:]
        var usedPriorTerms: Set<Int> = []
        let priorTerms = acceptedTerms(in: priorFixed)
        places.removeAll { place in
            guard let item = working[place.segment],
                  let location = location(of: place.match, in: item,
                                          segment: base.segments[place.segment]),
                  let evidence = priorTerms.indices
                    .filter({ index in
                        guard !usedPriorTerms.contains(index) else { return false }
                        let prior = priorTerms[index]
                        return prior.segmentID == base.segments[place.segment].id
                            && normalized(prior.heard) == normalized(place.match.heard)
                            && prior.visible.contains(place.match.correction.meant)
                            && matchDistance(prior.location, location) != nil
                    })
                    .min(by: { matchDistance(priorTerms[$0].location, location)!
                        < matchDistance(priorTerms[$1].location, location)! }) else { return false }
            usedPriorTerms.insert(evidence)
            let range = place.match.range.location..<(place.match.range.location + place.match.range.length)
            accepted[place.segment, default: []].append(
                WordFixes.Replacement(range: range, text: place.match.correction.meant, kind: .term))
            return true
        }
        var notes: [String] = []
        var asked = 0
        var unavailable: String?
        var termChecksComplete = true
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
            // The passage around a place: the segments before and after it in time, whatever their track.
            let order = base.segments.indices.sorted {
                (base.segments[$0].start, base.segments[$0].track ?? "")
                    < (base.segments[$1].start, base.segments[$1].track ?? "")
            }
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let total = min(places.count, maximumQuestions)
            var timedOut = 0
            var failed = 0
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
                    termChecksComplete = false
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
                case .keep:
                    break
                case .failed:
                    failed += 1
                    termChecksComplete = false
                case .timedOut:
                    timedOut += 1
                    termChecksComplete = false
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
                termChecksComplete = false
                notes.append("\(places.count - maximumQuestions) places past the first \(maximumQuestions) were not "
                    + "checked.")
            }
            if timedOut > 0 {
                notes.append("Apple Intelligence did not answer in time for \(timedOut) "
                    + "\(timedOut == 1 ? "place" : "places"), which stay as written.")
            }
            if failed > 0 {
                notes.append("Apple Intelligence could not answer for \(failed) "
                    + "\(failed == 1 ? "place" : "places"), which stay as written.")
            }
        }
        for (segment, replacements) in accepted {
            working[segment] = working[segment].map { WordFixes.applying(replacements, to: $0) }
        }
        try Task.checkCancellation()
        let segments = base.segments.indices.map { index in
            working[index].map { WordFixes.finished($0, segment: base.segments[index]) } ?? base.segments[index]
        }
        let fixed = Transcript(source: base.source, locale: base.locale, backend: base.backend, segments: segments,
                               languages: base.languages, fixedFrom: base.id,
                               liveCorrectedFrom: base.liveCorrectedFrom)
        return Computed(transcript: fixed, counts: WordFixes.Counts(fixed), asked: asked, notes: notes,
                        unavailable: unavailable, termChecksComplete: termChecksComplete)
    }

    /// Carries the automatic decisions of a displaced fixed revision onto a newly live-corrected base. This makes
    /// the live stage's publication self-contained: if edited speaker labels make the following automatic stage
    /// decline to recompute, its previous corrections, accepted terms, and Review reverts are still present. A live
    /// mark wins on overlap. The following word-fix stage can still rebuild these from `fixedFrom` when permitted.
    static func preservingPriorFixes(from prior: Transcript, on live: Transcript) -> Transcript {
        let evidence = priorFixes(in: prior)
        guard !evidence.isEmpty else { return live }
        var working = live.segments.map { WordFixes.Working($0, preservingExistingFixes: true) }
        var used: Set<Int> = []
        var preserved = false
        for segmentIndex in live.segments.indices {
            guard var item = working[segmentIndex] else { continue }
            while let choice = evidence.indices.compactMap({ index -> (Int, CorrectionList.Match, Double)? in
                guard !used.contains(index), evidence[index].segmentID == live.segments[segmentIndex].id else {
                    return nil
                }
                let prior = evidence[index]
                let sought = prior.kind == .reviewRevert ? prior.visible : prior.heard
                let finder = CorrectionList(entries: [
                    Correction(heard: sought, meant: sought + "\u{2060}"),
                ])
                return finder.matches(in: item.text).compactMap { match in
                    let range = match.range.location..<(match.range.location + match.range.length)
                    guard !item.marks.contains(where: { $0.range.overlaps(range) }),
                          let location = location(of: match, in: item, segment: live.segments[segmentIndex]),
                          let distance = matchDistance(prior.location, location) else { return nil }
                    return (index, match, distance)
                }.min(by: { $0.2 < $1.2 })
            }).min(by: { $0.2 < $1.2 }) {
                let prior = evidence[choice.0]
                let range = choice.1.range.location..<(choice.1.range.location + choice.1.range.length)
                let before = item
                item = WordFixes.applying([
                    .init(range: range, text: prior.visible, kind: prior.kind, heard: prior.heard),
                ], to: item)
                preserved = preserved || item != before
                used.insert(choice.0)
            }
            working[segmentIndex] = item
        }
        guard preserved else { return live }
        let segments = live.segments.indices.map { index in
            working[index].map { WordFixes.finished($0, segment: live.segments[index]) } ?? live.segments[index]
        }
        return Transcript(source: live.source, locale: live.locale, backend: live.backend, segments: segments,
                          languages: live.languages, fixedFrom: live.id,
                          liveCorrectedFrom: live.liveCorrectedFrom)
    }

    private static func priorFixes(in transcript: Transcript) -> [PriorFix] {
        var result: [PriorFix] = []
        for segment in transcript.segments {
            let words = WordTiming.effectiveWords(of: segment)
            let text = segment.text as NSString
            for fix in segment.fixes ?? []
            where fix.kind == .correction || fix.kind == .term || fix.kind == .reviewRevert {
                guard fix.first >= 0, fix.first < fix.end, fix.end <= words.count else { continue }
                let first = words[fix.first], last = words[fix.end - 1]
                let range = NSRange(location: first.utf16Offset,
                                    length: last.utf16Offset + last.utf16Length - first.utf16Offset)
                guard range.location >= 0, range.location + range.length <= text.length else { continue }
                let duration = max(0, last.end - first.start)
                result.append(PriorFix(segmentID: segment.id, heard: fix.heard,
                                       visible: text.substring(with: range), kind: fix.kind,
                                       location: FixLocation(
                                        midpoint: (first.start + last.end) / 2,
                                        tolerance: max(0.05, duration / 4),
                                        wordMidpoint: (Double(fix.first) + Double(fix.end)) / 2,
                                        wordTolerance: max(1, Double(fix.end - fix.first) / 4),
                                        estimated: first.estimated || last.estimated)))
            }
        }
        return result
    }

    private static func acceptedTerms(in transcript: Transcript?) -> [AcceptedTerm] {
        guard let transcript else { return [] }
        var result: [AcceptedTerm] = []
        for segment in transcript.segments {
            let words = WordTiming.effectiveWords(of: segment)
            let text = segment.text as NSString
            for fix in segment.fixes ?? [] where fix.kind == .term {
                guard fix.first >= 0, fix.first < fix.end, fix.end <= words.count else { continue }
                let first = words[fix.first], last = words[fix.end - 1]
                let range = NSRange(location: first.utf16Offset,
                                    length: last.utf16Offset + last.utf16Length - first.utf16Offset)
                guard range.location >= 0, range.location + range.length <= text.length else { continue }
                let duration = max(0, last.end - first.start)
                result.append(AcceptedTerm(segmentID: segment.id, heard: fix.heard,
                                           visible: text.substring(with: range),
                                           location: FixLocation(
                                            midpoint: (first.start + last.end) / 2,
                                            tolerance: max(0.05, duration / 4),
                                            wordMidpoint: (Double(fix.first) + Double(fix.end)) / 2,
                                            wordTolerance: max(1, Double(fix.end - fix.first) / 4),
                                            estimated: first.estimated || last.estimated)))
            }
        }
        return result
    }

    private static func preserveReviewReverts(from transcript: Transcript?, in base: Transcript,
                                              working: inout [WordFixes.Working?]) {
        let evidence = reviewReverts(in: transcript)
        var used: Set<Int> = []
        for segmentIndex in base.segments.indices {
            guard var item = working[segmentIndex] else { continue }
            while let choice = evidence.indices.compactMap({ index -> (Int, CorrectionList.Match, Double)? in
                guard !used.contains(index), evidence[index].segmentID == base.segments[segmentIndex].id else {
                    return nil
                }
                let prior = evidence[index]
                let finder = CorrectionList(entries: [
                    Correction(heard: prior.visible, meant: prior.visible + "\u{2060}"),
                ])
                return finder.matches(in: item.text).compactMap { match in
                    let range = match.range.location..<(match.range.location + match.range.length)
                    guard !item.marks.contains(where: { $0.range.overlaps(range) }),
                          let location = location(of: match, in: item, segment: base.segments[segmentIndex]),
                          let distance = matchDistance(prior.location, location) else { return nil }
                    return (index, match, distance)
                }.min(by: { $0.2 < $1.2 })
            }).min(by: { $0.2 < $1.2 }) {
                let prior = evidence[choice.0]
                let range = choice.1.range.location..<(choice.1.range.location + choice.1.range.length)
                item.marks.append(.init(range: range, heard: prior.rejected, kind: .reviewRevert))
                used.insert(choice.0)
            }
            working[segmentIndex] = item
        }
    }

    private static func reviewReverts(in transcript: Transcript?) -> [RevertedFix] {
        guard let transcript else { return [] }
        var result: [RevertedFix] = []
        for segment in transcript.segments {
            let words = WordTiming.effectiveWords(of: segment)
            let text = segment.text as NSString
            for fix in segment.fixes ?? [] where fix.kind == .reviewRevert {
                guard fix.first >= 0, fix.first < fix.end, fix.end <= words.count else { continue }
                let first = words[fix.first], last = words[fix.end - 1]
                let range = NSRange(location: first.utf16Offset,
                                    length: last.utf16Offset + last.utf16Length - first.utf16Offset)
                guard range.location >= 0, range.location + range.length <= text.length else { continue }
                let duration = max(0, last.end - first.start)
                result.append(RevertedFix(segmentID: segment.id, rejected: fix.heard,
                                          visible: text.substring(with: range),
                                          location: FixLocation(
                                            midpoint: (first.start + last.end) / 2,
                                            tolerance: max(0.05, duration / 4),
                                            wordMidpoint: (Double(fix.first) + Double(fix.end)) / 2,
                                            wordTolerance: max(1, Double(fix.end - fix.first) / 4),
                                            estimated: first.estimated || last.estimated)))
            }
        }
        return result
    }

    private static func location(of match: CorrectionList.Match, in working: WordFixes.Working,
                                 segment: TranscriptSegment)
        -> FixLocation? {
        let range = match.range.location..<(match.range.location + match.range.length)
        let words = WordTiming.effectiveWords(of: WordFixes.finished(working, segment: segment))
        let touched = words.indices.filter { index in
            let word = words[index]
            return (word.utf16Offset..<(word.utf16Offset + word.utf16Length)).overlaps(range)
        }
        guard let firstIndex = touched.first, let lastIndex = touched.last else { return nil }
        let first = words[firstIndex], last = words[lastIndex]
        let duration = max(0, last.end - first.start)
        return FixLocation(midpoint: (first.start + last.end) / 2,
                           tolerance: max(0.05, duration / 4),
                           wordMidpoint: (Double(firstIndex) + Double(lastIndex + 1)) / 2,
                           wordTolerance: max(1, Double(lastIndex + 1 - firstIndex) / 4),
                           estimated: first.estimated || last.estimated)
    }

    private static func matchDistance(_ prior: FixLocation, _ current: FixLocation) -> Double? {
        if prior.estimated || current.estimated {
            let distance = abs(prior.wordMidpoint - current.wordMidpoint)
            return distance <= max(prior.wordTolerance, current.wordTolerance) ? distance : nil
        }
        let distance = abs(prior.midpoint - current.midpoint)
        return distance <= max(prior.tolerance, current.tolerance) ? distance : nil
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
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

    private struct Publication {
        var problem: String?
        var labelsPreserved = false
    }

    /// Under the writer lock and then the speaker lock (as the languages stage publishes), checks once more what the
    /// head is. A named, unforced `fix-words` maps a usable head and its effective edits to the new word positions;
    /// automatic processing still leaves edited labels and the transcript alone, while `--force` relabels as before.
    /// The event precedes the transcript pointer, and a preserved head follows it. A cancellation seen with both
    /// locks held publishes nothing.
    private static func publish(_ fixed: Transcript, details: [String: String], request: Request) async throws
        -> Publication {
        let archive = try SessionArchive.openForMaintenance(at: request.session, lease: request.lease)
        do {
            let publication = try await SessionArchive.withSpeakerLockAsync(at: request.session) {
                () async throws -> Publication in
                let head = try SpeakerAnalysis.headState(session: request.session, transcript: request.transcript)
                let edited = head?.needsForce(false) == true
                if edited, !request.requested { return Publication(problem: editedHead) }
                var plan: SpeakerTranscriptRetarget.Plan?
                if request.requested, !request.force, head?.usableRunID != nil {
                    let snapshot = try SpeakerSessionSnapshot.load(session: request.session)
                    plan = try SpeakerTranscriptRetarget.plan(session: request.session, from: snapshot, to: fixed)
                    if edited, plan == nil {
                        return Publication(problem: "The speaker labels could not be kept, so the transcript was not changed.")
                    }
                }
                whilePublishing?()
                try Task.checkCancellation()
                if let plan { try SpeakerTranscriptRetarget.stage(plan, session: request.session) }
                try await archive.recordEvent(kind: MeetingEventKind.wordsFixed, details: details)
                try await archive.saveTranscript(fixed, writeLegacyExports: false)
                if let plan {
                    do {
                        try SpeakerTranscriptRetarget.publishHead(plan, session: request.session)
                    } catch {
                        throw IncompletePublication(message: "The fixed transcript was saved, but the speaker head "
                                                    + "could not be published: \(error.localizedDescription)")
                    }
                }
                return Publication(problem: nil, labelsPreserved: plan != nil)
            }
            await archive.releaseLock()
            return publication
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    /// Repairs the only incomplete state `publish` can leave: the fixed transcript is current while the preceding
    /// head is still published. The old head remains a complete snapshot, so rebuild the same retarget plan from it.
    /// Returns true only when it published a replacement head; no head, or a head already on `transcript`, needs the
    /// ordinary later-stage decision.
    private static func repairPreservedHeadIfNeeded(_ transcript: Transcript, request: Request) async throws -> Bool {
        let initial = try SpeakerAnalysis.headState(session: request.session, transcript: transcript)
        guard let initial, !initial.sameTranscript, initial.run != nil else { return false }
        let archive = try SessionArchive.openForMaintenance(at: request.session, lease: request.lease)
        do {
            let repaired = try await SessionArchive.withSpeakerLockAsync(at: request.session) { () async throws -> Bool in
                guard try SessionFiles.currentTranscript(session: request.session)?.id == transcript.id else {
                    throw HolosError.invalidInput("The transcript changed while its speaker labels were being repaired.")
                }
                guard let head = try SpeakerAnalysis.headState(session: request.session, transcript: transcript),
                      head.runID == initial.runID else {
                    throw HolosError.invalidInput("The speaker labels changed while they were being repaired.")
                }
                if head.sameTranscript { return false }
                let snapshot = try SpeakerSessionSnapshot.load(session: request.session)
                guard let plan = try SpeakerTranscriptRetarget.plan(session: request.session, from: snapshot,
                                                                   to: transcript) else {
                    if head.hasEdits {
                        throw HolosError.invalidInput("The edited speaker labels cannot be mapped to the fixed words.")
                    }
                    return false
                }
                try Task.checkCancellation()
                try SpeakerTranscriptRetarget.stage(plan, session: request.session)
                try SpeakerTranscriptRetarget.publishHead(plan, session: request.session)
                return true
            }
            await archive.releaseLock()
            return repaired
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    // MARK: - Lineage

    /// The transcript `transcriptID` was corrected from, following automatic and live correction events back to one
    /// that was not corrected; `transcriptID` itself when it was not. Every bookkeeping that names transcripts by ID
    /// (a merge's languages, a rebuild) asks about that one, since a corrected transcript stands for it.
    static func unfixedID(_ transcriptID: String, events: [ArchiveEvent]) -> String {
        var id = transcriptID
        var seen: Set<String> = [id]
        while let base = events.last(where: {
            ($0.kind == MeetingEventKind.wordsFixed || $0.kind == MeetingEventKind.liveHintsApplied)
                && $0.details["transcriptID"] == id
        })?.details["base"], !base.isEmpty, seen.insert(base).inserted {
            id = base
        }
        return id
    }
}
