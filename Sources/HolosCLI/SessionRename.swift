import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting

extension Session {
    /// `voiceislocal session rename` (docs/meeting-design.md §4.17).
    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a finished session, or give it back its generated title.",
            discussion: """
                The name is kept as yours: the Meetings list, Review and the transcript files show it, and no title \
                Apple Intelligence writes replaces it. With --generated (or an empty name) the session shows the \
                title Apple Intelligence wrote again, or its default name until there is one. A name is one line of \
                at most \(MeetingNaming.maximumUserNameCharacters) characters (a longer one is cut, at a space when \
                it can be). The transcript files are rewritten so the Markdown heading follows; nothing is \
                summarized again. Refused while the session is recording or being saved, while another Voice is \
                Local command is working on it, while a final transcript or summary of it is being made, for a \
                session that was interrupted or not finished properly (recover it first), and when its transcript \
                cannot be read. Exits 0 when renamed (or it already had that name), 3 when renamed but the \
                transcript files could not be rewritten (run the same rename again to rewrite them), and 1 \
                otherwise, with nothing changed (the reason is printed).
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Argument(help: "The new name. Leave it out with --generated.") var name: String?
        @Flag(help: "Show the title Apple Intelligence wrote again instead of a name you gave.") var generated = false
        @Flag(help: "Print the result as JSON.") var json = false
        /// The meeting the caller means (the app): refused when the folder holds another.
        @Option(help: .hidden) var expectId: String?

        func validate() throws {
            if generated, name != nil {
                throw ValidationError("Give a name or --generated, not both.")
            }
            if !generated, name == nil {
                throw ValidationError("Give the new name, or --generated to show the generated title again.")
            }
        }

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            var request = SessionRenameCommand.Request(session: session, name: generated ? nil : name)
            request.expectedID = expectId
            let outcome = await SessionRenameCommand.run(request)
            if json {
                try Console.json(outcome)
                if outcome.exitCode != 0 { Console.error(outcome.message) }
            } else if outcome.exitCode == 1 {
                Console.error(outcome.message)
            } else {
                // Exit 3's message says why the transcript files were not rewritten.
                Console.output(outcome.title.map { "\(outcome.message) Title: \(Session.List.oneLine($0))" }
                    ?? outcome.message)
            }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }
    }
}
