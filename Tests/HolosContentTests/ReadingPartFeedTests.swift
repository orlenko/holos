import Foundation
import Testing
@testable import HolosContent

@MainActor struct ReadingPartFeedTests {
    private func part(_ index: Int, of total: Int = 3, duration: Double = 2) -> ReadingMadePart {
        ReadingMadePart(index: index, total: total, audio: URL(fileURLWithPath: "/tmp/part\(index).caf"),
                        duration: duration, silenceBefore: index == 0 ? 0 : 0.5)
    }

    /// Parts made out of order (a resume that kept a later part) play only from the first on, with none missing.
    @Test func partsPlayInOrderFromTheFirst() {
        let feed = ReadingPartFeed()
        #expect(feed.total == nil)
        #expect(feed.madeInOrder == 0)
        feed.add(part(1))
        #expect(feed.total == 3)
        #expect(feed.madeInOrder == 0)
        #expect(feed.madeDuration == 0)
        feed.add(part(0))
        #expect(feed.madeInOrder == 2)
        #expect(feed.madeDuration == 2 + 0.5 + 2)
        #expect(!feed.isComplete)
        feed.add(part(2, duration: 1))
        #expect(feed.madeInOrder == 3)
        #expect(feed.madeDuration == 2 + 2.5 + 1.5)
        #expect(feed.isComplete)
    }

    /// Invariants 1-3: a part added again, one of another total, and anything after the end change nothing and say
    /// nothing; the end is set once.
    @Test func partsAreAddedOnceAndNothingAfterTheEnd() {
        let feed = ReadingPartFeed()
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.add(part(0, duration: 2))
        feed.add(part(0, duration: 9))
        feed.add(part(1, of: 4))
        #expect(changes == 1)
        #expect(feed.parts[0]?.duration == 2)
        #expect(feed.parts[1] == nil)

        feed.finish(.failed("The voice is gone."))
        feed.finish(.finished)
        feed.add(part(1))
        #expect(changes == 2)
        #expect(feed.end == .failed("The voice is gone."))
        #expect(feed.parts.count == 1)
    }
}
