import AppKit
import HolosContent

/// Read the selection aloud (docs/design.md "Read the selection aloud"): the shortcut, its readings' playback, the
/// menu bar menu's Stop Reading Aloud, and Settings › Reading's row.
extension HolosAppDelegate {
    /// The app's one, made on first use with the Reading list.
    var readAloud: ReadAloud {
        if let made = ReadAloud.shared { return made }
        let made = ReadAloud(readings: readings)
        ReadAloud.shared = made
        return made
    }

    /// At launch, once the Reading list is read: readings the shortcut added play when made; the menu and Settings
    /// follow its state; the shortcut is registered when on.
    func startReadAloud() {
        let readAloud = readAloud
        readings.onEnded = { [weak readAloud] id in readAloud?.readingEnded(id) }
        readAloud.onChange = { [weak self] in self?.rebuildMenu() }
        readAloud.start()
    }

    /// The menu bar menu's item while a reading the shortcut added plays or waits.
    func addReadAloudItem(to menu: NSMenu) {
        guard readAloud.isActive else { return }
        menu.addItem(item("Stop Reading Aloud", #selector(stopReadingAloud)))
    }

    @objc func stopReadingAloud() {
        readAloud.stop()
    }

    /// The Reading section, playing through the shortcut's player so its readings show there too.
    func makeReadingPane() -> ReadingPane {
        let pane = ReadingPane(controller: readings, player: readAloud.player)
        pane.playsWithoutWindow = { [weak self] id in self?.readAloud.playing == id }
        return pane
    }
}
