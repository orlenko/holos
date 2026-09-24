import Foundation
import Darwin
import HolosCore

/// Free space on a volume, injectable for tests (docs/meeting-design.md §4.5).
public protocol FreeSpaceProvider: Sendable {
    /// Bytes available to this user on the volume that holds `url`. A path that does not exist yet is
    /// measured on the volume of its nearest existing ancestor.
    func availableBytes(at url: URL) throws -> Int64
}

/// Measures the real volume with `statfs`: `f_bavail × f_bsize`.
public struct VolumeFreeSpace: FreeSpaceProvider {
    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        guard url.isFileURL else { throw HolosError.invalidInput("Free space needs a file URL.") }
        var candidate = url.standardizedFileURL
        while true {
            var info = statfs()
            if statfs(candidate.path, &info) == 0 {
                let blocks = Int64(clamping: info.f_bavail)
                let blockSize = Int64(clamping: info.f_bsize)
                let (bytes, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
                return overflow ? .max : bytes
            }
            let code = errno
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard code == ENOENT || code == ENOTDIR, parent.path != candidate.path else {
                throw HolosError.io("Cannot measure free space: \(AtomicFile.errnoText(code)).")
            }
            candidate = parent
        }
    }
}

/// A fixed answer, for tests and for dependency bundles that must not touch the disk.
public struct FixedFreeSpace: FreeSpaceProvider {
    public let bytes: Int64

    public init(_ bytes: Int64) { self.bytes = bytes }

    public func availableBytes(at url: URL) throws -> Int64 { bytes }
}
