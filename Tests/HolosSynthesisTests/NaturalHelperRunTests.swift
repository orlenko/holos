import Darwin
import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// `voiceislocal say` run by the app (--parent-pid): it stops when the app ends, and waits for an earlier helper still
// writing the same output.

@MainActor @Suite(.timeLimit(.minutes(1))) struct NaturalHelperRunTests {
    private final class Flags: Sendable {
        let started = Mutex(false)
        let cleanedUp = Mutex(false)
        let waiting = Mutex(false)
        let parentEnded = Mutex(false)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-helper-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits until `condition` holds, for at most `polls` short sleeps (never a wall-clock bound); whether it held.
    private func eventually(polls: Int = 3_000, _ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<polls where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A render that runs until it is cancelled, then cleans up.
    private func endless(_ flags: Flags) -> @MainActor () async throws -> Int {
        {
            flags.started.withLock { $0 = true }
            defer { flags.cleanedUp.withLock { $0 = true } }
            while true { try await Task.sleep(for: .seconds(3_600)) }
        }
    }

    @Test func theRenderStopsAndCleansUpWhenTheAppEnds() async throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(at: place) }
        // The app: a real process, killed with SIGKILL (no chance to stop its helpers).
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["600"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }
        let pid = app.processIdentifier
        let flags = Flags()
        let task = Task { @MainActor in
            try await NaturalHelperRun.whileParentRuns(
                pid, isAlive: { kill(pid, 0) == 0 }, output: place.appendingPathComponent("part0001.caf"),
                lockFolder: place.appendingPathComponent("locks"),
                parentEnded: { flags.parentEnded.withLock { $0 = true } }, endless(flags))
        }
        #expect(try await eventually { flags.started.withLock { $0 } })
        kill(pid, SIGKILL)
        let stopped = try await eventually { flags.cleanedUp.withLock { $0 } }
        #expect(stopped)
        if !stopped { task.cancel() }
        let error = await #expect(throws: HolosError.self) { _ = try await task.value }
        #expect(error?.localizedDescription.contains("has quit") == true)
        #expect(flags.cleanedUp.withLock { $0 })
        #expect(flags.parentEnded.withLock { $0 })
    }

    @Test func anAppThatEndedBeforeTheWatchStartedIsSeen() async throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let flags = Flags()
        // This process never exits during the test; it is no longer the parent.
        let task = Task { @MainActor in
            try await NaturalHelperRun.whileParentRuns(
                getpid(), isAlive: { false }, output: place.appendingPathComponent("p.caf"),
                lockFolder: place.appendingPathComponent("locks"), endless(flags))
        }
        let stopped = try await eventually { flags.cleanedUp.withLock { $0 } }
        #expect(stopped)
        if !stopped { task.cancel() }
        await #expect(throws: HolosError.self) { _ = try await task.value }
    }

    @Test func aHelperWaitsForAnEarlierOneWritingTheSameOutput() async throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let locks = place.appendingPathComponent("locks")
        let output = place.appendingPathComponent("part0001.caf")
        // The earlier helper (left by an app that ended) holds the output's lock.
        let earlier = try await NaturalOutputLock.acquire(for: output, in: locks)
        let flags = Flags()
        let task = Task { @MainActor in
            try await NaturalHelperRun.whileParentRuns(
                getpid(), isAlive: { true }, output: output, lockFolder: locks, interval: .milliseconds(10),
                waiting: { flags.waiting.withLock { $0 = true } }) { () async throws -> Int in
                flags.started.withLock { $0 = true }
                return 7
            }
        }
        #expect(try await eventually { flags.waiting.withLock { $0 } })
        #expect(!flags.started.withLock { $0 })
        NaturalOutputLock.release(earlier)
        #expect(try await task.value == 7)
        #expect(flags.started.withLock { $0 })
        // Another output is never waited for.
        let other = try await NaturalOutputLock.acquire(for: place.appendingPathComponent("part0002.caf"), in: locks)
        let held = try await NaturalOutputLock.acquire(for: output, in: locks)
        NaturalOutputLock.release(held)
        NaturalOutputLock.release(other)
    }

    @Test func aStopEndsTheWait() async throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let locks = place.appendingPathComponent("locks")
        let output = place.appendingPathComponent("part0001.caf")
        let earlier = try await NaturalOutputLock.acquire(for: output, in: locks)
        defer { NaturalOutputLock.release(earlier) }
        let waiting = Mutex(false)
        let task = Task { try await NaturalOutputLock.acquire(for: output, in: locks, interval: .milliseconds(10)) {
            waiting.withLock { $0 = true }
        } }
        #expect(try await eventually { waiting.withLock { $0 } })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func theLockIsTheSameThroughALinkedFolder() throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let real = place.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = place.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let locks = place.appendingPathComponent("locks")
        #expect(NaturalOutputLock.file(for: link.appendingPathComponent("a.caf"), in: locks)
            == NaturalOutputLock.file(for: real.appendingPathComponent("a.caf"), in: locks))
        #expect(NaturalOutputLock.file(for: real.appendingPathComponent("a.caf"), in: locks)
            != NaturalOutputLock.file(for: real.appendingPathComponent("b.caf"), in: locks))
    }

    @Test func onlyAFolderTheAppMadeForTheHelperIsRemovedWhenTheAppEnds() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let made = try NaturalHelperScratch.create(in: root, owner: 4_242)
        #expect(NaturalHelperScratch.isMade(made, for: 4_242, in: root))
        // Folders a helper may be given with --scratch-directory that the app did not make for it: left alone.
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let unmarked = root.appendingPathComponent("holos-natural-\(UUID().uuidString)", isDirectory: true)
        let linkedMarker = root.appendingPathComponent("holos-natural-\(UUID().uuidString)", isDirectory: true)
        for untouched in [documents, unmarked, linkedMarker] {
            try manager.createDirectory(at: untouched, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: untouched.appendingPathComponent("file.txt"))
        }
        try manager.createSymbolicLink(at: linkedMarker.appendingPathComponent(NaturalHelperScratch.marker),
                                       withDestinationURL: made.appendingPathComponent(NaturalHelperScratch.marker))
        let link = root.appendingPathComponent("holos-natural-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: link, withDestinationURL: made)
        let elsewhere = try folder()
        defer { try? manager.removeItem(at: elsewhere) }
        let away = try NaturalHelperScratch.create(in: elsewhere, owner: 4_242)
        for folder in [documents, unmarked, linkedMarker, link, away] {
            #expect(!(try NaturalHelperScratch.removeIfMade(folder, for: 4_242, in: root)), "\(folder.lastPathComponent)")
        }
        // Made for another app.
        #expect(!(try NaturalHelperScratch.removeIfMade(made, for: 4_243, in: root)))
        for folder in [documents, unmarked, linkedMarker] {
            #expect(manager.fileExists(atPath: folder.appendingPathComponent("file.txt").path))
        }
        #expect(manager.fileExists(atPath: away.path))
        #expect(manager.fileExists(atPath: made.path))

        // The helper of an app that ends removes the folder made for it, and only that one.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["600"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }
        let pid = app.processIdentifier
        let mine = try NaturalHelperScratch.create(in: root, owner: pid)
        let flags = Flags()
        let task = Task { @MainActor in
            try await NaturalHelperRun.whileParentRuns(
                pid, isAlive: { kill(pid, 0) == 0 }, output: root.appendingPathComponent("part0001.caf"),
                lockFolder: root.appendingPathComponent("locks"),
                parentEnded: {
                    for folder in [mine, documents] {
                        _ = try? NaturalHelperScratch.removeIfMade(folder, for: pid, in: root)
                    }
                }, endless(flags))
        }
        #expect(try await eventually { flags.started.withLock { $0 } })
        kill(pid, SIGKILL)
        #expect(try await eventually { !manager.fileExists(atPath: mine.path) })
        if manager.fileExists(atPath: mine.path) { task.cancel() }
        await #expect(throws: HolosError.self) { _ = try await task.value }
        #expect(manager.fileExists(atPath: documents.appendingPathComponent("file.txt").path))
    }
}
