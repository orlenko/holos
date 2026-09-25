import Foundation
import Testing
@testable import HolosCore

@Test func dictationLanguagesListEnglishThenFrenchThenTheRest() {
    let display = Locale(identifier: "en-US")
    let supported = ["de_DE", "fr_FR", "en_US", "ja_JP", "fr_CA", "en_CA", "en_GB", "es_MX", "fr-CA"]
    #expect(DictationLanguage.ordered(supported, in: display)
        == ["en-CA", "en-GB", "en-US", "fr-CA", "fr-FR", "de-DE", "ja-JP", "es-MX"])
    #expect(DictationLanguage.groups(supported, in: display)
        == [["en-CA", "en-GB", "en-US"], ["fr-CA", "fr-FR"], ["de-DE", "ja-JP", "es-MX"]])
    #expect(DictationLanguage.groups(["de_DE", "en_US"], in: display) == [["en-US"], ["de-DE"]])
}

@Test func defaultLanguageFollowsThePreferredLanguages() {
    let supported = ["de_DE", "en_AU", "en_CA", "en_GB", "en_US", "fr_BE", "fr_CA", "fr_CH", "fr_FR", "zh_CN",
                     "zh_TW", "es_MX", "es_ES"]
    func pick(_ preferred: [String], region: String? = nil, from list: [String] = supported) -> String {
        DictationLanguage.preferred(supported: list, preferredLanguages: preferred, region: region)
    }
    // Exact match first.
    #expect(pick(["fr-CH", "en-CA"]) == "fr-CH")
    #expect(pick(["en-GB"]) == "en-GB")
    #expect(pick(["en_US"]) == "en-US")
    // Same language, closest region: the language's main region when its own is missing.
    #expect(pick(["fr-CH"], from: ["fr_CA", "fr_FR", "en_CA"]) == "fr-FR")
    #expect(pick(["fr-CH"], from: ["fr_CA", "en_CA"]) == "fr-CA")
    #expect(pick(["de-AT"]) == "de-DE")
    // A preference without a region takes the system region, else the main one.
    #expect(pick(["fr"], region: "CA") == "fr-CA")
    #expect(pick(["fr"], region: "US") == "fr-FR")
    #expect(pick(["es"], region: "MX") == "es-MX")
    // The script decides between variants of one language.
    #expect(pick(["zh-Hant-HK"]) == "zh-TW")
    #expect(pick(["zh-Hans"]) == "zh-CN")
    // A later preferred language is used only when an earlier one has no variant at all.
    #expect(pick(["ja-JP", "fr-CA"]) == "fr-CA")
    // en-CA only when nothing matches, or the supported list is not known.
    #expect(pick(["ja-JP"]) == "en-CA")
    #expect(pick(["fr-CA"], from: []) == "en-CA")
    #expect(pick([]) == "en-CA")
}

@Test func dictationLanguageNamesAndCodes() {
    let display = Locale(identifier: "en-US")
    #expect(DictationLanguage.name(of: "fr-CA", in: display) == "French (Canada)")
    #expect(DictationLanguage.name(of: "en_CA", in: display) == "English (Canada)")
    #expect(DictationLanguage.name(of: "fr-CA", in: Locale(identifier: "fr-CA")) == "français (Canada)")
    #expect(DictationLanguage.languageCode(of: "fr-CA") == "fr")
    #expect(DictationLanguage.languageCode(of: "yue_CN") == "yue")
    #expect(DictationLanguage.identifier("en_CA") == "en-CA")
}
