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

    /// Stands in for every volume's name limit in tests (see `nameLimit(in:)`); nil: the volume's.
    @TaskLocal static var volumeNameLimit: Int? = nil

    /// The volume's file name limit for names in `directory` (its `NAME_MAX`), at most 255.
    static func nameLimit(in directory: URL) -> Int {
        if let limit = volumeNameLimit { return limit }
        let value = pathconf(RawFilePath.system(directory), _PC_NAME_MAX)
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
        if output == nil { try checkFolder(readingsRoot, role: "Readings folder", names: cacheFolderNameLength) }
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
            try checkFolder(readingsRoot, role: "Readings folder", names: cacheFolderNameLength)
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
            if ReadingManifest.isReading(RawFilePath.appending(ReadingManifest.fileName, to: url)) {
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
    /// and accepts new files (checked by creating and removing one); its name, and every name
    /// written beside it (temporaries, reservation, probe: `outputFolderNameLength`), fits the
    /// volume's `NAME_MAX`; its path fits `PATH_MAX`, with room for the longest of those; and,
    /// unless `allowExisting`, nothing (not even a broken link) is there yet.
    public static func checkDestination(_ output: URL, allowExisting: Bool = false) throws {
        guard output.isFileURL else { throw HolosError.invalidInput("Reading output must be a file path.") }
        let folder = output.deletingLastPathComponent()
        try checkFolder(folder, role: "Output folder", names: outputFolderNameLength)
        guard fits(output.lastPathComponent, limit: nameLimit(in: folder)) else {
            throw HolosError.invalidInput("Output file name is too long for its volume: \(output.lastPathComponent)")
        }
        try checkPathLength(output)
        var metadata = stat()
        if !allowExisting, lstat(RawFilePath.system(output), &metadata) == 0 {
            throw HolosError.invalidInput("Reading output already exists: \(output.path)")
        }
    }

    /// The longest temporary name written beside the output while it is joined: the join file's
    /// and `AudioBookWriter`'s temporary for it (see `ReadingPipeline`).
    static let temporaryNameLength = AudioBookWriter.temporaryName(
        for: ReadingTemporaries.joinName(key: String(repeating: "0", count: 16), run: UUID())).utf8.count

    /// `checkFolder`'s writability probe, `.holos-probe-<UUID>`.
    static func probeName() -> String { ".holos-probe-\(UUID().uuidString)" }

    /// The longest name other than the output's written in the output's folder: the join
    /// temporaries, the reservation and its guard (see `ReadingOutputReservation`), and the probe.
    static let outputFolderNameLength = max(temporaryNameLength, ReadingOutputReservation.longestNameLength,
                                            probeName().utf8.count)

    /// The longest name written in the folder that holds reading caches: a cache's lock and its
    /// staging folder (see `ReadingDirectoryLock`, `ReadingCache`) and the probe. A reading
    /// without `--output` is made in a folder there, so its output folder's names count too (see
    /// `outputFolderNameLength`), as do the names inside a cache (`ReadingTemporaries`).
    static let cacheFolderNameLength: Int = {
        let key = String(repeating: "0", count: 64)
        let names = [
            ReadingDirectoryLock.lockName(key: key),
            ReadingCache.stagingName(key: key),
            ReadingTemporaries.manifestName(),
            ReadingTemporaries.invalidPrefix + UUID().uuidString + "-" + (ReadingPipeline.partPath(9_999) as NSString).lastPathComponent,
        ]
        return max(outputFolderNameLength, names.map(\.utf8.count).max() ?? 0)
    }()

    /// Fails unless every name up to `length` bytes fits the volume holding `folder` (see
    /// `nameLimit(in:)`); the names this app writes are ASCII.
    static func checkNameLimit(_ folder: URL, role: String, names length: Int) throws {
        let limit = nameLimit(in: folder)
        guard length <= limit else {
            throw HolosError.invalidInput("\(role) is on a volume whose file names are limited to \(limit) bytes, too few for the reading's temporary files (\(length) bytes): \(folder.path)")
        }
    }

    static func checkPathLength(_ output: URL) throws {
        let folder = output.deletingLastPathComponent().path
        let longest = max(output.lastPathComponent.utf8.count, outputFolderNameLength)
        // The path plus "/" and the name, and a terminating NUL, within PATH_MAX bytes.
        guard folder.utf8.count + 1 + longest < Int(PATH_MAX) else {
            throw HolosError.invalidInput("Output path is too long (the limit is \(PATH_MAX - 1) bytes): \(output.path)")
        }
    }

    /// Fails unless `folder` exists, is a folder, its volume takes names of `names` bytes (see
    /// `checkNameLimit`), and a new file can be created in it.
    static func checkFolder(_ folder: URL, role: String, names: Int) throws {
        // `stat` on the path as spelled (`FileManager` would decompose it; see `RawFilePath`).
        var metadata = stat()
        guard stat(RawFilePath.system(folder), &metadata) == 0 else {
            throw HolosError.invalidInput("\(role) does not exist: \(folder.path)")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw HolosError.invalidInput("\(role) is not a folder: \(folder.path)")
        }
        try checkNameLimit(folder, role: role, names: names)
        // Permissions, ACLs, read-only volumes, and sandboxing all show in an actual create. The
        // probe is made in the folder as spelled.
        let probe = RawFilePath.system(RawFilePath.appending(probeName(), to: folder))
        let descriptor = open(probe, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.invalidInput("\(role) is not writable: \(folder.path) (\(String(cString: strerror(errno))))")
        }
        close(descriptor)
        unlink(probe)
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
    /// current directory, "." and repeated "/" removed, and ".." applied as the system applies
    /// it, following links (see `standardized`).
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
        guard let resolved = shownRealPath(folder.isEmpty ? "/" : folder) else { return Self.url(path) }
        return appending(name, to: Self.url(resolved, isDirectory: true))
    }

    /// Whether `url` names a folder (links followed), asked with its spelling as given.
    static func isDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return stat(system(url), &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    /// Stands in for the volume in tests: the path a system call is given for a path as spelled,
    /// so a test can simulate a volume that keeps NFC and NFD names apart. nil: the path itself.
    @TaskLocal static var volume: (@Sendable (String) -> String)? = nil

    /// `path` as a system call is given it: its bytes as spelled (Swift passes a `String` to C
    /// as its UTF-8 bytes).
    static func system(_ path: String) -> String { volume?(path) ?? path }

    /// `url`'s path as a system call is given it (see `system(_:)`).
    static func system(_ url: URL) -> String { system(url.path) }

    /// The names in `folder`, listed with its spelling as given (`FileManager` would decompose
    /// it), "." and ".." left out; nil when it cannot be listed. A name that is not UTF-8 is left
    /// out too: no file this app makes has one.
    static func names(in folder: URL) -> [String]? {
        guard let stream = opendir(system(folder)) else { return nil }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(validating: bytes.prefix(length), as: UTF8.self)
            }
            guard let name, name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    /// `path` (absolute) without "." and empty components, and with ".." taken as the system
    /// takes it: the parent of the folder the path before it names, links resolved. When a link
    /// is followed by "..", as in "/tmp/link/../Book.m4a", ".." leaves the link's target, not
    /// "/tmp". So everything up to the last ".." is resolved on disk (`realpath`, shown without
    /// "/private" as `resolvingFolder` shows it) and the components after it keep their bytes;
    /// when that part cannot be resolved (a folder that does not exist), the path keeps its ".."
    /// for the system to refuse. Split on the "/" byte, which never occurs inside another UTF-8
    /// character.
    static func standardized(_ path: String) -> String {
        let parts = path.utf8.split(separator: UInt8(ascii: "/"))
            .filter { !$0.elementsEqual(".".utf8) }
        func joined(_ parts: ArraySlice<Substring.UTF8View>, under base: String = "") -> String {
            var bytes = Array(base.utf8)
            if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
            for part in parts {
                bytes.append(UInt8(ascii: "/"))
                bytes.append(contentsOf: part)
            }
            return bytes.isEmpty ? "/" : String(decoding: bytes, as: UTF8.self)
        }
        guard let last = parts.lastIndex(where: { $0.elementsEqual("..".utf8) }) else { return joined(parts[...]) }
        guard let resolved = shownRealPath(joined(parts[...last])) else { return joined(parts[...]) }
        return joined(parts[(last + 1)...], under: resolved)
    }

    /// `realpath` of `path`, shown without a leading "/private" where the path without it names
    /// the same place ("/private/var/…" as "/var/…"); nil when it cannot be resolved.
    private static func shownRealPath(_ path: String) -> String? {
        guard let resolved = realPath(path) else { return nil }
        let privatePrefix = "/private/"
        if resolved.hasPrefix(privatePrefix) {
            let shown = String(resolved.dropFirst(privatePrefix.count - 1))
            if realPath(shown) == resolved { return shown }
        }
        return resolved
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
