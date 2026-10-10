import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// The Reading card's natural voices (`ReadingPane`): its menu, its chosen voice, its Preview's errors.
/// Serialized: the tests share the notification center's `ReadingVoices.installedChanged`, which every pane hears.
@MainActor @Suite(.serialized) struct ReadingPaneNaturalVoicesTests {
    @Test func installingNaturalVoicesKeepsTheCardsVoiceAndSpeed() async throws {
        let pane = ReadingPane(controller: ReadingController())
        let popup = pane.voicePopup
        // A voice and a speed other than Settings' defaults, as if just chosen on the card.
        let chosen = try #require(popup.catalog.items.last { $0.id != ReadingPreferences.voice })
        popup.choose(chosen.id)
        let speed = ReadingPreferences.speed == 1.3 ? 0.9 : 1.3
        pane.speedSlider.doubleValue = speed
        let browser = popup.makeBrowser()
        browser.search.stringValue = "no matching voice"
        ReadingVoices.announceInstalled()
        #expect(await eventually { browser.visibleItems.isEmpty })
        #expect(popup.selectedID == chosen.id)
        #expect(abs(pane.speedSlider.doubleValue - speed) < 0.001, "\(pane.speedSlider.doubleValue) vs \(speed)")
    }

    @Test func aNaturalVoiceBrieflyMissingIsChosenAgainWhenItsPackIsBack() async throws {
        let pane = ReadingPane(controller: ReadingController())
        let popup = pane.voicePopup
        var installed: Set<NaturalVoicePack> = [.english]
        pane.installedPacks = { installed }
        func announced() async {
            ReadingVoices.announceInstalled()
            _ = await eventually {
                popup.catalog.items.contains { $0.id == "pocket:en:alba" } == installed.contains(.english)
            }
        }
        await announced()
        let alba = try #require(popup.catalog.items.first { $0.id == "pocket:en:alba" })
        popup.choose(alba.id)
        // A reinstall: the pack is missing for a moment, and the menu shows Automatic meanwhile.
        installed = []
        await announced()
        #expect(popup.selectedID == nil)
        installed = [.english]
        await announced()
        #expect(popup.selectedID == "pocket:en:alba")
    }

    @Test func aNewPreviewClearsTheLastOnesFailure() async throws {
        let pane = ReadingPane(controller: ReadingController())
        pane.installedPacks = { [.english] }
        pane.preview.installedPacks = { [.english] }
        let popup = pane.voicePopup
        ReadingVoices.announceInstalled()
        #expect(await eventually { popup.catalog.items.contains { $0.id == "pocket:en:alba" } })
        let alba = try #require(popup.catalog.items.first { $0.id == "pocket:en:alba" })
        popup.choose(alba.id)
        pane.preview.renderNatural = { _, _, _, _ in throw HolosError.io("The sample could not be made.") }
        pane.togglePreview()
        #expect(await eventually { pane.message?.contains("could not be made") == true })
        // The next Preview starts without the old failure on the card (nothing is played: it never finishes).
        pane.preview.renderNatural = { _, _, _, _ in
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        pane.togglePreview()
        #expect(pane.message == nil)
        pane.togglePreview()
    }
}
