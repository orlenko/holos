import Darwin
import Foundation
import HolosCore
import HolosSynthesis

/// The names of the temporary files a reading creates, and the removal of ones an interrupted run
/// left behind. Each name carries a marker only this reading's runs use, so a sweep never touches
/// another reading's (or anyone else's) files:
/// - beside the output: `.holos-join-<reading key>-<run UUID>.m4a`, the joined file before it is
///   published, and `.holos-join-<reading key>-<run UUID>-<UUID>.m4a`, the temporary
///   `AudioBookWriter` encodes it into. The key is a hash of the cache directory, whose lock
///   serializes runs, so one with another run's UUID is left over from an earlier run;
/// - in the cache: `.holos-manifest-<UUID>.tmp`, a manifest being saved;
/// - in the cache's `parts`: `.holos-<UUID>.<ext>` from the speech renderer and
///   `.invalid-<UUID>-<part>`, a part that failed its checksum.
enum ReadingTemporaries {
    static let joinPrefix = ".holos-join-"
    static let manifestPrefix = ".holos-manifest-"
    static let manifestSuffix = ".tmp"
    static let rendererPrefix = ".holos-"
    static let invalidPrefix = ".invalid-"

    static func key(for directory: URL) -> String { String(ReadingDirectoryLock.key(for: directory).prefix(16)) }

    /// The private folder beside the output that the reading's partly written file is moved into to be removed
    /// (see `ExclusivePublisher.removeVerified`), when a publication fails or a resume removes a copy a crash cut off:
    /// `.holos-delete-<reading key>.publish`. Derived from the cache, so a removal a crash cut off after the move is
    /// found there by the next resume or Delete (see `recoverPublicationAside`).
    static func publicationToken(key: String) -> String { ExclusivePublisher.removalPrefix + key + ".publish" }

    /// Where `publicationToken`'s folder keeps the partly written file of `output`.
    static func publicationAside(output: URL, key: String) -> URL {
        RawFilePath.appending(output.lastPathComponent, to: RawFilePath.appending(
            publicationToken(key: key), to: output.deletingLastPathComponent()))
    }

    /// Finishes a removal of the reading's partly written file that a crash cut off after it was moved aside: the
    /// file in `publicationAside` goes when it is that file (`identity`, the manifest's `publishing`), then the
    /// folder. Anything else there (another file, or one that cannot be checked) is an error and is left: the place
    /// is only the reading's, so a later removal must not find it taken.
    static func recoverPublicationAside(output: URL, key: String, evidence: ReadingLibrary.Evidence) throws {
        let file = publicationAside(output: output, key: key)
        let folder = file.deletingLastPathComponent()
        guard try ReadingOutput.exists(folder) else { return }
        if try ReadingOutput.exists(file) {
            guard try evidence.isPartial(file) else {
                throw HolosError.io("\(file.path) was left by an earlier try to save this reading, and it is not the "
                    + "reading's partly written file. Move it away or remove it in Finder, then try again.")
            }
            try ExclusivePublisher.removeFile(file)
        }
        guard rmdir(RawFilePath.system(folder)) == 0 || errno == ENOENT else {
            throw HolosError.io("\(folder.path), left by an earlier try to save this reading, could not be removed: "
                + String(cString: strerror(errno)) + ". Remove it in Finder, then try again.")
        }
    }

    static func joinName(key: String, run: UUID) -> String {
        "\(joinPrefix)\(key)-\(run.uuidString).\(ReadingAudioFormat.fileExtension)"
    }

    /// The join file of run `run` beside `output`, in its folder as spelled (see `RawFilePath`).
    static func joinURL(beside output: URL, key: String, run: UUID) -> URL {
        RawFilePath.appending(joinName(key: key, run: run), to: output.deletingLastPathComponent())
    }

    static func manifestName() -> String { "\(manifestPrefix)\(UUID().uuidString)\(manifestSuffix)" }

