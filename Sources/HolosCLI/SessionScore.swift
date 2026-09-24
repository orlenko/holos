import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

extension Session {
    /// `holos session score` (hidden; docs/meeting-design.md §5.5 PR7c, R24).
    struct Score: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare a session's speaker labels with Otter's for the same audio (numbers only).",
            discussion: """
                Reports "agreement with Otter": over the time where both have a speaker, the share whose speaker \
                differs after the best one-to-one mapping. Prints counts, seconds, and ratios only; with --json the \
                mapping is keyed by the first 12 hex digits of the SHA-256 of each Otter label. Never prints names \
                or transcript text.
                """,
            shouldDisplay: false)

        @Argument(help: "Path to a .holos directory with speaker labels.") var path: String
        @Option(help: "Otter's plain-text transcript export for the same audio.") var otter: String
        @Option(help: "Seconds around each Otter turn boundary that are not scored.") var collar = 0.25
        @Flag(help: "Print the scores as JSON.") var json = false

        /// Otter exports are a few hundred kilobytes; this bounds a wrong file.
        static let maxTranscriptBytes = 64 << 20

        func validate() throws {
            guard collar.isFinite, collar >= 0 else { throw ValidationError("--collar must be 0 or more seconds.") }
        }

        mutating func run() throws {
            // Only read, so a symbolic link to it is followed (the no-link rule is for files inside sessions).
            let url = fileURL(otter).resolvingSymlinksInPath()
            guard let data = try AtomicFile.readIfPresent(url, maxBytes: Self.maxTranscriptBytes) else {
                throw ValidationError("The Otter transcript \(url.path) does not exist.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValidationError("The Otter transcript is not UTF-8 text.")
            }
            let report = try SessionScorer.score(session: fileURL(path), otterTranscript: text, collar: collar)
            if json {
                try Console.json(report)
            } else {
                for line in report.summaryLines { Console.output(line) }
            }
        }
    }
}
