import AVFoundation
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

        /// The parts made of readings being made.
        var feeds: [UUID: ReadingPartFeed] = [:]

        func canPlay(_ id: UUID) -> Bool {
            guard let entry = entries[id] else { return false }
            return entry.state == .rendering ? (feeds[id]?.madeInOrder ?? 0) > 0 : entry.state == .done
        }

        func play(_ id: UUID, on player: ReadingPlayer) async throws -> Bool {
            if entries[id]?.state == .rendering, let feed = feeds[id] {
                try player.play(id, feed: feed, finishedFile: { nil })
                return true
            }
            return try await player.play(id) { try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) }
        }

        /// Reading `id`'s first part (of two) is made, its file not on disk (so it is never played).
        func makeFirstPart(_ id: UUID) {
            let feed = feeds[id] ?? ReadingPartFeed()
            feeds[id] = feed
            feed.add(ReadingMadePart(index: 0, total: 2, audio: URL(fileURLWithPath: "/nonexistent/part0.caf"),
                                     duration: 1, silenceBefore: 0))
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
        func seek(to time: TimeInterval) { currentTime = time }
    }

    /// Queues nothing anywhere: a reading being made plays nothing aloud.
    @MainActor final class SilentOutput: ReadingSegmentOutput {
        var playedFrames: Int64 = 0
        var onInterrupted: (() -> Void)?
        func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) throws {}
        func play() throws {}
        func pause() {}
        func stop() {}
    }

    @MainActor struct Fixture {
        let list = FakeList()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(SilentPlayback()) }, makeOutput: { SilentOutput() })
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

    /// A selection starts playing once its first part is made, while the rest is made.
    @Test(.timeLimit(.minutes(1))) func aSelectionPlaysOnceItsFirstPartIsMade() async throws {
        let fixture = Fixture()
        fixture.readAloud.pressed()
        #expect(await eventually { fixture.readAloud.waiting.count == 1 })
        let id = try #require(fixture.readAloud.waiting.first)
        fixture.list.set(id, .rendering)
        fixture.readAloud.readingProgressed(id)
        #expect(fixture.player.entryID == nil)

        fixture.list.makeFirstPart(id)
        fixture.readAloud.readingProgressed(id)
        #expect(await eventually { fixture.player.entryID == id })
        #expect(fixture.readAloud.playing == id)
        #expect(fixture.player.isPlaying)
        #expect(fixture.readAloud.waiting.isEmpty)
    }

    /// Making fails while it plays: what was made plays, then it leaves the player, the failure is told, and the
    /// next waiting selection plays.
    @Test(.timeLimit(.minutes(1))) func aFailureWhilePlayingEndsItAndTheNextPlays() async throws {
        let fixture = Fixture()
        for _ in 0..<2 { fixture.readAloud.pressed() }
        #expect(await eventually { fixture.readAloud.waiting.count == 2 })
        let ids = fixture.readAloud.waiting
        fixture.list.set(ids[0], .rendering)
        fixture.list.makeFirstPart(ids[0])
        fixture.readAloud.readingProgressed(ids[0])
        #expect(await eventually { fixture.player.entryID == ids[0] })
        fixture.list.set(ids[1], .done)
        fixture.readAloud.readingEnded(ids[1])
        #expect(fixture.player.entryID == ids[0])

        fixture.list.set(ids[0], .failed, message: "No voice.")
        fixture.list.feeds[ids[0]]?.finish(.failed("No voice."))
        fixture.readAloud.readingEnded(ids[0])
        #expect(fixture.notices.last == "The selection could not be read aloud")
        #expect(await eventually { fixture.player.entryID == ids[1] })
        #expect(fixture.readAloud.playing == ids[1])
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
