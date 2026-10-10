import Foundation
import HolosCore
import HolosSynthesis

extension ReadingLibrary {
    /// What a made reading's file is now, as its row shows it (see `fileStatus`).
    public enum FileStatus: Sendable, Equatable {
        /// Its file is there, the one it made (by identity); `size` in bytes.
        case available(size: Int64?)
        /// A regular file is at its path, but its identity is not the one recorded (or none was): it may still be the
        /// reading's file (a share mounted again gets a new device number; see `ExclusivePublisher.FileIdentity`),
        /// which only its checksum tells (`revalidate`). `found` is the file there, as it was then.
        case changed(found: FileVersion)
        /// Nothing (or no regular file) is at its path: it was moved or deleted.
        case missing
        /// The folder that holds it cannot be reached (its drive or share is not connected, or it answers with an
        /// error): the file may come back.
        case unavailable(String)
    }

    /// A file as it was at one moment: which file (its identity), and its size and last change, so a checksum read
    /// while it was being written (a file copied back into place) is known for what it is.
    public struct FileVersion: Sendable, Equatable {
        public let identity: ReadingFileIdentity
        public let size: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64

        /// The regular file at `url` now (a link is not followed); nil when nothing is there or it is not a regular
        /// file. Any other failure throws.
        static func of(_ url: URL) throws -> FileVersion? {
            guard let identity = try ExclusivePublisher.FileIdentity.lookup(url) else { return nil }
            var metadata = stat()
            guard lstat(RawFilePath.system(url), &metadata) == 0 else {
                let error = errno
                if error == ENOENT { return nil }
                throw HolosError.io("Could not check \(url.path): \(String(cString: strerror(error)))")
            }
            return FileVersion(identity: identity, size: Int64(metadata.st_size),
                               modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
                               modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
        }
    }

    /// The status of a made reading's file, from its metadata alone (the file is not read). Not on the main actor: a
    /// look-up on a share whose server stopped answering waits for its timeout.
    public static func fileStatus(of entry: ReadingEntry) -> FileStatus {
        guard let output = entry.outputURL else { return .missing }
        let found: FileVersion?
        do {
            found = try FileVersion.of(output)
        } catch {
            return .unavailable("\((output.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) "
                + "cannot be reached (\(error.localizedDescription))")
        }
        guard let found else { return ReadingOutput.unreachableReason(for: output).map { .unavailable($0) } ?? .missing }
        guard let made = entry.outputIdentity, made == found.identity else { return .changed(found: found) }
        return .available(size: found.size)
    }

    /// What reading a changed file's checksum found (see `revalidate`).
    public enum Revalidation: Sendable, Equatable {
        /// It is the reading's file: the identity to record.
        case same(ReadingFileIdentity)
        /// Another file (its checksum is not the reading's).
        case different
        /// It could not be told (the file could not be read, or it changed during the check): try again later.
        case unknown
    }

    /// Whether the file whose status is `.changed(found)` is the made reading's: `.same` with its identity when its
    /// checksum is the reading's. Either answer holds only when the file is still `found` (the same file, size, and
    /// last change) after the check: one written meanwhile is `.unknown`. Reads the whole file: not on the main
    /// actor; a cancelled task stops between chunks (`.unknown`).
    public static func revalidate(_ entry: ReadingEntry, found: FileVersion) -> Revalidation {
        guard let output = entry.outputURL, let sha256 = entry.outputSHA256 else { return .different }
        let checksum: String
        do {
            checksum = try fileSHA256(output)
        } catch {
            return .unknown
        }
        guard (try? FileVersion.of(output)) == found else { return .unknown }
        return checksum == sha256 ? .same(found.identity) : .different
    }

    /// The file at `output` opened for reading when the object opened is the one `identity` names (checked on the
    /// open descriptor, not the path): an action that reads through it (Play, Share…) uses that very file, whatever
    /// is put at the path at any moment. Nil when it is not there, not a regular file, or another file. Opened without
    /// waiting (see `openRegularFile`): a FIFO or a device put at the path is refused at once. Not on the main actor:
    /// an open on a share whose server stopped answering waits for its timeout.
    public static func openVerified(_ output: URL, identity: ReadingFileIdentity) -> FileHandle? {
        guard let handle = try? openRegularFile(output, followLinks: false),
              ExclusivePublisher.FileIdentity.of(descriptor: handle.fileDescriptor) == identity else { return nil }
        return handle
    }
}
