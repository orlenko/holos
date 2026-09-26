import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Synchronization

/// `--languages fr-CA,en-CA` for `record start` and `session import` (docs/meeting-design.md §4.14): the meeting's
/// languages, the one it is transcribed in live first. Instead of `--locale`.
struct MeetingLanguageOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "The meeting's languages, comma-separated, at most 3 (for example fr-CA,en-CA); instead of --locale.",
        discussion: "The first is transcribed live. After the recording, the audio is transcribed again in each, "
            + "and the transcript keeps, passage by passage, the language that fits."))
    var languages: String?

    /// The languages as given, trimmed; empty without the option.
    var list: [String] { languages.map(DictationLanguage.list) ?? [] }

    /// Refuses a list that is not a meeting's languages, and `--languages` with `--locale`.
    func validate(with recognition: RecognitionOptions) throws {
        guard languages != nil else { return }
        if recognition.locale != nil { throw ValidationError("Use --locale or --languages, not both.") }
        if let problem = DictationLanguage.meetingLanguagesProblem(list) { throw ValidationError(problem) }
    }

    /// The locale transcribed live (the first language, or `recognition`'s) and the meeting's languages (empty for
    /// one).
    func resolved(_ recognition: RecognitionOptions) async -> (locale: String, languages: [String]) {
        let languages = DictationLanguage.meetingLanguages(list)
        guard let first = languages.first else { return (await recognition.resolvedLocale(), []) }
        return (first, languages.count > 1 ? languages : [])
    }
}

extension Session {
    /// `voiceislocal session languages` (docs/meeting-design.md §4.14).
    struct Languages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Detect the languages of a finished session, passage by passage, and label its speakers again.",
            discussion: """
                Transcribes the saved audio again in each language (Apple's speech model for each must be \
                installed: voiceislocal setup --locale <language>), keeps, every few seconds, the language that \
                fits, and makes that the session's transcript. Speakers are then labelled again on it (names carry \
                over) and the transcript files rewritten. Transcriptions made before are reused, and running it \
                again with the same languages leaves the transcript and the speaker labels as they are. With one \
                language the transcript becomes that \
                language's alone. A session recorded or imported without a transcript (--record-only, \
                --no-transcribe) gets its first one this way. Exits 0 when done (also when the speaker models are not installed), 3 when the \
                transcript files were written but a language could not be transcribed or speaker labelling was \
                skipped or failed (it is printed), and 1 when nothing could be done.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Option(help: "The languages, comma-separated, the preferred one first, at most 3 (for example fr-CA,en-CA).")
        var languages: String
        @Flag(help: "Replace the transcript even when its speaker labels were edited; names carry over.")
        var force = false
        @Flag(help: "Print the post-processing record as JSON.") var json = false

        func validate() throws {
            if let problem = DictationLanguage.meetingLanguagesProblem(DictationLanguage.list(languages)) {
                throw ValidationError(problem)
            }
        }

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            let outcome = try await SessionLanguagesCommand.run(
                SessionLanguagesCommand.Request(session: session, languages: DictationLanguage.list(languages),
                                                force: force),
                diarizer: makeDiarizer(engineOverrides: [:]), profiles: SpeakerProfileStore(),
                progress: Self.progressPrinter())
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

        /// Prints each new progress message once to stderr.
        private static func progressPrinter() -> @Sendable (PostProcessingProgress) -> Void {
            let last = Mutex<String?>(nil)
            return { progress in
                let isNew = last.withLock { previous in
                    guard previous != progress.message else { return false }
                    previous = progress.message
                    return true
                }
                if isNew { Console.error(progress.message) }
            }
        }
    }
}
