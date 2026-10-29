import Foundation
import HolosContent
import Testing
@testable import HolosApp

/// The Reading list's feeds of parts: one per reading being made, ended as its entry says, then let go.
@MainActor struct ReadingPartFeedsTests {
    private func part(_ index: Int) -> ReadingMadePart {
        ReadingMadePart(index: index, total: 2, audio: URL(fileURLWithPath: "/tmp/part\(index).caf"), duration: 1,
                        silenceBefore: 0)
    }

    @Test func aFeedEndsAsItsReadingDidAndIsLetGo() throws {
        let feeds = ReadingPartFeeds()
        var made: [UUID] = []
        feeds.onPartMade = { made.append($0) }
        let (done, failed, stopped) = (UUID(), UUID(), UUID())
        for id in [done, failed, stopped] { feeds.add(part(0), to: id) }
        feeds.add(part(1), to: done)
        #expect(made == [done, failed, stopped, done])
        let kept = try #require(feeds.feed(done))
        #expect(kept.madeInOrder == 2)

        var entry = ReadingEntry(source: .selection(app: nil), requestedVoice: nil, speed: 1)
        entry.state = .done
        feeds.ended(done, as: entry)
        #expect(kept.end == .finished)
        #expect(feeds.feed(done) == nil)

        let failing = try #require(feeds.feed(failed))
        entry.state = .failed
        entry.message = "No voice."
        feeds.ended(failed, as: entry)
        #expect(failing.end == .failed("No voice."))

        let stopping = try #require(feeds.feed(stopped))
        entry.state = .stopped
        feeds.ended(stopped, as: entry)
        #expect(stopping.end == .stopped)

        // A reading with no part made has no feed to end.
        feeds.ended(UUID(), as: entry)
    }
}
