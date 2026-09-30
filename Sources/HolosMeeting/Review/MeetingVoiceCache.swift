import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// One meeting's turn embeddings while its review window is open (docs/meeting-design.md §4.10, "Voices within one
/// meeting"): one pass of the voice sample extractor per diarized track, asked about every turn of 2 s or more, so
/// the window can compare its speakers' voices and learn a named person's voice without another pass.
///
/// Biometric data held in memory only: nothing here is ever written to a file. The window drops it (`clear`) when it
/// closes, when the meeting is labelled again (the turns are another run's), and when its audio is deleted. Every
/// entry belongs to one session and one head run; a turn whose times changed since (a split trims it) is not served.
public final class MeetingVoiceCache: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")

    private struct Entry: Sendable {
        let track: String
        let start: Double
        let end: Double
        /// Nil when the pass found no clean single-speaker speech in the turn (it gets no embedding either way).
        let embedding: TurnEmbedding?
    }

    private struct Storage: Sendable {
        var session: URL?
        var runID: String?
        var entries: [String: Entry] = [:]
        /// Bumped by `begin` and `clear`: a pass's results are kept only while it is the current one.
        var epoch = 0
        var computing = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    public init() {}

    /// Forgets everything and starts collecting the passes of `runID`; returns the epoch their results carry.
    @discardableResult
    public func begin(session: URL, runID: String) -> Int {
        let (epoch, waiters) = storage.withLock { storage -> (Int, [CheckedContinuation<Void, Never>]) in
            storage.epoch += 1
            storage.session = session.standardizedFileURL
            storage.runID = runID
            storage.entries.removeAll()
            storage.computing = true
            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return (storage.epoch, waiters)
        }
        // Whoever waited for the previous pass reads what there is now (nothing), and falls back.
        for waiter in waiters { waiter.resume() }
        return epoch
    }

    /// Keeps one track's results of the pass `epoch`: every turn asked about is covered from now on, with its
    /// embedding or with none.
    public func store(_ embeddings: [TurnEmbedding], asked: [TurnRef], track: String, epoch: Int) {
        let byID = Dictionary(embeddings.map { ($0.turnID, $0) }, uniquingKeysWith: { first, _ in first })
        storage.withLock { storage in
            guard storage.epoch == epoch else { return }
            for turn in asked {
                storage.entries[turn.id] = Entry(track: track, start: turn.start, end: turn.end, embedding: byID[turn.id])
            }
        }
    }

    /// The pass `epoch` ended (done, failed, or cancelled): whoever waits for it goes on with what is stored.
    public func finish(epoch: Int) {
        let waiters = storage.withLock { storage -> [CheckedContinuation<Void, Never>] in
            guard storage.epoch == epoch else { return [] }
            storage.computing = false
            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Drops every embedding (the window closed, the meeting was labelled again, or its audio was deleted).
    public func clear() {
        let waiters = storage.withLock { storage -> [CheckedContinuation<Void, Never>] in
            storage.epoch += 1
            storage.session = nil
            storage.runID = nil
            storage.entries.removeAll()
            storage.computing = false
            let waiters = Array(storage.waiters.values)
            storage.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Whether a pass is running.
    public var isComputing: Bool { storage.withLock { $0.computing } }

    /// Turns covered so far (with or without an embedding).
    public var coveredTurns: Int { storage.withLock { $0.entries.count } }

    /// The stored embeddings of `runID` by turn ID; empty when the cache holds another run's.
    public func embeddings(runID: String) -> [String: TurnEmbedding] {
        storage.withLock { storage in
            guard storage.runID == runID else { return [:] }
            var result: [String: TurnEmbedding] = [:]
            for (id, entry) in storage.entries { if let embedding = entry.embedding { result[id] = embedding } }
            return result
        }
    }

    /// Returns once no pass is running, or at once when the calling task is cancelled.
    public func waitForPass() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = storage.withLock { storage -> Bool in
                    guard storage.computing, !Task.isCancelled else { return true }
                    storage.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = storage.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// The embeddings of `turns` when every one of them is covered for this session, this track, the head run
    /// `headRunID`, and the same times; nil otherwise (the caller runs its own pass).
    public func serve(session: URL, track: String, turns: [TurnRef], headRunID: String?) -> [TurnEmbedding]? {
        storage.withLock { storage -> [TurnEmbedding]? in
            guard let runID = storage.runID, runID == headRunID,
                  storage.session == session.standardizedFileURL else { return nil }
            var result: [TurnEmbedding] = []
            for turn in turns {
                guard let entry = storage.entries[turn.id], entry.track == track,
                      abs(entry.start - turn.start) < 1e-6, abs(entry.end - turn.end) < 1e-6 else { return nil }
                if let embedding = entry.embedding { result.append(embedding) }
            }
            return result
        }
    }
}

/// The review window's voice sample extractor: serves the turns it is asked about from the window's
/// `MeetingVoiceCache` (waiting for a pass that is running), so learning a named person's voice needs no pass of its
/// own; any turn the cache does not cover sends the whole request to `fallback` (one pass, as before the cache).
public struct CachedVoiceSampleExtractor: VoiceSampleExtractor {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")
    public let cache: MeetingVoiceCache
    public let fallback: any VoiceSampleExtractor

    public init(cache: MeetingVoiceCache, fallback: any VoiceSampleExtractor) {
        self.cache = cache; self.fallback = fallback
    }

    public func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        guard !turns.isEmpty else { return [] }
        await cache.waitForPass()
        try Task.checkCancellation()
        // Served only for the run the meeting is labelled with now; a relabel meanwhile makes the cache another run's.
        let head = try? SessionSpeakerStore.readHead(session: session)?.runID
        if let served = cache.serve(session: session, track: track, turns: turns, headRunID: head) {
            Self.log.info("Served \(served.count, privacy: .public) of \(turns.count, privacy: .public) turn embeddings on \(track, privacy: .public) from the review's voice cache")
            return served
        }
        return try await fallback.turnEmbeddings(session: session, track: track, turns: turns)
    }
}
