import AppKit

/// The Reading section's part of quitting (docs/design.md "Reading section").
extension HolosAppDelegate {
    /// Asks what becomes of the readings being made or waiting: Keep Rendering (quit now; they continue at the next
    /// launch), Stop (they stop, with Resume), or Cancel. Keep Rendering is offered only while the list is saved.
    /// Returns false to cancel the quit. `ReadingController.quitCancelled` undoes the preparation when the quit is
    /// cancelled later.
    func readingShouldTerminate() -> Bool {
        guard readings.isBusy else { return true }
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
            readings.prepareForQuit(keep: true)
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
            readings.prepareForQuit(keep: false)
        default:
            return false
        }
        return true
    }
}
