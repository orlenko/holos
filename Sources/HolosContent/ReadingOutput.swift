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
    /// reject are replaced, whitespace is collapsed, leading and trailing dots are dropped, a
    /// Windows device name ("CON", "com1.txt") gets a leading "_", and the name is shortened to
    /// 100 characters and, with its ".m4a", to `limit` filesystem units (see `fits`), on a
    /// character boundary.
    public static func fileName(title: String?, fallback: String? = nil, limit: Int = defaultNameLimit) -> String {
        for candidate in [title, fallback] {
            if let name = sanitize(candidate ?? ""), let fitted = fitted(name, limit: limit) {
                return fitted + fileExtension
            }
        }
        return fallbackName + fileExtension
    }

    /// Shortens `name` (without extension) so that it plus ".m4a" fits in `limit` units, or nil
    /// when nothing readable is left. A name Windows reserves (see `isReserved`) gets a leading
    /// "_", so the file can be copied to any system.
    static func fitted(_ name: String, limit: Int) -> String? {
        var result = name
        while true {
            while !result.isEmpty && !fits(result + fileExtension, limit: limit) { result.removeLast() }
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
            guard !result.isEmpty else { return nil }
            // Shortening keeps the "_", so the name is not reserved the second time round.
            guard isReserved(result) else { return result }
            result = "_" + result
        }
    }

    /// Windows device names: never usable as a file name, in any case, with any extension
    /// ("con.txt"), or with spaces before the extension ("CON .txt"). Windows reads the
    /// superscript digits ¹²³ as 1, 2, and 3 in COM and LPT names.
    static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        for digit in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{00B9}", "\u{00B2}", "\u{00B3}"] {
            names.insert("COM" + digit)
            names.insert("LPT" + digit)
        }
        return names
    }()

    /// Whether Windows reserves `name` (a file name, extension and all): its part before the
    /// first dot, without trailing spaces, is a device name in any case.
    static func isReserved(_ name: String) -> Bool {
        var base = Substring(name.prefix { $0 != "." })
        while base.last == " " { base.removeLast() }
        return reservedNames.contains(base.uppercased())
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

    /// `name` in NFC, shortened to fit `limit`, keeping its extension, and never a reserved name.
    static func fitting(_ name: String, limit: Int) -> String {
        let name = name.precomposedStringWithCanonicalMapping
        guard !fits(name, limit: limit) || isReserved(name) else { return name }
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
        // One defined spelling for every name made here: NFC, written byte for byte (see `RawFilePath`).
        return name.isEmpty ? nil : name.precomposedStringWithCanonicalMapping
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
    ///
    /// `output` is kept spelled byte for byte as typed, and `<name>` is written in NFC (see
    /// `RawFilePath`): on a volume that keeps a name's NFC and NFD spellings apart, each
    /// spelling is its own file and its own cache.
    ///
    /// Every destination is checked here, before anything is rendered (see `checkDestination`),
    /// and so is `readingsRoot`, which holds the cache. Without `resume`, a file already at the
    /// destination is an error: nothing is ever replaced.
    public static func locate(output: String?, name: String, identity: String, readingsRoot: URL,
                              resume: Bool = false) throws -> ReadingLocation {
        if output == nil { try checkFolder(readingsRoot, role: "Readings folder") }
        let (location, destination) = try resolve(output: output, name: name, identity: identity,
                                                  readingsRoot: readingsRoot)
        switch destination {
        case .newReading:
            try checkPathLength(location.output)
        case .readingFolder:
            // The reading's own folder: whether its finished file may exist is the pipeline's
            // call (it is this reading's when resuming, and a clear error otherwise).
            try checkDestination(location.output, allowExisting: true)
        case .explicit:
            try checkDestination(location.output, allowExisting: resume)
            try checkFolder(readingsRoot, role: "Readings folder")
        }
        return location
    }

    /// The file `locate` would give for the same arguments, resolved the same way but with
    /// nothing checked or created: what `voiceislocal read --print-text` shows. A new reading's
    /// folder is named when it is created, so it shows as `<new folder>`.
    public static func previewPath(output: String?, name: String, identity: String,
                                   readingsRoot: URL) throws -> String {
        let (location, destination) = try resolve(output: output, name: name, identity: identity,
                                                  readingsRoot: readingsRoot)
        guard destination == .newReading else { return location.output.path }
        return RawFilePath.appending(location.output.lastPathComponent,
                                     to: readingsRoot.appendingPathComponent("<new folder>", isDirectory: true)).path
    }

    /// Which kind of place `--output` names (see `locate`).
    enum Destination { case newReading, readingFolder, explicit }

    /// `locate`'s resolution alone: reads the filesystem (whether `output` is a folder, holds a
    /// reading, and its volume's name limit) but checks and creates nothing.
    static func resolve(output: String?, name: String, identity: String, readingsRoot: URL,
                        volume: ReadingPathIdentity.VolumeQuery = ReadingPathIdentity.volumeRules)
        throws -> (ReadingLocation, Destination) {
        func hashed(output: URL) -> ReadingLocation {
            Self.hashed(output: output, identity: identity, readingsRoot: readingsRoot, volume: volume)
        }
        guard let output else {
            let directory = readingsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let name = fitting(name, limit: nameLimit(in: readingsRoot))
            return (ReadingLocation(workDirectory: directory, output: RawFilePath.appending(name, to: directory)),
                    .newReading)
        }
        var url = RawFilePath.url(output)
        if RawFilePath.isDirectory(url) {
            url = RawFilePath.url(output, isDirectory: true)
            let name = fitting(name, limit: nameLimit(in: url))
            if ReadingManifest.isReading(url.appendingPathComponent(ReadingManifest.fileName)) {
                return (ReadingLocation(workDirectory: url, output: RawFilePath.appending(name, to: url)), .readingFolder)
            }
            return (hashed(output: RawFilePath.appending(name, to: url)), .explicit)
        }
        guard url.pathExtension.lowercased() == ReadingAudioFormat.fileExtension else {
            throw HolosError.invalidInput("--output must be a .m4a file path or an existing directory: \(url.path)")
        }
        return (hashed(output: url), .explicit)
    }

    /// Fails unless the finished file can be saved at `output`: its folder exists, is a folder,
    /// and accepts new files (checked by creating and removing one); its name fits the volume
    /// and its path fits `PATH_MAX`, with room for the temporary file written beside it; and,
    /// unless `allowExisting`, nothing (not even a broken link) is there yet.
    public static func checkDestination(_ output: URL, allowExisting: Bool = false) throws {
        guard output.isFileURL else { throw HolosError.invalidInput("Reading output must be a file path.") }
        let folder = output.deletingLastPathComponent()
        try checkFolder(folder, role: "Output folder")
        guard fits(output.lastPathComponent, limit: nameLimit(in: folder)) else {
            throw HolosError.invalidInput("Output file name is too long for its volume: \(output.lastPathComponent)")
        }
        try checkPathLength(output)
        var metadata = stat()
        if !allowExisting, lstat(output.path, &metadata) == 0 {
            throw HolosError.invalidInput("Reading output already exists: \(output.path)")
        }
    }

    /// The longest temporary name written beside the output while it is joined: the join file's
    /// and `AudioBookWriter`'s temporary for it (see `ReadingPipeline`).
    static let temporaryNameLength = AudioBookWriter.temporaryName(
        for: ReadingTemporaries.joinName(key: String(repeating: "0", count: 16), run: UUID())).utf8.count

    static func checkPathLength(_ output: URL) throws {
        let folder = output.deletingLastPathComponent().path
        let longest = max(output.lastPathComponent.utf8.count, temporaryNameLength)
        // The path plus "/" and the name, and a terminating NUL, within PATH_MAX bytes.
        guard folder.utf8.count + 1 + longest < Int(PATH_MAX) else {
            throw HolosError.invalidInput("Output path is too long (the limit is \(PATH_MAX - 1) bytes): \(output.path)")
        }
    }

    /// Fails unless `folder` exists, is a folder, and a new file can be created in it.
    static func checkFolder(_ folder: URL, role: String) throws {
        // `stat` on the path as spelled (`FileManager` would decompose it; see `RawFilePath`).
        var metadata = stat()
        guard stat(folder.path, &metadata) == 0 else {
            throw HolosError.invalidInput("\(role) does not exist: \(folder.path)")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw HolosError.invalidInput("\(role) is not a folder: \(folder.path)")
        }
        // Permissions, ACLs, read-only volumes, and sandboxing all show in an actual create.
        let probe = folder.appendingPathComponent(".holos-probe-\(UUID().uuidString)")
        let descriptor = open(probe.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.invalidInput("\(role) is not writable: \(folder.path) (\(String(cString: strerror(errno))))")
        }
        close(descriptor)
        unlink(probe.path)
    }

    private static func hashed(output: URL, identity: String, readingsRoot: URL,
                               volume: ReadingPathIdentity.VolumeQuery) -> ReadingLocation {
        let canonical = RawFilePath.resolvingFolder(of: output)
        // Keyed by the file's exact filesystem identity, so every spelling of one file
        // ("Book.m4a" and "book.m4a" on a volume known to ignore case, one name in NFC and NFD on
        // APFS or HFS+) finds the same cache, and two files (those names on a volume that may tell
        // them apart) never share one. `output` keeps its spelling as typed and the key is hashed
        // as bytes, so NFC and NFD spellings kept apart stay apart. The output's reservation stays
        // conservative (see `ReadingOutputReservation`).
        let key = ReadingPathIdentity.key(output, .exact, volume: volume)
        let digest = SHA256.hash(data: Data((key + "\u{0}" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = readingsRoot.appendingPathComponent("Output-\(digest.prefix(16))", isDirectory: true)
        return ReadingLocation(workDirectory: directory, output: canonical)
    }
}

/// File URLs that keep a path's bytes as given. Foundation's own ways to make and change one
/// (`URL(fileURLWithPath:)`, `standardizedFileURL`, `resolvingSymlinksInPath`, the name given to
/// `appendingPathComponent`, `FileManager`'s path methods) decompose names: an NFC "Café.m4a"
/// becomes NFD. APFS and HFS+ take both spellings for one file, but a volume that keeps names
/// as bytes (some network shares) holds two, and the decomposed one is not the file typed. A URL
/// made here keeps its spelling through `path`, `deletingLastPathComponent`, and system calls
/// given `path` (Swift passes a `String` to C as its UTF-8 bytes).
enum RawFilePath {
    /// `path` as a file URL, spelled as given: "~" expanded, a relative path taken from the
    /// current directory, and ".", "..", and repeated "/" removed without looking at the disk,
    /// as `standardizedFileURL` removes them.
    static func url(_ path: String, isDirectory: Bool = false) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : currentDirectory() + "/" + expanded
        return standardized(absolute).withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil)
        }
    }

    /// `name` inside `directory`, both spelled as given.
    static func appending(_ name: String, to directory: URL) -> URL {
        url(directory.path + "/" + name)
    }

    /// `url` with the links in its folder resolved, as `resolvingSymlinksInPath` resolves them
    /// ("/private/var/…" shown as "/var/…"), and its name as spelled. A folder that does not
    /// exist stays as spelled.
    static func resolvingFolder(of url: URL) -> URL {
        let path = standardized(url.path)
        let cut = path.utf8.lastIndex(of: UInt8(ascii: "/")) ?? path.utf8.startIndex
        let folder = String(path[..<cut])
        let name = String(path[path.utf8.index(after: cut)...])
        guard var resolved = realPath(folder.isEmpty ? "/" : folder) else { return Self.url(path) }
        let privatePrefix = "/private/"
        if resolved.hasPrefix(privatePrefix) {
            let shown = String(resolved.dropFirst(privatePrefix.count - 1))
            if realPath(shown) == resolved { resolved = shown }
        }
        return appending(name, to: Self.url(resolved, isDirectory: true))
    }

    /// Whether `url` names a folder (links followed), asked with its spelling as given.
    static func isDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return stat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    /// `path` (absolute) without ".", "..", and empty components; bytes elsewhere untouched.
    /// Split on the "/" byte, which never occurs inside another UTF-8 character.
    static func standardized(_ path: String) -> String {
        var parts: [Substring.UTF8View] = []
        for part in path.utf8.split(separator: UInt8(ascii: "/")) {
            if part.elementsEqual(".".utf8) { continue }
            if part.elementsEqual("..".utf8) {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        var bytes: [UInt8] = []
        for part in parts {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: part)
        }
        return bytes.isEmpty ? "/" : String(decoding: bytes, as: UTF8.self)
    }

    private static func currentDirectory() -> String {
        guard let buffer = getcwd(nil, 0) else { return FileManager.default.currentDirectoryPath }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
