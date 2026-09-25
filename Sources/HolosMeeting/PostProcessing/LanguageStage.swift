import Foundation
import HolosCore
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

    static let editedHead = "Speaker labels were edited; detect languages with --force (names carry over)."

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
        guard let target = targetLanguages(request, events: events), !target.isEmpty else { return unchanged }

        let started = recorder.begin(.languages, message: "Checking the meeting's languages…")
        if current.languages == target || (current.languages == nil && target == [current.locale]) {
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
        var sources: [String: Transcript] = [:]
        for language in target {
            sources[language] = reusablePass(language, events: events, session: request.session,
                                             backend: request.manifest.backend)
        }
        let plan = try await planTranscriptions(target.filter { sources[$0] == nil }, request: request,
                                                dependencies: dependencies)
        var reasons = plan.reasons
        // Nothing is transcribed when the languages that can be had would not make a merge anyway.
        let reachable = target.filter { sources[$0] != nil || plan.languages.contains($0) || fallback?.locale == $0 }
        if mergeable(reachable, target: target) {
            let transcribed = try await transcribe(plan.languages, request: request, dependencies: dependencies,
                                                   recorder: recorder)
            sources.merge(transcribed.sources) { _, new in new }
            reasons.merge(transcribed.failures) { _, new in new }
        }
        if let fallback, target.contains(fallback.locale), sources[fallback.locale] == nil {
            sources[fallback.locale] = fallback
            reasons[fallback.locale] = nil
            log.notice("Session \(request.manifest.id, privacy: .public): the recorded transcript stands in for \(fallback.locale, privacy: .public)")
        }

        let available = target.filter { sources[$0] != nil }
        let failures = target.compactMap { sources[$0] == nil ? reasons[$0] : nil }
        let failure = failures.isEmpty ? nil : failures.joined(separator: " ")
        guard let primary = target.first, mergeable(available, target: target) else {
            let message = "Kept the transcript as it was. " + (failure ?? "")
            recorder.end(.languages, .failed, message.trimmingCharacters(in: .whitespaces), since: started)
            return Outcome(transcript: current, problem: message.trimmingCharacters(in: .whitespaces))
        }
        if current.languages == available {
            // Nothing new could be added (a language is still missing): the current merge stands.
            recorder.end(.languages, .failed, failure, since: started)
            return Outcome(transcript: current, note: note(available), problem: failure)
        }

        // The merge (pure), then its publication under the writer lock.
        recorder.progress(.languages, track: nil, fraction: nil, message: "Choosing the language of each passage…")
        let tracks = sessionTracks(request.manifest)
        let candidates = available.map { language in
            LanguageMerge.Candidate(language: language,
                                    segments: attributed(sources[language]?.segments ?? [], tracks: tracks))
        }
        let result = LanguageMerge.merge(candidates, scorer: dependencies.makeScorer())
        try Task.checkCancellation()
        let merged = Transcript(source: request.session.path, locale: primary, backend: request.manifest.backend,
                                segments: result.segments, languages: available)
        if let problem = editedHeadProblem(request) {
            // Labels were edited while the audio was transcribed: they are kept, and the passes wait for --force.
            recorder.end(.languages, .skipped, problem, since: started)
            return Outcome(transcript: current, problem: problem)
        }
        var details = [
            "transcriptID": merged.id, "base": base?.id ?? "", "languages": available.joined(separator: ","),
            "requested": target.joined(separator: ","), "windows": String(result.summary.windows),
            "switches": String(result.summary.switches),
        ]
        for language in available {
            details["source.\(language)"] = sources[language]?.id ?? ""
            details["windows.\(language)"] = String(result.summary.windowsByLanguage[language] ?? 0)
        }
        do {
            try await publish(merged, details: details, session: request.session, lease: request.lease)
        } catch let error where !(error is CancellationError) {
            let message = "Cannot save the transcript merged from \(names(available)): \(error.localizedDescription)"
            recorder.end(.languages, .failed, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        log.notice("Session \(request.manifest.id, privacy: .public): merged \(available.count, privacy: .public) languages over \(result.summary.windows, privacy: .public) windows, \(result.summary.switches, privacy: .public) switches")
        // Merged: the stage did its job, even when a language is missing (that makes the post-processing partial).
        let summary = summaryMessage(result.summary, languages: available)
        recorder.end(.languages, .succeeded, [summary, failure].compactMap { $0 }.joined(separator: " "),
                     since: started)
        return Outcome(transcript: merged, note: note(available), problem: failure)
    }

    // MARK: - Which languages

    /// The languages to merge, the preferred one first; nil when there is nothing to do.
    private static func targetLanguages(_ request: Request, events: [ArchiveEvent]) -> [String]? {
        if let requested = request.requested {
            let languages = DictationLanguage.meetingLanguages(requested)
            return languages.isEmpty ? nil : languages
        }
        let meeting: MeetingInfo
        do {
            meeting = try SessionFiles.meetingInfo(session: request.session, manifest: request.manifest)
        } catch {
            // Stage 2 reports a meeting.json it cannot read; without it the meeting counts as one language.
            log.error("Session \(request.manifest.id, privacy: .public): meeting.json unreadable; languages not detected: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        let languages = DictationLanguage.meetingLanguages(meeting.languages ?? [])
        guard languages.count > 1 else { return nil }
        let current = request.transcript
        guard current.languages != nil else { return languages }
        // A merged transcript: redo it only when it was made from meeting.json's languages and missed some. One made
        // from languages asked for by name (`voiceislocal session languages`) stays.
        guard let merge = mergeEvent(of: current.id, events: events),
              merge.details["requested"] == languages.joined(separator: ","),
              current.languages != languages else { return nil }
        return languages
    }

    /// The `languagesDetected` event of the merged transcript `transcriptID`, if it was journaled.
    private static func mergeEvent(of transcriptID: String, events: [ArchiveEvent]) -> ArchiveEvent? {
        events.last { $0.kind == MeetingEventKind.languagesDetected && $0.details["transcriptID"] == transcriptID }
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
    /// may have added audio, when its revision reads as one.
    private static func reusablePass(_ language: String, events: [ArchiveEvent], session: URL,
                                     backend: SpeechBackend) -> Transcript? {
        let recovered = events.last { $0.kind == MeetingEventKind.archiveRecovered }?.sequence ?? 0
        for event in events.reversed() where event.sequence > recovered
            && event.kind == MeetingEventKind.languagePass && event.details["language"] == language {
            guard let id = event.details["transcriptID"],
                  let pass = try? SessionFiles.transcript(id: id, session: session),
                  pass.locale == language, pass.languages == nil, pass.backend == backend else { continue }
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
        for language in languages {
            try Task.checkCancellation()
            let status = await dependencies.modelStatus(language, request.manifest.backend)
            if status == "installed" {
                planned.append(language)
            } else {
                reasons[language] = modelProblem(language, status: status)
            }
        }
        return (planned, reasons)
    }

    /// Transcribes the saved audio of every track in each of `languages`, one after the other, and saves each
    /// transcription (`languagePass`). A language whose transcription fails is left out with the reason.
    private static func transcribe(_ languages: [String], request: Request,
                                   dependencies: LanguageDetectionDependencies,
                                   recorder: StageRecorder) async throws
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
                try await savePass(pass, tracks: tracks, manifest: manifest, session: session, lease: request.lease)
                sources[language] = pass
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
        let fed = LockedValue(0.0)
        let base = dependencies.makeSpeech
        let counting: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
            let session = try await base(locale, backend, contextualStrings, onUpdate)
            return CountingSpeechSession(base: session) { duration in
                let sum = fed.withLock { value -> Double in
                    value += duration
                    return value
                }
                progress(min(1, sum / total))
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

    /// Journals `languagesDetected` (before the save, so a merged current transcript is always explained), then makes
    /// the merged transcript current. The writer lock is held only for this.
    private static func publish(_ merged: Transcript, details: [String: String], session: URL,
                                lease: ProcessingLease) async throws {
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            try await archive.recordEvent(kind: MeetingEventKind.languagesDetected, details: details)
            try await archive.saveTranscript(merged, writeLegacyExports: false)
        } catch {
            await archive.releaseLock()
            throw error
        }
        await archive.releaseLock()
    }

    // MARK: - Helpers

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
            "\(name(language)) was not transcribed: its speech model is still downloading. Detect the languages again "
                + "once it is installed."
        default:
            "\(name(language)) was not transcribed: its speech model is not installed. Install it from the meeting "
                + "start panel or with voiceislocal setup --locale \(language), then detect the languages again."
        }
    }

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
