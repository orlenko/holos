import Testing
@testable import HolosCore

@Test func removesFillersAndTheirCommas() {
    #expect(FillerWords.remove(from: "I, uh, cannot stream") == "I cannot stream")
    #expect(FillerWords.remove(from: "Um, so we start") == "So we start")
    #expect(FillerWords.remove(from: "so um we start") == "so we start")
    #expect(FillerWords.remove(from: "we did it, um.") == "we did it.")
    #expect(FillerWords.remove(from: "Okay. Um. Next one") == "Okay. Next one")
    #expect(FillerWords.remove(from: "Hmm?") == "")
    #expect(FillerWords.remove(from: "Ahh, uh, right") == "Right")
    #expect(FillerWords.remove(from: "Um... next") == "Next")
    #expect(FillerWords.remove(from: "“Um, hello”") == "“Hello”")
    #expect(FillerWords.remove(from: "He said “um, hello”") == "He said “hello”")
    #expect(FillerWords.remove(from: "we did it, um... and then") == "we did it... and then")
}

@Test func keepsWordsThatOnlyLookLikeFillers() {
    let text = "Uh-huh, Ahmed measured 5 mm in the ER; umbrella drum"
    #expect(FillerWords.remove(from: text) == text)
    for token in ["write to um@example.com", "call foo_um_bar", "open um.example.com", "see path/um/file", "tag #um"] {
        #expect(FillerWords.remove(from: token) == token)
    }
    #expect(FillerWords.remove(from: "Okay. Um. Next") == "Okay. Next")
}

@Test func cleaningAGrowingTranscriptKeepsAPrefix() {
    let full = "I think, um, that works. Uh. Next, uh, step"
    for end in full.indices {
        let partial = FillerWords.removeWithholdingTrailingComma(from: String(full[..<end]))
        let complete = FillerWords.remove(from: full)
        // A partial filler ("u", "um" before its comma) may still be pending; only whole words count.
        if full[end] == " " {
            #expect(complete.hasPrefix(partial.trimmingCharacters(in: .whitespaces)), "\(partial) | \(complete)")
        }
    }
}
