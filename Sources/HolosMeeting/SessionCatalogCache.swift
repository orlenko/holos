import Foundation
import Synchronization

/// What the catalog read for each finished meeting, for a caller that lists again and again: reading a meeting parses
/// its transcript, its event journal and its speaker labels, so listing every meeting every 2 s kept a CPU core busy
/// while the app sat idle. A meeting whose folder did not change is not read again.
///
/// Invariants:
/// 1. A summary is reused only while its folder's stamp (`SessionCatalog.sizes`) and the recorder's liveness equal
///    those taken before the reads that made it. A write during the reads therefore makes the next listing read again,
///    and so does a file written, replaced, added or removed since. Two listings at once can only leave a stamp that no
///    longer matches, which reads again.
/// 2. Only a settled summary is kept (`isSettled`): no recorder at work on the meeting, and nothing in it unreadable,
///    so a file that is busy now and a meeting being written are read every time.
/// 3. A summary is reused for at most `maxAge`, measured on the listing's own clock, so a read that failed without
///    showing as a problem (a `try?` among the catalog's reads) cannot last until the app quits.
/// 4. `jobInProgress` is not kept: the background-job lock lives outside the folder, and the catalog reads it for each
///    listing.
public final class SessionCatalogCache: Sendable {
    /// How long a summary is reused however quiet its folder is.
    static let maxAge: TimeInterval = 600

    private struct Entry {
        var stamp: Int
        var liveness: RecorderLiveness
        var readAt: Date
        var summary: SessionSummary
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var reused = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// How many summaries were reused (tests).
    var reusedCount: Int { state.withLock { $0.reused } }

    /// The summary kept for `session`, while invariants 1 and 3 hold.
    func summary(of session: URL, stamp: Int, liveness: RecorderLiveness, now: Date) -> SessionSummary? {
        state.withLock { state in
            guard let entry = state.entries[session.path], entry.stamp == stamp, entry.liveness == liveness else {
                return nil
            }
            let age = now.timeIntervalSince(entry.readAt)
            guard age >= 0, age < Self.maxAge else { return nil }
            state.reused += 1
            return entry.summary
        }
    }

    /// Keeps `summary` when it is settled; otherwise forgets what was kept for `session`.
    func remember(_ summary: SessionSummary, session: URL, stamp: Int, now: Date) {
        state.withLock { state in
            state.entries[session.path] = Self.isSettled(summary)
                ? Entry(stamp: stamp, liveness: summary.liveness, readAt: now, summary: summary) : nil
        }
    }

    /// Forgets folders no longer listed.
    func keep(only paths: Set<String>) {
        state.withLock { state in state.entries = state.entries.filter { paths.contains($0.key) } }
    }

    /// Nothing is writing the meeting and everything in it could be read.
    static func isSettled(_ summary: SessionSummary) -> Bool {
        switch summary.liveness {
        case .capturing, .processing, .maintenance: return false
        case .exited, .dead: break
        }
        return summary.state != .damaged && summary.speakerState != .unreadable && summary.transcriptProblem == nil
            && summary.metadataProblem == nil && summary.exportsProblem == nil && summary.summaryProblem == nil
    }
}
