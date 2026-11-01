import AppKit
import HolosAppModel

extension HolosAppDelegate {
    /// Delete Audio on one meeting (a row's button or the menu): asks first unless the user chose "Don't ask again"
    /// (`MeetingAudioPreferences`). Deleting audio of several meetings always asks, since it names what is skipped.
    func confirmDeleteAudio(_ name: String, preferences: MeetingAudioPreferences = .init()) -> Bool {
        guard preferences.confirmsDeletion else { return true }
        let alert = NSAlert()
        alert.messageText = "Delete the audio of “\(name)”?"
        alert.informativeText = "The audio is deleted for good. The transcript, speaker labels, and transcript files stay."
        alert.addButton(withTitle: "Delete Audio")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { preferences.confirmsDeletion = false }
        return true
    }
}
