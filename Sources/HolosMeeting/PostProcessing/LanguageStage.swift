import Foundation
import HolosCore
import HolosSpeakers
import HolosSpeech
import HolosStorage
import os

/// What the language stage uses outside the session folder (docs/meeting-design.md §4.14): speech recognition, the
/// speech-model check, and language identification. Only `live` touches speech assets; tests pass fakes.
public struct LanguageDetectionDependencies: Sendable {
    /// Transcribes saved audio in one language (`TrackReplayer`).
    public var makeSpeech: LiveSpeechFactory
    /// A language's speech model state, as `AppleSpeechEngine.assetStatus` names it ("installed", "supported",
    /// "downloading", "unsupported"). Only "installed" can transcribe.
    public var modelStatus: @Sendable (_ locale: String, _ backend: SpeechBackend) async -> String
    /// A scorer for one merge (`LanguageMerge.Scorer`), used from one task.
    public var makeScorer: @Sendable () -> LanguageMerge.Scorer
    /// The time limits of each speech call while transcribing (the stop path's); nil: none.
    public var timeouts: StopTimeouts?

    public init(makeSpeech: @escaping LiveSpeechFactory,
                modelStatus: @escaping @Sendable (_ locale: String, _ backend: SpeechBackend) async -> String,
                makeScorer: @escaping @Sendable () -> LanguageMerge.Scorer, timeouts: StopTimeouts? = .standard) {
        self.makeSpeech = makeSpeech; self.modelStatus = modelStatus; self.makeScorer = makeScorer
        self.timeouts = timeouts
    }

    /// Apple's speech transcriber (`AppleSpeechSession`, final results only: nothing waits for these words), its asset
    /// inventory, and `NLLanguageRecognizer`.
    public static var live: LanguageDetectionDependencies {
        LanguageDetectionDependencies(
            makeSpeech: { locale, backend, contextualStrings, onUpdate in
                try await AppleSpeechSession.make(locale: locale, backend: backend,
                                                  contextualStrings: contextualStrings, accurate: true,
                                                  onUpdate: onUpdate)
            },
            modelStatus: { locale, backend in
                // The check throws only for a language the transcriber does not support.
                (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: backend)) ?? "unsupported"
            },
            makeScorer: { NaturalLanguageScorer().scorer })
    }
}

/// Stage 1b of the post-processor, `languages` (docs/meeting-design.md §4.14): for a meeting in several languages,
/// the saved audio is transcribed again in each language with final results only (the live transcript's fast results
/// measured about 3 points of word error rate worse), each transcription is kept as a revision that is not current
/// (`languagePass`), and the transcript merged from them (`LanguageMerge`) becomes current (`languagesDetected`, then
/// the save), so the later stages label speakers on it. The recorded transcript (the base) stands in for its own
/// language only when that language cannot be transcribed again, and never when it is incomplete.
///
/// Which languages: `requested` (`PostProcessingOptions.languages`) when given; else meeting.json's `languages`,
/// when the current transcript is not merged yet, or was merged automatically from them but missed some. Nothing is
/// done or recorded for a meeting in one language.
///
/// Resumable and idempotent: a current transcript already merged from exactly these languages is kept; a
/// transcription saved by an earlier run (after the last recovery) is reused; nothing is published until the merged
/// transcript is saved. Fails soft: a language that cannot be transcribed (no speech model, a speech error, deleted
/// audio) is left out and said why (`problem`, which makes the post-processing partial); without the first language,
/// or with fewer than two where several were asked for, the current transcript stays as it is, and nothing is
/// transcribed when that is known beforehand. A transcript whose speaker labels were edited is replaced only with
/// `force` (names carry over when speakers are labelled again).
enum LanguageStage {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    struct Request {
        var session: URL
        var manifest: SessionManifest
        /// The current transcript.
        var transcript: Transcript
        var lease: ProcessingLease
        /// `PostProcessingOptions.languages`.
        var requested: [String]?
        var force: Bool
    }

    struct Outcome {
        /// The transcript the later stages use: the merged one when this stage made or found it, else the current.
        var transcript: Transcript
        /// For the final record's message: "Transcribed in French (Canada) and English (Canada)."
        var note: String?
        /// Why the stage did not do all it was asked; makes the post-processing partial.
        var problem: String?
    }

