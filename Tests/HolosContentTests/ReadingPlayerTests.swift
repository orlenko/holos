import Foundation
import Synchronization
import Testing
@testable import HolosContent

/// A stand-in for `AVAudioPlayer`: nothing is played.
private final class FakePlayback: ReadingPlayback, @unchecked Sendable {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 60
    /// What `play` returns.
    var starts = true
    var stops = 0

    func play() -> Bool {
        isPlaying = starts
        return starts
    }

    func pause() { isPlaying = false }

    func stop() {
        isPlaying = false
        stops += 1
    }
}

@MainActor @Suite struct ReadingPlayerTests {
    private func file() throws -> FileHandle {
        try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    }

    /// A reading that cannot continue after a pause, or whose file cannot be decoded while it plays, is stopped and
    /// the failure told: never shown as simply finished.
    @Test func playbackFailuresAreReported() async throws {
        let playback = FakePlayback()
        let player = ReadingPlayer(open: { _ in OpenedPlayback(playback) })
        var errors: [String] = []
        player.onError = { errors.append($0) }
        let id = UUID()
        try await player.play(id, file: { try? self.file() })
        #expect(player.entryID == id)
        #expect(player.isPlaying)

        #expect(player.toggleLoaded(id))
        #expect(!player.isPlaying)
        playback.starts = false
        #expect(player.toggleLoaded(id))
        #expect(player.entryID == nil)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("could not continue") == true)

        playback.starts = true
        try await player.play(id, file: { try? self.file() })
        let loaded = try #require(player.loaded)
        player.ended(ObjectIdentifier(loaded), failure: "The audio could not be decoded.")
        #expect(player.entryID == nil)
        #expect(errors.last == "The audio could not be decoded.")

        // The end of the reading is no error.
        try await player.play(id, file: { try? self.file() })
        player.ended(ObjectIdentifier(try #require(player.loaded)), failure: nil)
        #expect(player.entryID == nil)
        #expect(errors.count == 2)

        // One that does not start is an error for the caller.
        playback.starts = false
        await #expect(throws: (any Error).self) { try await player.play(id, file: { try? self.file() }) }
        #expect(player.entryID == nil)
    }

    /// A reading whose player fails to open after another was asked for says nothing: it is no longer asked for.
    @Test func aFailureOfASupersededRequestIsNotTold() async throws {
        let failing = Mutex(true)
        let player = ReadingPlayer(open: { _ in
            if failing.withLock({ $0 }) { throw CocoaError(.fileReadCorruptFile) }
            return OpenedPlayback(FakePlayback())
        })
        let gate = SlowFile()
        let first = Task { @MainActor in try await player.play(UUID()) { await gate.open() } }
        await gate.waitUntilAsked()
        player.stop()
        gate.release()
        #expect(try await first.value)
        // Still asked for: its failure is the caller's.
        await #expect(throws: (any Error).self) { try await player.play(UUID(), file: { try? self.file() }) }
        failing.withLock { $0 = false }
    }

    /// A late callback from a player replaced since leaves the new one alone.
    @Test func aCallbackFromAReplacedPlayerIsIgnored() async throws {
        let first = FakePlayback()
        let second = FakePlayback()
        let next = Mutex([first, second])
        let player = ReadingPlayer(open: { _ in OpenedPlayback(next.withLock { $0.removeFirst() }) })
        var errors: [String] = []
        player.onError = { errors.append($0) }
        try await player.play(UUID(), file: { try? self.file() })
        let later = UUID()
        try await player.play(later, file: { try? self.file() })
        player.ended(ObjectIdentifier(first), failure: "Old.")
        #expect(player.entryID == later)
        #expect(errors.isEmpty)
    }

    /// A reading whose file opens slowly (a slow share) is not played once another was asked for after it, or
    /// playing was paused: the later request wins, whichever file opens first.
    @Test func aLaterRequestWinsOverOneWhoseFileOpensSlowly() async throws {
        let player = ReadingPlayer(open: { _ in OpenedPlayback(FakePlayback()) })
        let (slow, fast) = (UUID(), UUID())
        let gate = SlowFile()
        let first = Task { @MainActor in try await player.play(slow) { await gate.open() } }
        await gate.waitUntilAsked()
        try await player.play(fast, file: { try? self.file() })
        #expect(player.entryID == fast)
        gate.release()
        #expect(try await first.value)
        #expect(player.entryID == fast)

        // The loaded reading paused or continued after another was asked for: that one does not start over it.
        let toggled = SlowFile()
        let overridden = Task { @MainActor in try await player.play(slow) { await toggled.open() } }
        await toggled.waitUntilAsked()
        #expect(player.toggleLoaded(fast))
        toggled.release()
        _ = try await overridden.value
        #expect(player.entryID == fast)

        // The loaded reading ends while another opens: that one still starts.
        let next = SlowFile()
        let following = Task { @MainActor in try await player.play(slow) { await next.open() } }
        await next.waitUntilAsked()
        player.ended(ObjectIdentifier(try #require(player.loaded)), failure: nil)
        #expect(player.entryID == nil)
        next.release()
        _ = try await following.value
        #expect(player.entryID == slow)

        // Paused while a file opens: nothing starts.
        player.stop()
        let again = SlowFile()
        let paused = Task { @MainActor in try await player.play(slow) { await again.open() } }
        await again.waitUntilAsked()
        player.pause()
        again.release()
        _ = try await paused.value
        #expect(player.entryID == nil)
    }
}

/// A file that opens once the test releases it.
@MainActor private final class SlowFile {
    private var permit: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var asked = false

    func open() async -> FileHandle? {
        asked = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { permit = $0 }
        return try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    }

    func waitUntilAsked() async {
        if asked { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        permit?.resume()
        permit = nil
    }
}
