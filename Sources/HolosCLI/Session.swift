import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect and reprocess a portable .holos audio archive.",
        subcommands: [
            Inspect.self,
            Recover.self,
            Retranscribe.self,
        ])

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate an archive and report interrupted or damaged files without changing it.")
        @Argument(help: "Path to a .holos directory.") var path: String
        mutating func run() throws {
            if try SessionArchive.isActive(at: fileURL(path)) {
                let manifest = try SessionArchive.readManifest(at: fileURL(path))
                Console.output("\(manifest.name) — \(manifest.status); writer active, \(manifest.chunks.count) finalized chunks.")
                Console.output("Run the full integrity check after processing stops.")
                return
            }
            let report = try SessionArchive.inspectRecovery(at: fileURL(path))
            if let manifest = report.manifest {
                Console.output("\(manifest.name) (\(manifest.id)) — \(manifest.status)")
                Console.output("\(manifest.chunks.count) finalized chunks")
            }
            if let error = report.manifestError { Console.output("Manifest error: \(error)") }
            if report.tornFinalJournalLine { Console.output("Incomplete final journal entry (earlier entries remain readable).") }
            for path in report.missingChunks { Console.output("Missing: \(path)") }
            for path in report.corruptChunks { Console.output("Checksum mismatch: \(path)") }
            for path in report.unindexedChunks { Console.output("Unindexed audio: \(path)") }
            for path in report.unrecoveredChunks { Console.output("Unrecovered audio: \(path)") }
            if report.needsAttention { throw HolosError.incomplete("Archive needs attention; no files were changed.") }
            Console.output("Archive checks passed.")
        }
    }

    struct Recover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Recover readable timed audio from an interrupted archive; preserves original audio and backs up torn journals.")
        @Argument(help: "Path to an inactive .holos directory.") var path: String
        mutating func run() async throws {
            let report = try await SessionArchive.recover(at: fileURL(path))
            for item in report.unindexedChunks { Console.error("Unindexed audio: \(item)") }
            for item in report.unrecoveredChunks { Console.error("Could not safely recover: \(item)") }
            guard !report.needsAttention else { throw HolosError.incomplete("Recoverable metadata was saved; some audio still needs inspection.") }
            Console.output("Recovered \(report.manifest?.chunks.count ?? 0) finalized chunks. Audio preserved. Use holos session retranscribe to rebuild text.")
        }
    }

    struct Retranscribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reprocess finalized archive chunks into a new JSON transcript.")
        @Argument(help: "Path to a .holos directory.") var path: String
        @Option(name: .shortAndLong, help: "New JSON transcript output path; required to preserve original revisions.") var output: String
        @OptionGroup var recognition: RecognitionOptions
        mutating func run() async throws {
            let directory = fileURL(path)
            guard try !SessionArchive.isActive(at: directory) else { throw HolosError.invalidInput("Stop recording/processing before reprocessing this archive.") }
            let report = try SessionArchive.inspectRecovery(at: directory)
            guard !report.needsAttention, let manifest = report.manifest else {
                throw HolosError.incomplete("Inspect the archive first; missing, damaged, or unindexed audio needs attention.")
            }
            var segments: [TranscriptSegment] = []
            for track in Set(manifest.chunks.map(\.track)).sorted() {
                Console.error("Transcribing \(track)…")
                segments += try await TrackReplayer.replay(directory: directory, track: track,
                    locale: recognition.locale, backend: recognition.backend)
            }
            segments.sort { $0.start < $1.start }
            let transcript = Transcript(source: directory.path, locale: recognition.locale, backend: recognition.backend, segments: segments)
            try writeJSON(transcript, to: fileURL(output))
            Console.output(fileURL(output).path)
        }
    }
}
