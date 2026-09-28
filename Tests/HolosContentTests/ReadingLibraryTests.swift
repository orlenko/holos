import Foundation
import HolosSynthesis
import Testing
@testable import HolosContent

@Suite struct ReadingLibraryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func entry(_ state: ReadingEntry.State, created: TimeInterval = 0, resume: Bool = false) -> ReadingEntry {
        var entry = ReadingEntry(created: Date(timeIntervalSinceReferenceDate: created),
                                 source: .web(URL(string: "https://www.example.com/story")!),
                                 requestedVoice: nil, speed: 1)
        entry.state = state
        entry.resumeOnLaunch = resume
        return entry
    }

    @Test func indexRoundTripsAndStartsEmpty() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        #expect(store.load() == .init(entries: [], notice: nil, writable: true))

        var done = entry(.done, created: 10)
        done.title = "A story — “quoted”"
        done.output = "/Users/me/Music/Voice is Local/Readings/A story.m4a"
        done.duration = 1_234.5
        done.chapters = 3
        done.voiceIdentifier = "com.apple.voice.premium.en-US.Ava"
        done.outputSHA256 = String(repeating: "a", count: 64)
        done.outputIdentity = ExclusivePublisher.FileIdentity.of(root)
        var file = ReadingEntry(source: .file(URL(fileURLWithPath: "/tmp/Paper.pdf")), requestedVoice: "v", speed: 1.2)
        file.state = .failed
        file.message = "No readable text found in Paper.pdf."
        try store.save([done, file])
        let loaded = store.load()
        #expect(loaded.entries == [done, file])
        #expect(loaded.writable)
        #expect(loaded.notice == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: store.indexURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func anUnreadableIndexIsSetAsideAndANewListStarts() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root)
        try Data("{ not json".utf8).write(to: store.indexURL)
        let loaded = store.load()
        #expect(loaded.entries.isEmpty)
        #expect(loaded.writable)
        #expect(loaded.notice?.contains("could not be read") == true)
        #expect(!FileManager.default.fileExists(atPath: store.indexURL.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("library.json.unreadable-") }
        #expect(kept.count == 1)
    }

    @Test func aNewerBuildsIndexIsShownButNotRewritten() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root)
        let known = entry(.done)
        let encoded = try JSONEncoder().encode(known)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["futureField"] = 7
        let unknown: [String: Any] = ["id": UUID().uuidString, "state": "somethingNew"]
        let index: [String: Any] = ["kind": "voiceislocal.reading-library", "schemaVersion": 99,
                                    "entries": [object, unknown]]
        try JSONSerialization.data(withJSONObject: index).write(to: store.indexURL)
        let loaded = store.load()
        #expect(loaded.entries == [known])
        #expect(!loaded.writable)
        #expect(loaded.notice?.contains("newer") == true)
    }

    @Test func documentsAreKeptUntilRemoved() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root)
        let id = UUID()
        #expect(try store.document(for: id) == nil)
        let document = ReadableDocument(title: "Title", author: "Jane", language: "fr",
                                        sections: [.init(heading: "One", level: 2, paragraphs: ["Texte."])])
        #expect(!store.hasDocument(for: id))
        try store.saveDocument(document, for: id)
        #expect(store.hasDocument(for: id))
        #expect(try store.document(for: id) == document)
        try store.removeDocument(for: id)
        #expect(try store.document(for: id) == nil)
        try store.removeDocument(for: id)  // already gone: not an error
        // A saved text that cannot be decoded is an error, never "none saved" (a resume would load the source again).
        try FileManager.default.createDirectory(at: store.documentURL(id).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.documentURL(id))
        #expect(throws: (any Error).self) { try store.document(for: id) }
    }

    @Test func launchContinuesOnlyReadingsKeptOverTheQuitOldestFirst() {
        let running = entry(.rendering, created: 30, resume: true)
        let newer = entry(.queued, created: 50, resume: true)
        let older = entry(.queued, created: 40, resume: true)
        let crashed = entry(.rendering, created: 20)
        let done = entry(.done, created: 10)
        var deleting = entry(.rendering, created: 60, resume: true)
        deleting.deletePending = true
        // The list is newest first.
        let (entries, resume) = ReadingLibrary.afterLaunch([deleting, newer, older, running, crashed, done])
        #expect(resume == [running.id, older.id, newer.id])
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for id in [running.id, newer.id, older.id] {
            #expect(byID[id]?.state == .queued)
            #expect(byID[id]?.resumeOnLaunch == false)
        }
        #expect(byID[crashed.id]?.state == .stopped)
        #expect(byID[crashed.id]?.message?.contains("quit") == true)
        #expect(byID[done.id] == done)
        // A reading marked for deletion is left for the caller to delete, never resumed.
        #expect(byID[deleting.id] == deleting)
    }

    @Test func launchFinishesInterruptedDeletionsButLeavesANewerBuildsListAlone() {
        let running = entry(.rendering, created: 30, resume: true)
        let crashed = entry(.queued, created: 20)
        var deleting = entry(.done, created: 10)
        deleting.deletePending = true
        let list = [running, crashed, deleting]

        let plan = ReadingLibrary.launchPlan(.init(entries: list, notice: nil, writable: true))
        #expect(plan.delete == [deleting])
        #expect(plan.entries.map(\.id) == [running.id, crashed.id])
        #expect(plan.resume == [running.id])
        #expect(plan.entries.last?.state == .stopped)

        let newer = ReadingLibrary.launchPlan(.init(entries: list, notice: "newer", writable: false))
        #expect(newer.entries == list)
        #expect(newer.resume.isEmpty)
        #expect(newer.delete.isEmpty)
    }

    @Test func quittingKeepsOrStopsTheActiveReadings() {
        let list = [entry(.rendering), entry(.queued), entry(.done), entry(.failed)]
        let kept = ReadingLibrary.forQuit(list, keep: true)
        #expect(kept.map(\.resumeOnLaunch) == [true, true, false, false])
        #expect(kept.map(\.state) == [.rendering, .queued, .done, .failed])
        let stopped = ReadingLibrary.forQuit(list, keep: false)
        #expect(stopped.map(\.state) == [.stopped, .stopped, .done, .failed])
        #expect(stopped.map(\.resumeOnLaunch) == [false, false, false, false])
        // Kept over a quit, then launched: they continue.
        #expect(ReadingLibrary.afterLaunch(kept).resume == [list[0].id, list[1].id])
    }

    @Test func outputNamesAreNewInTheFolderAndInTheList() {
        let folder = URL(fileURLWithPath: "/Readings", isDirectory: true)
        let onDisk: Set<String> = ["/Readings/My Story.m4a", "/Readings/My Story 2.m4a"]
        let chosen = ReadingLibrary.outputURL(in: folder, title: "My: Story", fallback: nil,
                                              taken: ["/readings/my story 3.M4A"]) { onDisk.contains($0.path) }
        // "My: Story" is sanitized as `voiceislocal read` names files.
        #expect(chosen.path == "/Readings/My- Story.m4a")
        let plain = ReadingLibrary.outputURL(in: folder, title: "My Story", fallback: nil,
                                             taken: ["/readings/my story 3.M4A"]) { onDisk.contains($0.path) }
        #expect(plain.path == "/Readings/My Story 4.m4a")
        let untitled = ReadingLibrary.outputURL(in: folder, title: nil, fallback: "example.com", taken: []) { _ in false }
        #expect(untitled.lastPathComponent == "example.com.m4a")
        // Folder and name keep their spelling (NFC here), as the pipeline and the saved index use them.
        let composed = "Caf\u{E9}"
        let nfcFolder = ReadingOutput.fileURL(keepingSpelling: "/Volumes/Share/\(composed)", isDirectory: true)
        let accented = ReadingLibrary.outputURL(in: nfcFolder, title: composed, fallback: nil, taken: []) { _ in false }
        #expect(Array(accented.path.utf8) == Array("/Volumes/Share/\(composed)/\(composed).m4a".utf8))
        let saved = ReadingOutput.fileURL(keepingSpelling: accented.path)
        #expect(Array(saved.path.utf8) == Array(accented.path.utf8))
    }

    @Test func onlyThePipelinesCachesInTheReadingsFolderCountAsCaches() {
        let readings = URL(fileURLWithPath: "/Support/Readings", isDirectory: true)
        #expect(ReadingLibrary.isRenderCache("/Support/Readings/Output-0123456789abcdef", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/Support/Readings/Output-0123456789ABCDEF", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/Support/Readings/Output-0123", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/Support/Other/Output-0123456789abcdef", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/Support/Readings/../Output-0123456789abcdef", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/", in: readings))
        #expect(!ReadingLibrary.isRenderCache("/Support/Readings", in: readings))
    }

    /// Delete touches only the reading's own file: the finished one (by checksum, the entry's or the cache
    /// manifest's) or a copy a crash cut off (by the manifest's publishing identity), never a file put there since.
    @Test func onlyTheReadingsOwnFileIsItsOutput() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        let cache = root.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        #expect(try ReadingLibrary.ownership(of: output, sha256: "0", cache: cache) == nil)

        try Data("finished audio".utf8).write(to: output)
        let checksum = try fileSHA256(output)
        #expect(try ReadingLibrary.ownership(of: output, sha256: checksum, cache: nil) == .finished)
        #expect(try ReadingLibrary.ownership(of: output, sha256: nil, cache: nil) == nil)

        func writeManifest(outputSHA256: String?, publishing: ReadingFileIdentity?, output path: String) throws {
            var manifest = ReadingManifest(
                kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                sourceSHA256: "s", voiceIdentifier: "v", rate: nil, title: "Story", author: nil, language: nil,
                comment: "c", format: .current, output: path, outputSHA256: outputSHA256, duration: nil, chapters: [],
                status: "incomplete", parts: [])
            manifest.publishing = publishing
            try JSONEncoder().encode(manifest).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
        }
        // A reading published but not yet recorded as made: the manifest's checksum names it.
        try writeManifest(outputSHA256: checksum, publishing: nil, output: output.path)
        #expect(try ReadingLibrary.ownership(of: output, sha256: nil, cache: cache) == .finished)

        // Replaced by another file: not the reading's, whatever the entry and the manifest say.
        try FileManager.default.removeItem(at: output)
        try Data("the user's own file".utf8).write(to: output)
        #expect(try ReadingLibrary.ownership(of: output, sha256: checksum, cache: cache) == nil)

        // A copy cut off by a crash: the manifest's publishing identity is this very file.
        let identity = try #require(ExclusivePublisher.FileIdentity.of(output))
        try writeManifest(outputSHA256: nil, publishing: identity, output: output.path)
        #expect(try ReadingLibrary.ownership(of: output, sha256: nil, cache: cache) == .partial(identity))
        // A manifest for another output is not trusted.
        try writeManifest(outputSHA256: nil, publishing: identity, output: root.appendingPathComponent("Other.m4a").path)
        #expect(try ReadingLibrary.ownership(of: output, sha256: nil, cache: cache) == nil)
        // A manifest that is there but cannot be decoded may hold the only identity of a partial copy: an error.
        try Data("{".utf8).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
        #expect(throws: (any Error).self) { try ReadingLibrary.ownership(of: output, sha256: nil, cache: cache) }
        let reading = { () -> ReadingEntry in
            var reading = entry(.stopped)
            reading.output = output.path
            reading.cache = cache.path
            return reading
        }()
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        #expect(ReadingLibrary.deleteFiles(of: reading, readingsRoot: root, store: store) { _ in }.problem?
            .contains("could not be checked") == true)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    /// Delete: the reading's finished file goes to the Trash, then its cache and saved text; a file that cannot be
    /// trashed keeps the cache (whose manifest identifies it) and the text, for another try; a file that is not the
    /// reading's is left alone.
    @Test func deleteRemovesOnlyTheReadingsFilesAndKeepsTheCacheUntilItsFileIsGone() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        reading.outputSHA256 = try fileSHA256(output)
        try store.saveDocument(ReadableDocument(sections: [.init(paragraphs: ["Text."])]), for: reading.id)

        struct TrashFailed: Error {}
        var trashed: [URL] = []
        let failed = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            throw TrashFailed()
        }
        #expect(failed.problem?.contains("could not be moved to the Trash") == true)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try store.document(for: reading.id) != nil)
        // The file went back where it was, and the private folder it was checked in is gone.
        #expect(try Data(contentsOf: output) == Data("audio".utf8))
        func leftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".holos-delete-") }
        }
        #expect(try leftovers().isEmpty)

        let done = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { url in
            // The very file that was checked, moved aside under its own name (the Trash shows that name).
            #expect(try Data(contentsOf: url) == Data("audio".utf8))
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        #expect(done.problem == nil)
        #expect(trashed.map(\.lastPathComponent) == ["Story.m4a"])
        #expect(trashed.first?.deletingLastPathComponent().lastPathComponent.hasPrefix(".holos-delete-") == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try leftovers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(try store.document(for: reading.id) == nil)

        // A file put at the path since is not the reading's; a cache outside the Readings folder is never removed.
        try Data("someone else's".utf8).write(to: output)
        var stray = reading
        stray.cache = root.path
        #expect(ReadingLibrary.deleteFiles(of: stray, readingsRoot: readings, store: store) { _ in
            Issue.record("Trashed a file that is not the reading's")
        }.problem == nil)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// A finished file that cannot be read to check its checksum is neither trashed nor forgotten: the cache and the
    /// saved text stay for another try.
    @Test func anOutputThatCannotBeCheckedKeepsEverything() throws {
        let root = try folder()
        defer {
            _ = chmod(root.appendingPathComponent("Story.m4a").path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        reading.outputSHA256 = try fileSHA256(output)
        try store.saveDocument(ReadableDocument(sections: [.init(paragraphs: ["Text."])]), for: reading.id)
        #expect(chmod(output.path, 0) == 0)
        // Root reads anything; the check only means something as an ordinary user.
        guard getuid() != 0 else { return }
        #expect(throws: (any Error).self) { try ReadingLibrary.ownership(of: output, sha256: reading.outputSHA256, cache: cache) }
        let problem = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            Issue.record("Trashed a file whose checksum could not be read")
        }.problem
        #expect(problem?.contains("could not be checked") == true)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try store.document(for: reading.id) != nil)
    }

    /// Moved aside, a file whose content no longer matches (replaced after it was checked) goes back, untouched.
    @Test func aFileThatChangedBeforeTrashingGoesBack() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("someone else's".utf8).write(to: output)
        let problem = ReadingLibrary.trashVerified(output, checksums: [String(repeating: "0", count: 64)]) { _ in
            Issue.record("Trashed a file that did not match")
        }.problem
        #expect(problem?.contains("changed before") == true)
        #expect(try Data(contentsOf: output) == Data("someone else's".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Story.m4a"])
    }

    /// A copy a crash cut off is removed only while it is that very file: one put at the path since is left alone.
    @Test func aPartialCopyIsRemovedOnlyWhileItIsThatFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("partial".utf8).write(to: output)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(output))
        try FileManager.default.removeItem(at: output)
        try Data("the user's".utf8).write(to: output)
        #expect(ReadingLibrary.removePartial(output, identity: identity).problem == nil)
        #expect(try Data(contentsOf: output) == Data("the user's".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Story.m4a"])

        let own = try #require(ExclusivePublisher.FileIdentity.of(output))
        #expect(ReadingLibrary.removePartial(output, identity: own).problem == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// A reading on a drive that is not connected is not "gone": Delete keeps its row, cache, and saved text, and
    /// says why, until the file can be looked for. `/Volumes/<name>` counts only while a volume is mounted there.
    @Test func aReadingOnADisconnectedDriveIsKeptUntilItsFileCanBeChecked() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: false)
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = volumes.appendingPathComponent("Backup/Readings/Story.m4a")
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        reading.outputSHA256 = String(repeating: "a", count: 64)
        try store.saveDocument(ReadableDocument(sections: [.init(paragraphs: ["Text."])]), for: reading.id)

        try ReadingOutput.$volumesFolder.withValue(volumes.path) {
            #expect(ReadingOutput.unreachableReason(for: output)?.contains("“Backup” is not connected") == true)
            #expect(throws: ReadingLibrary.OutputUnreachable.self) {
                try ReadingLibrary.ownership(of: output, sha256: reading.outputSHA256, cache: cache)
            }
            let problem = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
                Issue.record("Trashed a file that is not there")
            }.problem
            #expect(problem?.contains("unavailable") == true)
            #expect(FileManager.default.fileExists(atPath: cache.path))
            #expect(try store.document(for: reading.id) != nil)

            // An empty folder left in /Volumes by an unclean unmount is not the drive.
            try FileManager.default.createDirectory(at: volumes.appendingPathComponent("Backup"),
                                                    withIntermediateDirectories: false)
            #expect(ReadingOutput.unreachableReason(for: output) != nil)

            // Nothing of the reading's can be there (no finished file, no copy begun): nothing to wait for.
            var stopped = entry(.stopped)
            stopped.output = output.path
            #expect(try ReadingLibrary.ownership(of: output, sha256: nil, cache: nil) == nil)
            #expect(ReadingLibrary.deleteFiles(of: stopped, readingsRoot: readings, store: store) { _ in }.problem == nil)

            // A volume mounted there (another device than the Volumes folder), whose folder is gone: the file is gone.
            let mounted = volumes.appendingPathComponent("Root")
            try FileManager.default.createSymbolicLink(atPath: mounted.path, withDestinationPath: "/")
            let onMounted = mounted.appendingPathComponent("holos-missing-\(UUID().uuidString)/Story.m4a")
            #expect(ReadingOutput.unreachableReason(for: onMounted) == nil)
        }
        // Outside the Volumes folder, a file whose folder is there but not the file is gone.
        #expect(ReadingOutput.unreachableReason(for: root.appendingPathComponent("Story.m4a")) == nil)
        var gone = reading
        gone.output = root.appendingPathComponent("Story.m4a").path
        #expect(ReadingLibrary.deleteFiles(of: gone, readingsRoot: readings, store: store) { _ in }.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// The manifest names the file through the folder's links resolved; the entry may name it through a link. Both
    /// are the same file, so the manifest's checksum still identifies it.
    @Test func aManifestNamingTheFileThroughAnotherPathStillCounts() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let cache = root.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let output = real.appendingPathComponent("Story.m4a")
        try Data("finished audio".utf8).write(to: output)
        let manifest = ReadingManifest(
            kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
            sourceSHA256: "s", voiceIdentifier: "v", rate: nil, title: "Story", author: nil, language: nil,
            comment: "c", format: .current, output: output.path, outputSHA256: try fileSHA256(output), duration: nil,
            chapters: [], status: "incomplete", parts: [])
        try JSONEncoder().encode(manifest).write(to: cache.appendingPathComponent(ReadingManifest.fileName))
        let throughLink = linked.appendingPathComponent("Story.m4a")
        #expect(try ReadingLibrary.ownership(of: throughLink, sha256: nil, cache: cache) == .finished)
        #expect(!ReadingLibrary.sameFile(root.appendingPathComponent("Other.m4a").path, throughLink))
    }

    /// A file the Trash refused that could not be put back (another file took its path) is kept aside; the result
    /// says where, and the next Delete, given that place, moves it to the Trash and removes its private folder.
    @Test func aFileLeftAsideIsDeletedByTheNextTry() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        reading.outputSHA256 = try fileSHA256(output)

        struct TrashFailed: Error {}
        let failed = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            // Another file takes the path while the reading's is aside, and the Trash refuses it.
            try Data("someone else's".utf8).write(to: output)
            throw TrashFailed()
        }
        let aside = try #require(failed.aside)
        #expect(failed.problem?.contains("It is kept at") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: aside)) == Data("audio".utf8))
        #expect(FileManager.default.fileExists(atPath: cache.path))

        reading = ReadingLibrary.afterFailedDelete(reading, problem: failed.problem ?? "", aside: failed.aside)
        var trashed: [String] = []
        let done = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        #expect(done.problem == nil)
        // The file now at the path is not the reading's: left alone, and said so.
        #expect(done.note?.contains("left in place") == true)
        #expect(trashed == ["Story.m4a"])
        #expect(try Data(contentsOf: output) == Data("someone else's".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".holos-delete-") }
            .isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// A Delete a quit cut off after it moved the file aside (before anything recorded where) leaves it in the place
    /// derived from the entry: the next Delete finds it there and moves it to the Trash.
    @Test func aFileMovedAsideByAnInterruptedDeleteIsFoundByTheEntry() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        var reading = entry(.done)
        reading.output = output.path
        reading.cache = cache.path
        let holding = root.appendingPathComponent(ReadingLibrary.asideToken(reading.id, partial: false))
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false)
        let aside = holding.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: aside)
        reading.outputSHA256 = try fileSHA256(aside)
        var trashed: [URL] = []
        let result = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        #expect(result == .init())
        #expect(trashed.map(\.lastPathComponent) == ["Story.m4a"])
        #expect(!FileManager.default.fileExists(atPath: holding.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// A file left aside that is not the reading's any more (changed since) stays attached to the entry: Delete keeps
    /// the entry, its cache, and names the file, rather than forget it hidden.
    @Test func aFileLeftAsideThatChangedKeepsTheEntry() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        var reading = entry(.done)
        reading.output = root.appendingPathComponent("Story.m4a").path
        reading.cache = cache.path
        reading.outputSHA256 = String(repeating: "a", count: 64)
        let holding = root.appendingPathComponent(ReadingLibrary.asideToken(reading.id, partial: false))
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false)
        let aside = holding.appendingPathComponent("Story.m4a")
        try Data("edited".utf8).write(to: aside)
        let result = ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in
            Issue.record("Trashed a file that is not the reading's")
        }
        #expect(result.problem?.contains("not this reading's file") == true)
        #expect(result.aside == aside.path)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    /// Play and Share… read the object opened and checked: a file put at the path afterwards is not the one read,
    /// and one put there before is refused.
    @Test func actionsReadTheFileThatWasChecked() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        let identity = try #require(ExclusivePublisher.FileIdentity.of(output))
        let file = try #require(ReadingLibrary.openVerified(output, identity: identity))
        // Replaced after the check: the copy still holds the reading's bytes, under its name.
        try FileManager.default.removeItem(at: output)
        try Data("someone else's".utf8).write(to: output)
        let copy = try ReadingLibrary.copyForSharing(file, name: "Story.m4a", into: root.appendingPathComponent("Share"))
        #expect(copy.lastPathComponent == "Story.m4a")
        #expect(try Data(contentsOf: copy) == Data("audio".utf8))
        #expect(ReadingLibrary.openVerified(output, identity: identity) == nil)
    }

    /// A Delete never moves the file anywhere but the entry's own place aside: when something is in the way there,
    /// it stops and says so, rather than use a place no later Delete would look in.
    @Test func aDeleteWhosePlaceAsideIsTakenStops() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        let output = root.appendingPathComponent("Story.m4a")
        try Data("audio".utf8).write(to: output)
        var reading = entry(.done)
        reading.output = output.path
        reading.outputSHA256 = try fileSHA256(output)
        let holding = root.appendingPathComponent(ReadingLibrary.asideToken(reading.id, partial: false))
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: false)
        try Data("other".utf8).write(to: holding.appendingPathComponent("Other.m4a"))
        let result = ReadingLibrary.deleteFiles(of: reading, readingsRoot: nil, store: store) { _ in
            Issue.record("Trashed through a place no later Delete looks in")
        }
        #expect(result.problem?.contains("is in the way") == true)
        #expect(try Data(contentsOf: output) == Data("audio".utf8))
    }

    /// While another process renders the same cache (it holds its lock), Delete removes nothing and keeps the entry.
    @Test func aCacheBeingRenderedElsewhereIsNotDeleted() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        var reading = entry(.stopped)
        reading.cache = cache.path
        let held = try ReadingDirectoryLock.acquire(for: cache)
        let result = withExtendedLifetime(held) {
            ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in }
        }
        #expect(result.problem?.contains("being made by another process") == true)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    /// An index that is there but cannot be looked up is never taken for a missing one (a new list would be saved
    /// over it): the list is shown empty and read-only.
    @Test func anIndexThatCannotBeLookedUpIsNeverReplaced() throws {
        let root = try folder()
        let library = root.appendingPathComponent("ReadingLibrary")
        defer {
            _ = chmod(library.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ReadingLibraryStore(folder: library)
        try store.save([entry(.done)])
        #expect(chmod(library.path, 0) == 0)
        guard getuid() != 0 else { return }
        let loaded = store.load()
        #expect(!loaded.writable)
        #expect(loaded.notice != nil)
    }

    /// NFC and NFD spellings of one name are two files on a volume whose rules cannot be told (a network share):
    /// a manifest naming one says nothing about the other.
    @Test func manifestPathsCompareByTheirExactSpelling() {
        let folder = "/holos-missing-\(UUID().uuidString)"
        let composed = "\(folder)/Caf\u{E9}.m4a"
        let decomposed = "\(folder)/Cafe\u{301}.m4a"
        #expect(ReadingLibrary.sameFile(composed, ReadingOutput.fileURL(keepingSpelling: composed)))
        #expect(!ReadingLibrary.sameFile(composed, ReadingOutput.fileURL(keepingSpelling: decomposed)))
    }

    /// A manifest that cannot be looked up may hold the only identity of a partly written file: an error, never "no
    /// manifest".
    @Test func aManifestThatCannotBeLookedUpIsAnError() throws {
        let root = try folder()
        let cache = root.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        defer {
            _ = chmod(cache.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let output = root.appendingPathComponent("Story.m4a")
        try Data("partial".utf8).write(to: output)
        #expect(chmod(cache.path, 0) == 0)
        guard getuid() != 0 else { return }
        #expect(throws: (any Error).self) { try ReadingLibrary.ownership(of: output, sha256: nil, cache: cache) }
    }

    /// A render cache that cannot be looked up is not "gone": Delete keeps the entry for another try.
    @Test func aCacheThatCannotBeCheckedKeepsTheEntry() throws {
        let root = try folder()
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        defer {
            _ = chmod(readings.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let cache = readings.appendingPathComponent("Output-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ReadingLibraryStore(folder: root.appendingPathComponent("ReadingLibrary"))
        var reading = entry(.stopped)
        reading.cache = cache.path
        #expect(chmod(readings.path, 0) == 0)
        guard getuid() != 0 else { return }
        #expect(ReadingLibrary.deleteFiles(of: reading, readingsRoot: readings, store: store) { _ in }.problem?
            .contains("could not be") == true)
        #expect(chmod(readings.path, 0o755) == 0)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    /// A made reading whose identity was not recorded gets it only from the file whose checksum is the reading's.
    @Test func aMissingIdentityIsTakenOnlyFromTheReadingsOwnFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Story.m4a")
        try Data("finished audio".utf8).write(to: output)
        let checksum = try fileSHA256(output)
        #expect(ReadingLibrary.verifiedIdentity(of: output, sha256: checksum) == ExclusivePublisher.FileIdentity.of(output))
        #expect(ReadingLibrary.verifiedIdentity(of: output, sha256: String(repeating: "0", count: 64)) == nil)
        #expect(ReadingLibrary.verifiedIdentity(of: root.appendingPathComponent("None.m4a"), sha256: checksum) == nil)
    }

    @Test func aReadingWhoseDeleteFailedComesBackStopped() {
        var running = entry(.rendering, resume: true)
        running.deletePending = true
        let back = ReadingLibrary.afterFailedDelete(running, problem: "Could not.")
        #expect(back.deletePending == nil)
        #expect(back.state == .stopped)
        #expect(!back.resumeOnLaunch)
        #expect(back.message == "Could not.")
        var done = entry(.done)
        done.deletePending = true
        #expect(ReadingLibrary.afterFailedDelete(done, problem: "x").state == .done)
    }

    @Test func durationsAndPositionsRead() {
        #expect(ReadingLibrary.durationText(40) == "40 s")
        #expect(ReadingLibrary.durationText(25 * 60 + 10) == "25 min")
        #expect(ReadingLibrary.durationText(3_600) == "1 h")
        #expect(ReadingLibrary.durationText(3_900) == "1 h 5 min")
        #expect(ReadingLibrary.clockText(187) == "3:07")
        #expect(ReadingLibrary.clockText(3_723) == "1:02:03")
        #expect(ReadingLibrary.clockText(.nan) == "0:00")
    }
}
