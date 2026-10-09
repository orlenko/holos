import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What the deep transcription pass uses outside the session folder (docs/meeting-design.md §4.16): the local model
/// and the prompt's sources. `none` (the default everywhere in HolosMeeting) has no model; the command-line tool
/// passes WhisperKit's (`HolosWhisper`), and tests pass fakes.
public struct DeepTranscriptionDependencies: Sendable {
    /// `Transcript.engine` of what `makeTranscriber` makes, known before it is loaded ("whisper:<model>"): a current
    /// transcript it made is not made again unless forced.
    public var engine: String
    /// Whether the model is installed, from files only.
    public var modelStatus: @Sendable () -> DeepModelStatus
    /// Loads the model (it can take minutes the first time on a Mac).
    public var makeTranscriber: @Sendable () async throws -> any DeepTranscriber
    /// The word list's terms (words.json).
    public var wordList: @Sendable () throws -> [String]
    /// The names of the people the app knows.
    public var names: @Sendable () -> [String]

    public init(engine: String = DeepTranscriptionModel.engine,
                modelStatus: @escaping @Sendable () -> DeepModelStatus,
                makeTranscriber: @escaping @Sendable () async throws -> any DeepTranscriber,
                wordList: @escaping @Sendable () throws -> [String],
                names: @escaping @Sendable () -> [String]) {
        self.engine = engine; self.modelStatus = modelStatus; self.makeTranscriber = makeTranscriber
        self.wordList = wordList; self.names = names
    }

    /// No model: the pass is refused with the setup hint.
    public static let none = DeepTranscriptionDependencies(
        modelStatus: { .notInstalled },
        makeTranscriber: { throw HolosError.unavailable(DeepTranscriptionModel.missingModelMessage) },
        wordList: { [] }, names: { [] })
}

/// The deep transcription pass of the post-processor, stage `deepTranscription` (docs/meeting-design.md §4.16), run
/// only when asked for by name (`voiceislocal session deep-transcribe`, the app's queue after a meeting): every
/// track's saved audio is rendered to 16 kHz (long gaps shortened, as for speaker labels) and transcribed again with a
/// local Whisper model, prompted with the meeting's name, the word list, and people's names; the segments are mapped
/// back to session time, cleared of Whisper's known failures (`DeepTranscriptGuards`), and the result becomes a new
/// current revision (`deepTranscribed`, then the save), keeping the recorded one. Live corrections, word fixes,
/// speaker labels, and exports then run on it as after a recording.
///
/// Like the languages stage it never replaces a transcript whose speaker labels were edited unless forced (names
/// carry over when speakers are labelled again), and checks that again under the locks of the publication. A meeting
/// in several languages is skipped: Whisper's language detection cannot be limited to the meeting's languages, so v1
/// handles meetings in one language. A current transcript the same model made is kept unless forced. Cancellation
/// publishes nothing; a run cancelled or killed starts over next time.
public enum DeepTranscriptionStage {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    struct Request {
        var session: URL
        var manifest: SessionManifest
        /// The current transcript, as the languages stage left it; nil for a session recorded or imported without one,
        /// which then gets its first transcript from this pass.
        var transcript: Transcript?
        var lease: ProcessingLease
        /// Asked for by name (`PostProcessingOptions.deepTranscribe`); nothing is done or recorded otherwise.
        var requested: Bool
        /// Transcribe again even when the current transcript is this model's, and replace edited speaker labels.
        var force: Bool
        /// Transcribe a meeting in one language other than English too (`--any-language`; never `force`).
        var anyLanguage = false
        var freeSpace: any FreeSpaceProvider
    }

    struct Outcome {
        /// The transcript the later stages use (nil when there was none and none was made).
        var transcript: Transcript?
        /// For the final record's message.
        var note: String?
        /// Why the stage did not do what it was asked; makes the post-processing partial.
        var problem: String?
    }

