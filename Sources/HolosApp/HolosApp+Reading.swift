import AppKit

/// The Reading section's part of quitting (docs/design.md "Reading section").
extension HolosAppDelegate {
    /// Asks what becomes of the readings being made or waiting: Keep Rendering (quit now; they continue at the next
    /// launch), Stop (they stop, with Resume), or Cancel. Returns nil to cancel the quit, else whether the readings
    /// were prepared for it (`ReadingController.quitCancelled` undoes that if the quit is cancelled later).
    func readingShouldTerminate() -> Bool? {
        guard readings.isBusy else { return false }
        let alert = NSAlert()
        let title = readings.runningTitle.map { "“\($0)”" } ?? "A reading"
        let waiting = readings.waitingCount
        alert.messageText = "\(title) is being made."
        var text = "Keep Rendering quits now and continues it the next time you open Voice is Local"
        if waiting > 0 { text += ", with the \(waiting == 1 ? "reading" : "\(waiting) readings") waiting after it" }
        text += ". Stop ends it; its row offers Resume."
        alert.informativeText = text
        alert.addButton(withTitle: "Keep Rendering")
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            readings.prepareForQuit(keep: true)
        case .alertSecondButtonReturn:
            readings.prepareForQuit(keep: false)
        default:
            return nil
        }
        return true
    }
}
