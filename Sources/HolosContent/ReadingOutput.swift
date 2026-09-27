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
    /// Longer titles are shortened for readability.
    static let maximumNameLength = 100
    /// The file name component limit of APFS, HFS+, exFAT, and SMB shares: 255 UTF-8 bytes on
    /// APFS, 255 UTF-16 units (stored decomposed) on HFS+ and exFAT.
    public static let defaultNameLimit = 255
    static var fileExtension: String { "." + ReadingAudioFormat.fileExtension }

    /// A file name from the document title: path separators and characters other systems
    /// reject are replaced, whitespace is collapsed, leading dots are dropped, and the name is
    /// shortened to 100 characters and, with its ".m4a", to `limit` filesystem units (see
    /// `fits`), on a character boundary.
    public static func fileName(title: String?, fallback: String? = nil, limit: Int = defaultNameLimit) -> String {
        for candidate in [title, fallback] {
            if let name = sanitize(candidate ?? ""), let fitted = fitted(name, limit: limit) {
                return fitted + fileExtension
            }
        }
        return fallbackName + fileExtension
    }

    /// Shortens `name` (without extension) so that it plus ".m4a" fits in `limit` units, or nil
    /// when nothing readable is left.
    static func fitted(_ name: String, limit: Int) -> String? {
        var result = name
        while !result.isEmpty && !fits(result + fileExtension, limit: limit) { result.removeLast() }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return result.isEmpty ? nil : result
    }

    /// Whether a name fits every way a Mac volume counts it: UTF-8 bytes as given (APFS),
    /// UTF-16 units as given, and UTF-16 units decomposed (HFS+ stores names in NFD).
    public static func fits(_ name: String, limit: Int = defaultNameLimit) -> Bool {
        name.utf8.count <= limit && name.utf16.count <= limit
            && name.decomposedStringWithCanonicalMapping.utf16.count <= limit
    }

    /// The volume's file name limit for names in `directory` (its `NAME_MAX`), at most 255.
    static func nameLimit(in directory: URL) -> Int {
        let value = pathconf(directory.path, _PC_NAME_MAX)
        return value > 0 ? min(Int(value), defaultNameLimit) : defaultNameLimit
    }

    /// `name` shortened to fit `limit`, keeping its extension.
    static func fitting(_ name: String, limit: Int) -> String {
        guard !fits(name, limit: limit) else { return name }
        let stem = name.hasSuffix(fileExtension) ? String(name.dropLast(fileExtension.count)) : name
        return (fitted(stem, limit: limit) ?? fallbackName) + fileExtension
    }

    static func sanitize(_ text: String) -> String? {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "|": result += "-"
            case "*", "?", "\"", "<", ">": continue
            default:
                // Format characters such as the zero-width joiner inside emoji are kept; bidi
                // overrides, which can make a name display as something else, are not.
                if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar) {
                    result += " "
                } else if !scalar.properties.isBidiControl {
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
    /// - a directory holding a reading's manifest (a reading made without `--output`): that
    ///   reading, to resume. Only a manifest this app wrote counts; a directory with some other
    ///   `manifest.json` is an ordinary output directory;
    /// - a path ending in `.m4a`: that file;
    /// - an existing directory: `<name>` inside it.
    /// `<name>` is shortened to the destination volume's file name limit. With an explicit
    /// output, the cache lives in `<readings>/Output-<hash>`, a hash of the output path and
    /// `identity` (the text and settings, see `ReadingPipeline.identity`), so running the same
    /// command again with `--resume` finds it, and changed text or settings start a new reading.
    public static func locate(output: String?, name: String, identity: String, readingsRoot: URL,
                              fileManager: FileManager = .default) throws -> ReadingLocation {
        guard let output else {
            let directory = readingsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let name = fitting(name, limit: nameLimit(in: readingsRoot))
            return ReadingLocation(workDirectory: directory, output: directory.appendingPathComponent(name))
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            let name = fitting(name, limit: nameLimit(in: url))
            if ReadingManifest.isReading(url.appendingPathComponent(ReadingManifest.fileName)) {
                return ReadingLocation(workDirectory: url, output: url.appendingPathComponent(name))
            }
            return hashed(output: url.appendingPathComponent(name), identity: identity, readingsRoot: readingsRoot)
        }
        guard url.pathExtension.lowercased() == ReadingAudioFormat.fileExtension else {
            throw HolosError.invalidInput("--output must be a .m4a file path or an existing directory: \(url.path)")
        }
        guard fits(url.lastPathComponent, limit: nameLimit(in: url.deletingLastPathComponent())) else {
            throw HolosError.invalidInput("--output file name is too long for its volume: \(url.lastPathComponent)")
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
