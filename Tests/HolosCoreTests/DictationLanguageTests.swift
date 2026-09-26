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

@Test func languageIsUnknownUntilTheSupportedListLoadsUnlessSaved() {
    func resolve(_ saved: String?, _ supported: [String]?) -> String? {
        DictationLanguage.resolved(saved: saved, supported: supported, preferredLanguages: ["fr-CA"], region: "CA")
    }
    // Not loaded yet: a saved choice stands; the default is not known (not en-CA).
    #expect(resolve(nil, nil) == nil)
    #expect(resolve("", nil) == nil)
    #expect(resolve("de-DE", nil) == "de-DE")
    // Loaded: the default follows the preferred languages; a failed load (empty) falls back to en-CA.
    #expect(resolve(nil, ["en_CA", "fr_CA"]) == "fr-CA")
    #expect(resolve(nil, []) == "en-CA")
    #expect(resolve("de-DE", ["en_CA", "fr_CA"]) == "de-DE")
}

@Test func meetingLanguagesDefaultToTheDictationLanguageOnceKnown() {
    #expect(DictationLanguage.meetingLocales(saved: ["es-MX"], dictation: nil) == ["es-MX"])
    #expect(DictationLanguage.meetingLocales(saved: ["", "es-MX"], dictation: "fr-CA") == ["es-MX"])
    #expect(DictationLanguage.meetingLocales(saved: [""], dictation: "fr-CA") == ["fr-CA"])
    #expect(DictationLanguage.meetingLocales(saved: nil, dictation: "fr-CA") == ["fr-CA"])
    #expect(DictationLanguage.meetingLocales(saved: [], dictation: nil) == nil)
    #expect(DictationLanguage.meetingLocales(saved: nil, dictation: nil) == nil)
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

@Test func identifiersAreOneSpellingPerLocale() {
    // Case variants of a valid BCP 47 tag are the same locale, so they compare equal once canonical.
    #expect(DictationLanguage.identifier("en-ca") == "en-CA")
    #expect(DictationLanguage.identifier("EN_ca") == "en-CA")
    #expect(DictationLanguage.identifier("zh-hans-cn") == "zh-Hans-CN")
    #expect(DictationLanguage.identifier("ZH_HANT_tw") == "zh-Hant-TW")
    #expect(DictationLanguage.identifier("es-419") == "es-419")
    #expect(DictationLanguage.identifier("yue_CN") == "yue-CN")
    #expect(DictationLanguage.identifier("fr") == "fr")
    #expect(DictationLanguage.identifier("") == "")
    #expect(DictationLanguage.identifier("de-DE-u-CO-phonebk") == "de-DE-u-co-phonebk")
    #expect(DictationLanguage.identifier("en_US@rg=CAzzzz") == "en-US@rg=CAzzzz")
    // Every comparison built on it treats the spellings alike.
    #expect(DictationLanguage.meetingLanguages(["fr-ca", "en-CA", "EN-ca"]) == ["fr-CA", "en-CA"])
    #expect(DictationLanguage.meetingLanguagesProblem(["en-CA", "en-ca"]) == "en-CA is listed twice.")
}
