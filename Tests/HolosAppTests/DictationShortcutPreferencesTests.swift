import AppKit
import HolosDesktop
import Testing
@testable import HolosApp

@Test func upgradingKeepsTheSavedLiveShortcutAndAssignsAnAccurateShortcut() throws {
    let suite = "holos.tests.shortcuts.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("controlOptionSpace", forKey: "shortcut")
    defaults.set(true, forKey: "dictationAfterRelease")
    defaults.set("parakeet", forKey: "accurateDictationModel")

    let preferences = DictationShortcutPreferences(defaults: defaults)
    #expect(preferences.shortcuts == .init(live: .controlOptionSpace, accurate: .rightCommandOption))
    #expect(AccurateDictationSettings(defaults).model == .parakeet)
    let changed = try #require(preferences.shortcuts.changing(.live, to: .off))
    preferences.save(changed)
    #expect(DictationShortcutPreferences(defaults: defaults).shortcuts == changed)
}

@Test @MainActor func settingsRouteEachShortcutPickerToItsOwnMode() throws {
    var changes: [(DictationShortcutMode, HotkeyChoice)] = []
    let pane = SettingsPane(callbacks: .init(perform: { _ in }, opacity: { _ in }, language: { _ in },
                                            shortcut: { changes.append(($0, $1)) }, retention: { _ in },
                                            appearance: { _ in }))
    _ = pane.view
    let live = pane.shortcutPopup
    let accurate = pane.accurateShortcutPopup
    for popup in [live, accurate] {
        #expect(popup.itemTitles.contains("Off"))
        #expect(popup.itemTitles.contains("Right Command + Right Option"))
    }
    live.selectItem(withTitle: "Control–Option–Space")
    accurate.selectItem(withTitle: "Control–Shift–Space")
    pane.shortcutChosen(live)
    pane.shortcutChosen(accurate)
    #expect(changes.map(\.0) == [.live, .accurate])
    #expect(changes.map(\.1) == [.controlOptionSpace, .controlShiftSpace])
}

@Test func accurateRemainsAvailableDuringLiveSetupAndCanRestoreAfterWake() {
    #expect(DictationShortcuts().canInstallLiveModel(whileEnabled: true))
    #expect(!DictationShortcuts(accurate: .off).canInstallLiveModel(whileEnabled: true))
    #expect(DictationShortcuts(accurate: .off).canInstallLiveModel(whileEnabled: false))
    #expect(DictationShortcuts().canEnable(installingLiveAssets: true))
    #expect(DictationShortcuts(live: .off).canEnable(installingLiveAssets: true))
    #expect(!DictationShortcuts(accurate: .off).canEnable(installingLiveAssets: true))
    #expect(!DictationShortcuts(live: .off, accurate: .off).canEnable(installingLiveAssets: false))
    #expect(DictationShortcutMode.accurate.canBegin(liveAssetState: nil, installingLiveAssets: true))
    #expect(!DictationShortcutMode.live.canBegin(liveAssetState: "installed", installingLiveAssets: true))
    #expect(DictationShortcutMode.live.canBegin(liveAssetState: "installed", installingLiveAssets: false))
}
