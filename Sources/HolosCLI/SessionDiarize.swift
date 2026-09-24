import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import Synchronization

extension Session {
    /// `holos session diarize` (docs/meeting-design.md §5.5 PR7b).
    struct Diarize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Label the speakers of a finished session and rewrite its transcript exports.",
            discussion: """
                Exits 0 when speakers were labelled, 3 when the exports were written but speaker labelling was \
                skipped or failed (the reason is printed), and 1 when nothing could be done. Needs the speaker \
                models (holos setup --speakers). Edited speaker labels are kept unless --force is given; names carry \
                over to the new labels.
                """)

        @Argument(help: "Path to a .holos directory.") var path: String
        @Flag(help: "Relabel even when speaker labels were edited; names, links, and rejections carry over.")
        var force = false
        @Option(help: "The exact number of speakers.") var speakers: Int?
        @Option(help: "At least this many speakers.") var minSpeakers: Int?
        @Option(help: "At most this many speakers.") var maxSpeakers: Int?
        @Flag(inversion: .prefixedNo,
              help: "In a call, also label speakers on the microphone track because others share the room.")
        var othersInRoom: Bool?
        @Flag(help: "Keep the rendered audio in derived/ afterwards.") var keepDerived = false
        @Flag(help: "Run as a recording's post-processing: wait up to 30 s for the recording to finish saving.")
        var afterRecording = false
        @Flag(help: "Print the post-processing record as JSON.") var json = false
        @Option(help: .hidden) var exclusiveSegments: Bool?
        @Flag(help: .hidden) var voiceData = false
        @Option(help: .hidden) var leaseFd: Int32?

        func validate() throws {
            if speakers != nil, minSpeakers != nil || maxSpeakers != nil {
                throw ValidationError("Use --speakers, or --min-speakers and --max-speakers, not both.")
            }
            for value in [speakers, minSpeakers, maxSpeakers].compactMap({ $0 }) where value < 1 {
                throw ValidationError("Speaker counts must be at least 1.")
            }
            if let minSpeakers, let maxSpeakers, minSpeakers > maxSpeakers {
                throw ValidationError("--min-speakers cannot be more than --max-speakers.")
            }
            if let leaseFd, leaseFd < 0 { throw ValidationError("--lease-fd must be a descriptor number.") }
        }

        mutating func run() async throws {
            var hint: SpeakerCountHint?
            if let speakers {
                hint = SpeakerCountHint(exactly: speakers)
            } else if minSpeakers != nil || maxSpeakers != nil {
                hint = SpeakerCountHint(minimum: minSpeakers, maximum: maxSpeakers)
            }
            var overrides: [String: String] = [:]
            if let exclusiveSegments { overrides["exclusiveSegments"] = String(exclusiveSegments) }
            let options = PostProcessingOptions(speakers: hint, force: force, keepDerived: keepDerived,
                                                othersInRoom: othersInRoom, engineOverrides: overrides,
                                                forceVoiceData: voiceData)
            let request = SessionDiarizeCommand.Request(session: fileURL(path), options: options,
                                                        afterRecording: afterRecording, leaseDescriptor: leaseFd)
            let outcome = try await SessionDiarizeCommand.run(
                request, diarizer: makeDiarizer(engineOverrides: overrides), progress: progressPrinter())
            // Stdout carries the result; a warning or failure is explained on stderr (docs/meeting-design.md §1.4).
            if json {
                try Console.json(outcome.record)
                if outcome.exitCode != 0, let message = outcome.record.message { Console.error(message) }
            } else if outcome.exitCode == 0 {
                Console.output(outcome.summary)
            } else {
                Console.error(outcome.summary)
            }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }

        /// Prints each new progress message once to stderr.
        private func progressPrinter() -> @Sendable (PostProcessingProgress) -> Void {
            let last = Mutex<String?>(nil)
            return { progress in
                let isNew = last.withLock { previous in
                    guard previous != progress.message else { return false }
                    previous = progress.message
                    return true
                }
                if isNew { Console.error(progress.message) }
            }
        }
    }
}
