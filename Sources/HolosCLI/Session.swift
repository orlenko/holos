import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Synchronization

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect and reprocess a portable .holos audio archive.",
        subcommands: [
            Inspect.self,
            List.self,
            Recover.self,
            Retranscribe.self,
            Diarize.self,
            Import.self,
            Export.self,
            Score.self,
            Delete.self,
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
                if (try? AtomicFile.readIfPresent(SessionPaths.audioDeleted(fileURL(path)), maxBytes: 1 << 20)) != nil {
                    Console.output("The audio was deleted (holos session delete --audio-only); its chunks are "
                        + "expected to be missing.")
                }
            }
            if let error = report.manifestError { Console.output("Manifest error: \(error)") }
            if report.tornFinalJournalLine { Console.output("Incomplete final journal entry (earlier entries remain readable).") }
            if let note = SessionRecoveryCommand.journalNote(report.unreadableEventLines) { Console.output(note) }
            for path in report.missingChunks { Console.output("Missing: \(path)") }
            for path in report.corruptChunks { Console.output("Checksum mismatch: \(path)") }
            for path in report.unindexedChunks { Console.output("Unindexed audio: \(path)") }
            for path in report.unrecoveredChunks { Console.output("Unrecovered audio: \(path)") }
            if report.needsAttention { throw HolosError.incomplete("Archive needs attention; no files were changed.") }
            Console.output("Archive checks passed.")
        }
    }

    struct Recover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Recover an interrupted session: index its saved audio, rebuild its transcript, and label its speakers.",
            discussion: """
                Saved audio is never rewritten, and a torn journal is backed up before it is repaired. The \
                transcript is rebuilt from the phrases live transcription saved; only the audio they do not cover \
                is transcribed again. A session that was not interrupted keeps its transcript unless --force is \
                given. Running recover again changes nothing. Exits 0 when done (also when speaker models are not \
                installed), 3 when the transcript was rebuilt but speaker labelling failed or was skipped for \
                another reason (it is printed), and 1 when recovery or the rebuild failed or some saved audio \
                could not be recovered.
                """)
        @Argument(help: "Path to an inactive .holos folder, or a session ID.") var path: String
        @Flag(help: "Rebuild the transcript from the saved phrases only; do not transcribe any audio.")
        var noTranscribe = false
        @Flag(help: "Do not label speakers or rewrite the transcript files afterwards.") var noPostprocess = false
        @Flag(help: "Rebuild the transcript even if it was rebuilt already or the session was not interrupted.")
        var force = false
        @Flag(help: "Print the result as JSON.") var json = false

        struct Result: Encodable {
            struct Rebuild: Encodable {
                var transcriptID: String
                var journalSegments: Int
                var coverageEnd: [String: Double]
                var replayedSeconds: [String: Double]
                var reused: Bool
            }

            var sessionID: String?
            /// The manifest status once recover ended (for example "recovered").
            var status: String?
            var chunks: Int
            var savedSeconds: Double
            var unindexedChunks: [String]
            var unrecoveredChunks: [String]
            var unreadableEventLines: Int
            var rebuild: Rebuild?
            var postProcessing: PostProcessingRecord?
            var summary: String
            var warnings: [String]
            var exitCode: Int32
        }

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            let request = SessionRecoveryCommand.Request(session: session, transcribe: !noTranscribe,
                                                         postProcess: !noPostprocess, force: force)
            let outcome = try await SessionRecoveryCommand.run(
                request, diarizer: noPostprocess ? nil : makeDiarizer(engineOverrides: [:]),
                progress: Self.progressPrinter())
            if json {
                let recovery = outcome.recovery
                try Console.json(Result(
                    sessionID: recovery.manifest?.id, status: outcome.status ?? recovery.manifest?.status,
                    chunks: recovery.manifest?.chunks.count ?? 0, savedSeconds: recovery.manifest?.savedSeconds ?? 0,
                    unindexedChunks: recovery.unindexedChunks, unrecoveredChunks: recovery.unrecoveredChunks,
                    unreadableEventLines: recovery.unreadableEventLines,
                    rebuild: outcome.rebuild.map {
                        Result.Rebuild(transcriptID: $0.transcriptID, journalSegments: $0.journalSegments,
                                       coverageEnd: $0.coverageEnd, replayedSeconds: $0.replayedSeconds,
                                       reused: $0.reused)
                    },
                    postProcessing: outcome.postProcessing, summary: outcome.summary, warnings: outcome.warnings,
                    exitCode: outcome.exitCode))
            } else {
                Console.output(outcome.summary)
            }
            for warning in outcome.warnings { Console.error(warning) }
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
