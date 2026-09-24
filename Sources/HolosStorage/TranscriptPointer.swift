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
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: 64 << 10) else { return nil }
        let pointer = try SchemaVersion.decode(TranscriptPointer.self, from: data,
                                               current: SchemaVersion.transcriptPointer, name: name)
        guard validTranscriptID(pointer.transcriptID) else {
            throw HolosError.invalidInput("\(name) names an invalid transcript ID.")
        }
        return pointer
    }

    /// A token that is not "current" in any case: transcripts/current.json is the pointer, never a revision
    /// (and the volume may be case-insensitive).
    static func validTranscriptID(_ id: String) -> Bool {
        SessionArchive.validToken(id) && id.lowercased() != "current"
    }
}

/// Schema rule 3 (docs/meeting-design.md §1.6): a reader refuses a file from a newer Holos.
///
/// Each file type has its own current version, so raising one (for example runs to 2) never makes the
/// other files, or older lines of the edit journal, unreadable. Readers accept `1...current`.
enum SchemaVersion {
    static let transcriptPointer = 1
    static let speakerHead = 1
    static let diarizationRun = 1
    static let speakerEdit = 1
    static let recognition = 1
    static let voiceData = 1
    static let audioDeleted = 1

    private struct Probe: Decodable {
        var schemaVersion: Int
    }

    /// The top-level `schemaVersion` of a JSON object, or nil when the data has none.
    static func probe(_ data: Data) -> Int? {
        (try? HolosJSON.decoder().decode(Probe.self, from: data))?.schemaVersion
    }

    /// Whether a reader of `current` can read `version`.
    static func readable(_ version: Int, current: Int) -> Bool {
        (1...current).contains(version)
    }

    static func check(_ version: Int, current: Int, file: String) throws {
        if version > current {
            throw HolosError.unavailable("\(file) was written by a newer Holos; update Holos to read it.")
        }
        if version < 1 {
            throw HolosError.invalidInput("\(file) has an unsupported schema version \(version).")
        }
    }

    /// Checks the version before decoding the whole file, so a newer file that uses values this build does
    /// not know (a new enum case) is refused as newer (`unavailable`), not as damaged (`invalidInput`).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, current: Int, name: String) throws -> T {
        if let version = probe(data) {
            try check(version, current: current, file: name)
        }
        // With no readable version, the full decode reports the damage.
        return try AtomicFile.decode(type, from: data, name: name)
    }
}
