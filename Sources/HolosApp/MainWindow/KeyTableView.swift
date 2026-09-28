import AppKit

/// A table whose Return opens the selected row and whose Delete (⌫, or ⌦) deletes it, both through closures (the
/// section asks for confirmation), and Space through a closure when one is set. ↑↓ and the rest of the keyboard behave as
/// in any table.
@MainActor
final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Space (Reading: play or pause); nil keeps the table's own Space.
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, selectedRow >= 0 {
            switch event.keyCode {
            case 49:  // Space
                if let onSpace {
                    onSpace()
                    return
                }
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