    static let editedHead = "Speaker labels were edited, so the languages were not detected again. To detect them "
        + "and label speakers again (names carry over), run voiceislocal session languages with --force."
    /// Ends the note that the recorded transcript stood in for a language that could not be transcribed again.
    static let standsIn = "The recorded transcript stands in for it."

    /// Test hook: while set (a task-local value), called after the merge and before its publication takes the locks,
    /// the window where a speaker edit saved meanwhile must still keep the merge from being published.
    @TaskLocal static var beforePublish: (@Sendable () -> Void)? = nil
    /// Test hook: while set (a task-local value), called with the writer and speaker locks held, after the last
    /// edited-labels check and before the merged transcript is journaled and saved.
    @TaskLocal static var whilePublishing: (@Sendable () -> Void)? = nil

    /// Runs the stage and records its outcome. Throws only `CancellationError`: every other failure is recorded
    /// and the current transcript kept.
    static func run(_ request: Request, dependencies: LanguageDetectionDependencies,
                    recorder: StageRecorder) async throws -> Outcome {
        let current = request.transcript
        let unchanged = Outcome(transcript: current)
        let events: [ArchiveEvent]
        do {
            events = try SessionArchive.readEvents(at: request.session).events
        } catch let error where !(error is CancellationError) {
            // Without the journal no earlier merge can be told apart, so only languages asked for now are detected.
            guard request.requested != nil else { return unchanged }
            let started = recorder.begin(.languages, message: "Checking the meeting's languages…")
            let message = "Cannot read the event journal: \(error.localizedDescription)"
            recorder.end(.languages, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        guard let target = targetLanguages(requested: request.requested, session: request.session,
                                           manifest: request.manifest, transcript: current, events: events),
              !target.isEmpty else { return unchanged }

        let started = recorder.begin(.languages, message: "Checking the meeting's languages…")
        // The language the recorded transcript stood in for in the current merge, which is tried again.
        let previousStandIn = standIn(of: current, events: events)
        if alreadyMade(current, target: target, previousStandIn: previousStandIn) {
            recorder.end(.languages, .succeeded, "The transcript was already made from \(names(target)).",
                         since: started)
            return Outcome(transcript: current, note: note(target))
        }
        if let problem = editedHeadProblem(request) {
            recorder.end(.languages, .skipped, problem, since: started)
            return Outcome(transcript: current, problem: problem)
        }

        // The transcription in each language: an earlier run's, else one made now from the saved audio (final
        // results only, which measured better than the live transcript's fast ones); the recorded transcript stands in
        // for its own language only when that language cannot be transcribed again.
        let base = baseTranscript(current, events: events, session: request.session)
        let fallback = request.manifest.status == ArchiveStatus.transcriptionIncomplete ? nil : base
        // The language the recorded transcript is in, as the targets name it ("en_CA" in an older session is "en-CA").
        let fallbackLocale = fallback.map { canonical($0.locale) }
        // A transcription with no words where the current transcript has some failed rather than heard silence: it
        // never replaces those words (nor is it reused), and the recorded transcript may stand in for it.
        let expectsWords = hasWords(current.segments)
        var sources: [String: Transcript] = [:]
        for language in target {
            sources[language] = reusablePass(language, events: events, session: request.session,
                                             backend: request.manifest.backend, expectsWords: expectsWords)
        }
        let plan = try await planTranscriptions(target.filter { sources[$0] == nil }, request: request,
                                                dependencies: dependencies)
        var reasons = plan.reasons
        // Nothing is transcribed when the languages that can be had would not make a merge anyway.
        let reachable = target.filter { sources[$0] != nil || plan.languages.contains($0) || fallbackLocale == $0 }
        if mergeable(reachable, target: target) {
            let transcribed = try await transcribe(plan.languages, request: request, dependencies: dependencies,
                                                   recorder: recorder, expectsWords: expectsWords)
            sources.merge(transcribed.sources) { _, new in new }
            reasons.merge(transcribed.failures) { _, new in new }
        }
        // Said in the messages and journaled (`fallback`), so a later run tries that language again.
        var standIn: String?
        var standInNote: String?
        if let fallback, let locale = fallbackLocale, target.contains(locale), sources[locale] == nil {
            sources[locale] = fallback
            standIn = locale
            standInNote = (reasons[locale] ?? "\(name(locale)) was not transcribed again.") + " " + standsIn
            reasons[locale] = nil
            log.notice("Session \(request.manifest.id, privacy: .public): the recorded transcript stands in for \(locale, privacy: .public)")
        }

        let available = target.filter { sources[$0] != nil }
        let failures = target.compactMap { sources[$0] == nil ? reasons[$0] : nil }
        let failure = failures.isEmpty ? nil : failures.joined(separator: " ")
        guard let primary = target.first, mergeable(available, target: target) else {
            let message = "Kept the transcript as it was. " + (failure ?? "")
            recorder.end(.languages, .failed, message.trimmingCharacters(in: .whitespaces), since: started)
            return Outcome(transcript: current, problem: message.trimmingCharacters(in: .whitespaces))
        }
        let merging = [note(available), standInNote].compactMap { $0 }.joined(separator: " ")
        if canonical(current.languages) == available && previousStandIn == standIn {
            // Nothing new could be added (a language is still missing, or still stood in for): the current merge
            // stands.
            let message = [standInNote, failure].compactMap { $0 }.joined(separator: " ")
            recorder.end(.languages, failure == nil ? .succeeded : .failed, message.isEmpty ? nil : message,
                         since: started)
            return Outcome(transcript: current, note: merging, problem: failure)
        }

        // The merge (pure), then its publication under the writer lock.
        recorder.progress(.languages, track: nil, fraction: nil, message: "Choosing the language of each passage…")
        let tracks = sessionTracks(request.manifest)
        let echo = echoParameters(request)
        let candidates = available.map { language in
            let segments = attributed(sources[language]?.segments ?? [], tracks: tracks)
            // Microphone echo of a call, found in each language's own transcription, where both tracks were heard
            // by the same recognizer (LanguageMerge rule 5).
            let spans = echo.map { parameters in
                EchoFilter.echoSpans(transcript: Transcript(source: request.session.path, locale: language,
                                                            backend: request.manifest.backend, segments: segments),
                                     parameters: parameters)
            } ?? []
            return LanguageMerge.Candidate(language: language, segments: segments, echo: spans)
        }
        let result = LanguageMerge.merge(candidates, scorer: dependencies.makeScorer())
        try Task.checkCancellation()
        guard !expectsWords || hasWords(result.segments) else {
            // A merge that kept no words never replaces a transcript that has some.
            let message = "Kept the transcript as it was: no words were recognized in \(names(available))."
            recorder.end(.languages, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        let merged = Transcript(source: request.session.path, locale: primary, backend: request.manifest.backend,
                                segments: result.segments, languages: available)
        var details = [
            "transcriptID": merged.id, "base": base?.id ?? "", "languages": available.joined(separator: ","),
            "requested": target.joined(separator: ","), "windows": String(result.summary.windows),
            "switches": String(result.summary.switches),
        ]
        for language in available {
            details["source.\(language)"] = sources[language]?.id ?? ""
            details["windows.\(language)"] = String(result.summary.windowsByLanguage[language] ?? 0)
        }
        if let standIn { details["fallback"] = standIn }
        beforePublish?()
        do {
            // Labels edited while the audio was transcribed are kept, and the passes wait for --force. Decided under
            // the speaker lock the publication holds, so an edit saved meanwhile is either seen or waits for it.
            if let problem = try await publish(merged, details: details, request: request) {
                recorder.end(.languages, .skipped, problem, since: started)
                return Outcome(transcript: current, problem: problem)
            }
        } catch let error where !(error is CancellationError) {
            let message = "Cannot save the transcript merged from \(names(available)): \(error.localizedDescription)"
            recorder.end(.languages, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        log.notice("Session \(request.manifest.id, privacy: .public): merged \(available.count, privacy: .public) languages over \(result.summary.windows, privacy: .public) windows, \(result.summary.switches, privacy: .public) switches")
        // Merged: the stage did its job, even when a language is missing (that makes the post-processing partial).
        let summary = summaryMessage(result.summary, languages: available)
        recorder.end(.languages, .succeeded, [summary, standInNote, failure].compactMap { $0 }.joined(separator: " "),
                     since: started)
        return Outcome(transcript: merged, note: merging, problem: failure)
    }

    // MARK: - Which languages

    /// Whether a run without languages asked for by name (Label Speakers, an automatic relabel, recovery) would try to
    /// change `transcript`: meeting.json names several languages and it is not merged from them yet, or it was merged
    /// from them automatically and missed one or had the recorded transcript stand in for one. Recovery asks this
    /// before it calls the speaker labels up to date, so the missed language is retried once its model is installed.
    /// False when the journal or meeting.json cannot be read (the stage would do nothing either).
    static func hasPendingWork(session: URL, manifest: SessionManifest, transcript: Transcript) -> Bool {
        guard let events = try? SessionArchive.readEvents(at: session).events,
              let target = targetLanguages(requested: nil, session: session, manifest: manifest,
                                           transcript: transcript, events: events),
              !target.isEmpty else { return false }
        return !alreadyMade(transcript, target: target,
                            previousStandIn: standIn(of: transcript, events: events))
    }

    /// The languages to merge, the preferred one first; nil when there is nothing to do.
    private static func targetLanguages(requested: [String]?, session: URL, manifest: SessionManifest,
                                        transcript current: Transcript, events: [ArchiveEvent]) -> [String]? {
        if let requested {
            let languages = DictationLanguage.meetingLanguages(requested)
            return languages.isEmpty ? nil : languages
        }
        let meeting: MeetingInfo
        do {
            meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        } catch {
            // Stage 2 reports a meeting.json it cannot read; without it the meeting counts as one language.
            log.error("Session \(manifest.id, privacy: .public): meeting.json unreadable; languages not detected: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        let languages = DictationLanguage.meetingLanguages(meeting.languages ?? [])
        guard languages.count > 1 else { return nil }
        guard current.languages != nil else { return languages }
        // A merged transcript: redo it only when it was made from meeting.json's languages and missed some. One made
        // from languages asked for by name (`voiceislocal session languages`) stays.
        // A language the recorded transcript stood in for counts as missed.
        guard let merge = mergeEvent(of: current.id, events: events),
              canonical(DictationLanguage.list(merge.details["requested"] ?? "")) == languages,
              canonical(current.languages) != languages || standIn(of: current, events: events) != nil
        else { return nil }
        return languages
    }

    /// Whether `current` is already the transcript `target` asks for: merged from exactly those languages with none
    /// stood in for, or, for one language, the recording's own transcript in it.
    private static func alreadyMade(_ current: Transcript, target: [String], previousStandIn: String?) -> Bool {
        if let languages = canonical(current.languages) { return languages == target && previousStandIn == nil }
        return target == [canonical(current.locale)]
    }

    /// The language the recorded transcript stood in for in the merge `current` is (its `languagesDetected`
    /// `fallback`); nil when it is not merged or none stood in.
    private static func standIn(of current: Transcript, events: [ArchiveEvent]) -> String? {
        guard current.languages != nil,
              let fallback = mergeEvent(of: current.id, events: events)?.details["fallback"],
              !fallback.isEmpty else { return nil }
        return canonical(fallback)
    }

    /// The `languagesDetected` event of the merged transcript `transcriptID`, if it was journaled.
    static func mergeEvent(of transcriptID: String, events: [ArchiveEvent]) -> ArchiveEvent? {
        events.last { $0.kind == MeetingEventKind.languagesDetected && $0.details["transcriptID"] == transcriptID }
    }

    /// A locale identifier as the stage compares and journals it ("en-CA" for "en_CA"): every comparison of a
    /// transcript's, pass's, or journaled language with the targets goes through this, since an older session
    /// can have recorded an underscore identifier.
    private static func canonical(_ locale: String) -> String { DictationLanguage.identifier(locale) }

    private static func canonical(_ locales: [String]?) -> [String]? { locales.map { $0.map(canonical) } }

    /// Whether any segment holds a word.
    private static func hasWords(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { !$0.words.isEmpty || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Why the transcript must not be replaced now: its speaker labels were edited and `force` is off. Nil when it
    /// may be (a head that cannot be read counts as replaceable only when it is damaged, as stage 3 decides).
    private static func editedHeadProblem(_ request: Request) -> String? {
        do {
            guard let head = try SpeakerAnalysis.headState(session: request.session, transcript: request.transcript),
                  head.needsForce(request.force) else { return nil }
            return editedHead
        } catch {
            return "Cannot read the current speaker labels, so the transcript was kept: \(error.localizedDescription)"
        }
    }

    // MARK: - The transcription in each language

    /// The recorded transcript the merged ones are made from: the current transcript when it is not merged, else the
    /// one its `languagesDetected` event names (nil when that cannot be read).
    private static func baseTranscript(_ current: Transcript, events: [ArchiveEvent], session: URL) -> Transcript? {
        guard current.languages != nil else { return current }
        guard let id = mergeEvent(of: current.id, events: events)?.details["base"], !id.isEmpty,
              let base = try? SessionFiles.transcript(id: id, session: session), base.languages == nil else {
            return nil
        }
        return base
    }

    /// The last transcription in `language` an earlier run saved (`languagePass`) after the last recovery, which
    /// may have added audio, when its revision reads as one (and, with `expectsWords`, holds words).
    private static func reusablePass(_ language: String, events: [ArchiveEvent], session: URL,
                                     backend: SpeechBackend, expectsWords: Bool) -> Transcript? {
        let recovered = events.last { $0.kind == MeetingEventKind.archiveRecovered }?.sequence ?? 0
        for event in events.reversed() where event.sequence > recovered
            && event.kind == MeetingEventKind.languagePass && event.details["language"].map(canonical) == language {
            guard let id = event.details["transcriptID"],
                  let pass = try? SessionFiles.transcript(id: id, session: session),
                  canonical(pass.locale) == language, pass.languages == nil, pass.backend == backend,
                  !expectsWords || hasWords(pass.segments) else { continue }
            return pass
        }
        return nil
    }

    /// Whether `available` can be merged for `target`: it has the first language, and two languages when several were
    /// asked for.
    private static func mergeable(_ available: [String], target: [String]) -> Bool {
        guard let primary = target.first else { return false }
        return available.contains(primary) && available.count >= min(2, target.count)
    }

    /// Which of `languages` can be transcribed now (their speech model is installed and the audio is there), and why
    /// each other one cannot.
    private static func planTranscriptions(_ languages: [String], request: Request,
                                           dependencies: LanguageDetectionDependencies) async throws
        -> (languages: [String], reasons: [String: String]) {
        guard !languages.isEmpty else { return ([], [:]) }
        var reasons: [String: String] = [:]
        do {
            if try SessionFiles.audioDeleted(session: request.session, sessionID: request.manifest.id) {
                for language in languages {
                    reasons[language] = "\(name(language)) was not transcribed: the meeting's audio was deleted."
                }
                return ([], reasons)
            }
        } catch let error where !(error is CancellationError) {
            for language in languages {
                reasons[language] = "\(name(language)) was not transcribed: \(error.localizedDescription)"
            }
            return ([], reasons)
        }
        var planned: [String] = []
        let check = dependencies.modelStatus
        let backend = request.manifest.backend
        for language in languages {
            try Task.checkCancellation()
            // The asset inventory is a platform call; it is waited for within the stop path's limit (§1.3).
            let status: String
            if let limit = dependencies.timeouts?.speechFinishBase {
                switch await awaitWithTimeout(limit, { await check(language, backend) }) {
                case .finished(.success(let value)): status = value
                case .finished(.failure): status = "unsupported"
                case .cancelled: throw CancellationError()
                case .timedOut:
                    reasons[language] = "\(name(language)) was not transcribed: its speech model did not answer "
                        + "in time. Later, " + detectAgain + "."
                    continue
                }
            } else {
                status = await check(language, backend)
            }
            if status == "installed" {
                planned.append(language)
            } else {
                reasons[language] = modelProblem(language, status: status)
            }
        }
        return (planned, reasons)
    }

    /// Transcribes the saved audio of every track in each of `languages`, one after the other, and saves each
    /// transcription (`languagePass`). A language whose transcription fails is left out with the reason, and so is
    /// one that recognized no words at all when `expectsWords` (the current transcript has some): nothing is saved
    /// for it, so a later run tries again.
    private static func transcribe(_ languages: [String], request: Request,
                                   dependencies: LanguageDetectionDependencies,
                                   recorder: StageRecorder, expectsWords: Bool) async throws
        -> (sources: [String: Transcript], failures: [String: String]) {
        guard !languages.isEmpty else { return ([:], [:]) }
        let session = request.session
        let manifest = request.manifest
        let tracks = sessionTracks(manifest)
        // The meeting's vocabulary, as the recording used it; an unreadable one is left out rather than stopping.
        let vocabulary = (try? TranscriptRebuilder.sessionVocabulary(session)) ?? []
        let journal = recorder.journal
        var sources: [String: Transcript] = [:]
        var failures: [String: String] = [:]
        for language in languages {
            try Task.checkCancellation()
            let message = "Transcribing the meeting in \(name(language))…"
            recorder.progress(.languages, track: nil, fraction: 0, message: message)
            do {
                let pass = try await transcription(in: language, tracks: tracks, request: request,
                                                   vocabulary: vocabulary, dependencies: dependencies) { fraction in
                    journal.progress(PostProcessingProgress(stage: .languages, fraction: fraction, message: message))
                }
                try Task.checkCancellation()
                guard !expectsWords || hasWords(pass.segments) else {
                    log.error("Session \(manifest.id, privacy: .public): the transcription in \(language, privacy: .public) recognized no words")
                    failures[language] = "\(name(language)) was not transcribed: no words were recognized."
                    continue
                }
                sources[language] = pass
                do {
                    try await savePass(pass, tracks: tracks, manifest: manifest, session: session,
                                       lease: request.lease)
                } catch let error where !(error is CancellationError) && !Task.isCancelled {
                    // The transcription still goes into this merge; only a later run cannot reuse it.
                    log.error("Session \(manifest.id, privacy: .public): the transcription in \(language, privacy: .public) was not saved for later runs: \(error.localizedDescription, privacy: .private)")
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                log.error("Session \(manifest.id, privacy: .public): transcription in \(language, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                failures[language] = "\(name(language)) was not transcribed: \(error.localizedDescription)"
            }
        }
        return (sources, failures)
    }

    /// One transcription of every track in `language`, from the saved audio, every speech call within the time limits.
    private static func transcription(in language: String, tracks: [String], request: Request, vocabulary: [String],
                                      dependencies: LanguageDetectionDependencies,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let manifest = request.manifest
        let total = max(tracks.reduce(0.0) { $0 + manifest.audioSeconds(track: $1) }, 1e-9)
        // Audio is fed in buffers of about 85 ms, over a hundred times faster than real time: progress is reported
        // at most once per whole percent, as rendering does, so the status files are not rewritten for every buffer.
        let fed = LockedValue((seconds: 0.0, percent: -1))
        let base = dependencies.makeSpeech
        let counting: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
            let session = try await base(locale, backend, contextualStrings, onUpdate)
            return CountingSpeechSession(base: session) { duration in
                let percent = fed.withLock { value -> Int? in
                    value.seconds += duration
                    let percent = Int(min(1, value.seconds / total) * 100)
                    guard percent > value.percent else { return nil }
                    value.percent = percent
                    return percent
                }
                if let percent { progress(Double(percent) / 100) }
            }
        }
        var segments: [TranscriptSegment] = []
        for track in tracks {
            try Task.checkCancellation()
            segments += try await TrackReplayer.replay(directory: request.session, track: track, locale: language,
                                                       backend: manifest.backend, contextualStrings: vocabulary,
                                                       makeSpeech: counting, timeouts: dependencies.timeouts)
        }
        segments.sort { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        return Transcript(source: request.session.path, locale: language, backend: manifest.backend,
                          segments: segments)
    }

    /// Saves a transcription as a revision that is not current, then journals it (`languagePass`), so a later run
    /// can reuse it. The writer lock is held only for this.
    private static func savePass(_ pass: Transcript, tracks: [String], manifest: SessionManifest, session: URL,
                                 lease: ProcessingLease) async throws {
        let seconds = tracks.reduce(0.0) { $0 + manifest.audioSeconds(track: $1) }
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            try await archive.saveTranscriptRevision(pass)
            try await archive.recordEvent(kind: MeetingEventKind.languagePass, details: [
                "transcriptID": pass.id, "language": pass.locale, "tracks": tracks.joined(separator: ","),
                "seconds": String(seconds),
            ])
        } catch {
            await archive.releaseLock()
            throw error
        }
        await archive.releaseLock()
    }

    /// Under the writer lock and then the speaker lock (the §1.7 order deletion uses), checks once more that the
    /// current transcript's speaker labels were not edited (`editedHeadProblem`, returned without publishing), then
    /// journals `languagesDetected` (before the save, so a merged current transcript is always explained) and makes
    /// the merged transcript current. A speaker edit (`SpeakerEditor`, which takes the speaker lock) is therefore
    /// either saved before the check and keeps the merge from being published, or waits until the merged transcript
    /// is current and is then an edit of the replaced transcript's labels, which the speaker stages treat as they do
    /// after any new transcript (names carry over). Both locks are held only for this.
    private static func publish(_ merged: Transcript, details: [String: String],
                                request: Request) async throws -> String? {
        let archive = try SessionArchive.openForMaintenance(at: request.session, lease: request.lease)
        do {
            let problem = try await SessionArchive.withSpeakerLockAsync(at: request.session) { () async throws -> String? in
                if let problem = editedHeadProblem(request) { return problem }
                whilePublishing?()
                try await archive.recordEvent(kind: MeetingEventKind.languagesDetected, details: details)
                try await archive.saveTranscript(merged, writeLegacyExports: false)
                return nil
            }
            await archive.releaseLock()
            return problem
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    // MARK: - Helpers

    /// The speaker stages' alignment parameters when they look for microphone echo (a call); nil otherwise, or when
    /// meeting.json cannot be read (stage 2 reports that).
    private static func echoParameters(_ request: Request) -> AlignmentParameters? {
        guard let meeting = try? SessionFiles.meetingInfo(session: request.session, manifest: request.manifest)
        else { return nil }
        let parameters = SpeakerAnalysis.alignmentParameters(meeting: meeting)
        return parameters.echoWindowSeconds == nil ? nil : parameters
    }

    /// The session's tracks with audio, "mic" before "system".
    private static func sessionTracks(_ manifest: SessionManifest) -> [String] {
        Set(manifest.chunks.map(\.track)).sorted()
    }

    /// Segments without a track (older transcripts) belong to the session's only track, when it has one, so they are
    /// compared with that track's other transcriptions.
    private static func attributed(_ segments: [TranscriptSegment], tracks: [String]) -> [TranscriptSegment] {
        guard tracks.count == 1, let only = tracks.first else { return segments }
        return segments.map { segment in
            var attributed = segment
            if attributed.track == nil { attributed.track = only }
            return attributed
        }
    }

    /// "French (Canada)": language names in English, as the rest of the messages.
    static func name(_ language: String) -> String {
        DictationLanguage.name(of: language, in: Locale(identifier: "en_US"))
    }

    /// "French (Canada) and English (Canada)"; "French (Canada), English (Canada), and Spanish (Spain)".
    static func names(_ languages: [String]) -> String {
        let spelled = languages.map(name)
        switch spelled.count {
        case 0: return ""
        case 1: return spelled[0]
        case 2: return "\(spelled[0]) and \(spelled[1])"
        default: return spelled.dropLast().joined(separator: ", ") + ", and " + (spelled.last ?? "")
        }
    }

    /// "Transcribed in French (Canada) and English (Canada)."
    static func note(_ languages: [String]) -> String {
        "Transcribed in \(names(languages))."
    }

    /// Why `language` cannot be transcribed, from its speech model state.
    static func modelProblem(_ language: String, status: String) -> String {
        switch status {
        case "unsupported":
            "\(name(language)) was not transcribed: this Mac's speech recognition does not support it."
        case "downloading":
            "\(name(language)) was not transcribed: its speech model is still downloading. Once it is installed, "
                + detectAgain + "."
        default:
            "\(name(language)) was not transcribed: its speech model is not installed. Install it from the meeting "
                + "start panel or with voiceislocal setup --locale \(language), then " + detectAgain + "."
        }
    }

    /// What detects the languages again from the app: Label Speakers runs `session diarize`, which runs this stage
    /// first and picks up a language missed before (unless speaker labels were edited).
    static let detectAgain = "choose Label Speakers in Meetings to detect the languages again"

    /// "Kept French (Canada) in 70 % of the passages and English (Canada) in 30 %, with 212 switches."
    static func summaryMessage(_ summary: LanguageMerge.Summary, languages: [String]) -> String {
        guard summary.windows > 0 else { return "No words were recognized in any language." }
        let parts = languages.enumerated().map { index, language in
            let share = Int((Double(summary.windowsByLanguage[language] ?? 0) / Double(summary.windows) * 100)
                .rounded())
            return index == 0 ? "\(name(language)) in \(share) % of the passages" : "\(name(language)) in \(share) %"
        }
        let joined = parts.count <= 2 ? parts.joined(separator: " and ")
            : parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        let switches = summary.switches == 1 ? "1 switch" : "\(summary.switches) switches"
        return "Kept \(joined), with \(switches)."
    }
}
