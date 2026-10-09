import Foundation
import HolosCore

/// Contents of transcripts/current.json.
public struct TranscriptPointer: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var transcriptID: String
    public var updatedAt: Date

    public init(schemaVersion: Int = 1, transcriptID: String, updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.transcriptID = transcriptID; self.updatedAt = updatedAt
    }
}

extension TranscriptPointer {
    /// Reads the pointer of `session`; nil when the file does not exist.
    static func read(session: URL) throws -> TranscriptPointer? {
        try read(SessionPaths.transcriptPointer(session), name: "transcripts/current.json")
    }

    /// Reads `transcripts/current.pending` (same format): the revision a save started publishing; nil when
    /// no save is pending.
    static func readPending(session: URL) throws -> TranscriptPointer? {
        try read(SessionPaths.pendingTranscript(session), name: "transcripts/current.pending")
    }

    private static func read(_ url: URL, name: String) throws -> TranscriptPointer? {
        try VersionedFile<TranscriptPointer>(name, current: SchemaVersion.transcriptPointer, maxBytes: 64 << 10)
            .read(url)
    }

    /// A token that is not "current" in any case: transcripts/current.json is the pointer, never a revision
    /// (and the volume may be case-insensitive).
    static func validTranscriptID(_ id: String) -> Bool {
        SessionArchive.validToken(id) && id.lowercased() != "current"
    }
}
