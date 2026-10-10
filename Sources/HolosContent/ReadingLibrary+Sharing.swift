import Foundation
import HolosCore

extension ReadingLibrary {
    /// This process's folder for Share… copies inside `base`: `<process ID>-<start time>`, so another copy of the app
    /// running meanwhile never removes the copies it hands to a service.
    public static func sharingFolder(in base: URL) -> URL {
        let pid = getpid()
        return base.appendingPathComponent("\(pid)-\(ReadingOutputReservation.processStart(pid) ?? 0)", isDirectory: true)
    }

    /// Removes the Share… copies of processes that have ended (their services are done with them by now), and those
    /// an earlier build left directly in `base`. Not on the main actor.
    public static func sweepSharingFolders(in base: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            let parts = name.split(separator: "-", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]), let start = Int64(parts[1]),
               ReadingOutputReservation.processStart(pid) == start { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    /// A copy of the open file `file`, named `name`, in a new folder inside `folder`: a clone (instant, no space)
    /// where the volume can, else its bytes. What Share… hands to the services, which read it later.
    public static func copyForSharing(_ file: FileHandle, name: String, into folder: URL) throws -> URL {
        let holder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copy = RawFilePath.appending(name, to: holder)
        if fclonefileat(file.fileDescriptor, AT_FDCWD, RawFilePath.system(copy), 0) == 0 { return copy }
        do {
            let output = open(RawFilePath.system(copy), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw HolosError.io("Could not copy \(name): \(String(cString: strerror(errno)))") }
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            try file.seek(toOffset: 0)
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try writer.close()
            return copy
        } catch {
            // A copy cut off (a full disk) is not left taking space until the next launch.
            try? FileManager.default.removeItem(at: holder)
            throw error
        }
    }
}
