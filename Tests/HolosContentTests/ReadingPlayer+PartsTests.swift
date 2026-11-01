import Foundation
import HolosTestSupport
import Testing
@testable import HolosContent

/// A stand-in for the finished file's `AVAudioPlayer`: nothing is played.
private final class FinishedPlayback: ReadingPlayback, @unchecked Sendable {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10

    func play() -> Bool {
        isPlaying = true
        return true
    }

    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
}

/// `ReadingPlayer` with a reading being made: its parts play, it waits for the next, and once the reading is made the
/// rest plays from its file from the same place, the end then reported as for any finished reading.
@MainActor @Suite struct ReadingPlayerPartsTests {
    private func file() -> FileHandle? { try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) }

    @Test func aReadingBeingMadeIsHandedOverToItsFile() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let output = QueueOutput()
        let finished = FinishedPlayback()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(finished) }, makeOutput: { output })
        var ended: [UUID] = []
        var errors: [String] = []
        player.onEnded = { ended.append($0) }
        player.onError = { errors.append($0) }
        let feed = ReadingPartFeed()
        for index in 0..<3 { feed.add(try files.part(index, of: 3, seconds: 1)) }
        let id = UUID()
        try player.play(id, feed: feed, finishedFile: { self.file() })
        #expect(player.entryID == id)
        #expect(player.isPlaying)
        #expect(await eventually { output.queued.count == 3 })
        #expect(player.position?.isFinal == true)

        feed.finish(.finished)
        output.playNext()
        output.playNext()
        output.playNext()
        #expect(await eventually { player.loaded === finished })
        #expect(finished.currentTime == 2.5)
        #expect(finished.isPlaying)
        #expect(player.entryID == id)

        // Its end is the reading's end, as for any finished file.
        player.ended(ObjectIdentifier(finished), failure: nil)
        #expect(ended == [id])
        #expect(errors.isEmpty)
    }

    /// Paused when making finishes: the file is loaded at the same place, still paused; Space continues it.
    @Test func aPausedReadingStaysPausedWhenHandedOver() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let output = QueueOutput()
        let finished = FinishedPlayback()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(finished) }, makeOutput: { output })
        let feed = ReadingPartFeed()
        feed.add(try files.part(0, of: 2, seconds: 1))
        let id = UUID()
        try player.play(id, feed: feed, finishedFile: { self.file() })
        #expect(await eventually { output.queued.count == 1 })
        output.playNext()
        #expect(player.isWaiting)
        #expect(player.position?.isFinal == false)
        #expect(player.toggleLoaded(id))
        #expect(!player.isPlaying)
        feed.finish(.finished)
        #expect(await eventually { player.loaded === finished })
        #expect(finished.currentTime == 1)
        #expect(!finished.isPlaying)
        #expect(player.toggleLoaded(id))
        #expect(finished.isPlaying)
    }

    /// Space while the finished file opens (a slow drive) pauses or continues what plays once it is open: no error.
    @Test func spaceWhileTheFileOpensSetsWhetherItPlays() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let output = QueueOutput()
        let finished = FinishedPlayback()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(finished) }, makeOutput: { output })
        var errors: [String] = []
        player.onError = { errors.append($0) }
        let (opening, open) = AsyncStream.makeStream(of: Void.self)
        let feed = ReadingPartFeed()
        feed.add(try files.part(0, of: 2, seconds: 1))
        let id = UUID()
        try player.play(id, feed: feed, finishedFile: {
            for await _ in opening { break }
            return self.file()
        })
        #expect(await eventually { output.queued.count == 1 })
        feed.finish(.finished)
        output.playNext()
        #expect(player.toggleLoaded(id))
        #expect(!player.isPlaying)
        #expect(player.entryID == id)
        open.yield()
        #expect(await eventually { player.loaded === finished })
        #expect(!finished.isPlaying)
        #expect(finished.currentTime == 1)
        #expect(errors.isEmpty)
    }

    /// Making failed: the made parts play, then the failure is told and the reading unloaded; no end is reported.
    @Test func aFailureWhileMakingIsToldNotTakenForTheEnd() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let output = QueueOutput()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(FinishedPlayback()) }, makeOutput: { output })
        var ended: [UUID] = []
        var errors: [String] = []
        player.onEnded = { ended.append($0) }
        player.onError = { errors.append($0) }
        let feed = ReadingPartFeed()
        feed.add(try files.part(0, of: 3, seconds: 1))
        try player.play(UUID(), feed: feed, finishedFile: { nil })
        #expect(await eventually { output.queued.count == 1 })
        feed.finish(.failed("The voice is gone."))
        output.playNext()
        #expect(errors == ["Playback stopped at part 2 of 3: The voice is gone."])
        #expect(ended.isEmpty)
        #expect(player.entryID == nil)
    }
}
