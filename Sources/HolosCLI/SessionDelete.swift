import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

extension Session {
    /// `holos session delete` (docs/meeting-design.md §4.13, §5.6).
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a session to the Trash, or with --audio-only delete its audio and keep the rest.",
            discussion: """
                Without --audio-only the session folder is moved to the Trash (restore it from there) and its \
                recorder log is deleted. With --audio-only the audio is deleted for good; the transcript, speaker \
                labels, and exports stay. Either way any stored voice data of the session is deleted. Refused while \
                the session is recording or another Holos command is working on it. Nothing is deleted without --yes.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Flag(help: "Delete only the audio (and renders); keep the transcript, speaker labels, and exports.")
        var audioOnly = false
        @Flag(help: "Confirm the deletion.") var yes = false
        @Flag(help: "Print the result as JSON.") var json = false

        struct Result: Encodable {
            var sessionID: String
            var name: String
            /// "audio" or "meeting".
            var deleted: String
            var path: String
        }

        mutating func run() throws {
            let session = try SessionLocator.resolve(path)
            let manifest = try? SessionArchive.readManifest(at: session)
            let name = manifest.map { "“\(Session.List.oneLine($0.name))”" } ?? session.lastPathComponent
            guard yes else {
                let effect = audioOnly
                    ? "This deletes the audio of \(name) for good; its transcript, speaker labels, and exports stay."
                    : "This moves \(name) to the Trash."
                throw HolosError.invalidInput("\(effect) Run again with --yes to confirm.")
            }
            if audioOnly, manifest == nil {
                throw HolosError.invalidInput("The session's manifest cannot be read, so its audio cannot be deleted "
                    + "on its own. Delete the whole session instead (without --audio-only).")
            }
            let lease = try SessionArchive.acquireProcessingLease(at: session)
            defer { lease.release() }
            let sessionID = manifest?.id ?? session.deletingPathExtension().lastPathComponent
            if audioOnly {
                // A maintenance command marks a dead recorder's status exited (§4.1).
                _ = try? RecorderChannel.markDeadRecorderExited(session: session)
                try SessionDeletion.deleteAudio(session: session, lease: lease)
                if json {
                    try Console.json(Result(sessionID: sessionID, name: manifest?.name ?? "", deleted: "audio",
                                            path: session.path))
                } else {
                    let chunks = manifest?.chunks.count ?? 0
                    Console.output("Deleted the audio of \(name) (\(chunks) \(chunks == 1 ? "chunk" : "chunks"), "
                        + "\(Record.Status.clock(manifest?.savedSeconds ?? 0))). Its transcript, speaker labels, and "
                        + "exports are kept.")
                }
            } else {
                try SessionDeletion.moveToTrash(session: session, lease: lease)
                if json {
                    try Console.json(Result(sessionID: sessionID, name: manifest?.name ?? "", deleted: "meeting",
                                            path: session.path))
                } else {
                    Console.output("Moved \(name) to the Trash.")
                }
            }
        }
    }
}
