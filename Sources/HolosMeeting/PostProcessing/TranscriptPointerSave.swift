import Foundation
import HolosCore
import HolosStorage

/// Makes a transcript revision current for a publication made from Review (a word edit, its undo, an automatic fix's
/// revert), where a save that throws may already have published it: the pointer is renamed into place before later
/// steps (syncing its folder) can fail. Such a save is committed, never a refusal: the caller's incomplete-publication
/// error says so, with what it published, so the speaker head it still owes is repaired from the old one.
enum TranscriptPointerSave {
    /// Test hook: while set (a task-local value), called right after a transcript is saved, as a failure after its
    /// pointer was renamed into place would throw.
    @TaskLocal static var afterSave: (@Sendable () throws -> Void)?

    /// Saves `transcript` as current. When that throws and the pointer already names it, throws `committed(error)`
    /// (the publication went through); otherwise rethrows the error (nothing was published).
    static func save(_ transcript: Transcript, archive: SessionArchive, session: URL,
                     committed: (any Error) -> any Error) async throws {
        do {
            try await archive.saveTranscript(transcript, writeLegacyExports: false)
            try afterSave?()
        } catch {
            guard (try? SessionFiles.currentTranscript(session: session))?.id == transcript.id else { throw error }
            throw committed(error)
        }
    }
}
