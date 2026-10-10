import AppKit
import HolosSynthesis
import Testing
@testable import HolosApp

@MainActor @Suite struct ReadingVoicePopupTests {
    private let voices = [
        VoiceDescriptor(id: "fr.amelie", name: "Amélie", language: "fr-FR", quality: "enhanced"),
        VoiceDescriptor(id: "en.ava", name: "Ava", language: "en-US", quality: "premium"),
    ]

    @Test func aMissingVoiceFallsBackWithoutCommittingAnotherPreference() {
        let popup = ReadingVoicePopup(frame: .zero)
        var choices: [String?] = []
        popup.onChoose = { choices.append($0) }
        ReadingVoicePopup.fill(popup, selecting: "pocket:en:alba", installed: [.english], voices: voices)
        #expect(popup.selectedID == "pocket:en:alba")
        #expect(popup.title == "Alba (Natural)")
        ReadingVoicePopup.fill(popup, selecting: "pocket:en:alba", installed: [], voices: voices)
        #expect(popup.selectedID == nil)
        #expect(popup.title == ReadingVoicePopup.automaticTitle)
        popup.choose("pocket:en:alba")
        #expect(choices.isEmpty)
        ReadingVoicePopup.fill(popup, selecting: "pocket:en:alba", installed: [.english], voices: voices)
        #expect(popup.selectedID == "pocket:en:alba")
        popup.choose(nil)
        #expect(choices.count == 1 && choices[0] == nil)
    }

    @Test func refreshingAnOpenPickerKeepsItsQueryAndLanguageWithoutChangingItsChoice() throws {
        let popup = ReadingVoicePopup(frame: .zero)
        ReadingVoicePopup.fill(popup, selecting: "en.ava", installed: [], voices: voices)
        let browser = popup.makeBrowser()
        browser.search.stringValue = "amelie"
        let language = try #require(browser.languagePopup.itemArray.first { $0.representedObject as? String == "fr" })
        browser.languagePopup.select(language)
        browser.refreshResults()
        var choices: [String?] = []
        popup.onChoose = { choices.append($0) }
        ReadingVoicePopup.fill(popup, selecting: "en.ava", installed: [.french], voices: voices)
        #expect(browser.search.stringValue == "amelie")
        #expect(browser.languagePopup.selectedItem?.representedObject as? String == "fr")
        #expect(browser.visibleItems.map(\.id) == ["fr.amelie"])
        #expect(popup.selectedID == "en.ava")
        #expect(choices.isEmpty)
        browser.chooseHighlighted()
        #expect(choices == ["fr.amelie"])
        #expect(popup.selectedID == "fr.amelie")
    }
}
