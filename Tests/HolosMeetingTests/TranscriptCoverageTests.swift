import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// Joining live transcription with a replay of what it missed (docs/meeting-design.md §4.6).

/// A segment whose words start at `starts`, each 0.2 s long, spelled "w0", "w1", …
private func timed(_ starts: [Double], id: String = UUID().uuidString, end: Double? = nil,
                   prefix: String = "w") -> TranscriptSegment {
    var text = ""
    var words: [TimedWord] = []
    for (index, start) in starts.enumerated() {
        if !text.isEmpty { text += " " }
        let word = "\(prefix)\(index)"
        words.append(TimedWord(text: word, start: start, end: start + 0.2, utf16Offset: text.utf16.count,
                               utf16Length: word.utf16.count))
        text += word
    }
    return TranscriptSegment(id: id, start: starts.first ?? 0, end: end ?? (starts.last ?? 0) + 0.2, text: text,
                             words: words, track: "mic")
}

@Test func coverageEndIsTheLastLiveEndCappedAtBehind() {
    let live = [timed([1, 2], end: 3), timed([10, 11], end: 12)]
    #expect(TranscriptCoverage.coverageEnd(live: live, behindFrom: nil) == 12)
    #expect(TranscriptCoverage.coverageEnd(live: live, behindFrom: 5) == 5)
    #expect(TranscriptCoverage.coverageEnd(live: live, behindFrom: 20) == 12)
    #expect(TranscriptCoverage.coverageEnd(live: [], behindFrom: nil) == 0)
    #expect(TranscriptCoverage.coverageEnd(live: [], behindFrom: 7) == 0)
}

@Test func coverageMergeSplitsStraddlingSegment() {
    let live = [timed([50, 51, 52], id: "LIVE", end: 53, prefix: "live")]
    let replayed = [timed([54.0, 55.0, 55.3, 56.0], id: "REPLAY", end: 57, prefix: "again")]
    let merged = TranscriptCoverage.merge(live: live, replayed: replayed, coverageEnd: 55.2)
    #expect(merged.count == 2)
    #expect(merged[0] == live[0], "Live words before the coverage end are intact.")
    let cut = merged[1]
    #expect(cut.id != "REPLAY", "The second part of a cut segment gets a new ID.")
    #expect(UUID(uuidString: cut.id) != nil)
    #expect(cut.words.map(\.start) == [55.3, 56.0])
    #expect(cut.text == "again2 again3")
    #expect(cut.words.map(\.utf16Offset) == [0, 7])
    #expect(cut.start == 55.3)
    #expect(cut.end == 57)
    #expect(cut.track == "mic")
}

@Test func liveSegmentCutKeepsItsIDAndTheWordsBefore() {
    let live = [timed([10, 11, 12, 13], id: "LIVE", end: 14)]
    let merged = TranscriptCoverage.merge(live: live, replayed: [], coverageEnd: 12)
    #expect(merged.count == 1)
    #expect(merged[0].id == "LIVE")
    #expect(merged[0].text == "w0 w1")
    #expect(merged[0].words.map(\.text) == ["w0", "w1"])
    #expect(merged[0].start == 10)
    #expect(abs(merged[0].end - 11.2) < 1e-9)
}

@Test func untimedSegmentsGoWholeByMidpoint() {
    let live = [TranscriptSegment(start: 8, end: 11, text: "kept"), TranscriptSegment(start: 9, end: 13, text: "dropped")]
    let replayed = [TranscriptSegment(start: 9, end: 10.5, text: "old"), TranscriptSegment(start: 9.5, end: 12, text: "new")]
    let merged = TranscriptCoverage.merge(live: live, replayed: replayed, coverageEnd: 10.5)
    #expect(merged.map(\.text) == ["kept", "new"])
}

@Test func mergeKeepsEveryWordOnce() {
    // Live covers 0–40 s; the replay starts 2 s earlier, at 38 s.
    let live = stride(from: 0.0, to: 40, by: 5).map { start in timed(Array(stride(from: start, to: start + 5, by: 1))) }
    let replayed = [timed(Array(stride(from: 38.0, to: 60, by: 1)))]
    let coverage = TranscriptCoverage.coverageEnd(live: live, behindFrom: 41.1)
    #expect(abs(coverage - 39.2) < 1e-9)
    let words = TranscriptCoverage.merge(live: live, replayed: replayed, coverageEnd: coverage).flatMap(\.words)
    #expect(words.map(\.start) == (0..<60).map(Double.init))
}

@Test func wordOffsetsThatDoNotFitTheTextAreRebuilt() {
    var segment = timed([1, 2, 3])
    segment.words[2].utf16Offset = 999
    let merged = TranscriptCoverage.merge(live: [], replayed: [segment], coverageEnd: 2.5)
    #expect(merged.count == 1)
    #expect(merged[0].text == "w2")
    #expect(merged[0].words.map(\.utf16Offset) == [0])
}
