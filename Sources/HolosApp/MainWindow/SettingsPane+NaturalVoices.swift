import AppKit
import HolosSynthesis

/// Settings › Reading's natural voices: a row per language pack (Download, progress, Cancel), and the texts that
/// mention them.
extension SettingsPane {
    static let readingVoiceHint = "Natural voices sound best; download them below. Apple's Premium voices come next; "
        + "add them in System Settings › Accessibility › Spoken Content"
    static let readingVoiceKeywords = ["reading voice", "text to speech", "tts", "premium", "siri", "natural"]
    static let readingNote = """
        Readings are made on this Mac: nothing is uploaded, and the only things fetched are the page you paste and, \
        when you choose Download, the natural voices. While a reading is made, its parts are kept in Application \
        Support so it can continue after a stop.
        """

    func addNaturalVoiceRows(to grid: NSGridView) {
        addRow(.naturalVoicesEnglish, "Natural voices (English)", to: grid)
        addRow(.naturalVoicesFrench, "Natural voices (French)", to: grid)
        addRowItem(.reading, .naturalVoicesEnglish,
                   keywords: ["natural", "neural", "pocket", "kyutai", "alba", "download", "voices"])
        addRowItem(.reading, .naturalVoicesFrench,
                   keywords: ["natural", "neural", "pocket", "kyutai", "estelle", "french", "download"])
    }

    /// Each pack's row; voices installed since the menu was filled (a download that just ended) are offered.
    func showNaturalVoices(_ state: SetupState) {
        for (action, pack) in [(SetupAction.naturalVoicesEnglish, NaturalVoicePack.english),
                               (.naturalVoicesFrench, .french)] {
            let row = (state.naturalVoices[pack] ?? NaturalVoiceDownload(pack: pack)).row
            set(action, row.done ? .done : row.problem ? .problem : .pending, row.detail, button: row.button,
                enabled: row.enabled)
        }
        let installed = Set(state.naturalVoices.filter { $0.value.phase == .installed }.keys)
        if installed != shownNaturalVoices {
            shownNaturalVoices = installed
            refreshReadingCard()
        }
    }
}
