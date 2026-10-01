import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// Contents of a recording's `live.json` (docs/meeting-design.md §5.8 "Live transcript"): the words live speech has
/// heard but not finalized yet, by track. Finalized words are in `events.jsonl` (`transcriptFinalized`); these are
/// the volatile hypotheses that follow them and change as more audio arrives. Written by the recorder while it runs
/// (at most every `LiveTextPublisher.interval`), removed when live speech ends; nothing else depends on it.
public struct LiveTextFile: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Grows with every write.
    public var sequence: Int
    public var updatedAt: Date
    /// Volatile segments by track ("mic", "system"), on the session timeline, ordered by start.
    public var volatile: [String: [TranscriptSegment]]

    public init(schemaVersion: Int = 1, sequence: Int, updatedAt: Date = Date(),
                volatile: [String: [TranscriptSegment]]) {
        self.schemaVersion = schemaVersion; self.sequence = sequence; self.updatedAt = updatedAt
        self.volatile = volatile
    }

    /// Reads `live.json` of `session`; nil when there is none or it cannot be read (a reader just shows no volatile
    /// words then).
    public static func read(session: URL) -> LiveTextFile? {
        guard let data = try? AtomicFile.readIfPresent(SessionPaths.liveText(session), maxBytes: maxBytes) else {
            return nil
        }
        return try? HolosJSON.decoder().decode(LiveTextFile.self, from: data)
    }

    /// A file larger than this is not read.
    static let maxBytes = 1 << 20
}

/// What one track's live speech has not finalized yet (`LiveTrack`'s volatile words). Follows the speech framework's
/// own rule (`ResultCollector`): a result replaces the volatile hypotheses over the audio interval it covers, so a
/// final result removes the volatile words it confirms. Times are on the session timeline. Pure.
struct VolatileText: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        /// The speech session that reported it (`LiveTrack`'s session serial).
        var session: Int
        var segment: TranscriptSegment
    }

    private(set) var entries: [Entry] = []

    var segments: [TranscriptSegment] { entries.map(\.segment) }

    /// A volatile result: replaces the volatile hypotheses it overlaps. Returns whether anything changed.
    @discardableResult
    mutating func volatile(_ segment: TranscriptSegment, session: Int) -> Bool {
        let before = entries
        removeOverlapping(segment)
        entries.append(Entry(session: session, segment: segment))
        entries.sort { $0.segment.start < $1.segment.start }
        return entries != before
    }

    /// A final result: the volatile hypotheses it overlaps are now final text. Returns whether anything changed.
    @discardableResult
    mutating func final(_ segment: TranscriptSegment) -> Bool {
        let count = entries.count
        removeOverlapping(segment)
        return entries.count != count
    }

    /// The speech session ended (finished, failed, or was cancelled): its hypotheses will not be confirmed.
    @discardableResult
    mutating func endSession(_ session: Int) -> Bool {
        let count = entries.count
        entries.removeAll { $0.session == session }
        return entries.count != count
    }

    @discardableResult
    mutating func removeAll() -> Bool {
        defer { entries.removeAll() }
        return !entries.isEmpty
    }

    private mutating func removeOverlapping(_ segment: TranscriptSegment) {
        // As `ResultCollector`: overlapping intervals; a zero-length result still replaces one that starts with it.
        entries.removeAll { entry in
            let other = entry.segment
            return (other.start < segment.end && other.end > segment.start) || other.start == segment.start
        }
    }
}

/// Writes `live.json` for a recording: the latest volatile words of every track, at most once every `interval`, so
/// a fast speech framework never turns into a stream of disk writes. Thread-safe; `set` never blocks on the disk.
/// `close()` stops it and removes the file.
public final class LiveTextPublisher: Sendable {
    /// At most one write per this interval (the app's live view reads four times a second).
    public static let interval: Duration = .milliseconds(200)

    /// Writes one file (atomically, outside tests).
    typealias FileWrite = @Sendable (LiveTextFile, URL) throws -> Void

    private struct State {
        var volatile: [String: [TranscriptSegment]] = [:]
        var dirty = false
        var closed = false
        var sequence = 0
        var writer: Task<Void, Never>?
    }

    private let url: URL
    private let interval: Duration
    private let fileWrite: FileWrite
    private let state = Mutex(State())

    public convenience init(session: URL) {
        self.init(url: SessionPaths.liveText(session))
    }

    init(url: URL, interval: Duration = LiveTextPublisher.interval, write: FileWrite? = nil) {
        self.url = url
        self.interval = interval
        fileWrite = write ?? { file, url in try AtomicFile.writeJSON(file, to: url) }
    }

    /// `track`'s volatile segments now (empty: none). Written with the next write.
    public func set(track: String, segments: [TranscriptSegment]) {
        state.withLock { state in
            guard !state.closed, state.volatile[track] ?? [] != segments else { return }
            state.volatile[track] = segments.isEmpty ? nil : segments
            state.dirty = true
            guard state.writer == nil else { return }
            state.writer = Task.detached(priority: .utility) { [weak self] in await self?.writeWhileDirty() }
        }
    }

    /// Stops writing and removes `live.json`. Later `set` calls are ignored.
    public func close() async {
        let writer = state.withLock { state -> Task<Void, Never>? in
            state.closed = true
            defer { state.writer = nil }
            return state.writer
        }
        writer?.cancel()
        await writer?.value
        _ = AtomicFile.removeRegularFile(url)
    }

    /// Writes while something changed, pausing `interval` after each write; ends (clearing `writer`) when nothing
    /// changed during the pause, or once closed.
    private func writeWhileDirty() async {
        while let file = takeChange() {
            try? fileWrite(file, url)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    private func takeChange() -> LiveTextFile? {
        state.withLock { state in
            guard state.dirty, !state.closed else {
                if !state.closed { state.writer = nil }
                return nil
            }
            state.dirty = false
            state.sequence += 1
            return LiveTextFile(sequence: state.sequence, volatile: state.volatile)
        }
    }
}
