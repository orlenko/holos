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
            abstract: "Find the call's echo in a call's microphone audio and relabel the speakers without it.",
            discussion: """
                For a call recorded on laptop speakers, the microphone also records the other people a moment \
                after the system audio. This compares the two tracks, saves which moments of the microphone are \
                echo in the meeting's echo/ folder, and rebuilds the speaker labels without the microphone words that \
                are echo. The speakers are not labelled again: names, links and turn changes carry over, and the \
                transcript and its word fixes are not touched. Meetings labelled after a recording already get this. \
                Exits 0 when done, also when there is nothing to change.
                """)

        @Argument(help: "Path to a finished .holos folder, or a session ID.") var path: String
        @Flag(help: "Analyse the audio again even when the saved analysis matches it.") var force = false
        @Flag(help: "Print the result as JSON.") var json = false

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            let last = Mutex<String?>(nil)
            let outcome = try await SessionEchoAnalyzeCommand.run(
                SessionEchoAnalyzeCommand.Request(session: session, force: force), profiles: SpeakerProfileStore(),
                progress: { message in
                    let isNew = last.withLock { previous in
                        guard previous != message else { return false }
                        previous = message
                        return true
                    }
                    if isNew { Console.error(message) }
                })
            if json {
                try Console.json(outcome)
            } else {
                Console.output(outcome.summary)
            }
        }
    }
}
