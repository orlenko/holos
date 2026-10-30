import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting

extension Session {
    /// `voiceislocal session clean-audio` (docs/design.md "Automatic audio cleanup").
    struct CleanAudio: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean-audio",
            abstract: "Delete a finished meeting's audio if the automatic audio cleanup allows it.",
            discussion: """
                What the app's automatic audio cleanup runs. Under the meeting's processing lease, the meeting must \
                be at least --older-than days old, complete or recovered with a readable transcript and readable \
                meeting.json, and have its speakers labelled with no language left to detect; then its audio is \
                deleted for good, as `session delete --audio-only` does, and its transcript, speaker labels and \
                transcript files are kept. A deletion that began and did not finish is finished whatever the \
                meeting's age. --dry-run decides the same way and deletes nothing. Exits 0 when the audio is gone \
                (or would be), 3 when it stays (the reason is printed), and 1 when \
                nothing could be done, also when another final transcript, summary, echo analysis or cleanup runs: \
                one runs at a time on this Mac.
                """)

        @Argument(help: "Path to a finished .holos folder, or a session ID.") var path: String
        @Option(help: "The meeting must be at least this many days old.") var olderThan: Int
        @Flag(help: "Decide as a run would and print it; delete nothing.") var dryRun = false
        @Flag(help: "Print the result as JSON.") var json = false

        mutating func run() throws {
            guard olderThan >= 1 else { throw ValidationError("--older-than must be at least 1.") }
            let session = try SessionLocator.resolve(path)
            let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: olderThan,
                                                                   jobLock: DeepTranscriptionLock.url, dryRun: dryRun))
            if json { try Console.json(outcome) } else { Console.output(outcome.summary) }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }
    }
}
