import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// The per-paragraph check: what is heard against what is written, numbers spelled out on both sides.

@Suite struct SpeechChunkCheckTests {
    @Test func whatIsHeardMatchesIgnoringCasePunctuationAndHowNumbersAreWritten() {
        let text = "The garden had 1,500 flowers. Children walked out on Sundays!"
        for heard in ["the garden had 1500 flowers children walked out on sundays",
                      "the garden had one thousand five hundred flowers children walked out on sundays"] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard, language: "en").passed, "\(heard)")
        }
        let digits = "the garden had 1500 flowers children walked out on sundays"
        #expect(SpeechChunkCheck.evaluate(expected: text, heard: digits, language: "en").wordErrorRate == 0)
        #expect(SpeechChunkCheck.evaluate(expected: "Café crème", heard: "cafe creme", language: "fr").wordErrorRate == 0)
    }

    @Test func garbledOrCutOffSpeechFails() {
        let text = "Each morning he carried buckets of rainwater up the rocky path, counting his steps out of habit."
        #expect(!SpeechChunkCheck.evaluate(expected: text, heard: "each morning he carried banana phone river tock",
                                           language: "en").passed)
        // A long paragraph cut off after nine words: few edits proportionally, but more than 8 words missing.
        let long = Array(repeating: text, count: 4).joined(separator: " ")
        let cut = long.split(separator: " ").dropLast(9).joined(separator: " ")
        let verdict = SpeechChunkCheck.evaluate(expected: long, heard: cut, language: "en")
        #expect(verdict.wordErrorRate < 0.15)
        #expect(!verdict.passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "Hello there.", heard: "", language: "en").passed)
    }

    @Test func shortTextsAllowTwoEditsButNeedAWordRight() {
        #expect(SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden",
                                          heard: "the lighthouse keepers garden", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden", heard: "a light house",
                                           language: "en").passed)
        // Two edits allowed, but not every word wrong.
        #expect(SpeechChunkCheck.evaluate(expected: "A Heading", heard: "a heading", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "A Heading", heard: "the heading", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "A Heading", heard: "banana phone", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "Garden", heard: "parrot", language: "en").passed)
    }
}

@Suite struct SpeechChunkCheckNumberTests {
    @Test func numbersCompareHoweverTheRecognizerWritesThem() {
        let text = "In 2015 the tower was 3.05 metres tall and had 1,500 visitors."
        for heard in ["in 2015 the tower was 3.05 metres tall and had 1500 visitors",
                      "in two thousand fifteen the tower was three point zero five metres tall and had one thousand "
                          + "five hundred visitors"] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard, language: "en").passed, "\(heard)")
        }
        #expect(!SpeechChunkCheck.evaluate(
            expected: text, heard: "in 2015 the parrot sang loudly beside the river of visitors", language: "en").passed)
        let french = "En 2015, la tour mesurait 3,5 mètres et accueillait 1 500 visiteurs."
        for heard in ["en 2015 la tour mesurait 3,5 mètres et accueillait 1500 visiteurs",
                      "en deux mille quinze la tour mesurait trois virgule cinq mètres et accueillait mille cinq cents "
                          + "visiteurs"] {
            #expect(SpeechChunkCheck.evaluate(expected: french, heard: heard, language: "fr").passed, "\(heard)")
        }
    }

    @Test func aParagraphOfNumbersAloneFailsOnOtherNumbersOrNothing() {
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "2015", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "two thousand and fifteen", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "twenty", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "garbage", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "50 cents", heard: "5000", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "—", heard: "", language: "en").passed)
    }
}
