import Darwin
import Foundation
import HolosCore
import Testing
@testable import HolosSynthesis

// Moving a pack into place on a volume without an exclusive rename, and damaged files that cannot be removed.

@Suite struct NaturalVoiceMoveTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An exclusive rename the volume does not support.
    private let unsupported: (String, String) -> Int32 = { _, _ in
        errno = ENOTSUP
        return -1
    }

    @Test func aVolumeWithoutExclusiveRenameGetsAPlainOneWhenTheDestinationIsFree() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("english.download")
        let directory = root.appendingPathComponent("english")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try NaturalVoiceModels.move(staging, to: directory, what: "into", exclusiveRename: unsupported)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        // A destination already there is never replaced.
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let error = #expect(throws: HolosError.self) {
            try NaturalVoiceModels.move(staging, to: directory, what: "into", exclusiveRename: unsupported)
        }
        #expect(error?.localizedDescription.contains("already exists") == true)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        // Another failure is reported as it is.
        #expect(throws: HolosError.self) {
            try NaturalVoiceModels.move(staging, to: root.appendingPathComponent("x"), what: "into") { _, _ in
                errno = EACCES
                return -1
            }
        }
    }

    @Test func aDamagedFileThatCannotBeRemovedIsSaid() throws {
        let root = try folder()
        defer {
            _ = chmod(root.appendingPathComponent("locked").path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("damaged.bin"))
        try NaturalVoicePackFiles.remove(["damaged.bin"], in: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("damaged.bin").path))
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: locked.appendingPathComponent("weight.bin"))
        #expect(chmod(locked.path, 0o500) == 0)
        let error = #expect(throws: HolosError.self) {
            try NaturalVoicePackFiles.remove(["locked/weight.bin"], in: root)
        }
        #expect(error?.localizedDescription.contains("locked/weight.bin") == true)
    }
}
