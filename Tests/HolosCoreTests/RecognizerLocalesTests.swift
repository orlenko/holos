import Foundation
import Testing
@testable import HolosCore

/// Lists shaped like Apple's: `SpeechTranscriber` has English and French, `DictationTranscriber` has those and more
/// (Russian, Ukrainian, another English region), spelled with underscores.
private let recognizers = RecognizerLocales(
    speech: ["en_CA", "en_US", "fr_CA", "fr_FR", "de_DE"],
    dictation: ["en_CA", "en_US", "en_IN", "fr_CA", "fr_FR", "de_DE", "ru_RU", "uk_UA"])

@Test func aLanguageBothRecognizersHaveUsesTheSpeechTranscriber() {
    #expect(recognizers.backend(for: "en-CA") == .speech)
    #expect(recognizers.backend(for: "fr_FR") == .speech)
    #expect(recognizers.backend(for: "de-de") == .speech)
}

@Test func aLanguageOnlyTheDictationTranscriberHasUsesIt() {
    #expect(recognizers.backend(for: "ru-RU") == .dictation)
    #expect(recognizers.backend(for: "uk_UA") == .dictation)
    // A region only it has, of a language both have.
    #expect(recognizers.backend(for: "en-IN") == .dictation)
}

@Test func aLanguageWithoutTheRegionGoesByLanguageSpeechFirst() {
    #expect(recognizers.backend(for: "ru") == .dictation)
    #expect(recognizers.backend(for: "uk") == .dictation)
    #expect(recognizers.backend(for: "fr") == .speech)
    #expect(recognizers.backend(for: "en-GB") == .speech)
}

@Test func anUnknownLanguageOrUnknownListsKeepTheSpeechTranscriber() {
    #expect(recognizers.backend(for: "ja-JP") == .speech)
    #expect(recognizers.backend(for: "") == .speech)
    #expect(RecognizerLocales.unknown.backend(for: "ru-RU") == .speech)
    #expect(RecognizerLocales.unknown.isEmpty)
    #expect(!recognizers.isEmpty)
}

@Test func dictationOffersBothListsAndMeetingsTheSpeechOne() {
    #expect(recognizers.dictationLocales
        == ["de-DE", "en-CA", "en-IN", "en-US", "fr-CA", "fr-FR", "ru-RU", "uk-UA"])
    #expect(recognizers.speech == ["de-DE", "en-CA", "en-US", "fr-CA", "fr-FR"])
    let display = Locale(identifier: "en-US")
    #expect(DictationLanguage.groups(recognizers.dictationLocales, in: display)
        == [["en-CA", "en-IN", "en-US"], ["fr-CA", "fr-FR"], ["de-DE", "ru-RU", "uk-UA"]])
}

@Test func theDefaultDictationLanguagePrefersTheSpeechTranscriber() {
    func pick(_ preferred: [String], region: String? = nil) -> String {
        recognizers.preferredDictation(preferredLanguages: preferred, region: region)
    }
    // English in India: the dictation transcriber has en-IN, but English is a speech language, so its region
    // follows the speech list.
    #expect(pick(["en-IN"]) == "en-US")
    #expect(pick(["en"], region: "CA") == "en-CA")
    #expect(pick(["fr-CH"]) == "fr-FR")
    // A language only the dictation transcriber has.
    #expect(pick(["ru-RU", "en-CA"]) == "ru-RU")
    #expect(pick(["uk"], region: "CA") == "uk-UA")
    // None of them: the standard one.
    #expect(pick(["ja-JP"]) == DictationLanguage.standard)
    #expect(RecognizerLocales.unknown.preferredDictation(preferredLanguages: ["ru-RU"]) == DictationLanguage.standard)
}

@Test func aSavedDictationLanguageStandsAndTheDefaultWaitsForTheLists() {
    func resolve(_ saved: String?, _ lists: RecognizerLocales?) -> String? {
        DictationLanguage.resolved(saved: saved, recognizers: lists, preferredLanguages: ["uk-UA"], region: "CA")
    }
    #expect(resolve(nil, nil) == nil)
    #expect(resolve("ru-RU", nil) == "ru-RU")
    #expect(resolve(nil, recognizers) == "uk-UA")
    #expect(resolve(nil, .unknown) == DictationLanguage.standard)
}

@Test func meetingsStandInWithASpeechLanguageForADictationOnlyOne() {
    func meeting(_ dictation: String) -> String {
        recognizers.meetingLanguage(dictation: dictation, preferredLanguages: ["ru-RU", "fr-CA"], region: "CA")
    }
    #expect(meeting("fr-CA") == "fr-CA")
    #expect(meeting("en-US") == "en-US")
    #expect(meeting("ru-RU") == "fr-CA")
    #expect(meeting("uk-UA") == "fr-CA")
}
