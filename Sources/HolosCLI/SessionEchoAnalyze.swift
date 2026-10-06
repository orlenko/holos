import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Synchronization

extension Session {
    /// `voiceislocal session echo-analyze` (docs/meeting-design.md §5.11).
    struct EchoAnalyze: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "echo-analyze",
            abstract: "Find the call's echo in a call's microphone audio and hide it from the speaker labels.",
            discussion: """
                For a call recorded on laptop speakers, the microphone also records the other people a moment \
                after the system audio. This compares the two tracks and saves which moments of the microphone are \
                echo in the meeting's echo/ folder; the speaker labels, the review window and the transcript files \
                then leave those microphone words out. Nothing else changes: the speaker labels, their edits, the \
                transcript and its word fixes stay as they are. Meetings post-processed after this version get it \
                on their own. Exits 0 when done, also when there is nothing to change; 3 when the analysis was saved \
                but the transcript files or a voice sample could not be updated; 1 when nothing could be done (the \
                reason is printed), also when another final transcript, meeting summary or echo analysis is running: \
                one runs at a time on this Mac. Ctrl-C stops it; running it again finishes what was left.
                """)

        @Argument(help: "Path to a finished .holos folder, or a session ID.") var path: String
        @Flag(help: "Analyse the audio again even when the saved analysis matches it.") var force = false
        @Flag(help: "Print the result as JSON.") var json = false

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            // Under the background-job lock for its whole life, as final transcripts and summaries: one job at a time
            // on this Mac, also across an app relaunch (docs/meeting-design.md §5.11).
            let request = SessionEchoAnalyzeCommand.Request(session: session, force: force,
                                                            jobLock: DeepTranscriptionLock.url)
            // Ctrl-C or SIGTERM (the app, when a meeting starts) stops it; the next run finishes what was left.
            let outcome: SessionEchoAnalyzeCommand.Outcome
            do {
                outcome = try await EvalInterrupt.run { () async throws in
                    try await SessionEchoAnalyzeCommand.run(
                        request, voiceSamples: cliVoiceSamples, profiles: SpeakerProfileStore(),
                        progress: Self.progressPrinter())
                }
            } catch is CancellationError {
                Console.error(SessionEchoAnalyzeCommand.cancellationMessage)
                throw ExitCode(EvalInterrupt.lastExitCode)
            }
            if json {
                try Console.json(outcome)
            } else {
                Console.output(outcome.summary)
            }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }

        /// Prints each new progress message once to stderr.
        private static func progressPrinter() -> @Sendable (String) -> Void {
            let last = Mutex<String?>(nil)
            return { message in
                let isNew = last.withLock { previous in
                    guard previous != message else { return false }
                    previous = message
                    return true
                }
                if isNew { Console.error(message) }
            }
        }
    }
}
