import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import HolosWhisper
import Synchronization

extension Session {
    /// `voiceislocal session deep-transcribe` (docs/meeting-design.md §4.16).
    struct DeepTranscribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "deep-transcribe",
            abstract: "Transcribe a finished session's saved audio again with the local Whisper model.",
            discussion: """
                Transcribes every track of the saved audio again on this Mac with the deep transcription model \
                (Whisper large-v3 turbo through WhisperKit; install it with voiceislocal setup --whisper), prompted \
                with the meeting's name, your word list, and the names of the people you know. Passages written \
                over silence where the recorded transcript has no words, and runs of three or more identical \
                passages, are left out. The result becomes a new version of the transcript; the one before is kept. \
                Live corrections and meeting word fixes are applied to it, speakers are labelled again (names carry \
                over), and the transcript files are rewritten. Nothing leaves this Mac. It takes about 11 minutes \
                per hour of audio on an M4 Pro, more on the first run while Core ML prepares the model. Running it \
                again keeps a transcript the model already made; --force transcribes again. It is tuned for \
                English meetings: a meeting in another language keeps Apple's transcript unless --any-language \
                (to try it anyway); meetings in several languages are not supported. A meeting whose speaker labels were \
                edited is not transcribed \
                again unless --force (names carry over). Exits 0 when done (also when the speaker models are not \
                installed), 3 when the transcript files were written but the meeting could not be transcribed again \
                or speaker labelling was skipped or failed (it is printed), and 1 when nothing could be done (the \
                model is not installed, the audio was deleted, the meeting is not in English or in several \
                languages, or another \
                pass is running: one runs at a time on this Mac).
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Flag(help: ArgumentHelp("Transcribe again even when the model already made the transcript, and replace "
            + "edited speaker labels (names carry over)."))
        var force = false
        @Flag(help: ArgumentHelp("Transcribe a meeting in one language other than English too (not validated on "
            + "real recordings; for trying it)."))
        var anyLanguage = false
        @Flag(help: "Print the post-processing record as JSON.") var json = false

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            // One pass at a time on this Mac, held for the command's whole life: the app reads from the lock that a
            // pass is running, on which meeting, and which process to signal (docs/meeting-design.md §4.16, "App").
            let sessionID = (try? SessionArchive.readManifest(at: session).id)
                ?? session.deletingPathExtension().lastPathComponent
            guard let held = try DeepTranscriptionLock.take(
                DeepTranscriptionLock.Holder(pid: getpid(), sessionID: sessionID, force: force)) else {
                throw HolosError.unavailable(DeepTranscriptionLock.busyMessage)
            }
            defer { held.release() }
            let request = SessionDeepTranscribeCommand.Request(session: session, force: force,
                                                               anyLanguage: anyLanguage)
            let before = try? SessionArchive.currentTranscriptID(at: session)
            // Ctrl-C or SIGTERM (the app's Cancel) cancels the pass. Before the new transcript is published nothing
            // changes; after it, the later stages may be unfinished, and the message says which.
            let outcome: SessionDeepTranscribeCommand.Outcome
            do {
                outcome = try await EvalInterrupt.run { () async throws in
                    try await SessionDeepTranscribeCommand.run(
                        request, voiceSamples: cliVoiceSamples, diarizer: makeDiarizer(engineOverrides: [:]),
                        profiles: SpeakerProfileStore(),
                        wordFixes: makeWordFixDependencies(), deepTranscription: makeDeepTranscriptionDependencies(),
                        progress: Self.progressPrinter())
                }
            } catch is CancellationError {
                let after = try? SessionArchive.currentTranscriptID(at: session)
                Console.error(SessionDeepTranscribeCommand.cancellationMessage(before: before ?? nil,
                                                                               after: after ?? nil))
                throw ExitCode(EvalInterrupt.lastExitCode)
            }
            // Stdout carries the result; a warning or failure is explained on stderr (docs/meeting-design.md §1.4).
            if json {
                try Console.json(outcome.record)
                if outcome.exitCode != 0 { Console.error(outcome.summary) }
            } else if outcome.exitCode == 0 {
                Console.output(outcome.summary)
            } else {
                Console.error(outcome.summary)
            }
            if outcome.exitCode != 1, let snapshot = try? SpeakerSessionSnapshot.load(session: session) {
                SpeakerCommand.printNotes(snapshot.diagnostics)
            }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }

        /// Prints each new progress message once to stderr, then whole tens of percent of the transcription.
        private static func progressPrinter() -> @Sendable (PostProcessingProgress) -> Void {
            let last = Mutex<(message: String?, step: Int)>((nil, -1))
            return { progress in
                let step = progress.stage == .deepTranscription
                    ? progress.fraction.map { Int(min(1, max(0, $0)) * 10) } ?? -1 : -1
                let line: String? = last.withLock { previous in
                    if previous.message != progress.message {
                        previous = (progress.message, step)
                        return progress.message
                    }
                    guard step > previous.step else { return nil }
                    previous.step = step
                    return "\(progress.message) \(step * 10) %"
                }
                if let line { Console.error(line) }
            }
        }
    }
}

/// The deep transcription pass's inputs (docs/meeting-design.md §4.16): the installed WhisperKit model under
/// `DeepTranscriptionModel.root` (`HOLOS_WHISPER_MODELS_DIR`, else `<supportRoot>/Models/whisperkit`), the user's
/// words.json, and the names of the people the app knows.
func makeDeepTranscriptionDependencies() -> DeepTranscriptionDependencies {
    DeepTranscriptionDependencies(
        modelStatus: { WhisperModels.status() },
        makeTranscriber: { try await WhisperKitTranscriber.load() },
        wordList: { try WordListStore().load().terms },
        names: { VoiceProfileService.profileNames().values.sorted() })
}
