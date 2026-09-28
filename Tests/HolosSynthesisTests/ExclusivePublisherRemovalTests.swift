import Foundation
import Testing
@testable import HolosSynthesis

/// `ExclusivePublisher.removeVerified`: the file is moved aside before it is checked, so a file another process puts
/// at the path after the check is never the one removed.
@Suite struct ExclusivePublisherRemovalTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func theCheckedFileIsRemovedAndNothingIsLeft() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("partial".utf8).write(to: file)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(file))
        #expect(ExclusivePublisher.removeIfIdentical(file, to: identity) == .removed)
        #expect(try names(root).isEmpty)
        #expect(ExclusivePublisher.removeIfIdentical(file, to: identity) == .absent)
    }

    /// Another file put at the path while the checked one is aside (after the check) stays; only the checked one goes.
    @Test func aFilePutAtThePathAfterTheCheckIsKept() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("partial".utf8).write(to: file)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(file))
        let removal = ExclusivePublisher.removeVerified(file, matches: { staged in
            let same = ExclusivePublisher.FileIdentity.of(staged) == identity
            // Another process writes its own file at the path, between the check and the removal.
            try? Data("someone else's".utf8).write(to: file)
            return same
        })
        #expect(removal == .removed)
        #expect(try Data(contentsOf: file) == Data("someone else's".utf8))
        #expect(try names(root) == ["Story.m4a"])
    }

    /// A file that is not the one asked for goes back untouched; when something took its place meanwhile it is kept
    /// aside (never over that file), and the result says where.
    @Test func aFileThatDoesNotMatchGoesBackOrIsKeptAside() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("the user's".utf8).write(to: file)
        let other = ExclusivePublisher.FileIdentity(stat())
        #expect(ExclusivePublisher.removeIfIdentical(file, to: other) == .notMatching(keptAt: nil))
        #expect(try Data(contentsOf: file) == Data("the user's".utf8))
        #expect(try names(root) == ["Story.m4a"])

        let removal = ExclusivePublisher.removeVerified(file, matches: { _ in
            try? Data("newer".utf8).write(to: file)
            return false
        })
        guard case .notMatching(let keptAt?) = removal else {
            Issue.record("Expected the file kept aside, got \(removal)")
            return
        }
        #expect(try Data(contentsOf: file) == Data("newer".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: keptAt)) == Data("the user's".utf8))
        #expect(URL(fileURLWithPath: keptAt).deletingLastPathComponent().lastPathComponent.hasPrefix(ExclusivePublisher.removalPrefix))
    }

    /// On a volume that cannot rename exclusively, a file goes back only through a hard link (which fails when
    /// anything is at the path), never a plain rename over what is there; without links it stays aside.
    @Test func restoringNeverReplacesAFileWhereTheVolumeCannotRenameExclusively() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        let staged = root.appendingPathComponent(ExclusivePublisher.removalPrefix + "x")
        let unsupported: ExclusivePublisher.ExclusiveRename = { _, _ in errno = ENOTSUP; return -1 }
        try Data("audio".utf8).write(to: staged)
        #expect(ExclusivePublisher.restore(staged, to: file, exclusiveRename: unsupported) == nil)
        #expect(try names(root) == ["Story.m4a"])
        #expect(try Data(contentsOf: file) == Data("audio".utf8))

        // Something took the path meanwhile: it stays, and the staged file is kept aside.
        try FileManager.default.moveItem(at: file, to: staged)
        try Data("newer".utf8).write(to: file)
        #expect(ExclusivePublisher.restore(staged, to: file, exclusiveRename: unsupported) == staged.path)
        #expect(try Data(contentsOf: file) == Data("newer".utf8))
        #expect(try Data(contentsOf: staged) == Data("audio".utf8))

        // No hard links either: kept aside even with the path free.
        try FileManager.default.removeItem(at: file)
        let noLinks: (String, String) -> Int32 = { _, _ in errno = ENOTSUP; return -1 }
        #expect(ExclusivePublisher.restore(staged, to: file, exclusiveRename: unsupported, hardLink: noLinks) == staged.path)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// An identity that cannot be looked up is an error, not "nothing there"; and a file that cannot be looked up is
    /// never removed by identity.
    @Test func anIdentityThatCannotBeLookedUpThrows() throws {
        let root = try folder()
        let inner = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let file = inner.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: file)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(file))
        defer {
            _ = chmod(inner.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try ExclusivePublisher.FileIdentity.lookup(root.appendingPathComponent("None")) == nil)
        #expect(chmod(inner.path, 0) == 0)
        // Root looks into anything; the check only means something as an ordinary user.
        guard getuid() != 0 else { return }
        #expect(throws: (any Error).self) { try ExclusivePublisher.FileIdentity.lookup(file) }
        guard case .failed = ExclusivePublisher.removeIfIdentical(file, to: identity) else {
            Issue.record("A file that could not be looked up was not a failure")
            return
        }
        #expect(chmod(inner.path, 0o755) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A file that cannot be checked is a failure, never "not the one": it goes back, and nothing is removed.
    @Test func aFileThatCannotBeCheckedIsAFailure() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: file)
        struct Unreadable: Error {}
        let removal = ExclusivePublisher.removeVerified(file, matches: { _ in throw Unreadable() })
        guard case .failed(_, nil) = removal else {
            Issue.record("Expected a failure with the file back, got \(removal)")
            return
        }
        #expect(!removal.isGone)
        #expect(try names(root) == ["Story.m4a"])
    }

    /// The file is handed over under its own name in a private folder; one `dispose` refuses goes
    /// back, and the folder is removed either way.
    @Test func theFileIsHandedOverUnderItsNameAndARefusedOneGoesBack() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: file)
        struct Refused: Error {}
        let refused = ExclusivePublisher.removeVerified(file, matches: { _ in true },
                                                        dispose: { _ in throw Refused() })
        guard case .failed(_, nil) = refused else {
            Issue.record("Expected a failure with the file back, got \(refused)")
            return
        }
        #expect(try names(root) == ["Story.m4a"])

        var handed: URL?
        let removal = ExclusivePublisher.removeVerified(file, matches: { _ in true }) { staged in
            handed = staged
            try ExclusivePublisher.removeFile(staged)
        }
        #expect(removal == .removed)
        #expect(handed?.lastPathComponent == "Story.m4a")
        #expect(handed?.deletingLastPathComponent().lastPathComponent.hasPrefix(ExclusivePublisher.removalPrefix) == true)
        #expect(try names(root).isEmpty)
    }

    /// A file's identity names its volume by UUID where it has one, so it is the same file on another mount of that
    /// volume (a new device number); without a UUID on both sides, the device number decides.
    @Test func identitiesCompareByVolumeUUIDAcrossMounts() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: file)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(file))
        // The startup disk (APFS) has a volume UUID.
        #expect(identity.volume != nil)
        let handle = try FileHandle(forReadingFrom: file)
        #expect(ExclusivePublisher.FileIdentity.of(descriptor: handle.fileDescriptor) == identity)
        try handle.close()

        var metadata = stat()
        #expect(lstat(file.path, &metadata) == 0)
        let (device, other) = (metadata.st_dev, metadata.st_dev &+ 1)
        metadata.st_dev = other
        #expect(ExclusivePublisher.FileIdentity(metadata, volume: "A") == ExclusivePublisher.FileIdentity(metadata, volume: "A"))
        let remounted = ExclusivePublisher.FileIdentity(metadata, volume: "A")
        metadata.st_dev = device
        #expect(ExclusivePublisher.FileIdentity(metadata, volume: "A") == remounted)
        #expect(ExclusivePublisher.FileIdentity(metadata, volume: "B") != remounted)
        #expect(ExclusivePublisher.FileIdentity(metadata) != remounted)
        #expect(ExclusivePublisher.FileIdentity(metadata) == ExclusivePublisher.FileIdentity(metadata, volume: "A"))
        // Saved by an earlier build (no volume): it still decodes.
        let old = Data(#"{"device":1,"inode":2,"birthSeconds":3,"birthNanoseconds":4}"#.utf8)
        let decoded = try JSONDecoder().decode(ExclusivePublisher.FileIdentity.self, from: old)
        #expect(decoded.volume == nil)
        #expect(decoded.inode == 2)
    }

    /// A failed copy whose partly written file cannot be confirmed removed says so, naming the file's identity, so the
    /// caller keeps it; a confirmed removal is the plain failure.
    @Test func aPartialCopyThatCouldNotBeRemovedIsReported() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".source.m4a")
        let destination = root.appendingPathComponent("Story.m4a")
        let unsupported: ExclusivePublisher.ExclusiveRename = { _, _ in errno = ENOTSUP; return -1 }
        struct Refused: Error {}
        try Data("audio".utf8).write(to: source)
        do {
            try ExclusivePublisher.publish(source, to: destination, exclusiveRename: unsupported, existing: "exists",
                                           isCancelled: { false }, pacing: .init(),
                                           remove: { _, _, _ in .failed(reason: "No space left on device.", keptAt: nil) },
                                           claimed: { _ in throw Refused() })
            Issue.record("The publication should fail")
        } catch let failure as ExclusivePublisher.CleanupFailed {
            #expect(failure.underlying is Refused)
            #expect(ExclusivePublisher.FileIdentity.of(destination) == failure.identity)
            #expect(failure.localizedDescription.contains("No space left"))
        }
        try FileManager.default.removeItem(at: destination)

        // With a token, the partial file goes through that place aside; a place already taken keeps the file.
        let token = ExclusivePublisher.removalPrefix + "test.publish"
        let holding = root.appendingPathComponent(token)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false)
        #expect(throws: ExclusivePublisher.CleanupFailed.self) {
            try ExclusivePublisher.publish(source, to: destination, exclusiveRename: unsupported, cleanupToken: token,
                                           claimed: { _ in throw Refused() })
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.removeItem(at: holding)
        #expect(throws: Refused.self) {
            try ExclusivePublisher.publish(source, to: destination, exclusiveRename: unsupported, cleanupToken: token,
                                           claimed: { _ in throw Refused() })
        }
        #expect(try names(root) == [".source.m4a"])
    }
}
