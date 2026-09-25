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

@Test func dictationLanguageNamesAndCodes() {
    let display = Locale(identifier: "en-US")
    #expect(DictationLanguage.name(of: "fr-CA", in: display) == "French (Canada)")
    #expect(DictationLanguage.name(of: "en_CA", in: display) == "English (Canada)")
    #expect(DictationLanguage.name(of: "fr-CA", in: Locale(identifier: "fr-CA")) == "français (Canada)")
    #expect(DictationLanguage.languageCode(of: "fr-CA") == "fr")
    #expect(DictationLanguage.languageCode(of: "yue_CN") == "yue")
    #expect(DictationLanguage.identifier("en_CA") == "en-CA")
}
