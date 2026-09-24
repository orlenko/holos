import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

extension ExportFormat: ExpressibleByArgument {}

extension Session {
    /// `holos session export` (docs/meeting-design.md §4.11, §5.7).
    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a session's transcript with speaker labels as Markdown, JSON, or text.",
            discussion: """
                With --format, the transcript is written to stdout, or with --output to a new file (never over an \
                existing one). With --all, the session's exports/ folder (transcript.md, transcript.json, \
                transcript.txt) is rewritten and its path printed; a copy there that was edited by hand is kept \
                under a new name first. No export contains voice data.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(help: "The transcript format: Markdown, JSON, or plain text.") var format: ExportFormat?
        @Option(name: .shortAndLong, help: "Write to this new file instead of stdout.") var output: String?
        @Flag(help: "Rewrite every format in the session's exports/ folder.") var all = false

        func validate() throws {
            if all {
                if format != nil || output != nil {
                    throw ValidationError(
                        "--all rewrites every format in exports/; use it without --format or --output.")
                }
            } else if format == nil {
                throw ValidationError("Choose --format md, json, or txt, or use --all.")
            }
        }

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            // People's current names, as every other writer of the exports passes them, so an automatic name
            // ("Jim (auto)") does not depend on which command wrote the exports last.
            let names = VoiceProfileService.profileNames()
            // And "Remember voices": off means the kept voice samples, and the suggestions made from them, are
            // not used, so the exports name nobody automatically until it is turned back on.
            let recognition = VoiceProfileService.recognitionAllowed()
            if all {
                let result = try SessionExports.regenerate(session: directory, profileNames: names,
                                                           applyRecognition: recognition)
                Console.output(SessionPaths.exports(directory).path)
                for url in result.movedAside { Console.error(SpeakerCommand.movedAsideNote(url)) }
                return
            }
            guard let format else { throw ValidationError("Choose --format md, json, or txt, or use --all.") }
            let data = try SessionExports.render(format, session: directory, profileNames: names,
                                                 applyRecognition: recognition)
            guard let output else {
                try FileHandle.standardOutput.write(contentsOf: data)
                return
            }
            let url = fileURL(output)
            try SessionExports.writeNewFile(data, at: url)
            Console.output(url.path)
        }
    }
}
