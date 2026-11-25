import Foundation
import HolosCore
import HolosDesktop

extension HolosAppDelegate {
    var dictationShortcuts: DictationShortcuts { DictationShortcutPreferences().shortcuts }
    var shortcutTitle: String {
        let choices = dictationShortcuts
        return switch (choices.live, choices.accurate) {
        case (.off, .off): "a shortcut configured in Settings"
        case (.off, let accurate): accurate.title
        case (let live, .off): live.title
        case (let live, let accurate): "\(live.title) for Live or \(accurate.title) for Accurate"
        }
    }

    var canChangeShortcut: Bool { !isBusy && !enabling && !installingAssets }

    func changeShortcut(_ mode: DictationShortcutMode, to choice: HotkeyChoice) {
        let current = dictationShortcuts
        guard canChangeShortcut, let next = current.changing(mode, to: choice), next != current else {
            updateSettings()
            return
        }
        let wasEnabled = enabled
        if wasEnabled { disable(persist: next.live == .off && next.accurate == .off) }
        DictationShortcutPreferences().save(next)
        if wasEnabled, canEnableDictationShortcuts() { enable() }
        else { updateSettings() }
    }

    func canEnableDictationShortcuts() -> Bool {
        let choices = dictationShortcuts
        if choices.live == .off, choices.accurate == .off {
            show("Choose a Live or Accurate shortcut in Dictation settings.")
        }
        return choices.canEnable(installingLiveAssets: installingAssets)
    }

    func liveAssetsForEnabling(locale: String, backend: SpeechBackend) async -> String? {
        guard dictationShortcuts.live != .off, !installingAssets else { return nil }
        do {
            return try await checkDictationAssets(locale: locale, backend: backend)
        } catch {
            return "unknown"
        }
    }

    func canBeginDictation(_ mode: DictationShortcutMode) -> Bool {
        guard !mode.canBegin(liveAssetState: assetState, installingLiveAssets: installingAssets) else { return true }
        let hint = installingAssets ? "The Live speech model is downloading."
            : "Install the Live speech model for \(languageName) in Dictation settings."
        show(hint, attention: true)
        if !installingAssets { refreshAssetState() }
        return false
    }

    func makeAccurateDictationWorker(mode: DictationShortcutMode) -> AccurateDictationWorker? {
        guard mode == .accurate else { return nil }
        return AccurateDictationWorker(model: AccurateDictationSettings().model, locale: locale,
                                       vocabulary: controller.contextualStrings)
    }
}

struct DictationShortcutPreferences {
    var defaults: UserDefaults = .standard

    var shortcuts: DictationShortcuts {
        let live = defaults.string(forKey: "shortcut").flatMap(HotkeyChoice.init) ?? .rightOption
        let accurate = defaults.string(forKey: "accurateDictationShortcut").flatMap(HotkeyChoice.init) ?? .rightCommandOption
        return DictationShortcuts(live: live, accurate: accurate)
    }

    func save(_ shortcuts: DictationShortcuts) {
        defaults.set(shortcuts.live.rawValue, forKey: "shortcut")
        defaults.set(shortcuts.accurate.rawValue, forKey: "accurateDictationShortcut")
    }
}

extension DictationShortcuts {
    func canInstallLiveModel(whileEnabled: Bool) -> Bool { !whileEnabled || accurate != .off }

    /// Accurate can be restored after sleep while a Live-only download is still running.
    func canEnable(installingLiveAssets: Bool) -> Bool {
        accurate != .off || (live != .off && !installingLiveAssets)
    }
}

extension DictationShortcutMode {
    func canBegin(liveAssetState: String?, installingLiveAssets: Bool) -> Bool {
        self == .accurate || (!installingLiveAssets && liveAssetState == "installed")
    }
}