    static let editedHead = "Speaker labels were edited, so the meeting was not transcribed again. To transcribe it "
        + "again and label speakers again (names carry over), run voiceislocal session deep-transcribe with --force."
    static let editedWords = "Words were edited in Review, so the meeting was not transcribed again. To transcribe it "
        + "again (the edited words are replaced), run voiceislocal session deep-transcribe with --force."
    /// Deep transcription runs on English meetings only until other languages are validated on real recordings: on a
    /// real bilingual meeting, Whisper's French was worse than Apple's (docs/status.md).
    static let notEnglish = "Deep transcription is tuned for English meetings; this meeting keeps Apple's transcript."
    static let severalLanguages = "This meeting is in several languages; deep transcription handles meetings in one "
        + "language for now, so the transcript was kept."
    static let audioDeleted = "The meeting's audio was deleted, so it cannot be transcribed again."
    public static let noDiskSpace = "Not enough disk space to transcribe the meeting again. Free some space, then try again."
    static let kept = "Kept the transcript as it was."

    /// The meeting's language for the pass: the transcript's (the one the current one stands for), else meeting.json's
    /// first, else the recording's.
    static func locale(meeting: MeetingInfo, transcript: Transcript?, manifest: SessionManifest) -> String {
        transcript?.locale ?? meeting.languages?.first ?? manifest.locale
    }

    /// Why the pass does not transcribe a meeting: several languages (meeting.json's or a merge's; a transcript of one
    /// language named with `session languages` has `languages` too, so only several count), never; one other than
    /// English (`notEnglish`), unless `anyLanguage` (`--any-language`, to try it; `--force` and the app's Make Final
    /// Transcript Now never lift it, so a meeting whose language changed while queued is checked when it runs). Nil
    /// when it does.
    static func languageProblem(meeting: MeetingInfo, transcript: Transcript?, manifest: SessionManifest,
                                anyLanguage: Bool) -> String? {
        if DictationLanguage.meetingLanguages(meeting.languages ?? []).count > 1
            || DictationLanguage.meetingLanguages(transcript?.languages ?? []).count > 1 {
            return severalLanguages
        }
        let language = locale(meeting: meeting, transcript: transcript, manifest: manifest)
        if !anyLanguage, DeepTranscriptionModel.whisperLanguage(language) != "en" { return notEnglish }
        return nil
    }

    /// Test hook: while set (a task-local value), called with the writer and speaker locks held, after the last
    /// edited-labels check and before the new transcript is journaled and saved.
    @TaskLocal static var whilePublishing: (@Sendable () -> Void)? = nil

