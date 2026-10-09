import Foundation
import Testing
@testable import HolosCore

// The word list (docs/design.md "Word list"): case-preserving terms, deduplicated ignoring case; the recognizer's
// vocabulary built from it, corrections and names; and its words as real words for the fix's guard.

private let listDate = Date(timeIntervalSince1970: 1_790_000_000)

@Test func theWordListKeepsCaseAndDeduplicatesIgnoringCase() {
    var list = WordList()
    #expect(list.add("Keycloak", at: listDate) == .added("Keycloak"))
    #expect(list.add("  Urban   Sky ", at: listDate) == .added("Urban Sky"))
    #expect(list.add("keycloak") == .duplicate(existing: "Keycloak"))
    #expect(list.add("URBAN SKY") == .duplicate(existing: "Urban Sky"))
    #expect(list.add("urban\tsky") == .duplicate(existing: "Urban Sky"))
    #expect(list.add("   ") == .empty)
    #expect(list.add(String(repeating: "a", count: WordList.maximumLength + 1)) == .tooLong)
    #expect(list.add("Husky bus", source: .review, at: listDate) == .added("Husky bus"))
    #expect(list.terms == ["Keycloak", "Urban Sky", "Husky bus"])
    #expect(list.entries[2].source == .review && list.entries[0].addedAt == listDate)
    #expect(list.contains("KEYCLOAK") && !list.contains("Keycloa"))
    #expect(list.remove("keyCLOAK") == "Keycloak")
    #expect(list.remove("Keycloak") == nil)
    #expect(list.terms == ["Urban Sky", "Husky bus"])
}

@Test func theWordListStopsAtItsLimit() {
    var list = WordList()
    for index in 0..<WordList.maximumTerms { list.add("term \(index)") }
    #expect(list.add("one more") == .full)
    // A duplicate says so even when the list is full.
    #expect(list.add("TERM 3") == .duplicate(existing: "term 3"))
    #expect(list.count == WordList.maximumTerms)
}

@Test func pastedAndImportedTextIsOneTermPerLine() {
    #expect(WordList.lines(in: "Volpe lite\r\n  Husky bus \n\n\tDavin\nGeofence") == ["Volpe lite", "Husky bus", "Davin", "Geofence"])
    #expect(WordList.lines(in: "\n \n") == [])
}

@Test func theWordListRoundTripsAndRefusesANewerVersion() throws {
    var list = WordList()
    list.add("AtmoSys", at: listDate)
    list.add("Fab", source: .review, at: listDate)
    let data = try HolosJSON.encoder().encode(list)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\" : 1") && text.contains("\"source\" : \"review\""))
    #expect(try HolosJSON.decoder().decode(WordList.self, from: data) == list)

    // A hand-edited file is cleaned and deduplicated as `add` does; an unknown source is kept as written.
    let edited = """
        {"schemaVersion": 1, "entries": [
          {"text": " Apex ", "addedAt": "2026-09-29T10:00:00Z", "source": "user"},
          {"text": "apex", "addedAt": "2026-09-29T10:00:00Z", "source": "user"},
          {"text": "", "addedAt": "2026-09-29T10:00:00Z", "source": "user"},
          {"text": "ops", "addedAt": "2026-09-29T10:00:00Z", "source": "sync"}]}
        """
    let read = try HolosJSON.decoder().decode(WordList.self, from: Data(edited.utf8))
    #expect(read.terms == ["Apex", "ops"] && read.entries[1].source == WordListSource("sync"))

    let newer = #"{"schemaVersion": 2, "entries": []}"#
    #expect(throws: HolosError.self) { try HolosJSON.decoder().decode(WordList.self, from: Data(newer.utf8)) }
}

