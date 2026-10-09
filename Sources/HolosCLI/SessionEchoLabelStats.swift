import ArgumentParser
import Foundation
import HolosMeeting

extension Session {
    /// `voiceislocal session echo-label-stats` (hidden; docs/meeting-design.md §5.11).
    struct EchoLabelCounts: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "echo-label-stats",
            abstract: "Count what the echo evidence rule changes in calls' speaker labels (numbers only).",
            discussion: """
                For each call given, compares the microphone words the speaker labels count as the user's under \
                the acoustic echo word rule before the evidence requirement and under the rule now, and prints one \
                line per session and a total. Prints counts only: never transcript text, names or word times. Only \
                reads; a meeting that is recording is not read, and an argument that names no session is listed by its \
                place ("#3: not measured") without its path. Exits 1 when no session could be measured.
                """,
            shouldDisplay: false)

        @Argument(help: "Paths to finished .holos folders, or session IDs.") var paths: [String]
        @Flag(help: "Print the counts as JSON.") var json = false

        mutating func run() throws {
            // Each argument on its own: one that names no session is listed as not measured, without its path.
            let report = SessionEchoLabelStats.report(arguments: paths)
            if json {
                try Console.json(report)
            } else {
                for line in report.lines { Console.output(line) }
            }
            if report.exitCode != 0 { throw ExitCode(report.exitCode) }
        }
    }
}
