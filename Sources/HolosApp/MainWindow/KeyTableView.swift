import AppKit

/// A table whose Return opens the selected row and whose Delete (⌫, ⌘⌫, or ⌦) deletes it, both through closures (the
/// section asks for confirmation), whose Space can play the selected row, and whose ⌘R can rename it. ↑↓ and the
/// rest of the keyboard behave as in any table.
@MainActor
final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Space (History: play or pause the selected dictation's audio); returns false to let the table have it.
    var onSpace: (() -> Bool)?
    /// ⌘R (Meetings: rename the selected meeting).
    var onRename: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, selectedRow >= 0, let onRename,
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onRename()
            return
        }
        // ⌘⌫ deletes as ⌫ does (the Finder's Move to Trash).
        if modifiers == .command, selectedRow >= 0, event.keyCode == 51, let onDelete {
            onDelete()
            return
        }
        if modifiers.isEmpty, selectedRow >= 0 {
            switch event.keyCode {
            case 49:  // Space
                if let onSpace, onSpace() { return }
            case 36, 76:  // Return, keypad Enter
                if let onReturn {
                    onReturn()
                    return
                }
            case 51, 117:  // Delete, Forward Delete
                if let onDelete {
                    onDelete()
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
