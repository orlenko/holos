import Foundation
import HolosCore
import Testing

// A meeting's languages (docs/meeting-design.md §4.14): the list the recorder, the import, and post-processing take,
// and the optional fields that record them.

@Test func meetingLanguagesKeepEachLanguageOnceInOrder() {
    #expect(DictationLanguage.meetingLanguages([" fr_CA", "", "en-CA", "fr-CA"]) == ["fr-CA", "en-CA"])
    // Another region of a language already listed is left out; so is anything past three.
    #expect(DictationLanguage.meetingLanguages(["fr-CA", "fr-FR", "en-CA", "es-ES", "de-DE"])
        == ["fr-CA", "en-CA", "es-ES"])
    // Chinese scripts are different languages.
    #expect(DictationLanguage.meetingLanguages(["zh-CN", "zh-TW", "zh-SG"]) == ["zh-CN", "zh-TW"])
    #expect(DictationLanguage.meetingLanguages([]) == [])
}

@Test func sameLanguageComparesLanguageAndScript() {
    #expect(DictationLanguage.sameLanguage("fr-CA", "fr_FR"))
    #expect(DictationLanguage.sameLanguage("en-CA", "en-CA"))
    #expect(!DictationLanguage.sameLanguage("fr-CA", "en-CA"))
    #expect(!DictationLanguage.sameLanguage("zh-CN", "zh-TW"))
    #expect(!DictationLanguage.sameLanguage("", ""))
}

@Test func meetingLanguagesProblemExplainsARefusedList() {
    #expect(DictationLanguage.meetingLanguagesProblem(["fr-CA", "en-CA"]) == nil)
    #expect(DictationLanguage.meetingLanguagesProblem(["en-CA"]) == nil)
    #expect(DictationLanguage.meetingLanguagesProblem([" ", ""]) == "Name at least one language, like fr-CA.")
    #expect(DictationLanguage.meetingLanguagesProblem(["fr-CA", "en-CA", "fr_CA"]) == "fr-CA is listed twice.")
    #expect(DictationLanguage.meetingLanguagesProblem(["fr-CA", "fr-FR"])
        == "fr-CA and fr-FR are the same language; list one of them.")
    #expect(DictationLanguage.meetingLanguagesProblem(["fr-CA", "en-CA", "es-ES", "de-DE"])
        == "A meeting can have at most 3 languages.")
}

@Test func languageListsSplitAtCommas() {
    #expect(DictationLanguage.list("fr-CA, en-CA,,es-ES ") == ["fr-CA", "en-CA", "es-ES"])
    #expect(DictationLanguage.list("") == [])
}

@Test func languageFieldsAreLeftOutWhenUnset() throws {
    // Sessions and transcripts in one language encode as before.
    let info = MeetingInfo(sessionID: "S", mode: .inPerson, othersInRoom: false,
                           createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(!String(decoding: try HolosJSON.encoder().encode(info), as: UTF8.self).contains("languages"))
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 1_790_000_000), source: "s",
                                locale: "fr-CA", backend: .speech,
                                segments: [TranscriptSegment(id: "A", start: 0, end: 1, text: "bonjour")])
    let encoded = String(decoding: try HolosJSON.encoder().encode(transcript), as: UTF8.self)
    #expect(!encoded.contains("language"))

    var merged = transcript
    merged.languages = ["fr-CA", "en-CA"]
    merged.segments[0].language = "fr-CA"
    let decoded = try HolosJSON.decoder().decode(Transcript.self, from: HolosJSON.encoder().encode(merged))
    #expect(decoded == merged)
    var bilingual = info
    bilingual.languages = ["fr-CA", "en-CA"]
    #expect(try HolosJSON.decoder().decode(MeetingInfo.self, from: HolosJSON.encoder().encode(bilingual)) == bilingual)
}