@Test func theRecognizerGetsTheWordListFirstDeduplicatedAndCapped() {
    let corrections = CorrectionList(entries: [Correction(heard: "key cloak", meant: "keycloak"),
                                               Correction(heard: "you bun too", meant: "on Ubuntu")])
    #expect(RecognizerVocabulary.dictation(wordList: ["Keycloak", "Urban Sky"], corrections: corrections,
                                           language: "en-US") == ["Keycloak", "Urban Sky", "Ubuntu"])
    #expect(RecognizerVocabulary.meeting(wordList: ["Davin"], names: ["davin", "Mary Smith"], corrections: corrections,
                                         languages: ["en-US"]) == ["Davin", "Mary Smith", "keycloak", "Ubuntu"])
    // Blank and over-long strings are dropped; whitespace is collapsed.
    #expect(RecognizerVocabulary.merged([[" Husky  bus ", "", String(repeating: "x", count: 101)], ["husky bus"]])
        == ["Husky bus"])
    // Past the limit, the word list comes first and the rest is left out.
    let many = (0..<150).map { "term\($0)" }
    let capped = RecognizerVocabulary.dictation(wordList: many, corrections: corrections, language: "en-US")
    #expect(capped.count == RecognizerVocabulary.maximumStrings && capped.first == "term0" && capped.last == "term99")
    #expect(RecognizerVocabulary.maximumStrings == 100)
}

@Test func theRunAgainPipelineGivesTheRecognizerTheWordList() {
    let corrections = CorrectionList(entries: [Correction(heard: "you bun too", meant: "Ubuntu")])
    let pipeline = DictationTextPipeline(language: "en-US", removeFillers: true, corrections: corrections,
                                         wordList: ["Geofence", "ubuntu"])
    #expect(pipeline.vocabulary == ["Geofence", "ubuntu"])
    #expect(DictationTextPipeline(language: "en-US", removeFillers: true, corrections: corrections).vocabulary
        == ["Ubuntu"])
}

// MARK: - The fix's guard

/// A lexicon that knows a few ordinary words and `terms`' words, and nothing else.
private func lexicon(_ terms: [String] = []) -> Lexicon {
    let known: Set<String> = ["we", "log", "in", "with", "the", "team", "ask", "today", "is", "on", "call", "opt"]
    return Lexicon(taught: terms, lookup: { known.contains($0.lowercased()) })
}

@Test func wordListTermsAreRealWordsForTheGuard() {
    #expect(lexicon(["Keycloak", "Urban Sky"]).isWord("keycloak"))
    #expect(lexicon(["Keycloak", "Urban Sky"]).isWord("urban") && lexicon(["Urban Sky"]).isWord("sky"))
    #expect(!lexicon().isWord("keycloak"))
}

@Test func aNonWordMayBecomeACloseWordListTerm() {
    let original = "we log in with keycloack", fixed = "we log in with keycloak"
    #expect(AIFixGuard.check(original: original, fixed: fixed, lexicon: lexicon(["Keycloak"])) == .accept)
    #expect(AIFixGuard.check(original: original, fixed: fixed, lexicon: lexicon()) != .accept)
}

@Test func theWordListLoosensNothingElse() {
    // A listed term is a real word: it changes only for a listed homophone, never for another close word.
    #expect(AIFixGuard.check(original: "the ops team is on call", fixed: "the opt team is on call",
                             lexicon: lexicon(["ops"])) != .accept)
    // A capitalized name stays as written, even when the replacement is on the list.
    #expect(AIFixGuard.check(original: "ask Daven today", fixed: "ask Davin today", lexicon: lexicon(["Davin"]))
        != .accept)
    // No word is split or joined for a term ("key cloak" is two words).
    #expect(AIFixGuard.check(original: "we log in with key cloak", fixed: "we log in with keycloak",
                             lexicon: lexicon(["Keycloak"])) == .reject(.wordCountChanged))
    // The case of the term is not brought in mid-sentence.
    #expect(AIFixGuard.check(original: "we log in with keycloack", fixed: "we log in with Keycloak",
                             lexicon: lexicon(["Keycloak"])) != .accept)
}

@Test(.systemSpelling) func theFixerCountsItsWordListAsRealWords() async {
    func fix(_ wordList: [String]) async -> TranscriptFixer.Outcome {
        var fixer = TranscriptFixer(corrections: CorrectionList(), wordList: wordList, referenceBudget: 500,
                                    timeout: .seconds(30), language: "en-US") { _, _ in "we sign in with keycloak" }
        fixer.spellingBudget = .seconds(60)
        return await fixer.fix("we sign in with keycloack", isFinal: false).outcome
    }
    #expect(await fix(["Keycloak"]) == .fixed)
    #expect(await fix([]) == .rejected)
}