    /// Runs the stage and records its outcome. Throws only `CancellationError`: every other failure is recorded and
    /// the current transcript kept.
    static func run(_ request: Request, dependencies: DeepTranscriptionDependencies,
                    recorder: StageRecorder) async throws -> Outcome {
        let current = request.transcript
        // What a failure says first: what became of the current transcript.
        let keptText = current == nil ? "No transcript was made." : kept
        let unchanged = Outcome(transcript: current)
        guard request.requested else { return unchanged }
        let started = recorder.begin(.deepTranscription, message: "Preparing to transcribe the meeting again…")
        func fail(_ message: String, _ result: StageResult = .failed) -> Outcome {
            recorder.end(.deepTranscription, result, message, since: started)
            return Outcome(transcript: current, problem: message)
        }
        try Task.checkCancellation()

        let events: [ArchiveEvent]
        let meeting: MeetingInfo
        do {
            events = try SessionArchive.readEvents(at: request.session).events
            meeting = try SessionFiles.meetingInfo(session: request.session, manifest: request.manifest)
        } catch let error where !(error is CancellationError) {
            return fail("\(keptText) \(error.localizedDescription)")
        }
        let base = current.map { recordedBase(of: $0, events: events, session: request.session) }
        // A transcript this model already made is kept, whatever its language (made with --any-language, or by an
        // earlier version), before the language is judged.
        if let base, base.unfixed.engine == dependencies.engine, !request.force {
            let message = "The meeting was already transcribed with \(DeepTranscriptionModel.displayName)."
            recorder.end(.deepTranscription, .succeeded, message, since: started)
            return Outcome(transcript: current, note: message)
        }
        if let problem = languageProblem(meeting: meeting, transcript: base?.unfixed, manifest: request.manifest,
                                         anyLanguage: request.anyLanguage) {
            return fail(problem, .skipped)
        }
        if let problem = editedHeadProblem(request) { return fail(problem, .skipped) }
        do {
            if try SessionFiles.audioDeleted(session: request.session, sessionID: request.manifest.id) {
                return fail(audioDeleted, .skipped)
            }
        } catch let error where !(error is CancellationError) {
            return fail("\(keptText) \(error.localizedDescription)")
        }
        let tracks = Set(request.manifest.chunks.map(\.track)).sorted()
        guard !tracks.isEmpty else { return fail("\(keptText) This meeting has no saved audio.", .skipped) }
        guard dependencies.modelStatus() == .installed else { return fail(DeepTranscriptionModel.missingModelMessage) }
        // Read as the rebuild reads it: missing or damaged is none, one from a newer Holos is refused.
        let vocabulary: [String]
        let wordList: [String]
        do {
            vocabulary = try TranscriptRebuilder.sessionVocabulary(request.session)
            wordList = try dependencies.wordList()
        } catch let error where !(error is CancellationError) {
            return fail("\(keptText) \(error.localizedDescription)")
        }

        recorder.progress(.deepTranscription, track: nil, fraction: nil,
                          message: "Loading the deep transcription model…")
        let transcriber: any DeepTranscriber
        do {
            transcriber = try await dependencies.makeTranscriber()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return fail("\(keptText) \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let prompt: DeepTranscriptionPrompt.Prompt
        do {
            prompt = try await DeepTranscriptionPrompt.build(
                meetingName: request.manifest.name,
                candidates: DeepTranscriptionPrompt.candidates(vocabulary: vocabulary, wordList: wordList,
                                                               names: dependencies.names()),
                tokenCount: { try await transcriber.promptTokenCount($0) })
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return fail("\(keptText) The vocabulary prompt could not be made: \(error.localizedDescription)")
        }
        // The current transcript's language (a one-language merge's), else the meeting's.
        let locale = Self.locale(meeting: meeting, transcript: base?.unfixed, manifest: request.manifest)
        let pass: Pass
        do {
            pass = try await transcribe(tracks: tracks, request: request, transcriber: transcriber,
                                        reference: base?.reference,
                                        language: DeepTranscriptionModel.whisperLanguage(locale),
                                        prompt: prompt.text, recorder: recorder)
        } catch let failure as StageFailure {
            return fail(failure.message, failure.result)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return fail("\(keptText) The meeting could not be transcribed again: \(error.localizedDescription)")
        }

        // Without a recorded transcript, the silence guard has no words to look for: the audio level alone decides.
        let (segments, guarded, lostSpeech) = Self.segments(pass.segments, reference: base?.reference)
        // Speech the model left out even decoded again in parts: never published as a complete transcript.
        guard lostSpeech.isEmpty else { return fail("\(keptText) \(Self.lostMessage(lostSpeech))") }
        guard LanguageStage.hasWords(segments) || !(current.map { LanguageStage.hasWords($0.segments) } ?? true) else {
            return fail("\(keptText) No words were recognized when the meeting was transcribed again.")
        }
        let deep = Transcript(source: request.session.path, locale: locale, backend: request.manifest.backend,
                              segments: segments, engine: transcriber.engine)
        let details = [
            "transcriptID": deep.id, "base": base?.reference?.id ?? "", "engine": transcriber.engine,
            "language": locale, "tracks": tracks.joined(separator: ","),
            "seconds": String(format: "%.1f", pass.seconds), "segments": String(segments.count),
            "words": String(segments.reduce(0) { $0 + $1.words.count }),
            "droppedSilent": String(guarded.droppedSilent), "droppedRepeats": String(guarded.droppedRepeats),
            "promptTerms": String(prompt.terms.count), "promptTokens": String(prompt.tokens),
        ]
        do {
            if let problem = try await publish(deep, details: details, request: request) {
                return fail(problem, .skipped)
            }
        } catch let error where !(error is CancellationError) {
            return fail("\(keptText) The new transcript could not be saved: \(error.localizedDescription)")
        }
        log.notice("Session \(request.manifest.id, privacy: .public): deep transcription made \(segments.count, privacy: .public) segments; dropped \(guarded.droppedSilent, privacy: .public) silent and \(guarded.droppedRepeats, privacy: .public) repeated")
        recorder.end(.deepTranscription, .succeeded,
                     summary(segments: segments.count, droppedSilent: guarded.droppedSilent,
                             droppedRepeats: guarded.droppedRepeats, promptTerms: prompt.terms.count),
                     since: started)
        return Outcome(transcript: deep, note: note)
    }

    /// The final record's note.
    static let note = "Transcribed again with \(DeepTranscriptionModel.displayName)."

    /// "Transcribed again with Whisper large-v3 turbo: 412 passages, with 18 words from the vocabulary in its prompt;
    /// left out 3 passages over silence and 2 repeats."
    static func summary(segments: Int, droppedSilent: Int, droppedRepeats: Int, promptTerms: Int) -> String {
        var text = "Transcribed again with \(DeepTranscriptionModel.displayName): "
            + (segments == 1 ? "1 passage" : "\(segments) passages")
        if promptTerms > 0 {
            text += ", with \(promptTerms) vocabulary \(promptTerms == 1 ? "term" : "terms") in its prompt"
        }
        var dropped: [String] = []
        if droppedSilent > 0 {
            dropped.append(droppedSilent == 1 ? "1 passage over silence" : "\(droppedSilent) passages over silence")
        }
        if droppedRepeats > 0 { dropped.append(droppedRepeats == 1 ? "1 repeat" : "\(droppedRepeats) repeats") }
        if !dropped.isEmpty { text += "; left out " + dropped.joined(separator: " and ") }
        return text + "."
    }

    // MARK: - Lineage

    /// The transcript the current one stands for (`unfixed`: the one its live corrections and word fixes were made
    /// from), and the recorded transcript its words are checked against (`reference`): for a deep transcript, the one
    /// its `deepTranscribed` event names as `base` (nil when that cannot be read); else the current transcript itself.
    public static func recordedBase(of current: Transcript, events: [ArchiveEvent], session: URL)
        -> (unfixed: Transcript, reference: Transcript?) {
        let unfixedID = WordFixStage.unfixedID(current.id, events: events)
        let unfixed = unfixedID == current.id ? current
            : (try? SessionFiles.transcript(id: unfixedID, session: session)) ?? current
        guard DeepTranscriptionModel.isWhisper(unfixed.engine) else { return (unfixed, current) }
        guard let id = deepEvent(of: unfixed.id, events: events)?.details["base"], !id.isEmpty,
              let base = try? SessionFiles.transcript(id: id, session: session) else { return (unfixed, nil) }
        return (unfixed, base)
    }

    /// The last `deepTranscribed` event naming `transcriptID`.
    static func deepEvent(of transcriptID: String, events: [ArchiveEvent]) -> ArchiveEvent? {
        events.last { $0.kind == MeetingEventKind.deepTranscribed && $0.details["transcriptID"] == transcriptID }
    }

    // MARK: - Transcription

    /// Why the stage stopped before publishing, with the stage result to record.
    private struct StageFailure: Error {
        var message: String
        var result: StageResult
    }

    private struct Pass {
        var segments: [DeepHeardSegment]
        /// Seconds of rendered audio transcribed.
        var seconds: Double
    }

    /// Every track, one after another: rendered to derived/deep-<track>-16k.caf (deleted once transcribed), read in
    /// pieces of at most `DeepAudio.pieceSeconds` ending at a quiet moment, each piece transcribed and mapped back to
    /// session time.
    private static func transcribe(tracks: [String], request: Request, transcriber: any DeepTranscriber,
                                   reference: Transcript?, language: String?, prompt: String, recorder: StageRecorder) async throws -> Pass {
        let manifest = request.manifest
        let total = max(1e-9, tracks.reduce(0) { $0 + TrackRenderer.renderedSeconds(manifest: manifest, track: $1) })
        let journal = recorder.journal
        var done = 0.0
        var segments: [DeepHeardSegment] = []
        for track in tracks {
            try Task.checkCancellation()
            let message = "Transcribing the meeting again with \(DeepTranscriptionModel.displayName) "
                + "(\(SpeakerAnalysis.trackLabel(track)))…"
            recorder.progress(.deepTranscription, track: track, fraction: done / total, message: message)
            let seconds = TrackRenderer.renderedSeconds(manifest: manifest, track: track)
            do {
                let free = try request.freeSpace.availableBytes(at: SessionPaths.derived(request.session))
                guard SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: seconds) else {
                    throw StageFailure(message: noDiskSpace, result: .skipped)
                }
            } catch let failure as StageFailure {
                throw failure
            } catch {
                // Unmeasurable: try; a render that runs out of space fails and publishes nothing.
                log.error("Cannot measure free space before rendering: \(error.localizedDescription, privacy: .private)")
            }
            let base = done
            do {
                segments += try await transcribeTrack(
                    track, session: request.session, manifest: manifest,
                    renderTo: SessionPaths.derived(request.session).appendingPathComponent("deep-\(track)-16k.caf"),
                    transcriber: transcriber, language: language, prompt: prompt,
                    reference: reference) { trackSeconds in
                        journal.progress(PostProcessingProgress(stage: .deepTranscription, track: track,
                                                                fraction: min(1, (base + trackSeconds) / total),
                                                                message: message))
                    }
            } catch let failure as RenderFailure {
                throw StageFailure(message: "\(kept) The \(SpeakerAnalysis.trackAudioLabel(track)) could not be "
                    + "prepared: \(failure.underlying.localizedDescription)", result: .failed)
            }
            done += seconds
        }
        return Pass(segments: segments, seconds: done)
    }

    /// A track's render failed (wrapping why).
    struct RenderFailure: Error {
        var underlying: any Error
    }

    /// One track's saved audio transcribed by `transcriber`, in session time: rendered to `output` (16 kHz, long gaps
    /// shortened; deleted afterwards), read in pieces of at most `DeepAudio.pieceSeconds` that end at a quiet moment,
    /// each piece transcribed and mapped back through the render's time map, with each segment's level. `progress`
    /// gets the seconds of the render done. A render that fails throws `RenderFailure`.
    public static func transcribeTrack(_ track: String, session: URL, manifest: SessionManifest,
                                       renderTo output: URL, transcriber: any DeepTranscriber, language: String?,
                                       prompt: String, reference: Transcript?,
                                       progress: @escaping @Sendable (Double) -> Void) async throws
        -> [DeepHeardSegment] {
        let rendered: RenderedTrack
        do {
            rendered = try TrackRenderer.render(session: session, manifest: manifest, track: track, to: output)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw RenderFailure(underlying: error)
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try AVAudioFile(forReading: rendered.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(file.length)
        let pieceFrames = Int(DeepAudio.pieceSeconds) * DeepAudio.sampleRate
        let searchFrames = Int(DeepAudio.cutSearchSeconds) * DeepAudio.sampleRate
        var position = 0
        var segments: [DeepHeardSegment] = []
        while position < frames {
            try Task.checkCancellation()
            let remaining = frames - position
            var samples = try read(file, from: position, count: min(remaining, pieceFrames))
            if remaining > pieceFrames {
                let cut = DeepAudio.quietestCut(samples, searchFrom: samples.count - searchFrames)
                samples.removeSubrange(cut...)
            }
            guard !samples.isEmpty else { break }
            let pieceStart = Double(position) / Double(DeepAudio.sampleRate)
            let pieceSeconds = Double(samples.count) / Double(DeepAudio.sampleRate)
            let recordedWords = DeepAudio.recordedWords(reference, track: track, timeMap: rendered.timeMap,
                                                        pieceStart: pieceStart, pieceSeconds: pieceSeconds)
            let heard = try await transcriber.transcribe(
                DeepTranscriptionRequest(samples: samples, language: language, prompt: prompt,
                                         recordedWords: recordedWords),
                progress: { fraction in
                    let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
                    progress(pieceStart + value * pieceSeconds)
                })
            try Task.checkCancellation()
            segments += DeepAudio.sessionSegments(heard, piece: samples, pieceStart: pieceStart, track: track,
                                                  timeMap: rendered.timeMap)
            position += samples.count
            progress(Double(position) / Double(DeepAudio.sampleRate))
        }
        return segments
    }

    /// The transcript segments of a pass: the guards applied against `reference` (the recorded transcript; nil when
    /// there is none), then each kept segment built with its word timings, in time order.
    public static func segments(_ heard: [DeepHeardSegment], reference: Transcript?)
        -> (segments: [TranscriptSegment], guards: DeepTranscriptGuards.Result, lost: [DeepHeardSegment]) {
        let guarded = DeepTranscriptGuards.apply(heard.filter { !$0.unheard }, reference: reference?.segments)
        let segments = guarded.kept.compactMap(DeepAudio.transcriptSegment)
            .sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        return (segments, guarded, lost(heard.filter(\.unheard), reference: reference))
    }

    /// At least this many words of the recorded transcript in an audible stretch the model left empty make it lost
    /// speech; fewer (or no recorded transcript) is taken for music or noise, which Whisper rightly writes nothing for.
    static let lostSpeechWords = DeepTranscriptionRequest.recordedSpeechWords

    /// Empty stretches on one track at most this far apart are one stretch: a retry split (or the plan's pieces) can
    /// cut one omitted stretch into several, each with fewer recorded words than the whole.
    static let lostJoinSeconds = 1.0

    /// The audible stretches the model left empty (`unheard`, after its retries), adjacent ones on a track joined
    /// (`lostJoinSeconds`), where the recorded transcript has at least `lostSpeechWords` words on the same track:
    /// speech the pass would leave out.
    static func lost(_ unheard: [DeepHeardSegment], reference: Transcript?) -> [DeepHeardSegment] {
        guard let reference else { return [] }
        var joined: [DeepHeardSegment] = []
        for span in unheard.sorted(by: { ($0.track, $0.start) < ($1.track, $1.start) }) {
            if let last = joined.last, last.track == span.track, span.start - last.end <= lostJoinSeconds {
                joined[joined.count - 1].end = max(last.end, span.end)
            } else {
                joined.append(span)
            }
        }
        return joined.sorted { $0.start < $1.start }.filter { span in
            let words = reference.segments.filter { ($0.track ?? span.track) == span.track }
                .flatMap { WordTiming.effectiveWords(of: $0) }
                .filter { $0.start >= span.start && $0.start < span.end }
            return words.count >= lostSpeechWords
        }
    }

    /// "2 stretches of audible audio where the recorded transcript has words came back without words from the model
    /// (from 312 s, 1,204 s)."
    public static func lostMessage(_ lost: [DeepHeardSegment]) -> String {
        let what = lost.count == 1 ? "1 stretch of audible audio" : "\(lost.count) stretches of audible audio"
        let starts = lost.prefix(5).map { "\(Int($0.start.rounded())) s" }.joined(separator: ", ")
        return "\(what) where the recorded transcript has words came back without words from the model (from \(starts))."
    }

    /// `count` mono samples of `file` from frame `start`.
    private static func read(_ file: AVAudioFile, from start: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { throw HolosError.io("Cannot allocate an audio buffer for deep transcription.") }
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: - Publication

    /// Why the transcript must not be replaced now: its words were edited in Review, or its speaker labels were edited,
    /// and `force` was not given. Nil when it may be.
    private static func editedHeadProblem(_ request: Request) -> String? {
        guard let transcript = request.transcript else { return nil }
        if !request.force, TranscriptWordEdit.hasReviewEdits(transcript) { return editedWords }
        do {
            guard let head = try SpeakerAnalysis.headState(session: request.session, transcript: transcript),
                  head.needsForce(request.force) else { return nil }
            return editedHead
        } catch {
            return "Cannot read the current speaker labels, so the transcript was kept: \(error.localizedDescription)"
        }
    }

    /// Under the writer lock and then the speaker lock (as the languages stage publishes), checks once more that the
    /// speaker labels were not edited meanwhile (returned without publishing), then journals `deepTranscribed` and
    /// makes the new transcript current. A cancellation seen with both locks held publishes nothing.
    private static func publish(_ deep: Transcript, details: [String: String],
                                request: Request) async throws -> String? {
        let archive = try SessionArchive.openForMaintenance(at: request.session, lease: request.lease)
        do {
            let problem = try await SessionArchive.withSpeakerLockAsync(at: request.session) { () async throws -> String? in
                if let problem = editedHeadProblem(request) { return problem }
                whilePublishing?()
                try Task.checkCancellation()
                try await archive.recordEvent(kind: MeetingEventKind.deepTranscribed, details: details)
                try await archive.saveTranscript(deep, writeLegacyExports: false)
                return nil
            }
            await archive.releaseLock()
            return problem
        } catch {
            await archive.releaseLock()
            throw error
        }
    }
}
