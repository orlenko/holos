import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What `voiceislocal session deep-transcribe` does (docs/meeting-design.md §4.16), as a library call: the CLI parses
/// its arguments and prints the outcome. It checks first that the pass can run at all (`precheck`), then runs the
/// post-processor with the deep transcription pass asked for by name, so the saved audio is transcribed again with the
/// local Whisper model, live corrections and word fixes are applied to the new text, speakers are labelled again on
/// it, and the exports rewritten, as after a recording. When the transcript stays as it was (already made by this
/// model, or kept after a failure), its speaker labels stay too.
public enum SessionDeepTranscribeCommand {
    public struct Request: Sendable {
        public var session: URL
        /// Transcribe again even when the current transcript was made by this model, and replace a transcript whose
        /// speaker labels were edited (names carry over).
        public var force: Bool

        public init(session: URL, force: Bool = false) {
            self.session = session; self.force = force
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var record: PostProcessingRecord
        /// 0 succeeded; 3 partial (the exports were written, but the meeting was not transcribed again, or speaker
        /// labelling was skipped or failed); 1 failed.
        public var exitCode: Int32
        /// One line for the terminal: what the pass did, then the speaker labels and the exports' folder. Names no
        /// people and quotes no transcript text.
        public var summary: String
    }

    /// Why the pass cannot run on `session` at all, thrown before anything is changed (the command exits 1): a
    /// recording that was not finished properly, deleted or missing audio, a meeting in several languages, or the
    /// model not installed. A run that has nothing to do (the current transcript is this model's, and not `force`)
    /// needs no model: it keeps the transcript.
    public static func precheck(session: URL, dependencies: DeepTranscriptionDependencies,
                                force: Bool = false) throws {
        let manifest = try SessionArchive.readManifest(at: session)
        // `processing` with no writer is a recorder that died while saving: recovery finishes it.
        if [ArchiveStatus.recording, ArchiveStatus.interrupted, ArchiveStatus.processing].contains(manifest.status) {
            if try SessionArchive.isActive(at: session) {
                throw HolosError.unavailable("This meeting is still recording or being saved; try again once it is "
                    + "saved.")
            }
            throw HolosError.unavailable("This session was not finished properly; run voiceislocal session recover "
                + "\(manifest.id) first, so all of its saved audio is transcribed.")
        }
        if try SessionFiles.audioDeleted(session: session, sessionID: manifest.id) {
            throw HolosError.invalidInput(DeepTranscriptionStage.audioDeleted)
        }
        guard !manifest.chunks.isEmpty else { throw HolosError.invalidInput("This session has no saved audio.") }
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        // A transcript made in one language named with `session languages` has `languages` too; only several count.
        let mergedLanguages = (try? SessionFiles.currentTranscript(session: session))??.languages ?? []
        let merged = DictationLanguage.meetingLanguages(mergedLanguages).count > 1
        if DictationLanguage.meetingLanguages(meeting.languages ?? []).count > 1 || merged {
            throw HolosError.invalidInput(DeepTranscriptionStage.severalLanguages)
        }
        if !force, let current = try? SessionFiles.currentTranscript(session: session),
           let events = try? SessionArchive.readEvents(at: session).events,
           DeepTranscriptionStage.recordedBase(of: current, events: events, session: session).unfixed.engine
            == dependencies.engine {
            return
        }
        switch dependencies.modelStatus() {
        case .installed: break
        case .downloading:
            throw HolosError.unavailable("The deep transcription model is still downloading; try again once it is "
                + "installed.")
        case .notInstalled:
            throw HolosError.unavailable(DeepTranscriptionModel.missingModelMessage)
        }
    }

    /// Runs `precheck`, then the post-processor. Throws, with nothing changed, when the precheck fails, the session is
    /// still recording, or another process holds its processing lease.
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           profiles: SpeakerProfileStore? = nil,
                           languages: LanguageDetectionDependencies = .live,
                           wordFixes: WordFixDependencies,
                           deepTranscription: DeepTranscriptionDependencies,
                           progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> Outcome {
        try precheck(session: request.session, dependencies: deepTranscription, force: request.force)
        let options = PostProcessingOptions(force: request.force, deepTranscribe: true)
        let processor = MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: freeSpace,
                                             profiles: profiles, languages: languages, wordFixes: wordFixes,
                                             deepTranscription: deepTranscription)
        let record = try await processor.run(session: request.session, lease: nil, progress: progress)
        return Outcome(record: record, exitCode: SessionDiarizeCommand.exitCode(record.state),
                       summary: summary(record, session: request.session))
    }

    /// What a cancelled run says, from the current transcript's ID before the run and after it: a cancellation can
    /// come after the new transcript was published, while live corrections, word fixes, speakers, or the exports were
    /// still being made, and then nothing was rolled back.
    public static func cancellationMessage(before: String?, after: String?) -> String {
        if before == after {
            return before == nil ? "Cancelled. No transcript was made." : "Cancelled. The transcript was kept as it was."
        }
        return "Cancelled after the new transcript was saved; its speaker labels and transcript files may not be up "
            + "to date. Run voiceislocal session diarize on the meeting to finish them."
    }

    /// The pass's message, then `SessionDiarizeCommand.summary` without the record's note of the pass, which the
    /// pass's message already says.
    static func summary(_ record: PostProcessingRecord, session: URL) -> String {
        var shown = record
        let stage = record.stages.last { $0.stage == .deepTranscription }?.message
        // The record's message starts with the pass's note, or with its problem (the stage's own message).
        for note in [DeepTranscriptionStage.note, stage].compactMap({ $0 }) {
            if let message = shown.message, message.hasPrefix(note) {
                let rest = message.dropFirst(note.count).trimmingCharacters(in: .whitespaces)
                shown.message = rest.isEmpty ? nil : rest
            }
        }
        return ([stage].compactMap { $0 } + [SessionDiarizeCommand.summary(shown, session: session)])
            .joined(separator: " ")
    }
}
