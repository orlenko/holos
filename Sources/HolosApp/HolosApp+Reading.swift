import AppKit

/// The Reading section's part of quitting (docs/design.md "Reading section").
extension HolosAppDelegate {
    /// Asks what becomes of the readings being made or waiting: Keep Rendering (quit now; they continue at the next
    /// launch), Stop (they stop, with Resume), or Cancel. Keep Rendering is offered only while the list is saved.
    /// Returns false to cancel the quit. `ReadingController.quitCancelled` undoes the preparation when the quit is
    /// cancelled later.
    func readingShouldTerminate() -> Bool {
        guard readings.isBusy else {
            // Nothing is being made, but a change since the last save that worked (a Stop, a Delete) may not be
            // saved: the next launch would then find the list as it was.
            guard !readings.saveBeforeQuit() else { return true }
            let alert = NSAlert()
            alert.messageText = "The Reading list could not be saved."
            alert.informativeText = "The next launch may continue a reading you stopped or show one you deleted. "
                + "Free some space or fix the folder's permissions, then quit again.\n\n\(readings.notice ?? "")"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            NSApplication.shared.activate()
            return alert.runModal() == .alertSecondButtonReturn
        }
        let alert = NSAlert()
        let title = readings.runningTitle.map { "“\($0)”" } ?? "A reading"
        let waiting = readings.waitingCount
        alert.messageText = "\(title) is being made."
        let keep = readings.canPersist
        if keep {
            var text = "Keep Rendering quits now and continues it the next time you open Voice is Local"
            if waiting > 0 { text += ", with the \(waiting == 1 ? "reading" : "\(waiting) readings") waiting after it" }
            alert.informativeText = text + ". Stop ends it; its row offers Resume."
            alert.addButton(withTitle: "Keep Rendering")
        } else {
            alert.informativeText = "The Reading list cannot be saved now, so it cannot continue after Voice is Local "
                + "quits. Stop ends it and quits."
        }
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        let response = alert.runModal()
        switch (keep, response) {
        case (true, .alertFirstButtonReturn):
            if !readings.prepareForQuit(keep: true) {
                // The save failed just now: say so rather than promise what the next launch cannot do.
                let failed = NSAlert()
                failed.messageText = "The reading cannot continue next time."
                failed.informativeText = "The Reading list could not be saved, so the next launch shows it as "
                    + "stopped, with Resume.\n\n\(readings.notice ?? "")"
                failed.runModal()
            }
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
            if !readings.prepareForQuit(keep: false) {
                // The saved list may still ask the next launch to continue these readings (an earlier Keep
                // Rendering): quitting now would undo this Stop. The readings stay stopped, with Resume.
                readings.quitCancelled()
                let failed = NSAlert()
                failed.messageText = "Voice is Local did not quit."
                failed.informativeText = "The reading was stopped, but the Reading list could not be saved, so the "
                    + "next launch could continue it anyway. Free some space or fix the folder's permissions, then "
                    + "quit again.\n\n\(readings.notice ?? "")"
                failed.runModal()
                return false
            }
        default:
            return false
        }
        return true
    }
}
