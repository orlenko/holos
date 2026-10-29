import Foundation
import HolosContent

/// What ▶ Play and the read-aloud shortcut play: a made reading from its checked file, and one being made from its
/// parts once its first is made, handed over to its file once it is made (docs/design.md "Reading section").
extension ReadingController {
    /// Reading `id` has something to play: its first part made while it is made, else its checked file.
    func canPlay(_ id: UUID) -> Bool {
        guard let entry = entry(id) else { return false }
        if entry.state == .rendering { return (feeds.feed(id)?.madeInOrder ?? 0) > 0 }
        return entry.state == .done && fileProblem(entry) == nil
    }

    /// Plays, pauses, or continues reading `id` on `player`. False when its file is not the one it made (see
    /// `ReadingPlayer.play`); throws when it cannot start.
    func play(_ id: UUID, on player: ReadingPlayer) async throws -> Bool {
        guard let entry = entry(id) else { return false }
        if entry.state == .rendering, let feed = feeds.feed(id), feed.madeInOrder > 0 {
            try player.play(id, feed: feed) { [weak self] in await self?.openFinishedFile(id: id) }
            return true
        }
        return try await player.play(id) { await self.openFinishedFile(entry) }
    }

    /// The reading's finished file opened (see `openFinishedFile`), as the reading is now: one being made when Play
    /// was pressed is looked up again once made.
    func openFinishedFile(id: UUID) async -> FileHandle? {
        guard let entry = entry(id) else { return nil }
        return await openFinishedFile(entry)
    }
}
