import Foundation
import HolosContent

/// The parts of the readings being made (`ReadingPartFeed`), so each can play before it is finished: one per reading,
/// from its first part made in a run until that run's work ends, when its feed says how and is let go (a player that
/// plays it keeps it).
///
/// Invariants:
/// 1. A reading has at most one feed, made by its first part of a run.
/// 2. Every run's end ends its feed, the quit's abandoned renders too, so nothing waits for parts that will not come.
/// 3. A feed's end says how the work ended, from the entry as it is at that moment.
/// 4. A stopped reading keeps its feed, which the next run's first part reopens.
@MainActor
final class ReadingPartFeeds {
    private var feeds: [UUID: ReadingPartFeed] = [:]
    /// A part of a reading was made.
    var onPartMade: ((UUID) -> Void)?

    func feed(_ id: UUID) -> ReadingPartFeed? { feeds[id] }

    func add(_ part: ReadingMadePart, to id: UUID) {
        let feed = feeds[id] ?? ReadingPartFeed()
        feeds[id] = feed
        // Resumed: a player still on what was made goes on with what is made now (invariant 4).
        feed.reopen()
        feed.add(part)
        onPartMade?(id)
    }

    /// The reading's work ended; `entry` (as it is now) says how: made, failed, or stopped.
    func ended(_ id: UUID, as entry: ReadingEntry?) {
        guard let feed = feeds[id] else { return }
        switch entry?.state {
        case .done?:
            feeds[id] = nil
            feed.finish(.finished)
        case .failed?:
            feeds[id] = nil
            feed.finish(.failed(entry?.message ?? "Making it failed."))
        default:
            // Stopped: kept for Resume, unless the reading has left the list.
            if entry == nil { feeds[id] = nil }
            feed.finish(.stopped)
        }
    }
}
