import Foundation
import HolosCore
import HolosSynthesis

extension ReadingLibrary {
    /// A reading's file was not found, but the folder that holds it cannot be reached: it may come back.
    public struct OutputUnreachable: LocalizedError, Equatable {
        public let file: String
        /// "the drive or share “Backup” is not connected".
        public let reason: String

        public var errorDescription: String? {
            "\(file) is unavailable: \(reason). Connect it, then try again."
        }
    }

    /// What the file at a reading's output path is to that reading.
    public enum OutputOwnership: Sendable, Equatable {
        /// The finished file it published (its checksum matches the entry's or the cache manifest's).
        case finished
        /// A copy into the destination that a crash cut off, named by the cache manifest's `publishing` identity.
        case partial(ReadingFileIdentity)
    }

    /// Whether the file at `output` is this reading's: the finished file (`sha256`, else the checksum the render
    /// cache's manifest saved for that output), or its own partly copied file (the manifest's `publishing`
    /// identity). Nil for anything else (a file put there since, or nothing there): Delete leaves it alone. Throws
    /// when that cannot be told (the file or the manifest cannot be read), so nothing that identifies it is removed;
    /// `OutputUnreachable` when nothing is found but the folder that holds it cannot be reached (its drive or share
    /// is not connected), and something of the reading's may be there.
    public static func ownership(of output: URL, sha256: String?, cache: URL?, made: Bool = false) throws
        -> OutputOwnership? {
        guard try ReadingOutput.exists(output) else {
            // Not found is "gone" only where the folder can be looked into: a drive that is not connected brings the
            // file back when it is, and the reading must still be there to delete it then. Unless nothing of the
            // reading's can be there (no finished file, no copy begun); a manifest that cannot be read may name one.
            if let reason = ReadingOutput.unreachableReason(for: output) {
                let evidence = try? ownershipEvidence(of: output, sha256: sha256, cache: cache, made: made)
                if evidence.map({ !$0.checksums.isEmpty || $0.publishing != nil }) ?? true {
                    throw OutputUnreachable(file: output.lastPathComponent, reason: reason)
                }
            }
            return nil
        }
        let evidence = try ownershipEvidence(of: output, sha256: sha256, cache: cache, made: made)
        if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(output)) { return .finished }
        // A lookup that fails (not "nothing there") throws: it says nothing about which file is there.
        if let claimed = evidence.publishing, try evidence.isPartial(output) { return .partial(claimed) }
        return nil
    }

    /// What identifies the reading's files (see `ownershipEvidence`).
    struct Evidence: Equatable {
        /// The checksums of its finished file.
        var checksums: [String]
        /// The identity of a copy into the output a crash cut off.
        var publishing: ReadingFileIdentity?
        /// The finished file's size, when known: a copy cut off is smaller.
        var finishedSize: Int64?

        /// Whether the file at `url` is the copy a crash cut off: the file `publishing` names, and smaller than the
        /// finished file when its size is known (one as large is the finished copy, edited in place since: it is
        /// never removed as a partial one). A look-up that fails throws.
        func isPartial(_ url: URL) throws -> Bool {
            guard let publishing, let found = try ReadingLibrary.FileVersion.of(url), found.identity == publishing
            else { return false }
            return finishedSize.map { found.size < $0 } ?? true
        }
    }

    /// What identifies the reading's file at `output`: the checksums of its finished file (`sha256`, and the one
    /// the cache's manifest saved for that output) and the identity of a copy a crash cut off. For a made reading
    /// (`made`) there is no such copy: the copy was finished, so the file with that identity is its finished file,
    /// edited in place when its checksum no longer matches, never a partial one to remove.
    static func ownershipEvidence(of output: URL, sha256: String?, cache: URL?, made: Bool = false) throws
        -> Evidence {
        var manifest: ReadingManifest?
        if let cache {
            let url = cache.appendingPathComponent(ReadingManifest.fileName)
            if try ReadingOutput.exists(url) {  // only "no such file" is no manifest
                // A manifest that is there but cannot be read, is too large, or is not a reading's may hold the
                // only identity of a partly copied file: that is an error, never "not the reading's".
                // Opened without waiting, and read only up to its limit (see `readSmallFile`).
                let saved = try JSONDecoder().decode(
                    ReadingManifest.self, from: try readSmallFile(url, maximumBytes: ReadingManifest.maximumBytes))
                guard saved.kind == ReadingManifest.readingKind else {
                    throw HolosError.io("\(url.path) is not a Voice is Local reading's manifest.")
                }
                // One made for another output says nothing about this file.
                if sameFile(saved.output, output) { manifest = saved }
            }
        }
        return Evidence(checksums: [sha256, manifest?.outputSHA256].compactMap { $0 },
                        publishing: made ? nil : manifest?.publishing, finishedSize: manifest?.outputSize)
    }

    /// The identity of the file at `output` when it is the finished file whose checksum is `sha256`, and the file read
    /// is the file named (the same identity before and after); nil otherwise or when it cannot be read. For a made
    /// reading whose identity could not be recorded when it was made. Reads the whole file: not on the main actor.
    public static func verifiedIdentity(of output: URL, sha256: String) -> ReadingFileIdentity? {
        guard let before = try? ExclusivePublisher.FileIdentity.lookup(output),
              (try? fileSHA256(output)) == sha256,
              (try? ExclusivePublisher.FileIdentity.lookup(output)) == before else { return nil }
        return before
    }

    /// Whether `path` (a manifest's output) names the file `output` names: spelled the same, or, through links in
    /// its folder or another spelling the volume takes for the same name, the same file (`ReadingPathIdentity`,
    /// by exact identity: two names the volume may tell apart are two files).
    static func sameFile(_ path: String, _ output: URL) -> Bool {
        // Compared as bytes: Foundation's paths and Swift's `==` take NFC and NFD spellings for one, which a volume
        // that keeps them apart holds as two files.
        if path.utf8.elementsEqual(output.path.utf8) { return true }
        return ReadingPathIdentity.key(path: path, .exact).utf8.elementsEqual(ReadingPathIdentity.key(output, .exact).utf8)
    }
}
