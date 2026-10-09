import Testing
@testable import HolosSynthesis

// A paragraph of numbers alone is checked by its numbers' values (`SpokenNumbers`).

@Suite struct SpeechChunkCheckNumbersTests {
    @Test func aParagraphOfNumbersAlonePassesOnlyWithTheSameNumbers() {
        // Right, however the recognizer writes them.
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "two thousand and fifteen").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "twenty fifteen").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "1,500 2,000 3,500.", heard: "1500 2000 3500").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "2015", heard: "deux mille quinze").passed)
        // Wrong numbers, other words, or nothing: a cut-off or garbled take.
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "twenty").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "garbage").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "1,500 2,000 3,500.", heard: "1500 2000").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "2015 and then some other words").passed)
        // Nothing to say at all passes as before.
        #expect(SpeechChunkCheck.evaluate(expected: "—", heard: "").passed)
    }
}
