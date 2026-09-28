import ArgumentParser
import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal history`: the dictation history the app keeps on this Mac (docs/design.md "Dictation history").
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List or clear the dictation history kept on this Mac.",
        discussion: """
            The app records each finished dictation (the text, the text as heard, the app, the language, and what \
            happened to it) in Application Support/Holos/History/dictations.jsonl, for as long as its History \
            setting says (30 days unless changed). Nothing is sent anywhere.
            """,
        subcommands: [List.self, Clear.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List dictations, newest first.")

        @Flag(help: "Print the dictations as JSON.") var json = false
        @Option(help: "Show at most this many dictations.") var limit: Int?

        mutating func validate() throws {
            if let limit, limit < 1 { throw ValidationError("--limit must be at least 1.") }
        }

        mutating func run() throws {
            let contents = try DictationHistoryStore().load()
            var records = Array(contents.records.reversed())
            if let limit { records = Array(records.prefix(limit)) }
            if json {
                try Console.json(records)
            } else if records.isEmpty {
                Console.output("No dictations in the history.")
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let rows = records.map { record in
                    [formatter.string(from: record.date), Self.oneLine(record.app ?? "—"), record.outcome.kind.rawValue,
                     record.language, Self.preview(record.text)]
                }
                for line in TextTable.render(header: ["DATE", "APP", "RESULT", "LANGUAGE", "TEXT"], rows: rows,
                                             alignments: [.left, .left, .left, .left, .left]) {
                    Console.output(line)
                }
            }
            if contents.newerLines > 0 {
                Console.error("Note: \(contents.newerLines) \(contents.newerLines == 1 ? "dictation was" : "dictations were") recorded by a newer Voice is Local and \(contents.newerLines == 1 ? "is" : "are") not shown.")
            }
            if contents.skippedLines > 0 {
                Console.error("Note: \(contents.skippedLines) unreadable \(contents.skippedLines == 1 ? "line was" : "lines were") skipped.")
            }
        }

        static func oneLine(_ text: String) -> String {
            text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        }

        static func preview(_ text: String, limit: Int = 60) -> String {
            let line = oneLine(text)
            return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete every dictation in the history.")

        @Flag(help: "Confirm deleting the history.") var yes = false

        mutating func validate() throws {
            guard yes else {
                throw ValidationError("Clearing deletes every dictation in the history; pass --yes to confirm.")
            }
        }

        mutating func run() throws {
            let removed = try DictationHistoryStore().clear()
            Console.output("Cleared \(removed) \(removed == 1 ? "dictation" : "dictations").")
        }
    }
}
