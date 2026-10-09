import Foundation
import HolosCore

/// Broken and foreign copies of one valid versioned JSON file, and what a reader made of each, for tests that pin how
/// a reader treats every kind of file it can meet: `cases` gives the files, `outcome` names the result of one read.
public enum VersionedFileCorpus {
    /// `valid` (a JSON object with a top-level `schemaVersion`) and copies of it: empty, cut in half, not JSON, of a
    /// newer version (`newerVersion`, with a field this build does not know), only a newer version, version 0, without
    /// `schemaVersion`, and with `schemaVersion` as a string. A file too large to read is made by `writeOversized`.
    public static func cases(valid: Data, newerVersion: Int) throws -> [(name: String, data: Data)] {
        guard let object = try JSONSerialization.jsonObject(with: valid) as? [String: Any] else {
            throw HolosError.invalidInput("The valid file must hold a JSON object.")
        }
        func json(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = object
            change(&copy)
            return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
        }
        let newer = try json { $0["schemaVersion"] = newerVersion; $0["addedLater"] = ["kind": "unknown"] }
        let zero = try json { $0["schemaVersion"] = 0 }
        let unversioned = try json { $0["schemaVersion"] = nil }
        let textVersion = try json { $0["schemaVersion"] = "1" }
        return [
            ("valid", valid),
            ("empty", Data()),
            ("truncated", valid.prefix(valid.count / 2)),
            ("garbled", Data("{\"schemaVersion\": 1, \u{0}\u{7f}".utf8)),
            ("newer", newer),
            ("newerOnlyVersion", Data("{\"schemaVersion\": \(newerVersion)}".utf8)),
            ("versionZero", zero),
            ("missingVersion", unversioned),
            ("textVersion", textVersion),
        ]
    }

    /// Writes `valid` to `url` and extends it, sparsely, to one byte over `maxBytes` (readers refuse such a file by
    /// its size, before reading it).
    public static func writeOversized(_ valid: Data, to url: URL, maxBytes: Int) throws {
        try valid.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: UInt64(maxBytes) + 1)
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
    }

    /// "value", "nil", or the error's kind and message ("invalidInput: …"); any other error is "other: …".
    public static func outcome(_ read: () throws -> Any?) -> String {
        do {
            return try read() == nil ? "nil" : "value"
        } catch let error as HolosError {
            switch error {
            case .invalidInput(let message): return "invalidInput: \(message)"
            case .unavailable(let message): return "unavailable: \(message)"
            case .permissionDenied(let message): return "permissionDenied: \(message)"
            case .incomplete(let message): return "incomplete: \(message)"
            case .io(let message): return "io: \(message)"
            }
        } catch {
            return "other: \(error)"
        }
    }

    /// Whether `outcome` is `expected`, or starts with it when `expected` ends in "…" (for messages that quote
    /// Foundation's own JSON errors).
    public static func matches(_ outcome: String, _ expected: String) -> Bool {
        expected.hasSuffix("…") ? outcome.hasPrefix(String(expected.dropLast())) : outcome == expected
    }
}
