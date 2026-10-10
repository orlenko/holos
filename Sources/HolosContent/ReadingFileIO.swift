import CryptoKit
import Darwin
import Foundation
import HolosCore
import HolosSynthesis

/// Publishes a finished reading through `ExclusivePublisher`, the one helper every file of a
/// reading (each rendered part, the finished `.m4a`) is published with: never over a file that
/// is already there, and without needing hard links.
enum ReadingPublisher {
    typealias ExclusiveRename = ExclusivePublisher.ExclusiveRename

    static let systemExclusiveRename: ExclusiveRename = ExclusivePublisher.systemExclusiveRename

    /// See `ExclusivePublisher.publish`.
    static func publish(_ source: URL, to destination: URL,
                        exclusiveRename: ExclusiveRename = systemExclusiveRename, cleanupToken: String? = nil,
                        claimed: (ReadingFileIdentity) throws -> Void = { _ in }) throws {
        try ExclusivePublisher.publish(source, to: destination, exclusiveRename: exclusiveRename,
                                       existing: "Reading output already exists and is not this reading",
                                       cleanupToken: cleanupToken, claimed: claimed)
    }
}

func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 of a file read in 1 MiB chunks, so a book-length file never sits in memory at once.
/// `url` opened for reading with its path as spelled (`FileHandle(forReadingFrom:)` would
/// decompose it; see `RawFilePath`): the output, its join file, and a manifest found through
/// `--output` are in the folder the user typed.
private func rawHandle(_ url: URL) throws -> FileHandle {
    try openRegularFile(url)
}

/// A reading's file could not be opened: why, and the `errno` (`EFTYPE` for one that is not a regular file).
public struct ReadingFileError: LocalizedError, Sendable {
    public let message: String
    public let code: Int32

    public var errorDescription: String? { message }
}

/// `url` opened for reading, its path as spelled (see `RawFilePath`), only when it is a regular file: opened without
/// waiting (`O_NONBLOCK`), so a FIFO or a device put at the path is refused at once instead of blocking the open until
/// a writer comes, and checked on the open descriptor. Every file of a reading that is read (a checksum, a manifest,
/// the index, a saved text, a finished file played) is opened here.
func openRegularFile(_ url: URL, followLinks: Bool = true) throws -> FileHandle {
    let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followLinks ? 0 : O_NOFOLLOW)
    let descriptor = open(RawFilePath.system(url), flags)
    guard descriptor >= 0 else {
        let error = errno
        throw ReadingFileError(message: "Could not read \(url.path): \(String(cString: strerror(error)))", code: error)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw ReadingFileError(message: "Could not read \(url.path): it is not a regular file.", code: EFTYPE)
    }
    // Reads of a regular file never wait anyway; blocking reads again, as the callers expect.
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

/// The file's SHA-256. `isCancelled` is asked between chunks (default: the current task's cancellation), so a Stop
/// ends a long checksum on a slow drive with `CancellationError` instead of reading the whole file.
func fileSHA256(_ url: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> String {
    let handle = try rawHandle(url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        if isCancelled() { throw CancellationError() }
        let done = try autoreleasepool { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
            hasher.update(data: chunk)
            return false
        }
        if done { break }
    }
    return hex(hasher.finalize())
}

/// `fileSHA256` off the main actor, where `ReadingPipeline` runs: a rendered part or a finished reading is megabytes,
/// and a resume checks every part, which would stall the app's window. The caller's cancellation reaches the checksum
/// (checked between chunks), and a cancelled caller gets `CancellationError` even when the checksum had finished.
func fileSHA256OffMain(_ url: URL) async throws -> String {
    let checksum = try await offMain { try fileSHA256(url) }
    try Task.checkCancellation()
    return checksum
}

/// Runs `work` off the main actor (a detached task), with the caller's cancellation passed on to it and the test
/// stand-ins the reading's file code reads (task-locals, which a detached task does not inherit) carried over.
public func offMain<Result: Sendable>(priority: TaskPriority = .userInitiated,
                                      _ work: @escaping @Sendable () throws -> Result) async throws -> Result {
    let volume = RawFilePath.volume
    let volumes = ReadingOutput.volumesFolder
    let nameLimit = ReadingOutput.volumeNameLimit
    let lockCall = ReadingDirectoryLock.lockCall
    let takeoverStep = ReadingOutputReservation.takeoverStep
    let task = Task.detached(priority: priority) {
        try RawFilePath.$volume.withValue(volume) {
            try ReadingOutput.$volumesFolder.withValue(volumes) {
                try ReadingOutput.$volumeNameLimit.withValue(nameLimit) {
                    try ReadingDirectoryLock.$lockCall.withValue(lockCall) {
                        try ReadingOutputReservation.$takeoverStep.withValue(takeoverStep) { try work() }
                    }
                }
            }
        }
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// The contents of a file expected to be small; a larger one is an error, not read whole.
func readSmallFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let handle = try rawHandle(url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
        throw HolosError.invalidInput("\(url.path) is larger than \(maximumBytes) bytes.")
    }
    return data
}

func save(_ manifest: ReadingManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try atomicWrite(encoder.encode(manifest), to: url)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(ReadingTemporaries.manifestName())
    try data.write(to: temporary, options: [.withoutOverwriting])
    if rename(temporary.path, url.path) != 0 {
        let message = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: temporary)
        throw HolosError.io("Could not save reading metadata: \(message)")
    }
}
