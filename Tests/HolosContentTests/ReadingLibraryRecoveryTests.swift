import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

/// The Reading list's storage when things go wrong: a support folder out of reach, an index too large, saves a crash cut
/// off, special files, shares mounted again, names that do not fit, and output folders reached through links.
@Suite struct ReadingLibraryRecoveryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func entry(_ state: ReadingEntry.State) -> ReadingEntry {
        var entry = ReadingEntry(source: .web(URL(string: "https://www.example.com/story")!), requestedVoice: nil,
                                 speed: 1)
        entry.state = state
        return entry
    }

    /// An index in a folder on a drive that is not connected is not an empty list: it is unavailable, never written,
    /// until the folder is back, and then the list there is read whole.
    @Test func anIndexOnADisconnectedDriveIsNeverTakenForAnEmptyList() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: false)
        let library = volumes.appendingPathComponent("Backup/Support/ReadingLibrary", isDirectory: true)
        let store = ReadingLibraryStore(folder: library)
        ReadingOutput.$volumesFolder.withValue(volumes.path) {
            let loaded = store.load()
            #expect(loaded.unavailable)
            #expect(!loaded.writable)
            #expect(loaded.entries.isEmpty)
            #expect(loaded.notice?.contains("unavailable") == true)
            #expect(ReadingLibrary.launchPlan(loaded).entries.isEmpty)
            // Nothing is written in its place.
            #expect(throws: (any Error).self) { try store.save([entry(.done)]) }
            #expect(!FileManager.default.fileExists(atPath: volumes.appendingPathComponent("Backup").path))
        }
        // Connected (outside the Volumes stand-in, nothing is out of reach): the list there is read.
        let saved = [entry(.done)]
        try store.save(saved)
        let back = store.load()
        #expect(!back.unavailable)
        #expect(back.writable)
        #expect(back.entries == saved)
    }

    /// An index larger than `load` reads is never saved: the one there stays, and the next launch reads it. A save
    /// that adds a reading stops at half that, so a full list can still be changed (a Delete marks its reading first,
    /// which makes the index larger) and read back.
    @Test func anIndexTooLargeToReadIsNotSaved() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var small = [entry(.done)]
        let bytes = try JSONEncoder.reading.encode(
            ReadingIndex(kind: ReadingIndex.kind, schemaVersion: ReadingIndex.currentSchemaVersion, entries: small)).count
        let store = ReadingLibraryStore(folder: root, maximumBytes: bytes + 16)
        try store.save(small, growing: true)
        #expect(throws: (any Error).self) { try store.save(small + [entry(.failed)], growing: true) }
        #expect(throws: (any Error).self) { try store.save(small + [entry(.done), entry(.failed), entry(.done)]) }
        #expect(store.load().entries == small)
        // Marked for deletion: larger than a growing save may write, still read back.
        small[0].deletePending = true
        small[0].message = String(repeating: "m", count: 20)
        try store.save(small)
        let loaded = store.load()
        #expect(loaded.entries == small)
        #expect(loaded.writable)
        #expect(loaded.notice == nil)
    }

    /// A save writes over only the index this store read or last wrote: one put at its place since (another disk
    /// mounted at the support folder's path) is kept, and the save fails.
    @Test func anIndexReplacedSinceItWasReadIsNotWrittenOver() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root)
        let mine = [entry(.done)]
        try store.save(mine)
        #expect(store.load().entries == mine)
        try store.save(mine + [entry(.failed)])
        // Another list takes its place.
        let theirs = [entry(.stopped)]
        let other = ReadingLibraryStore(folder: root.appendingPathComponent("Other"))
        try other.save(theirs)
        try FileManager.default.removeItem(at: store.indexURL)
        try FileManager.default.moveItem(at: other.indexURL, to: store.indexURL)
        #expect(throws: (any Error).self) { try store.save(mine) }
        #expect(ReadingLibraryStore(folder: root).load().entries == theirs)
        // Read again, it is the list this store saves.
        #expect(store.load().entries == theirs)
        try store.save(theirs + mine)
        #expect(store.load().entries == theirs + mine)
    }

    /// An index that cannot be read now (an I/O error, a permission) is read again later (`unavailable`), never
    /// replaced meanwhile.
    @Test func anIndexThatCannotBeReadIsReadAgainLater() throws {
        let root = try folder()
        let library = root.appendingPathComponent("ReadingLibrary")
        defer {
            _ = chmod(library.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ReadingLibraryStore(folder: library)
        let saved = [entry(.done)]
        try store.save(saved)
        #expect(chmod(library.path, 0) == 0)
        guard getuid() != 0 else { return }
        let loaded = store.load()
        #expect(loaded.unavailable)
        #expect(!loaded.writable)
        #expect(chmod(library.path, 0o755) == 0)
        #expect(store.load() == .init(entries: saved, notice: nil, writable: true))
    }

    /// Saves a quit or a crash cut off leave temporaries: the launch removes the index's and the texts', Delete removes
    /// its reading's, and nothing else is touched.
    @Test func temporariesLeftBySavesAreRemoved() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root)
        let (kept, deleted) = (UUID(), UUID())
        let document = ReadableDocument(sections: [.init(paragraphs: ["Text."])])
        try store.saveDocument(document, for: kept)
        try store.saveDocument(document, for: deleted)
        let documents = store.documentURL(kept).deletingLastPathComponent()
        let indexTemporary = root.appendingPathComponent(".library.json.\(UUID().uuidString).tmp")
        let keptTemporary = documents.appendingPathComponent(".\(kept.uuidString).json.\(UUID().uuidString).tmp")
        let deletedTemporary = documents.appendingPathComponent(".\(deleted.uuidString).json.\(UUID().uuidString).tmp")
        let unrelated = [root.appendingPathComponent(".notes.txt.\(UUID().uuidString).tmp"),
                         root.appendingPathComponent(".library.json.not-a-uuid.tmp"),
                         documents.appendingPathComponent("\(kept.uuidString).json.tmp")]
        for url in [indexTemporary, keptTemporary, deletedTemporary] + unrelated { try Data("x".utf8).write(to: url) }

        try store.removeDocument(for: deleted)
        #expect(!FileManager.default.fileExists(atPath: deletedTemporary.path))
        #expect(FileManager.default.fileExists(atPath: keptTemporary.path))
        #expect(try store.document(for: kept) == document)

        store.sweepTemporaries()
        for url in [indexTemporary, keptTemporary] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        for url in unrelated { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(try store.document(for: kept) == document)
        #expect(ReadingLibraryStore.temporaryTarget(".library.json.\(UUID().uuidString).tmp") == "library.json")
        #expect(ReadingLibraryStore.temporaryTarget(".library.json.tmp") == nil)
    }

    /// A FIFO (or any special file) put where a reading's file, text, or index is is refused at once, never waited on.
    @Test func specialFilesAreRefusedWithoutWaiting() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(output))
        try FileManager.default.removeItem(at: output)
        #expect(mkfifo(output.path, 0o600) == 0)
        #expect(ReadingLibrary.openVerified(output, identity: identity) == nil)
        #expect(throws: (any Error).self) { try fileSHA256(output) }
        #expect(ReadingLibrary.verifiedIdentity(of: output, sha256: String(repeating: "0", count: 64)) == nil)
        var made = entry(.done)
        made.output = output.path
        made.outputIdentity = identity
        #expect(ReadingLibrary.fileStatus(of: made) == .missing)
        let source = root.appendingPathComponent("Notes.txt")
        #expect(mkfifo(source.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try DocumentLoader.load(source) }

        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let id = UUID()
        try FileManager.default.createDirectory(at: store.documentURL(id).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(mkfifo(store.documentURL(id).path, 0o600) == 0)
        #expect(throws: (any Error).self) { try store.document(for: id) }
        #expect(mkfifo(store.indexURL.path, 0o600) == 0)
        let loaded = store.load()
        #expect(!loaded.writable)
        #expect(loaded.notice != nil)
    }

    /// A share mounted again gets a new device number: the file there no longer matches the identity recorded, but
    /// its checksum shows it is the reading's, and its identity is recorded anew; another file at its path is not.
    @Test func aFileWhoseIdentityChangedIsTheReadingsOnlyByItsChecksum() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("finished audio".utf8).write(to: output)
        let current = try #require(ExclusivePublisher.FileIdentity.of(output))
        var made = entry(.done)
        made.output = output.path
        made.outputSHA256 = try fileSHA256(output)
        made.outputIdentity = current
        #expect(ReadingLibrary.fileStatus(of: made) == .available(size: 14))

        // Recorded on another mount of its volume (another device number, no volume UUID then).
        var metadata = stat()
        #expect(lstat(output.path, &metadata) == 0)
        metadata.st_dev &+= 1
        made.outputIdentity = ExclusivePublisher.FileIdentity(metadata)
        guard case .changed(let found) = ReadingLibrary.fileStatus(of: made) else {
            Issue.record("A file whose identity changed should be checked")
            return
        }
        guard case .same(let renewed) = ReadingLibrary.revalidate(made, found: found) else {
            Issue.record("The reading's own file should be recognized by its checksum")
            return
        }
        #expect(renewed == current)
        made.outputIdentity = renewed
        #expect(ReadingLibrary.fileStatus(of: made) == .available(size: 14))

        // Another file put at its path: its checksum is not the reading's.
        try FileManager.default.removeItem(at: output)
        try Data("someone else's".utf8).write(to: output)
        guard case .changed(let other) = ReadingLibrary.fileStatus(of: made) else {
            Issue.record("Another file should not match the identity recorded")
            return
        }
        #expect(ReadingLibrary.revalidate(made, found: other) == .different)
        // One that cannot be read is not told apart: checked again later.
        #expect(chmod(output.path, 0) == 0)
        if getuid() != 0 { #expect(ReadingLibrary.revalidate(made, found: other) == .unknown) }
        #expect(chmod(output.path, 0o644) == 0)
        try FileManager.default.removeItem(at: output)
        #expect(ReadingLibrary.fileStatus(of: made) == .missing)
    }

    /// A checksum read while the file changed (one being copied back into place) says nothing: the file is read again
    /// once it is a new version (another size or last change).
    @Test func aChecksumReadWhileTheFileChangedIsReadAgain() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("finished".utf8).write(to: output)
        var made = entry(.done)
        made.output = output.path
        made.outputSHA256 = try fileSHA256(output)
        guard case .changed(let partial) = ReadingLibrary.fileStatus(of: made) else {
            Issue.record("A reading without a recorded identity should be checked")
            return
        }
        // Written to after the status was read: what was read is not that version.
        let handle = try FileHandle(forWritingTo: output)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" audio".utf8))
        try handle.close()
        #expect(ReadingLibrary.revalidate(made, found: partial) == .unknown)
        guard case .changed(let complete) = ReadingLibrary.fileStatus(of: made) else {
            Issue.record("The file should still be checked")
            return
        }
        #expect(complete != partial)
        #expect(ReadingLibrary.revalidate(made, found: complete) == .different)
    }

    /// A made reading's file edited in place keeps the identity of the copy that made it: even with that identity
    /// still in the cache's manifest (its last save failed), Delete leaves it, never removes it as a partly written
    /// copy.
    @Test func aMadeReadingsEditedFileIsNeverTakenForAPartialCopy() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        try Data("finished audio".utf8).write(to: output)
        let checksum = try fileSHA256(output)
        let manifest = ReadingManifest(
            kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
            sourceSHA256: "s", voiceIdentifier: "v", rate: nil, title: "Story", author: nil, language: nil,
            comment: "c", format: .current, output: output.path, outputSHA256: checksum, duration: nil, chapters: [],
            status: "incomplete", parts: [], publishing: ExclusivePublisher.FileIdentity.of(output))
        try JSONEncoder().encode(manifest).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
        // Edited in place: the same file, other bytes.
        let handle = try FileHandle(forWritingTo: output)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        reading.outputSHA256 = checksum
        #expect(try ReadingLibrary.ownership(of: output, sha256: checksum, cache: cache, made: true) == nil)
        let result = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            Issue.record("Trashed an edited file")
        }
        #expect(result.problem == nil)
        #expect(result.note?.contains("changed since it was made") == true)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    /// An output path whose file would not fit `PATH_MAX` once moved into the folder beside it that removals go
    /// through is refused before anything is made.
    @Test func anOutputPathCountsTheFolderItIsRemovedThrough() {
        let deep = "/" + String(repeating: "f", count: 900)
        #expect(throws: HolosError.self) {
            try ReadingOutput.checkPathLength(URL(fileURLWithPath: deep + "/x.m4a"))
        }
        #expect(throws: Never.self) {
            try ReadingOutput.checkPathLength(URL(fileURLWithPath: "/" + String(repeating: "f", count: 700) + "/x.m4a"))
        }
    }

    /// The fallback name used once every numbered name is taken fits the volume's 255-byte name limit, whatever the
    /// title's script.
    @Test func theLastResortNameFitsTheNameLimit() {
        let folder = URL(fileURLWithPath: "/Readings", isDirectory: true)
        let title = String(repeating: "読", count: 100)
        let chosen = ReadingLibrary.outputURL(in: folder, title: title, fallback: nil, taken: []) { url in
            // Every numbered name ("読…読.m4a", "読…読 2.m4a" … "読…読 999.m4a") is taken on disk; the fallback is free.
            let words = url.lastPathComponent.dropLast(4).split(separator: " ")
            return words.count == 1 || words[1].count <= 3
        }
        let name = chosen.lastPathComponent
        #expect(name.hasSuffix(".m4a"))
        #expect(name.hasPrefix("読"))
        #expect(ReadingOutput.fits(name))
        #expect(name.utf8.count <= 255)
    }

    /// An output folder reached through a link names the same files as its real path, which the list saves: a name
    /// another reading will write there is taken, and so is a render cache another reading holds.
    @Test func namesAndCachesTakenThroughALinkedFolderAreNotReused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: false)
        let resolved = try #require(realpath(real.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        // Another reading (stopped before its file was made) will write "Story.m4a" in the real folder.
        let taken = resolved + "/Story.m4a"
        let chosen = ReadingLibrary.outputURL(in: linked, title: "Story", fallback: nil, taken: [taken]) { _ in false }
        #expect(chosen.lastPathComponent == "Story 2.m4a")

        // Its render cache is the one the same text and settings reach through "Story.m4a": never shared.
        let first = try ReadingLibrary.location(
            chosen: nil, folder: { linked }, title: "Story", fallback: nil, name: "Story.m4a", identity: "i",
            readingsRoot: readings, taken: [], otherCaches: [])
        #expect(first.output.lastPathComponent == "Story.m4a")
        let second = try ReadingLibrary.location(
            chosen: ReadingOutput.fileURL(keepingSpelling: taken), folder: { linked }, title: "Story", fallback: nil,
            name: "Story.m4a", identity: "i", readingsRoot: readings, taken: [],
            otherCaches: [first.workDirectory.path])
        #expect(second.output.lastPathComponent == "Story 2.m4a")
        #expect(second.workDirectory != first.workDirectory)
    }

    /// Delete removes what its render left beside the output (joined files a quit or a crash cut off) and a partly
    /// written file its render moved aside to remove (the place derived from its cache).
    @Test func deleteRemovesWhatItsRenderLeftBesideTheOutput() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        let key = ReadingTemporaries.key(for: cache)
        let join = root.appendingPathComponent(ReadingTemporaries.joinName(key: key, run: UUID()))
        try Data("joined".utf8).write(to: join)
        // A copy of a joined file whose removal a crash cut off (see `AudioBookWriter.cleanupToken`).
        let joinName = ReadingTemporaries.joinName(key: key, run: UUID())
        let joinAside = root.appendingPathComponent(try #require(AudioBookWriter.cleanupToken(for: joinName)))
        try FileManager.default.createDirectory(at: joinAside, withIntermediateDirectories: false)
        try Data("joined".utf8).write(to: joinAside.appendingPathComponent(joinName))
        // Another reading's is left alone.
        let otherJoin = root.appendingPathComponent(ReadingTemporaries.joinName(key: "0000000000000000", run: UUID()))
        try Data("theirs".utf8).write(to: otherJoin)
        let aside = ReadingTemporaries.publicationAside(output: output, key: key)
        try FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: aside)
        let manifest = ReadingManifest(
            kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
            sourceSHA256: "s", voiceIdentifier: "v", rate: nil, title: "Story", author: nil, language: nil,
            comment: "c", format: .current, output: output.path, outputSHA256: nil, duration: nil, chapters: [],
            status: "incomplete", parts: [], publishing: ExclusivePublisher.FileIdentity.of(aside))
        try JSONEncoder().encode(manifest).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
        var reading = entry(.stopped)
        reading.output = output.path
        reading.cache = cache.path
        let result = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            Issue.record("Trashed a partly written file")
        }
        #expect(result == .init())
        // The joined files and the places aside are gone; the Readings folder (and its lock) and the other reading's
        // joined file are left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            == ["Readings", otherJoin.lastPathComponent].sorted())
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// A reading whose render got to joining (every part rendered) may have left a joined file beside its output:
    /// while that folder cannot be reached, Delete keeps the reading (and the cache that names the file). One that
    /// never got there has nothing to leave, and is deleted.
    @Test func deleteWaitsForAnUnreachableFolderOnlyWhereAJoinCouldBe() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: false)
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = volumes.appendingPathComponent("Backup/Readings/Story.m4a")
        func reading(allRendered: Bool) throws -> ReadingEntry {
            let cache = readings.appendingPathComponent("Output-\(allRendered ? "0" : "1")123456789abcdef",
                                                        isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let part = ReadingPart(index: 0, sourceUTF16Offset: 0, sourceUTF16Length: 1, textSHA256: "t",
                                   relativeAudioPath: "parts/part0001.caf", chapter: nil, startsSection: false,
                                   status: allRendered ? "complete" : "pending")
            let manifest = ReadingManifest(
                kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                sourceSHA256: "s", voiceIdentifier: "v", rate: nil, title: "Story", author: nil, language: nil,
                comment: "c", format: .current, output: output.path, outputSHA256: nil, duration: nil, chapters: [],
                status: "incomplete", parts: [part])
            try JSONEncoder().encode(manifest).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
            var reading = entry(.stopped)
            reading.output = output.path
            reading.cache = cache.path
            return reading
        }
        let joined = try reading(allRendered: true)
        let started = try reading(allRendered: false)
        let (joinedCache, startedCache) = (try #require(joined.cache), try #require(started.cache))
        ReadingOutput.$volumesFolder.withValue(volumes.path) {
            let kept = ReadingLibrary.deleteFiles(of: joined, readingsRoot: readings, store: store) { _ in }
            #expect(kept.problem?.contains("unavailable") == true)
            #expect(FileManager.default.fileExists(atPath: joinedCache))
            let deleted = ReadingLibrary.deleteFiles(of: started, readingsRoot: readings, store: store) { _ in }
            #expect(deleted.problem == nil)
            #expect(!FileManager.default.fileExists(atPath: startedCache))
        }
    }
}
