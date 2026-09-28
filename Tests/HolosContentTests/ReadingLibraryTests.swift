import Foundation
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
        #expect(store.document(for: id) == nil)
        let document = ReadableDocument(title: "Title", author: "Jane", language: "fr",
                                        sections: [.init(heading: "One", level: 2, paragraphs: ["Texte."])])
        try store.saveDocument(document, for: id)
        #expect(store.document(for: id) == document)
        store.removeDocument(for: id)
        #expect(store.document(for: id) == nil)
    }

    @Test func launchContinuesOnlyReadingsKeptOverTheQuitOldestFirst() {
        let running = entry(.rendering, created: 30, resume: true)
        let newer = entry(.queued, created: 50, resume: true)
        let older = entry(.queued, created: 40, resume: true)
        let crashed = entry(.rendering, created: 20)
        let done = entry(.done, created: 10)
        // The list is newest first.
        let (entries, resume) = ReadingLibrary.afterLaunch([newer, older, running, crashed, done])
        #expect(resume == [running.id, older.id, newer.id])
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for id in [running.id, newer.id, older.id] {
            #expect(byID[id]?.state == .queued)
            #expect(byID[id]?.resumeOnLaunch == false)
        }
        #expect(byID[crashed.id]?.state == .stopped)
        #expect(byID[crashed.id]?.message?.contains("quit") == true)
        #expect(byID[done.id] == done)
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
