import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

extension Session {
    /// `holos session list` (docs/meeting-design.md §5.6).
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List sessions, newest first, with their state, saved audio, size, and speaker labels.",
            discussion: """
                STATE is recording, processing, interrupted (the recorder stopped unexpectedly; recover it with \
                holos session recover), complete, audioOnly, transcriptionIncomplete, incomplete, failed, recovered, \
                or damaged (the manifest cannot be read). SAVED is the longest track's saved audio (h:mm:ss). \
                SPEAKERS is none, labelling, labelled, not labelled, failed, or interrupted.
                """)

        @Option(help: "Session folder (default: HOLOS_DATA_DIR or Application Support/Holos/Sessions).")
        var directory: String?
        @Flag(help: "Only sessions whose recorder stopped unexpectedly.") var interrupted = false
        @Flag(help: "Print the sessions as JSON.") var json = false

        mutating func run() throws {
            let root = directory.map(fileURL) ?? HolosPaths.sessions
            var sessions = SessionCatalog.list(root: root)
            if interrupted { sessions = sessions.filter { $0.state == .interrupted } }
            if json {
                try Console.json(sessions)
            } else if sessions.isEmpty {
                Console.output(interrupted ? "No interrupted sessions." : "No sessions yet.")
            } else {
                let rows = sessions.map { summary in
                    [summary.id, summary.state.rawValue, Record.Status.clock(summary.savedSeconds),
                     Self.size(summary.bytes), Self.speakers(summary), Self.oneLine(summary.name)]
                }
                for line in TextTable.render(header: ["ID", "STATE", "SAVED", "SIZE", "SPEAKERS", "NAME"], rows: rows,
                                             alignments: [.left, .left, .right, .right, .left, .left]) {
                    Console.output(line)
                }
            }
            // Journal lines that were skipped are not an error, but the user should know events were lost.
            for summary in sessions where summary.state != .damaged {
                let skipped = (try? SessionArchive.readEvents(at: summary.directory).unreadableLines) ?? 0
                if let note = SessionRecoveryCommand.journalNote(skipped) { Console.error("\(summary.id): \(note)") }
            }
        }

        /// The SPEAKERS column.
        static func speakers(_ summary: SessionSummary) -> String {
            switch summary.speakerState {
            case .none: "none"
            case .running: "labelling"
            case .labelled: "labelled"
            case .notLabelled: "not labelled"
            case .failed: "failed"
            case .interrupted: "interrupted"
            }
        }

        /// Decimal units, as Finder shows sizes: "940 KB", "1.2 GB".
        static func size(_ bytes: Int64) -> String {
            let units = ["B", "KB", "MB", "GB", "TB"]
            var value = Double(max(0, bytes))
            var unit = 0
            while value >= 999.5, unit < units.count - 1 {
                value /= 1000
                unit += 1
            }
            if unit == 0 { return "\(Int(value)) B" }
            let number = value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
            return "\(number) \(units[unit])"
        }

        /// A name on one line: line breaks and tabs become spaces.
        static func oneLine(_ text: String) -> String {
            text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        }
    }
}
