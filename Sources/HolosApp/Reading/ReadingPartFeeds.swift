import Foundation
import HolosContent

/// The parts of the readings being made (`ReadingPartFeed`), so each can play before it is finished: one per reading,
/// from its first part made in a run until that run's work ends, when its feed says how and is let go (a player that
/// plays it keeps it).
@MainActor
final class ReadingPartFeeds {
    private var feeds: [UUID: ReadingPartFeed] = [:]
    /// A part of a reading was made.
    var onPartMade: ((UUID) -> Void)?

    func feed(_ id: UUID) -> ReadingPartFeed? { feeds[id] }

    func add(_ part: ReadingMadePart, to id: UUID) {
        let feed = feeds[id] ?? ReadingPartFeed()
        feeds[id] = feed
        feed.add(part)
        onPartMade?(id)
    }

    /// The reading's work ended; `entry` (as it is now) says how: made, failed, or stopped.
    func ended(_ id: UUID, as entry: ReadingEntry?) {
        guard let feed = feeds.removeValue(forKey: id) else { return }
        switch entry?.state {
        case .done?: feed.finish(.finished)
        case .failed?: feed.finish(.failed(entry?.message ?? "Making it failed."))
        default: feed.finish(.stopped)
        }
    }
}
