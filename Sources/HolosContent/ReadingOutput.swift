import CryptoKit
import Foundation
import HolosCore
import HolosSynthesis
import NaturalLanguage

/// Where a reading's audio file goes and where its render cache (manifest, source text, and
/// parts) is kept while it is made.
public struct ReadingLocation: Sendable, Equatable {
    /// The render cache and manifest; `--resume` continues from here.
    public let workDirectory: URL
    /// The finished `.m4a`.
    public let output: URL
}

public enum ReadingOutput {
    public static let fallbackName = "Reading"
    static let maximumNameLength = 100

    /// A file name from the document title: path separators and characters other systems
    /// reject are replaced, whitespace is collapsed, leading dots are dropped, and the name is
    /// shortened to 100 characters. Ends in ".m4a".
    public static func fileName(title: String?, fallback: String? = nil) -> String {
        for candidate in [title, fallback] {
            if let name = sanitize(candidate ?? "") { return name + ".m4a" }
        }
        return fallbackName + ".m4a"
    }

    static func sanitize(_ text: String) -> String? {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "|": result += "-"
            case "*", "?", "\"", "<", ">": continue
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                    result += " "
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        var name = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.count > maximumNameLength {
            name = String(name.prefix(maximumNameLength))
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return name.isEmpty ? nil : name
    }

    /// Resolves `--output`:
    /// - nil: a new `<readings>/<UUID>/` holding both the cache and `<name>`;
    /// - a directory holding a reading's `manifest.json` (a reading made without `--output`):
    ///   that reading, to resume;
    /// - a path ending in `.m4a`: that file;
    /// - an existing directory: `<name>` inside it.
    /// With an explicit output, the cache lives in `<readings>/Output-<hash>`, a hash of the
    /// output path and `identity` (the text and settings), so running the same command again
    /// with `--resume` finds it, and changed text or settings start a new reading instead.
    public static func locate(output: String?, name: String, identity: String, readingsRoot: URL,
                              fileManager: FileManager = .default) throws -> ReadingLocation {
        guard let output else {
            let directory = readingsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            return ReadingLocation(workDirectory: directory, output: directory.appendingPathComponent(name))
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            if fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                return ReadingLocation(workDirectory: url, output: url.appendingPathComponent(name))
            }
            return hashed(output: url.appendingPathComponent(name), identity: identity, readingsRoot: readingsRoot)
        }
        guard url.pathExtension.lowercased() == ReadingAudioFormat.fileExtension else {
            throw HolosError.invalidInput("--output must be a .m4a file path or an existing directory: \(url.path)")
        }
        return hashed(output: url, identity: identity, readingsRoot: readingsRoot)
    }

    private static func hashed(output: URL, identity: String, readingsRoot: URL) -> ReadingLocation {
        let canonical = output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent)
        let digest = SHA256.hash(data: Data((canonical.path + "\u{0}" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = readingsRoot.appendingPathComponent("Output-\(digest.prefix(16))", isDirectory: true)
        return ReadingLocation(workDirectory: directory, output: canonical)
    }
}

public enum ReadingLanguage {
    /// The dominant language of `text` as a BCP 47 code ("en", "fr"), or nil when unsure.
    public static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(5_000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.5, language != .undetermined else { return nil }
        return language.rawValue
    }
}
