import Foundation
@testable import HolosMeeting
import Testing

// Review playback (docs/meeting-design.md §5.10): the word and turn at the play head, ⌘←/⌘→, clicking a word,
// following playback, the speed setting, and what VoiceOver hears. Helpers are prefixed `playback`.

private let playbackTurns: [(start: Double, end: Double)] = [
    (0, 4),     // 0
    (5, 12),    // 1
    (10, 14),   // 2: overlaps the end of 1
    (20, 25),   // 3
]

@Test func playbackTurnAtTimeIsTheLatestStartedTurnStillSpeaking() {
    #expect(ReviewTimeline.turnIndex(at: 0, turns: playbackTurns) == 0)
    #expect(ReviewTimeline.turnIndex(at: 3.99, turns: playbackTurns) == 0)
    #expect(ReviewTimeline.turnIndex(at: 4, turns: playbackTurns) == nil, "A turn's end is not in it.")
    #expect(ReviewTimeline.turnIndex(at: 4.5, turns: playbackTurns) == nil, "Silence between turns.")
    #expect(ReviewTimeline.turnIndex(at: 9, turns: playbackTurns) == 1)
    #expect(ReviewTimeline.turnIndex(at: 11, turns: playbackTurns) == 2, "The reply that overlaps wins.")
    #expect(ReviewTimeline.turnIndex(at: 13, turns: playbackTurns) == 2)
    #expect(ReviewTimeline.turnIndex(at: 30, turns: playbackTurns) == nil)
    #expect(ReviewTimeline.turnIndex(at: 1, turns: []) == nil)
    // Two turns starting together: the later one in the list.
    #expect(ReviewTimeline.turnIndex(at: 1, turns: [(0, 5), (0, 3)]) == 1)
    // A longer turn listed after a shorter one that started later still loses to it.
    #expect(ReviewTimeline.turnIndex(at: 2, turns: [(1, 3), (0, 9)]) == 0)
}

@Test func playbackWordAtTimeIsTheLastWordStarted() {
    let starts = [1.0, 1.4, 2.0, 2.5]
    #expect(ReviewTimeline.wordIndex(at: 0.5, starts: starts) == nil)
    #expect(ReviewTimeline.wordIndex(at: 1.0, starts: starts) == 0)
    #expect(ReviewTimeline.wordIndex(at: 1.38, starts: starts) == 0)
    #expect(ReviewTimeline.wordIndex(at: 1.395, starts: starts) == 1, "A seek rounded just below a word lands on it.")
    #expect(ReviewTimeline.wordIndex(at: 2.2, starts: starts) == 2)
    #expect(ReviewTimeline.wordIndex(at: 99, starts: starts) == 3)
    #expect(ReviewTimeline.wordIndex(at: 1, starts: []) == nil)
}

@Test func playbackNextAndPreviousTurn() {
    let starts = playbackTurns.map(\.start)
    #expect(ReviewTimeline.nextTurnStart(after: 0, starts: starts) == 5)
    #expect(ReviewTimeline.nextTurnStart(after: 5, starts: starts) == 10, "The turn just jumped to is skipped.")
    #expect(ReviewTimeline.nextTurnStart(after: 5.02, starts: starts) == 10)
    #expect(ReviewTimeline.nextTurnStart(after: 20, starts: starts) == nil)
    #expect(ReviewTimeline.nextTurnStart(after: 1, starts: [.nan, 3]) == 3)

    // Well into a turn: back to its start; just after it: the one before.
    #expect(ReviewTimeline.previousTurnStart(before: 8, starts: starts) == 5)
    #expect(ReviewTimeline.previousTurnStart(before: 5.5, starts: starts) == 0)
    #expect(ReviewTimeline.previousTurnStart(before: 22, starts: starts) == 20)
    #expect(ReviewTimeline.previousTurnStart(before: 21, starts: starts) == 10)
    #expect(ReviewTimeline.previousTurnStart(before: 1, starts: starts) == 0)
    #expect(ReviewTimeline.previousTurnStart(before: 3, starts: []) == 0)
    // A short turn just before the one playing is not skipped.
    #expect(ReviewTimeline.previousTurnStart(before: 10.6, starts: [0, 10, 10.5]) == 10)
    #expect(ReviewTimeline.previousTurnStart(before: 10, starts: [0, 10, 10.5]) == 0)
    // Turns starting together count once.
    #expect(ReviewTimeline.previousTurnStart(before: 5.2, starts: [2, 5, 5]) == 2)
}

@Test func playbackWordRangesFollowTheShownText() throws {
    let text = "Hello, world. It's “fine” — really."
    let ranges = ReviewWordRanges.ranges(of: ["Hello,", "world.", "It's", "fine", "—", "really."], in: text)
    let shown = text as NSString
    let words = ranges.map { $0.map { shown.substring(with: $0) } }
    #expect(words == ["Hello,", "world.", "It's", "fine", "—", "really."])
}

