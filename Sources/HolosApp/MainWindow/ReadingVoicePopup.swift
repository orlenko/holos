import AppKit
import HolosSynthesis

/// Fills a voice pop-up: "Automatic — best voice for the text's language", then the voices that speak the user's
/// languages, then the others (`ReadingVoiceMenu`), each item's `representedObject` the voice's identifier.
@MainActor
enum ReadingVoicePopup {
    static let automaticTitle = "Automatic — best voice for the text's language"

    static let naturalHint = "Natural voices: download them in Settings › Reading"

    /// `selecting` nil: Automatic. A voice that is not installed falls back to Automatic. The natural voices of the
    /// installed packs come first (Automatic picks Alba or Estelle once they are), then Apple's voices; without any,
    /// a disabled line says where to download them.
    static func fill(_ popup: NSPopUpButton, selecting id: String?,
                     installed: Set<NaturalVoicePack> = NaturalVoicesAppState.shared.installed) {
        let items = ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: Locale.preferredLanguages)
        popup.removeAllItems()
        popup.autoenablesItems = false
        let automatic = NSMenuItem(title: automaticTitle, action: nil, keyEquivalent: "")
        popup.menu?.addItem(automatic)
        let natural = NaturalVoiceCatalog.voices(installed: installed)
        if !natural.isEmpty { popup.menu?.addItem(.separator()) }
        for voice in natural {
            let entry = NSMenuItem(title: voice.title, action: nil, keyEquivalent: "")
            entry.representedObject = voice.id
            popup.menu?.addItem(entry)
        }
        if installed.count < NaturalVoicePack.allCases.count {
            popup.menu?.addItem(.separator())
            let hint = NSMenuItem(title: naturalHint, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            popup.menu?.addItem(hint)
        }
        var previousPreferred: Bool?
        for item in items {
            if previousPreferred != item.preferred { popup.menu?.addItem(.separator()) }
            previousPreferred = item.preferred
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            entry.representedObject = item.id
            popup.menu?.addItem(entry)
        }
        if let id, let index = popup.menu?.items.firstIndex(where: { $0.representedObject as? String == id }) {
            popup.selectItem(at: index)
        } else {
            popup.select(automatic)
        }
    }
}
