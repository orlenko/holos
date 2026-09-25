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
    #expect(FillerWords.remove(from: "Um, “hello”") == "“Hello”")
    #expect(FillerWords.remove(from: "Uh, (see above)") == "(See above)")
    #expect(FillerWords.remove(from: "He said “um, hello”") == "He said “hello”")
    #expect(FillerWords.remove(from: "we did it, um... and then") == "we did it... and then")
}

@Test func keepsWordsThatOnlyLookLikeFillers() {
    let text = "Uh-huh, Ahmed measured 5 mm in the ER; umbrella drum"
    #expect(FillerWords.remove(from: text) == text)
    for token in ["write to um@example.com", "call foo_um_bar", "open um.example.com", "see path/um/file", "tag #um", "set x=um", "https://example.test/?q=um&x=1",
                  "host um:8080", "a+um"] {
        #expect(FillerWords.remove(from: token) == token)
    }
    #expect(FillerWords.remove(from: "Okay. Um. Next") == "Okay. Next")
    #expect(FillerWords.remove(from: "Hmm? Right: um, yes") == "Right: yes")
}

@Test func englishIsTheDefaultAndAnyEnglishLocaleMatches() {
    for language in ["en", "en-CA", "en_US", "EN-gb"] {
        #expect(FillerWords.remove(from: "Um, so we start", language: language) == "So we start")
    }
    #expect(FillerWords.remove(from: "Euh, bonjour") == "Euh, bonjour")  // French fillers stay in English text
}

@Test func removesFrenchFillers() {
    let fr = "fr-CA"
    #expect(FillerWords.remove(from: "Euh, je pense que oui", language: fr) == "Je pense que oui")
    #expect(FillerWords.remove(from: "Je pense, euh, que c'est bon", language: fr) == "Je pense que c'est bon")
    #expect(FillerWords.remove(from: "on se voit demain euh", language: fr) == "on se voit demain")
    #expect(FillerWords.remove(from: "C'est fini, euhh.", language: fr) == "C'est fini.")
    #expect(FillerWords.remove(from: "Heu... on commence", language: fr) == "On commence")
    #expect(FillerWords.remove(from: "Hum, attends", language: fr) == "Attends")
    #expect(FillerWords.remove(from: "Hmm, pas sûr", language: fr) == "Pas sûr")
    #expect(FillerWords.remove(from: "Bah, on verra", language: "fr-FR") == "On verra")
}

@Test func keepsFrenchWordsThatCarryMeaningOrOnlyLookLikeFillers() {
    let fr = "fr-CA"
    // Discourse words that are real words or change what is said.
    for text in ["Ah bon, tu viens ?", "Ben oui, c'est ça", "Bon, on y va", "C'est genre trois heures",
                 "Tsé, c'est pas facile", "C'est correct, hein ?", "Quoi, déjà ?"] {
        #expect(FillerWords.remove(from: text, language: fr) == text)
    }
    // Words that contain a filler.
    let text = "À quelle heure? Une humeur de bahut, l'humour du Heuland, j'ai humé 5 mm"
    #expect(FillerWords.remove(from: text, language: fr) == text)
    for token in ["écris à euh@example.com", "ouvre euh.example.com", "tag #bah", "x=hum"] {
        #expect(FillerWords.remove(from: token, language: fr) == token)
    }
    // English fillers are not French ones.
    #expect(FillerWords.remove(from: "Um, bonjour", language: fr) == "Um, bonjour")
}

@Test func languagesWithoutFillersAreLeftAlone() {
    // German "um" is a word ("um fünf Uhr").
    #expect(FillerWords.remove(from: "Wir treffen uns um fünf Uhr", language: "de-DE") == "Wir treffen uns um fünf Uhr")
    #expect(FillerWords.remove(from: "Uh, hola", language: "es-MX") == "Uh, hola")
    #expect(FillerWords.examples(language: "de-DE") == nil)
    #expect(FillerWords.examples(language: "fr-FR")?.contains("euh") == true)
    #expect(FillerWords.examples(language: "en-CA")?.contains("um") == true)
}

@Test func cleaningAGrowingFrenchTranscriptKeepsAPrefix() {
    let full = "Je pense, euh, que ça marche. Bah. Ensuite, hum, la suite"
    let complete = FillerWords.remove(from: full, language: "fr-CA")
    #expect(complete == "Je pense que ça marche. Ensuite la suite")
    for end in full.indices where full[end] == " " {
        let partial = FillerWords.removeWithholdingTrailingComma(from: String(full[..<end]), language: "fr-CA")
        #expect(complete.hasPrefix(partial.trimmingCharacters(in: .whitespaces)), "\(partial) | \(complete)")
    }
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