@Test func playbackWordRangesSkipWordsNotShownNearby() {
    let text = "the cat sat on the mat"
    // "dog" and the empty word are not in the text: they get no range and the words after them still do.
    let ranges = ReviewWordRanges.ranges(of: ["the", "dog", "cat", " sat ", "", "on", "the", "mat"], in: text)
    #expect(ranges.map { $0?.location } == [0, nil, 4, 8, nil, 12, 15, 19])
    // Case and diacritics may differ.
    let other = ReviewWordRanges.ranges(of: ["cafe", "OK"], in: "Café ok")
    #expect(other.map { $0?.location } == [0, 5])
    // A word far past the previous one is not searched for.
    let far = ReviewWordRanges.ranges(of: ["a", "b"], in: "a " + String(repeating: "x", count: 100) + " b")
    #expect(far[1] == nil)
    #expect(ReviewWordRanges.ranges(of: ["a"], in: "").map { $0 == nil } == [true])
}

@Test func playbackClickedCharacterPicksItsWord() {
    let text = "Hello, world again"
    let ranges = ReviewWordRanges.ranges(of: ["Hello", "world", "again"], in: text)
    #expect(ReviewWordRanges.word(at: 0, ranges: ranges) == 0)
    #expect(ReviewWordRanges.word(at: 4, ranges: ranges) == 0)
    #expect(ReviewWordRanges.word(at: 5, ranges: ranges) == 0, "The comma after a word plays that word.")
    #expect(ReviewWordRanges.word(at: 6, ranges: ranges) == 0, "So does the space.")
    #expect(ReviewWordRanges.word(at: 7, ranges: ranges) == 1)
    #expect(ReviewWordRanges.word(at: 17, ranges: ranges) == 2)
    #expect(ReviewWordRanges.word(at: 99, ranges: ranges) == 2)
    // Before the first word found: the first word; no word found: nothing.
    let leading = ReviewWordRanges.ranges(of: ["missing", "b"], in: "a b")
    #expect(ReviewWordRanges.word(at: 0, ranges: leading) == 1)
    #expect(ReviewWordRanges.word(at: 0, ranges: [nil, nil]) == nil)
    #expect(ReviewWordRanges.word(at: 0, ranges: []) == nil)
}

@Test func playbackFollowPausesAfterScrollingAndResumes() {
    var follow = ReviewFollow()
    #expect(follow.isFollowing(at: 100))
    follow.userScrolled(at: 100)
    #expect(!follow.isFollowing(at: 100))
    #expect(!follow.isFollowing(at: 100 + ReviewFollow.resumeAfter - 0.1))
    #expect(follow.isFollowing(at: 100 + ReviewFollow.resumeAfter), "Following resumes a few seconds later.")

    // Scrolling again pushes the resume back.
    follow.userScrolled(at: 103)
    #expect(!follow.isFollowing(at: 106))
    #expect(follow.isFollowing(at: 103 + ReviewFollow.resumeAfter))

    // Play, a word, a timestamp: at once.
    follow.userScrolled(at: 200)
    follow.resume()
    #expect(follow.isFollowing(at: 200))
    #expect(follow.scrolledAt == nil)

    // A clock that went backwards does not hold following off.
    follow.userScrolled(at: 300)
    #expect(follow.isFollowing(at: 10))
}

@Test func playbackSpeedIsRememberedAndOnlyKnownSpeedsCount() throws {
    let suite = "ReviewPlaybackTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ReviewPlaybackSpeed.load(from: defaults) == 1, "Nothing saved: 1×.")
    ReviewPlaybackSpeed.save(1.5, to: defaults)
    #expect(ReviewPlaybackSpeed.load(from: defaults) == 1.5)
    ReviewPlaybackSpeed.save(3, to: defaults)
    #expect(ReviewPlaybackSpeed.load(from: defaults) == 1.5, "An unknown speed is not saved.")
    defaults.set(0.7, forKey: ReviewPlaybackSpeed.key)
    #expect(ReviewPlaybackSpeed.load(from: defaults) == 1, "An unknown saved speed reads as 1×.")
    defaults.set("fast", forKey: ReviewPlaybackSpeed.key)
    #expect(ReviewPlaybackSpeed.load(from: defaults) == 1)

    #expect(ReviewPlaybackSpeed.rates.map(ReviewPlaybackSpeed.title) == ["1×", "1.25×", "1.5×", "2×"])
}

@Test func playbackAnnouncesOnlyANewSpeaker() {
    var announcer = ReviewSpeakerAnnouncer()
    #expect(announcer.announcement(for: "Jim") == "Jim")
    #expect(announcer.announcement(for: "Jim") == nil, "The same speaker's next turn says nothing.")
    #expect(announcer.announcement(for: nil) == nil, "Silence says nothing.")
    #expect(announcer.announcement(for: "Jim") == nil, "Nor does the same speaker after a silence.")
    #expect(announcer.announcement(for: "Maria") == "Maria")
    announcer.reset()
    #expect(announcer.announcement(for: "Maria") == "Maria", "After a pause, the speaker is said again.")
}
