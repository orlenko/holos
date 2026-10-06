import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Synchronization

extension Session {
    /// `voiceislocal session fix-words` (docs/design.md "Meeting word fixes").
    struct FixWords: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fix-words",
            abstract: "Fix a finished session's misheard words with today's corrections and word list.",
            discussion: """
                Applies your learned corrections (as dictation does) to every passage, then asks Apple Intelligence, \
                for each place where a word-list term's "often heard as" phrase was written, whether the term was \
                meant there (voiceislocal words heard-as; only with "Fix misheard words with Apple Intelligence" on \
                in Settings). The fixed transcript becomes a new version; the one before is kept, and fixes are \
                always made from the transcript before any fix, so running it again with the same corrections and \
                terms changes nothing. Existing speaker labels and edits are mapped to the new word positions, and \
                the transcript files are rewritten without labelling again. A meeting is fixed this way after every \
                recording; run this after you add corrections or terms. --force labels speakers again instead \
                (names carry over). Exits 0 when done (also when the speaker models are not installed), 3 when the \
                transcript files were written but the words could not be fixed or speaker labelling was skipped or \
                failed (it is printed), and 1 when nothing could be done.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Flag(help: "Label speakers again on the fixed words instead of keeping the current labels; names carry over.")
        var force = false
        @Flag(help: "Print the post-processing record as JSON.") var json = false

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            let outcome = try await SessionWordFixesCommand.run(
                SessionWordFixesCommand.Request(session: session, force: force), voiceSamples: cliVoiceSamples,
                diarizer: makeDiarizer(engineOverrides: [:]), profiles: SpeakerProfileStore(),
                wordFixes: makeWordFixDependencies(), progress: Self.progressPrinter())
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
