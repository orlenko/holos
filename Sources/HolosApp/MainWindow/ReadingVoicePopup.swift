import AppKit
import HolosSynthesis

/// Fills a voice pop-up: "Automatic — best voice for the text's language", then the voices that speak the user's
/// languages, then the others (`ReadingVoiceMenu`), each item's `representedObject` the voice's identifier.
@MainActor
enum ReadingVoicePopup {
    static let automaticTitle = "Automatic — best voice for the text's language"

    /// `selecting` nil: Automatic. A voice that is not installed falls back to Automatic.
    static func fill(_ popup: NSPopUpButton, selecting id: String?) {
        let items = ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: Locale.preferredLanguages)
        popup.removeAllItems()
        let automatic = NSMenuItem(title: automaticTitle, action: nil, keyEquivalent: "")
        popup.menu?.addItem(automatic)
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
