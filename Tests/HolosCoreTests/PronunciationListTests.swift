import Foundation
import Testing
@testable import HolosCore

// The pronunciation list (docs/design.md "Pronunciations"): entries kept as set, and text respelled by them.

private let day = Date(timeIntervalSince1970: 1_790_000_000)

private func list(_ pairs: [(String, String)]) -> PronunciationList {
    var list = PronunciationList()
    for (written, sayAs) in pairs { list.set(written, sayAs: sayAs, at: day) }
    return list
}

@Test func anEntryIsAddedChangedAndRemovedByItsWrittenForm() {
    var list = PronunciationList()
    #expect(list.set("  XIMEA ", sayAs: "zai  mee ah", at: day)
        == .added(Pronunciation(written: "XIMEA", sayAs: "zai mee ah", addedAt: day)))
    #expect(list.set("XIMEA", sayAs: "zai mee ah") == .unchanged(list.entries[0]))
    let later = day.addingTimeInterval(60)
    #expect(list.set("XIMEA", sayAs: "zee mee ah", at: later)
        == .changed(Pronunciation(written: "XIMEA", sayAs: "zee mee ah", addedAt: day), previous: "zai mee ah"))
    // Case counts: "ximea" is another entry.
    #expect(list.set("ximea", sayAs: "kseemeh", at: day) == .added(Pronunciation(written: "ximea", sayAs: "kseemeh",
                                                                                  addedAt: day)))
    #expect(list.set(" ", sayAs: "x") == .empty && list.set("x", sayAs: "\n") == .empty)
    #expect(list.set(String(repeating: "a", count: 101), sayAs: "x") == .tooLong)
    #expect(list.remove("Ximea") == nil)
    #expect(list.remove(" XIMEA")?.written == "XIMEA")
    #expect(list.entries.map(\.written) == ["ximea"])
}

@Test func aFullListRefusesANewEntryButStillChangesOne() {
    var list = PronunciationList()
    for index in 0..<PronunciationList.maximumEntries { list.set("w\(index)", sayAs: "x", at: day) }
    #expect(list.set("another", sayAs: "x") == .full)
    #expect(list.set("w0", sayAs: "y") == .changed(Pronunciation(written: "w0", sayAs: "y", addedAt: day),
                                                    previous: "x"))
}

@Test func lowerCaseEntriesMatchAnyCaseAndCapitalisedOnesOnlyAsWritten() {
    let list = list([("XIMEA", "zai mee ah"), ("gz-link", "gee zee link"), ("US", "you ess")])
    let respelled = list.respelled("XIMEA, Ximea and ximea. Gz-link or GZ-LINK; us and the US.")
    #expect(respelled.text == "zai mee ah, Ximea and ximea. gee zee link or gee zee link; us and the you ess.")
    #expect(respelled.spellings == ["zai mee ah", "gee zee link", "you ess"])
}

@Test func onlyWholeWordsMatchAndPhrasesSpanAnyWhitespace() {
    let list = list([("XIMEA", "zai mee ah"), ("Urban Sky", "urban sky inc")])
    #expect(list.respelled("XIMEAs and MyXIMEA, XIMEA2, (XIMEA)").text == "XIMEAs and MyXIMEA, XIMEA2, (zai mee ah)")
    #expect(list.respelled("at Urban\nSky today").text == "at urban sky inc today")
    #expect(list.respelled("nothing listed here") == PronunciationList.Respelling(text: "nothing listed here",
                                                                                   spellings: []))
}

@Test func theFirstThenLongestMatchWinsAndASpellingIsNeverRespelled() {
    // "Urban Sky" beats "Sky" where both start; a spelling that holds another entry is left as given.
    let list = list([("Sky", "skai"), ("Urban Sky", "urban sky"), ("ah", "aah"), ("XIMEA", "zai mee ah")])
    #expect(list.respelled("Urban Sky and Sky and XIMEA, ah.").text == "urban sky and skai and zai mee ah, aah.")
    // An exact-case entry wins over a lower-case one matching the same words.
    let both = PronunciationList(entries: [Pronunciation(written: "us", sayAs: "uss", addedAt: day),
                                           Pronunciation(written: "US", sayAs: "you ess", addedAt: day)])
    #expect(both.respelled("US and us").text == "you ess and uss")
}

@Test func theListRoundTripsAsJSON() throws {
    let list = list([("XIMEA", "zai mee ah")])
    let decoded = try HolosJSON.decoder().decode(PronunciationList.self, from: HolosJSON.encoder().encode(list))
    #expect(decoded == list && decoded.schemaVersion == 1)
}
