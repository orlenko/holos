import AppKit
import HolosMeeting

@MainActor
extension ReviewWindow {
    // MARK: - Keys

    /// Playback keys, anywhere in the window but while typing in a text field (or a sheet is open): Space (except
    /// on a button focused with keyboard navigation) and K play/pause, ← and J back 5 seconds, → and L ahead 5 seconds, ⌘← the previous turn (the start of this one first),
    /// ⌘→ the next turn.
    func handlePlaybackKey(_ event: NSEvent) -> Bool {
        guard window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let special = event.specialKey
        if flags == [.command] {
            switch special {
            case .leftArrow?: previousTurn()
            case .rightArrow?: nextTurn()
            default: return false
            }
            return true
        }
        guard flags.isEmpty else { return false }
        switch special {
        case .leftArrow?:
            seek(to: player.currentTime - Self.seekStep)
            return true
        case .rightArrow?:
            seek(to: player.currentTime + Self.seekStep)
            return true
        default:
            break
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // With keyboard navigation on, Space presses the focused button, checkbox, or pop-up (K still plays).
        if key == " ", NSApplication.shared.isFullKeyboardAccessEnabled, window.firstResponder is NSButton {
            return false
        }
        switch key {
        case " ", "k":
            // Held down, it would flip on every repeat.
            if !event.isARepeat { togglePlay() }
            return true
        case "j":
            seek(to: player.currentTime - Self.seekStep)
            return true
        case "l":
            seek(to: player.currentTime + Self.seekStep)
            return true
        default:
            return false
        }
    }

    /// Seconds ← and → move the play head.
    private static let seekStep = 5.0

    /// Whether ⌘Z undoes typing (the text being edited) rather than the review's newest change: in a text field whose
    /// own undo has something to undo (`typingToUndo`, whatever the text reads now: "cat" typed over "dog" typed over
    /// "cat" is still typing), or a word's field holding text it did not open with (`unsavedText`: typing put back
    /// without its undo, after a ⇧-click widened the field or a save failed). Only an untouched field hands ⌘Z to the
    /// review.
    static func undoIsTyping(editingText: Bool, typingToUndo: Bool, unsavedText: Bool = false) -> Bool {
        editingText && (typingToUndo || unsavedText)
    }

    /// Shortcuts of the window (Holos has no main menu to carry them). Internal for tests.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let editingText = window.firstResponder is NSTextView
        if flags == [.command, .shift], key == "z" {
            return editingText && NSApplication.shared.sendAction(Selector(("redo:")), to: nil, from: window)
        }
        if flags == [.command, .shift], key == "e" {
            exportPopUp.performClick(nil)
            return true
        }
        if flags == [.command, .option], key == "s" {
            toggleSpeakers(nil)
            return true
        }
        guard flags == [.command] else { return false }
        switch key {
        case "'":
            nextUncertain()
            return true
        case "f":
            window.makeFirstResponder(searchField)
            return true
        case "e":
            // From the field being edited too: it closes unsaved, as the mode ends.
            toggleEditMode()
            return true
        case "w":
            window.performClose(nil)
            return true
        case "z":
            // In a text field with typing to undo, ⌘Z undoes the typing (it leaves the review, and its joins, alone);
            // with none (a word's field opened again after a join, say), it is the review's, as the banner says.
            let editor = window.firstResponder as? NSTextView
            let typingToUndo = editor?.undoManager?.canUndo ?? false
            let unsavedText = editor != nil && editor === turnList.editField.currentEditor()
                && turnList.wordEdit.map {
                    TranscriptWordEdit.cleaned(turnList.editField.stringValue) != TranscriptWordEdit.cleaned($0.shown)
                } == true
            if Self.undoIsTyping(editingText: editingText, typingToUndo: typingToUndo, unsavedText: unsavedText) {
                // Taken even when the field has no undo for its text: the review's change behind it stays.
                _ = NSApplication.shared.sendAction(Selector(("undo:")), to: nil, from: window)
                return true
            }
            undo()
            return true
        case "x":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.cut(_:)), to: nil, from: window)
        case "c":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: nil, from: window)
        case "v":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.paste(_:)), to: nil, from: window)
        case "a":
            return editingText
                && NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: window)
        default:
            return false
        }
    }
}
