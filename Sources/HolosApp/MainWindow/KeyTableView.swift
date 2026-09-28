import AppKit

/// A table whose Return opens the selected row and whose Delete (⌫, or ⌦) deletes it, both through closures (the
/// section asks for confirmation). ↑↓ and the rest of the keyboard behave as in any table.
@MainActor
final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, selectedRow >= 0 {
            switch event.keyCode {
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
