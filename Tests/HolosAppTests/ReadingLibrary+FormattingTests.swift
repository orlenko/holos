import HolosContent
import Testing
@testable import HolosApp

/// The Reading pane's duration and position texts (`ReadingLibrary+Formatting.swift`).
@Suite struct ReadingLibraryFormattingTests {
    @Test func durationsAndPositionsRead() {
        #expect(ReadingLibrary.durationText(40) == "40 s")
        #expect(ReadingLibrary.durationText(25 * 60 + 10) == "25 min")
        #expect(ReadingLibrary.durationText(3_600) == "1 h")
        #expect(ReadingLibrary.durationText(3_900) == "1 h 5 min")
        #expect(ReadingLibrary.clockText(187) == "3:07")
        #expect(ReadingLibrary.clockText(3_723) == "1:02:03")
        #expect(ReadingLibrary.clockText(.nan) == "0:00")
    }
}
