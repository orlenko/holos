import AppKit
import HolosSynthesis
import Testing
@testable import HolosApp

/// The voice menus (`ReadingVoicePopup`): natural voices first, or where to get them.
@MainActor @Suite struct ReadingVoicePopupTests {
    @Test func theVoiceMenuListsNaturalVoicesFirstOrSaysWhereToGetThem() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        ReadingVoicePopup.fill(popup, selecting: "pocket:en:alba", installed: [.english])
        let titles = popup.itemArray.map(\.title)
        #expect(titles.first == ReadingVoicePopup.automaticTitle)
        #expect(titles.dropFirst(2).first == "Natural — Alba (English)")
        #expect(popup.titleOfSelectedItem == "Natural — Alba (English)")
        #expect(titles.contains(ReadingVoicePopup.naturalHint))
        #expect(popup.itemArray.first { $0.title == ReadingVoicePopup.naturalHint }?.isEnabled == false)
        ReadingVoicePopup.fill(popup, selecting: "pocket:fr:estelle", installed: [])
        #expect(!popup.itemArray.contains { $0.title.hasPrefix("Natural —") })
        #expect(popup.titleOfSelectedItem == ReadingVoicePopup.automaticTitle)
        ReadingVoicePopup.fill(popup, selecting: nil, installed: [.english, .french])
        #expect(!popup.itemArray.map(\.title).contains(ReadingVoicePopup.naturalHint))
    }
}
