import AppKit
import HolosMeeting

extension MeetingsPane {
    var onStartRecording: (() -> Void)? {
        get { listState.onStartRecording }
        set { listState.onStartRecording = newValue; updateButtons() }
    }

    @objc func startRecording() {
        guard canStartRecording else { return }
        listState.onStartRecording?()
    }

    /// A meeting's Rename action edits its name without returning to a hidden list row.
    func renameOnMeetingScreen(_ summary: SessionSummary) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let edit = MeetingRenameEdit(summary)
        let field = NSTextField(string: edit.text)
        field.frame.size = NSSize(width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename Meeting"
        alert.informativeText = "Leave the name empty to use the generated title or default name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let request = edit.request(typed: field.stringValue) else { return }
            self?.runRename?(summary, request)
        }
        window.attachedSheet?.makeFirstResponder(field)
    }

    /// Actions are rebuilt at each click so processing and destructive-action availability stay current.
    func advancedMenu(sessionID: String) -> NSMenu? {
        guard let summary = activeMeeting, summary.id == sessionID else { return nil }
        let menu = NSMenu()
        fill(menu, summary: summary)
        return menu.items.first { $0.title == "Advanced" }?.submenu
    }
}
