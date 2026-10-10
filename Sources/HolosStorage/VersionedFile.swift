import Foundation
import HolosCore

/// A value read from a versioned JSON file (`VersionedFile`) that checks itself once decoded.
public protocol ValidatedDecodable: Decodable {
    /// Throws `HolosError.invalidInput`, naming `file`, when the decoded value breaks a rule its type cannot express.
    /// Checks that need more than the value (that it belongs to this session, that it is the revision asked for) stay
    /// with the reader. None by default.
    func validate(file: String) throws
}

extension ValidatedDecodable {
    public func validate(file: String) throws {}
}

/// One versioned JSON file format, read as schema rule 3 says (docs/conventions.md §1.6): at most `maxBytes` of a
/// regular file, never a link (`AtomicFile.readIfPresent`); a `schemaVersion` above `current` refused before the
/// whole file is decoded (`SchemaVersion.decode`), so a newer file is `unavailable` even when it uses values this build
/// does not know; then decoded with `HolosJSON` and `validate`d. A file over `maxBytes`, a version below 1, data that
/// does not decode (with no `schemaVersion`, the full decode decides), and a failed validation are damage
/// (`invalidInput`).
public struct VersionedFile<T: ValidatedDecodable>: Sendable {
    /// How messages name the file, such as "transcripts/current.json".
    public let name: String
    /// The newest `schemaVersion` this build reads; it reads `1...current`.
    public let current: Int
    public let maxBytes: Int
    public let damage: SchemaVersion.DamageMessage

    public init(_ name: String, current: Int, maxBytes: Int, damage: SchemaVersion.DamageMessage = .detailed) {
        self.name = name; self.current = current; self.maxBytes = maxBytes; self.damage = damage
    }

    /// The checked value in `url`; nil when the file (or its folder) does not exist.
    public func read(_ url: URL) throws -> T? {
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: maxBytes) else { return nil }
        return try decode(data)
    }

    public func decode(_ data: Data) throws -> T {
        let value = try SchemaVersion.decode(T.self, from: data, current: current, name: name, damage: damage)
        try value.validate(file: name)
        return value
    }
}

extension TranscriptPointer: ValidatedDecodable {
    public func validate(file: String) throws {
        guard Self.validTranscriptID(transcriptID) else {
            throw HolosError.invalidInput("\(file) names an invalid transcript ID.")
        }
    }
}

extension Transcript: ValidatedDecodable {}
extension MeetingInfo: ValidatedDecodable {}
extension PostProcessingRecord: ValidatedDecodable {}

/// Schema rule 3 (docs/conventions.md §1.6): a reader refuses a file from a newer Holos.
///
/// Each file type has its own current version, so raising one (for example runs to 2) never makes the
/// other files, or older lines of the edit journal, unreadable. Readers accept `1...current`.
public enum SchemaVersion {
    static let transcriptPointer = 1
    static let speakerHead = 1
    static let diarizationRun = 1
    static let speakerEdit = 1
    static let recognition = 1
    static let voiceData = 1
    static let audioDeleted = 1

    /// What a file that does not decode is reported as: "<name> is damaged or was not written by Voice is Local",
    /// with where the decoding failed in parentheses (`detailed`) or without (`plain`).
    public enum DamageMessage: Sendable { case detailed, plain }

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
            throw HolosError.unavailable("\(file) was written by a newer version of Voice is Local; update Voice is Local to read it.")
        }
        if version < 1 {
            throw HolosError.invalidInput("\(file) has an unsupported schema version \(version).")
        }
    }

    /// Checks the version before decoding the whole file, so a newer file that uses values this build does
    /// not know (a new enum case) is refused as newer (`unavailable`), not as damaged (`invalidInput`).
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, current: Int, name: String,
                                            damage: DamageMessage = .detailed) throws -> T {
        if let version = probe(data) {
            try check(version, current: current, file: name)
        }
        // With no readable version, the full decode reports the damage.
        switch damage {
        case .detailed:
            return try AtomicFile.decode(type, from: data, name: name)
        case .plain:
            do {
                return try HolosJSON.decoder().decode(type, from: data)
            } catch {
                throw HolosError.invalidInput("\(name) is damaged or was not written by Voice is Local.")
            }
        }
    }
}
