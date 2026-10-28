import AppKit
import HolosSynthesis

/// Settings › Reading's natural voices: a row per language pack (Download, progress, Cancel), the Pronunciations row,
/// the read-aloud shortcut's row, and the texts that mention them.
extension SettingsPane {
    static let readingVoiceHint = "Natural voices sound best; download them below. Apple's Premium voices come next; "
        + "add them in System Settings › Accessibility › Spoken Content"
    static let readingVoiceKeywords = ["reading voice", "text to speech", "tts", "premium", "siri", "natural"]
    static let readingNote = """
        Readings are made on this Mac: nothing is uploaded, and the only things fetched are the page you paste and, \
        when you choose Download, the natural voices. While a reading is made, its parts are kept in Application \
        Support so it can continue after a stop.
        """

    func addVoiceRows(to grid: NSGridView) {
        addRow(.naturalVoicesEnglish, "Natural voices (English)", to: grid)
        addRow(.naturalVoicesFrench, "Natural voices (French)", to: grid)
        addRowItem(.reading, .naturalVoicesEnglish,
                   keywords: ["natural", "neural", "pocket", "kyutai", "alba", "download", "voices"])
        addRowItem(.reading, .naturalVoicesFrench,
                   keywords: ["natural", "neural", "pocket", "kyutai", "estelle", "french", "download"])
        addRow(.pronunciations, "Pronunciations", to: grid)
        set(.pronunciations, .pending, "How every voice says names and jargon it does not know (XIMEA as \"zay mee "
            + "ah\")", button: "Edit…")
        rows[.pronunciations]?.icon.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        rows[.pronunciations]?.icon.contentTintColor = .secondaryLabelColor
        addRowItem(.reading, .pronunciations,
                   keywords: ["pronunciation", "pronounce", "say as", "names", "jargon", "phonetic", "spelling"])
        addRow(.readSelection, "Read the selection aloud", to: grid)
        addRowItem(.reading, .readSelection,
                   keywords: ["read aloud", "selection", "selected text", "shortcut", "hotkey", "speak", "listen"])
        showReadSelection()
    }

    /// The read-aloud shortcut's row (`ReadAloud`): on, off, or why it does not work.
    func showReadSelection() {
        guard let readAloud = ReadAloud.shared else { return }
        let chord = readAloud.chordTitle
        let what = "the text selected in any app is read aloud with the default voice and speed, and kept in "
            + "the Reading list"
        if !readAloud.isOn {
            set(.readSelection, .pending, "Off. Turn it on to use \(chord): " + what + ".", button: "Turn On")
        } else if let problem = readAloud.problem {
            set(.readSelection, .problem, problem, button: "Turn Off")
        } else if !AXIsProcessTrusted() {
            set(.readSelection, .problem, "\(chord) needs Accessibility access to read the selection (Permissions, "
                + "above).", button: "Turn Off")
        } else {
            set(.readSelection, .done, "Press \(chord): " + what + ".", button: "Turn Off")
        }
    }

    /// Each pack's row; voices installed since the menu was filled (a download that just ended) are offered. While one
    /// pack is being installed (here, or by another process), the other's Download waits (one model at a time).
    func showNaturalVoices(_ state: SetupState) {
        let busy = state.naturalVoices.values.contains { $0.isRunning || $0.phase == .otherProcess }
        for (action, pack) in [(SetupAction.naturalVoicesEnglish, NaturalVoicePack.english),
                               (.naturalVoicesFrench, .french)] {
            let download = state.naturalVoices[pack] ?? NaturalVoiceDownload(pack: pack)
            let row = download.row
            set(action, row.done ? .done : row.problem ? .problem : .pending, row.detail, button: row.button,
                enabled: row.enabled && (download.isRunning || download.phase == .otherProcess || !busy))
        }
        showReadSelection()
        let installed = Set(state.naturalVoices.filter { $0.value.phase == .installed }.keys)
        if installed != shownNaturalVoices {
            shownNaturalVoices = installed
            refreshReadingCard()
        }
    }
}
