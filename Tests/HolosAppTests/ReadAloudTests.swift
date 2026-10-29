import Foundation
@testable import HolosContent
import HolosCore
import HolosDesktop
import HolosTestSupport
import Testing
@testable import HolosApp

/// The read-aloud shortcut's queue (`ReadAloud`): selections are added to the list and played once made, in the order
/// asked, through a player that plays nothing aloud.
@MainActor @Suite struct ReadAloudTests {
    @MainActor final class FakeList: ReadAloudList {
        var entries: [UUID: ReadingEntry] = [:]
        var added: [(source: ReadingSource, document: ReadableDocument?)] = []
        var addFailure: Error?

        func entry(_ id: UUID) -> ReadingEntry? { entries[id] }

        func add(_ source: ReadingSource, voice: String?, speed: Double, document: ReadableDocument?) async throws
            -> UUID {
            if let addFailure { throw addFailure }
            let entry = ReadingEntry(source: source, requestedVoice: voice, speed: speed)
            entries[entry.id] = entry
            added.append((source, document))
            return entry.id
        }

        func openFinishedFile(_ entry: ReadingEntry) async -> FileHandle? {
            try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        }

        func set(_ id: UUID, _ state: ReadingEntry.State, message: String? = nil) {
            entries[id]?.state = state
            entries[id]?.message = message
        }
    }

    final class SilentPlayback: ReadingPlayback {
        var isPlaying = false
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 10
        func play() -> Bool { isPlaying = true; return true }
        func pause() { isPlaying = false }
        func stop() { isPlaying = false }
    }

    @MainActor struct Fixture {
        let list = FakeList()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(SilentPlayback()) })
        let readAloud: ReadAloud
        let defaults: UserDefaults
        let suite = "ReadAloudTests-\(UUID().uuidString)"
        var notices: [String] { recorded.titles }
        let recorded = Recorded()

        final class Recorded { var titles: [String] = [] }

        init(selection: String = "First words to read.") {
            defaults = UserDefaults(suiteName: suite)!
            readAloud = ReadAloud(readings: list, player: player, defaults: defaults)
            let recorded = recorded
            readAloud.notify = { title, _ in recorded.titles.append(title) }
            readAloud.readSelection = { (selection, "Notes") }
        }

        /// The player's reading plays to its end.
        func finishPlaying() throws {
            player.ended(ObjectIdentifier(try #require(player.loaded)), failure: nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aSelectionIsAddedAndPlaysOnceMade() async throws {
        let fixture = Fixture()
        fixture.readAloud.pressed()
        #expect(await eventually { fixture.readAloud.waiting.count == 1 })
        let added = try #require(fixture.list.added.first)
        #expect(added.source == .selection(app: "Notes"))
        #expect(added.document?.plainText == "First words to read.")
        #expect(fixture.notices == ["Making audio…"])
        let id = try #require(fixture.readAloud.waiting.first)
        #expect(fixture.player.entryID == nil)

        fixture.list.set(id, .done)
        fixture.readAloud.readingEnded(id)
        #expect(await eventually { fixture.player.entryID == id })
        #expect(fixture.readAloud.playing == id)
        #expect(fixture.readAloud.isActive)

        try fixture.finishPlaying()
        #expect(fixture.readAloud.playing == nil)
        #expect(!fixture.readAloud.isActive)
    }

    @Test(.timeLimit(.minutes(1))) func selectionsPlayInTheOrderAskedAndAFailedOneIsSkipped() async throws {
        let fixture = Fixture()
        for _ in 0..<3 { fixture.readAloud.pressed() }
        #expect(await eventually { fixture.readAloud.waiting.count == 3 })
        let ids = fixture.readAloud.waiting

        // The second is made first: it waits for the first.
        fixture.list.set(ids[1], .done)
        fixture.readAloud.readingEnded(ids[1])
        #expect(fixture.player.entryID == nil)
        // The first fails: it is skipped, said so, and the second plays.
        fixture.list.set(ids[0], .failed, message: "No voice.")
        fixture.readAloud.readingEnded(ids[0])
        #expect(fixture.notices.last == "The selection could not be read aloud")
        #expect(await eventually { fixture.player.entryID == ids[1] })
        // The third is made while the second plays, and plays once it ends.
        fixture.list.set(ids[2], .done)
        fixture.readAloud.readingEnded(ids[2])
        #expect(fixture.player.entryID == ids[1])
        try fixture.finishPlaying()
        #expect(await eventually { fixture.player.entryID == ids[2] })
    }

    @Test(.timeLimit(.minutes(1))) func stopEndsThePlayingOneAndForgetsTheWaitingOnes() async throws {
        let fixture = Fixture()
        fixture.readAloud.pressed()
        fixture.readAloud.pressed()
        #expect(await eventually { fixture.readAloud.waiting.count == 2 })
        let ids = fixture.readAloud.waiting
        fixture.list.set(ids[0], .done)
        fixture.readAloud.readingEnded(ids[0])
        #expect(await eventually { fixture.player.entryID == ids[0] })

        fixture.readAloud.stop()
        #expect(fixture.player.entryID == nil)
        #expect(!fixture.readAloud.isActive)
        fixture.list.set(ids[1], .done)
        fixture.readAloud.readingEnded(ids[1])
        #expect(fixture.player.entryID == nil)
    }

    @Test func nothingSelectedIsSaidAndNothingIsAdded() async {
        let blank = Fixture(selection: "  \n ")
        blank.readAloud.pressed()
        #expect(blank.notices == ["Nothing to read aloud"])

        let refused = Fixture()
        refused.readAloud.readSelection = { throw SelectedTextError.secureInput }
        refused.readAloud.pressed()
        #expect(refused.notices == ["Nothing to read aloud"])
        await Task.yield()
        #expect(blank.list.added.isEmpty && refused.list.added.isEmpty)
    }

    @Test func turningItOffIsKept() {
        let fixture = Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        #expect(fixture.readAloud.isOn)
        fixture.readAloud.setOn(false)
        #expect(!fixture.readAloud.isOn)
        #expect(fixture.defaults.object(forKey: ReadAloud.defaultsKey) as? Bool == false)
    }
}
