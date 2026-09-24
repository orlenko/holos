import ArgumentParser
import Darwin
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
            if all {
                let result = try SessionExports.regenerate(session: directory)
                Console.output(SessionPaths.exports(directory).path)
                for url in result.movedAside { Console.error(SpeakerCommand.movedAsideNote(url)) }
                return
            }
            guard let format else { throw ValidationError("Choose --format md, json, or txt, or use --all.") }
            let data = try SessionExports.render(format, session: directory)
            guard let output else {
                try FileHandle.standardOutput.write(contentsOf: data)
                return
            }
            let url = fileURL(output)
            let exists = HolosError.invalidInput(
                "\(url.path) already exists; holos session export never replaces a file. Choose another name.")
            guard !Self.entryExists(url) else { throw exists }
            do {
                // Private like every Holos file: the transcript may hold confidential speech. The file is created
                // only if nothing has that name, even when another process makes one meanwhile.
                try AtomicFile.create(data, at: url, permissions: 0o600)
            } catch HolosError.invalidInput where Self.entryExists(url) {
                throw exists
            }
            Console.output(url.path)
        }

        /// Whether anything, even a dangling symbolic link, has this path.
        private static func entryExists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
    }
}