    /// Removes this reading's temporaries from earlier runs: regular files owned by this user whose
    /// names match exactly, except the current run's.
    static func sweep(workDirectory: URL, outputFolder: URL, key: String, currentRun: UUID) {
        _ = sweepJoins(outputFolder: outputFolder, key: key, currentRun: currentRun)
        remove(in: workDirectory) { name in
            uuid(between: manifestPrefix, and: manifestSuffix, in: name) != nil
        }
        remove(in: workDirectory.appendingPathComponent("parts")) { name in
            if name.hasPrefix(invalidPrefix) {
                let rest = name.dropFirst(invalidPrefix.count)
                guard rest.count > 37, UUID(uuidString: String(rest.prefix(36))) != nil else { return false }
                return rest.dropFirst(36).first == "-"
            }
            guard name.hasPrefix(rendererPrefix), let dot = name.lastIndex(of: ".") else { return false }
            let stem = name[name.index(name.startIndex, offsetBy: rendererPrefix.count)..<dot]
            let ext = name[name.index(after: dot)...]
            return UUID(uuidString: String(stem)) != nil && !ext.isEmpty
                && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The run in a join file's name (`<start><run UUID><end>`), or in the name of the temporary
    /// `AudioBookWriter` encodes it into (`<start><run UUID>-<UUID><end>`); nil for any other name.
    static func joinRun(_ name: String, start: String, end: String) -> UUID? {
        if let run = uuid(between: start, and: end, in: name) { return run }
        guard name.hasPrefix(start), name.hasSuffix(end) else { return nil }
        let middle = name.dropFirst(start.count).dropLast(end.count)
        guard middle.count == 36 + 1 + 36, middle.dropFirst(36).first == "-",
              UUID(uuidString: String(middle.suffix(36))) != nil else { return nil }
        return UUID(uuidString: String(middle.prefix(36)))
    }

    static func uuid(between prefix: String, and suffix: String, in name: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    /// Removes this reading's joined files from runs other than `currentRun` beside the output (see `sweep`), and
    /// the places aside a copy of one was being removed through when a crash came (`.holos-delete-<join name>`, see
    /// `AudioBookWriter.cleanupToken`). Returns what could not be looked at or removed (nil when all is gone), for a
    /// Delete, which keeps the reading until it is.
    static func sweepJoins(outputFolder: URL, key: String, currentRun: UUID) -> String? {
        let start = "\(joinPrefix)\(key)-"
        let end = "." + ReadingAudioFormat.fileExtension
        func isStale(_ name: String) -> Bool { joinRun(name, start: start, end: end).map { $0 != currentRun } ?? false }
        guard let names = RawFilePath.names(in: outputFolder) else {
            let error = errno
            return error == ENOENT ? nil
                : "\(outputFolder.path) could not be looked into: \(String(cString: strerror(error)))."
        }
        var problems: [String] = []
        func unlinkOwn(_ url: URL) {
            let path = RawFilePath.system(url)
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                // Only "not there" is gone: a file that cannot be looked up may still be there.
                if errno != ENOENT {
                    problems.append("\(url.path) could not be checked: \(String(cString: strerror(errno))).")
                }
                return
            }
            guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid() else { return }
            if unlink(path) != 0, errno != ENOENT {
                problems.append("\(url.path) could not be removed: \(String(cString: strerror(errno))).")
            }
        }
        for name in names {
            if isStale(name) {
                unlinkOwn(RawFilePath.appending(name, to: outputFolder))
            } else if name.hasPrefix(ExclusivePublisher.removalPrefix),
                      case let joined = String(name.dropFirst(ExclusivePublisher.removalPrefix.count)), isStale(joined) {
                let folder = RawFilePath.appending(name, to: outputFolder)
                unlinkOwn(RawFilePath.appending(joined, to: folder))
                if rmdir(RawFilePath.system(folder)) != 0, errno != ENOENT {
                    problems.append("\(folder.path) could not be removed: \(String(cString: strerror(errno))).")
                }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// Listed and removed with `folder` spelled as given (see `RawFilePath`).
    private static func remove(in folder: URL, where matches: (String) -> Bool) {
        guard let names = RawFilePath.names(in: folder) else { return }
        for name in names where matches(name) {
            let path = RawFilePath.system(RawFilePath.appending(name, to: folder))
            var metadata = stat()
            guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid() else { continue }
            _ = unlink(path)
        }
    }
}
