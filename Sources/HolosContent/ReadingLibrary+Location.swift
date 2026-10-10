import Foundation
import HolosCore
import HolosSynthesis

extension ReadingLibrary {
    /// A new file in `folder` named after the title (see `ReadingOutput.fileName`): "Title.m4a", else "Title 2.m4a",
    /// "Title 3.m4a", …, skipping names another reading of the list will write (`taken`) and names already on disk
    /// (`exists`). A name is taken when it names the same file as one in `taken` through any path: the folders are
    /// compared with their links resolved (an output folder reached through a link, as the list saves the resolved
    /// path), and names without case, as the Mac's volumes compare them. The folder and the name (in NFC, as
    /// `ReadingOutput.fileName` makes it) keep their spelling (see `RawFilePath`). When every numbered name is taken,
    /// "Title 1a2b3c4d.m4a", its stem shortened so that it fits the volume's 255-unit name limit too.
    public static func outputURL(in folder: URL, title: String?, fallback: String?, taken: Set<String>,
                                 exists: (URL) -> Bool) -> URL {
        let suffix = { (text: String) in " \(text).\(ReadingAudioFormat.fileExtension)" }
        func stem(room: Int) -> String {
            let name = ReadingOutput.fileName(title: title, fallback: fallback, limit: ReadingOutput.defaultNameLimit - room)
            return String(name.dropLast(ReadingAudioFormat.fileExtension.count + 1))
        }
        // Room for " 999" in the volume's 255-unit name limit.
        let numbered = stem(room: " 999".utf8.count)
        let takenKeys = Set(taken.map(outputKey))
        func free(_ candidate: URL) -> Bool { !takenKeys.contains(outputKey(candidate.path)) && !exists(candidate) }
        for number in 1...999 {
            let candidate = RawFilePath.appending(number == 1 ? numbered + "." + ReadingAudioFormat.fileExtension
                : numbered + suffix(String(number)), to: folder)
            if free(candidate) { return candidate }
        }
        // Room for " " and eight hex digits.
        let short = stem(room: suffix(String(repeating: "0", count: 8)).utf8.count - ReadingAudioFormat.fileExtension.count - 1)
        var candidate = RawFilePath.appending(short + suffix(String(UUID().uuidString.prefix(8))), to: folder)
        for _ in 0..<8 where !free(candidate) {
            candidate = RawFilePath.appending(short + suffix(String(UUID().uuidString.prefix(8))), to: folder)
        }
        return candidate
    }

    /// One key for every path that names the same output: its folder's links resolved (`ReadingPathIdentity`), then
    /// case and Unicode normalization folded (the conservative rule: two names that may be one file count as one).
    static func outputKey(_ path: String) -> String {
        ReadingPathIdentity.key(path: path, .lock).precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    /// The folder new readings' files go to, checked (see `location`): the default one is made when missing; one
    /// chosen in Settings that is missing (its disk is not connected) is not, so nothing is written on the startup
    /// disk in its place. `shown` is how the folder is named in the message.
    public static func outputFolder(_ folder: URL, isDefault: Bool, shown: String) throws -> URL {
        if isDefault {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            // `stat` on the path as spelled (`FileManager` would decompose it).
            var metadata = stat()
            guard stat(RawFilePath.system(folder), &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.unavailable("The folder \(shown) chosen in Settings › Reading is not available. "
                    + "Connect its disk, or choose another folder there, then Try Again.")
            }
        }
        return folder
    }

    /// Where a reading's file and render cache go when it starts: the file chosen when it first started (`chosen`),
    /// unless something else took that name since (no render cache of this reading, but a file there) or its cache is
    /// another reading's (`otherCaches`); else a new name (see `outputURL`) in `folder()`, never one another reading
    /// of the list writes (`taken`) nor one whose cache is another reading's (the same text, voice, and settings
    /// reach the same cache through the same file: two entries would share, and delete, one another's file).
    /// Checks and creates what `ReadingOutput.locate` does: not on the main actor.
    public static func location(chosen: URL?, folder: () throws -> URL, title: String?, fallback: String?,
                                name: String, identity: String, readingsRoot: URL, taken: [String],
                                otherCaches: [String]) throws -> ReadingLocation {
        let claimedCaches = Set(otherCaches.map(cacheKey))
        func claimed(_ location: ReadingLocation) -> Bool { claimedCaches.contains(cacheKey(location.workDirectory.path)) }
        if let chosen {
            let found = try ReadingOutput.locate(output: chosen.path, name: name, identity: identity,
                                                 readingsRoot: readingsRoot, resume: true)
            if !claimed(found), try ReadingOutput.exists(found.workDirectory) || !ReadingOutput.exists(found.output) {
                return found
            }
        }
        let folder = try folder()
        var taken = Set(taken)
        for _ in 0..<8 {
            let url = outputURL(in: folder, title: title, fallback: fallback, taken: taken) { url in
                (try? ReadingOutput.exists(url)) ?? true
            }
            let location = try ReadingOutput.locate(output: url.path, name: name, identity: identity,
                                                    readingsRoot: readingsRoot, resume: false)
            if !claimed(location) { return location }
            taken.insert(url.path)
        }
        throw HolosError.unavailable("No free name was found for the reading's file in \(folder.path).")
    }

    private static func cacheKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
