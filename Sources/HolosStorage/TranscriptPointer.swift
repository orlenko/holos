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
        let url = SessionPaths.transcriptPointer(session)
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: 64 << 10) else { return nil }
        let pointer = try AtomicFile.decode(TranscriptPointer.self, from: data, name: "transcripts/current.json")
        try SchemaVersion.check(pointer.schemaVersion, file: "transcripts/current.json")
        guard SessionArchive.validToken(pointer.transcriptID) else {
            throw HolosError.invalidInput("transcripts/current.json names an invalid transcript ID.")
        }
        return pointer
    }
}

/// Schema rule 3 (docs/meeting-design.md §1.6): a reader refuses a file from a newer Holos.
enum SchemaVersion {
    static let current = 1

    static func check(_ version: Int, file: String) throws {
        if version > current {
            throw HolosError.unavailable("\(file) was written by a newer Holos; update Holos to read it.")
        }
        if version < 1 {
            throw HolosError.invalidInput("\(file) has an unsupported schema version \(version).")
        }
    }
}
